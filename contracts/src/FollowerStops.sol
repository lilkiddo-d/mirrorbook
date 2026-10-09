// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IManagerVault} from "./interfaces/IManagerVault.sol";

/// @title FollowerStops
/// @notice Optional per-follower stop: if a vault's share price falls `dropBps` below the follower's entry
///         price, anyone (keepers) can trigger an exit on the follower's behalf. Funds always go to the
///         follower. Exit is in stablecoin when the vault has enough idle cash and cash exits are open,
///         otherwise in kind. The follower authorises this by approving vault shares to this contract.
contract FollowerStops is ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint16 public constant MIN_DROP_BPS = 100; // 1%
    uint16 public constant MAX_DROP_BPS = 9_000; // 90%

    struct Stop {
        uint192 entryPrice; // normalized share price at activation
        uint16 dropBps;
        bool active;
    }

    IVaultFactory public immutable factory;
    mapping(address vault => mapping(address follower => Stop)) public stops;

    event StopSet(address indexed vault, address indexed follower, uint256 entryPrice, uint16 dropBps);
    event StopCancelled(address indexed vault, address indexed follower);
    event StopExecuted(
        address indexed vault,
        address indexed follower,
        address indexed keeper,
        uint256 shares,
        uint256 price,
        bool inKind,
        uint256 stablecoinOut
    );

    error UnknownVault();
    error InvalidDrop();
    error StalePrice();
    error NoStop();
    error NotTriggered(uint256 price, uint256 trigger);
    error NothingToRedeem();

    constructor(address factory_) {
        factory = IVaultFactory(factory_);
    }

    /// @notice Arm (or re-arm) a stop at the current share price.
    function setStop(address vault, uint16 dropBps) external {
        if (!factory.isVault(vault)) revert UnknownVault();
        if (dropBps < MIN_DROP_BPS || dropBps > MAX_DROP_BPS) revert InvalidDrop();
        (uint256 price, bool fresh) = IManagerVault(vault).sharePrice();
        if (!fresh || price == 0) revert StalePrice();
        stops[vault][msg.sender] = Stop(uint192(price), dropBps, true);
        emit StopSet(vault, msg.sender, price, dropBps);
    }

    function cancelStop(address vault) external {
        if (!stops[vault][msg.sender].active) revert NoStop();
        delete stops[vault][msg.sender];
        emit StopCancelled(vault, msg.sender);
    }

    function triggerPrice(address vault, address follower) public view returns (uint256) {
        Stop memory s = stops[vault][follower];
        return uint256(s.entryPrice) * (BPS - s.dropBps) / BPS;
    }

    /// @notice True if the stop can be executed right now (used by keepers).
    function isTriggered(address vault, address follower) public view returns (bool) {
        Stop memory s = stops[vault][follower];
        if (!s.active) return false;
        (uint256 price, bool fresh) = IManagerVault(vault).sharePrice();
        return fresh && price <= triggerPrice(vault, follower);
    }

    function execute(address vault, address follower)
        external
        nonReentrant
        returns (uint256 shares, bool inKind, uint256 stablecoinOut)
    {
        Stop memory s = stops[vault][follower];
        if (!s.active) revert NoStop();
        IManagerVault v = IManagerVault(vault);
        (uint256 price, bool fresh) = v.sharePrice();
        if (!fresh) revert StalePrice();
        uint256 trig = triggerPrice(vault, follower);
        if (price > trig) revert NotTriggered(price, trig);

        shares = Math.min(IERC20(vault).balanceOf(follower), IERC20(vault).allowance(follower, address(this)));
        // slither-disable-next-line incorrect-equality
        if (shares == 0) revert NothingToRedeem();

        delete stops[vault][follower];
        if (v.maxRedeem(follower) >= shares) {
            stablecoinOut = v.redeem(shares, follower, follower);
        } else {
            inKind = true;
            (, uint256[] memory amounts) = v.redeemInKind(shares, follower, follower);
            stablecoinOut = amounts[0];
        }
        emit StopExecuted(vault, follower, msg.sender, shares, price, inKind, stablecoinOut);
    }
}
