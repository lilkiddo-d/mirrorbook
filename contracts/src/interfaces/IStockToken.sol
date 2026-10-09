// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain stock tokens expose an advisory oracle pause flag during corporate actions.
/// @dev https://docs.robinhood.com/chain/oracles-and-price-feeds ("Oracle Pauses During Corporate Actions")
interface IStockToken {
    function oraclePaused() external view returns (bool);
}
