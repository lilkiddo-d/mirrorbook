// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IManagerVault} from "./interfaces/IManagerVault.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {Guardrails} from "./Guardrails.sol";
import {PerformanceTracker} from "./PerformanceTracker.sol";

/// @title TradeExecutor
/// @notice The only path by which a manager can move vault assets. Enforces, in order:
///         manager auth -> market open -> deadline -> pair whitelist -> daily trade budget ->
///         oracle-derived minimum output (max slippage) -> swap via whitelisted adapter ->
///         post-trade position cap.
contract TradeExecutor is Pausable, ReentrancyGuard {
    uint256 internal constant BPS = 10_000;

    struct Trade {
        address vault;
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut; // manager's own bound; the oracle bound is applied on top
        uint256 deadline;
        bytes adapterData;
    }

    IVaultFactory public immutable factory;

    event TradeExecuted(
        address indexed vault,
        address indexed manager,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oracleMinOut
    );

    error OnlyManager();
    error OnlyGuardian();
    error MarketClosed();
    error Expired();
    error StalePrice();
    error PositionCapExceeded();
    error UnknownVault();

    constructor(address factory_) {
        factory = IVaultFactory(factory_);
    }

    function pause() external {
        if (!factory.isGuardian(msg.sender)) revert OnlyGuardian();
        _pause();
    }

    function unpause() external {
        if (!factory.isGuardian(msg.sender)) revert OnlyGuardian();
        _unpause();
    }

    /// @notice Oracle-implied minimum output for `amountIn` of `tokenIn` at `slippageBps`.
    function oracleMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint16 slippageBps)
        public
        view
        returns (uint256 minOut, bool ok)
    {
        uint256 fair;
        (fair, ok) = IOracleAdapter(factory.oracle()).convert(tokenIn, amountIn, tokenOut);
        minOut = Math.mulDiv(fair, BPS - slippageBps, BPS, Math.Rounding.Ceil);
    }

    function execute(Trade calldata t) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (!factory.isVault(t.vault)) revert UnknownVault();
        if (factory.paused()) revert EnforcedPause();
        IManagerVault vault = IManagerVault(t.vault);
        if (msg.sender != vault.manager()) revert OnlyManager();
        if (!IMarketClock(factory.marketClock()).isOpen()) revert MarketClosed();
        if (block.timestamp > t.deadline) revert Expired();

        Guardrails g = Guardrails(factory.guardrails());
        g.checkPair(t.tokenIn, t.tokenOut);
        g.consumeTrade(t.vault);

        // Track record: the day's first snapshot is taken before the manager's first trade of the day.
        // Whether a snapshot was taken (or today's already exists) does not affect the trade.
        // slither-disable-next-line unused-return
        PerformanceTracker(factory.tracker()).record(t.vault);

        (uint256 minOut, bool ok) = oracleMinOut(t.tokenIn, t.tokenOut, t.amountIn, g.configOf(t.vault).maxSlippageBps);
        if (!ok) revert StalePrice();
        uint256 effectiveMin = Math.max(minOut, t.minAmountOut);

        amountOut = vault.executeSwap(t.adapter, t.tokenIn, t.tokenOut, t.amountIn, effectiveMin, t.deadline, t.adapterData);

        if (t.tokenOut != vault.asset() && !g.positionWithinCap(t.vault, t.tokenOut)) revert PositionCapExceeded();
        emit TradeExecuted(t.vault, msg.sender, t.tokenIn, t.tokenOut, t.amountIn, amountOut, minOut);
    }
}
