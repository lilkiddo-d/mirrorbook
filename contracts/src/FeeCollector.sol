// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IManagerVault} from "./interfaces/IManagerVault.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";

/// @title FeeCollector
/// @notice Receives the protocol's cut of vault fees (as vault shares), converts them to stablecoin
///         and splits proceeds between the treasury and project-token stakers. While the project token
///         is not set (or nobody stakes) everything goes to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint16 public constant MAX_STAKER_SHARE_BPS = 8_000;

    IVaultFactory public factory;
    address public treasury;
    address public projectHooks;
    uint16 public stakerShareBps = 5_000;

    event FactorySet(address indexed factory);
    event TreasurySet(address indexed treasury);
    event ProjectHooksSet(address indexed hooks);
    event StakerShareSet(uint16 bps);
    event Harvested(address indexed vault, uint256 shares, uint256 assets);
    event Distributed(uint256 toStakers, uint256 toTreasury);
    event Swept(address indexed token, uint256 amount);

    error FactoryAlreadySet();
    error ZeroAddress();
    error InvalidShare();
    error UnknownVault();

    constructor(address admin, address treasury_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setFactory(address factory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(factory) != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IVaultFactory(factory_);
        emit FactorySet(factory_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setProjectHooks(address hooks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        projectHooks = hooks;
        emit ProjectHooksSet(hooks);
    }

    function setStakerShare(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert InvalidShare();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    /// @notice Redeem up to `shares` of protocol-owned vault shares for stablecoin (needs open cash exits).
    function harvest(address vault, uint256 shares) external nonReentrant returns (uint256 assets) {
        if (!factory.isVault(vault)) revert UnknownVault();
        IManagerVault v = IManagerVault(vault);
        uint256 maxShares = v.maxRedeem(address(this));
        if (shares > maxShares) shares = maxShares;
        if (shares == 0) return 0;
        assets = v.redeem(shares, address(this), address(this));
        emit Harvested(vault, shares, assets);
    }

    /// @notice Split the stablecoin balance between stakers and the treasury.
    function distribute() external nonReentrant returns (uint256 toStakers, uint256 toTreasury) {
        IERC20 cash = IERC20(factory.asset());
        uint256 bal = cash.balanceOf(address(this));
        // Nothing to distribute; a donation can only make this branch not taken.
        // slither-disable-next-line incorrect-equality
        if (bal == 0) return (0, 0);
        address hooks = projectHooks;
        if (
            hooks != address(0) && IProjectTokenHooks(hooks).projectToken() != address(0)
                && IProjectTokenHooks(hooks).totalStaked() != 0
        ) {
            toStakers = bal * stakerShareBps / BPS;
        }
        toTreasury = bal - toStakers;
        if (toStakers != 0) {
            cash.forceApprove(hooks, toStakers);
            IProjectTokenHooks(hooks).notifyRewardAmount(toStakers);
        }
        if (toTreasury != 0) cash.safeTransfer(treasury, toTreasury);
        emit Distributed(toStakers, toTreasury);
    }

    /// @notice Send any non-stablecoin token (e.g. in-kind leftovers) to the treasury.
    function sweep(address token) external nonReentrant {
        if (token == factory.asset() || factory.isVault(token)) revert InvalidShare();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(treasury, bal);
        emit Swept(token, bal);
    }
}
