// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable execution venue. Pulls exactly `amountIn` of `tokenIn` from msg.sender and
///         sends at least `minAmountOut` of `tokenOut` to `recipient`, or reverts.
interface IDexAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
