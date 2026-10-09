// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";

/// @title ProjectTokenHooks
/// @notice Every $MIRR feature lives here and is inert until the Timelock calls `setProjectToken` (once).
///         - Staking: anyone stakes the project token and earns a share of protocol fees (stablecoin).
///         - Verified managers: a manager whose stake >= `verifiedMinStake` gets a badge and a lower
///           protocol cut (read by FeeEngine).
///         - Slashing: stake (including stake in the unstake cooldown) can be slashed by the SLASHER_ROLE
///           (Timelock) when a manager breaches guardrails through an exploit.
///         No ERC-20 is deployed by this project; the token address is supplied later.
contract ProjectTokenHooks is IProjectTokenHooks, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 internal constant ACC = 1e36;
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    IERC20 public immutable rewardToken; // protocol stablecoin
    address public feeCollector;
    address public projectToken;
    uint256 public verifiedMinStake;

    uint256 public totalStaked;
    uint256 public accRewardPerShare; // scaled by ACC
    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingRewards;

    struct Unstake {
        uint192 amount;
        uint64 readyAt;
    }

    mapping(address => Unstake) public unstaking;

    event ProjectTokenSet(address indexed token);
    event FeeCollectorSet(address indexed collector);
    event VerifiedMinStakeSet(uint256 amount);
    event Staked(address indexed account, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event Unstaked(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event RewardClaimed(address indexed account, uint256 amount);
    event Slashed(address indexed account, uint256 amount, address indexed recipient, string reason);

    error TokenAlreadySet();
    error TokenNotSet();
    error ZeroAddress();
    error ZeroAmount();
    error OnlyFeeCollector();
    error NoStakers();
    error InsufficientStake();
    error NotReady();

    modifier tokenLive() {
        if (projectToken == address(0)) revert TokenNotSet();
        _;
    }

    constructor(address admin, address rewardToken_, address guardian) {
        if (rewardToken_ == address(0)) revert ZeroAddress();
        rewardToken = IERC20(rewardToken_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SLASHER_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ------------------------------------------------------------------ admin (Timelock)

    /// @notice One-shot: wire in the externally launched project token. Cannot be changed afterwards.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (projectToken != address(0)) revert TokenAlreadySet();
        if (token == address(0)) revert ZeroAddress();
        projectToken = token;
        emit ProjectTokenSet(token);
    }

    function setFeeCollector(address collector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCollector = collector;
        emit FeeCollectorSet(collector);
    }

    function setVerifiedMinStake(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifiedMinStake = amount;
        emit VerifiedMinStakeSet(amount);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function isVerified(address manager) external view returns (bool) {
        return projectToken != address(0) && verifiedMinStake != 0 && staked[manager] >= verifiedMinStake;
    }

    function earned(address account) public view returns (uint256) {
        return pendingRewards[account] + staked[account] * accRewardPerShare / ACC - rewardDebt[account];
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant whenNotPaused tokenLive {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare / ACC;
        IERC20(projectToken).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Moves stake into a cooldown (stops earning, loses verified weight, stays slashable).
    function requestUnstake(uint256 amount) external nonReentrant tokenLive {
        if (amount == 0) revert ZeroAmount();
        if (amount > staked[msg.sender]) revert InsufficientStake();
        _checkpoint(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        rewardDebt[msg.sender] = staked[msg.sender] * accRewardPerShare / ACC;
        Unstake storage u = unstaking[msg.sender];
        u.amount += uint192(amount);
        u.readyAt = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        emit UnstakeRequested(msg.sender, amount, u.readyAt);
    }

    function withdrawUnstaked() external nonReentrant tokenLive {
        Unstake memory u = unstaking[msg.sender];
        if (u.amount == 0) revert ZeroAmount();
        if (block.timestamp < u.readyAt) revert NotReady();
        delete unstaking[msg.sender];
        IERC20(projectToken).safeTransfer(msg.sender, u.amount);
        emit Unstaked(msg.sender, u.amount);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        _checkpoint(msg.sender);
        amount = pendingRewards[msg.sender];
        if (amount == 0) return 0;
        pendingRewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice FeeCollector pushes stablecoin rewards for current stakers.
    function notifyRewardAmount(uint256 amount) external nonReentrant tokenLive {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (totalStaked == 0) revert NoStakers();
        accRewardPerShare += amount * ACC / totalStaked;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardNotified(amount);
    }

    /// @notice Slash a manager's stake (active first, then cooling down) after a governance decision.
    function slash(address account, uint256 amount, address recipient, string calldata reason)
        external
        nonReentrant
        onlyRole(SLASHER_ROLE)
        tokenLive
    {
        if (recipient == address(0)) revert ZeroAddress();
        _checkpoint(account);
        uint256 fromStake = amount > staked[account] ? staked[account] : amount;
        staked[account] -= fromStake;
        totalStaked -= fromStake;
        rewardDebt[account] = staked[account] * accRewardPerShare / ACC;
        uint256 rest = amount - fromStake;
        if (rest != 0) {
            uint256 cooling = unstaking[account].amount;
            if (rest > cooling) rest = cooling;
            unstaking[account].amount = uint192(cooling - rest);
        }
        uint256 total = fromStake + rest;
        if (total != 0) IERC20(projectToken).safeTransfer(recipient, total);
        emit Slashed(account, total, recipient, reason);
    }

    function _checkpoint(address account) internal {
        pendingRewards[account] = earned(account);
        rewardDebt[account] = staked[account] * accRewardPerShare / ACC;
    }
}
