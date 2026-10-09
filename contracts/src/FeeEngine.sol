// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";

/// @title FeeEngine
/// @notice Fee math and protocol fee policy, with every cap hard-coded:
///         management fee <= 2%/yr, performance fee <= 25% over the high-water mark,
///         protocol cut <= 30% of fees charged. Verified managers (staked project token) pay a lower cut.
///         Fees are taken by minting vault shares, so no asset ever leaves a vault to pay a fee.
contract FeeEngine is AccessControl {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    uint16 public constant MAX_MANAGEMENT_FEE_BPS = 200;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2_500;
    uint16 public constant MAX_PROTOCOL_CUT_BPS = 3_000;
    /// @dev Upper bound on management fee per accrual so share math can never explode.
    uint256 internal constant MAX_MGMT_FRACTION = WAD / 10;

    uint16 public protocolCutBps = 1_500;
    uint16 public verifiedProtocolCutBps = 1_000;
    address public projectHooks;

    struct FeeInput {
        uint256 totalAssets;
        uint256 supply;
        uint256 virtualShares; // 10 ** decimalsOffset of the vault
        uint256 highWaterMark; // normalized share price (1e18 = initial price)
        uint256 elapsed;
        bool navFresh;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
    }

    struct FeeOutput {
        uint256 managementShares;
        uint256 performanceShares;
        uint256 newHighWaterMark;
    }

    event ProtocolCutSet(uint16 cutBps, uint16 verifiedCutBps);
    event ProjectHooksSet(address indexed hooks);

    error InvalidCut();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setProtocolCut(uint16 cutBps, uint16 verifiedCutBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cutBps > MAX_PROTOCOL_CUT_BPS || verifiedCutBps > cutBps) revert InvalidCut();
        protocolCutBps = cutBps;
        verifiedProtocolCutBps = verifiedCutBps;
        emit ProtocolCutSet(cutBps, verifiedCutBps);
    }

    function setProjectHooks(address hooks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        projectHooks = hooks;
        emit ProjectHooksSet(hooks);
    }

    function validateFees(uint16 managementFeeBps, uint16 performanceFeeBps) public pure returns (bool) {
        return managementFeeBps <= MAX_MANAGEMENT_FEE_BPS && performanceFeeBps <= MAX_PERFORMANCE_FEE_BPS;
    }

    /// @notice Protocol share of fees for `manager`; lower for verified (staked) managers once the token is live.
    function protocolCutFor(address manager) public view returns (uint16) {
        address hooks = projectHooks;
        if (hooks != address(0)) {
            try IProjectTokenHooks(hooks).isVerified(manager) returns (bool v) {
                if (v) return verifiedProtocolCutBps;
            } catch {}
        }
        return protocolCutBps;
    }

    /// @notice Normalized share price: 1e18 == the vault's initial price.
    function sharePrice(uint256 totalAssets, uint256 supply, uint256 virtualShares) public pure returns (uint256) {
        return Math.mulDiv(totalAssets + 1, WAD * virtualShares, supply + virtualShares);
    }

    function computeFees(FeeInput memory i) public pure returns (FeeOutput memory o) {
        o.newHighWaterMark = i.highWaterMark;
        if (i.supply == 0) return o; // nobody to charge

        // Management fee: dilution so that holders lose exactly f of their claim.
        if (i.managementFeeBps != 0 && i.elapsed != 0) {
            uint256 f = Math.mulDiv(uint256(i.managementFeeBps) * i.elapsed, WAD, YEAR * BPS);
            if (f > MAX_MGMT_FRACTION) f = MAX_MGMT_FRACTION;
            o.managementShares = Math.mulDiv(i.supply, f, WAD - f);
        }
        uint256 supplyAfterMgmt = i.supply + o.managementShares;

        // Performance fee over the high-water mark (only with a trustworthy NAV).
        if (i.navFresh) {
            uint256 price = sharePrice(i.totalAssets, supplyAfterMgmt, i.virtualShares);
            if (price > i.highWaterMark) {
                if (i.performanceFeeBps != 0) {
                    uint256 denom = supplyAfterMgmt + i.virtualShares;
                    // gain in asset units across all shares
                    uint256 gain = Math.mulDiv(price - i.highWaterMark, denom, WAD * i.virtualShares);
                    uint256 feeAssets = gain * i.performanceFeeBps / BPS;
                    uint256 assetsPlusOne = i.totalAssets + 1;
                    if (feeAssets != 0 && feeAssets < assetsPlusOne) {
                        o.performanceShares = Math.mulDiv(feeAssets, denom, assetsPlusOne - feeAssets);
                    }
                }
                o.newHighWaterMark =
                    sharePrice(i.totalAssets, supplyAfterMgmt + o.performanceShares, i.virtualShares);
                if (o.newHighWaterMark < i.highWaterMark) o.newHighWaterMark = i.highWaterMark;
            }
        }
    }

    /// @notice Splits `feeShares` into (protocol, manager) parts.
    function split(address manager, uint256 feeShares) external view returns (uint256 protocolShares, uint256 managerShares) {
        protocolShares = feeShares * protocolCutFor(manager) / BPS;
        managerShares = feeShares - protocolShares;
    }
}
