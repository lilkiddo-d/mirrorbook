// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. All prices are USD with 18 decimals.
interface IOracleAdapter {
    /// @return price USD price of one whole token, 18 decimals
    /// @return ok    false if stale, invalid, paused, deviating, sequencer down or unsupported
    function getPrice(address token) external view returns (uint256 price, bool ok);

    /// @notice Value `amount` of `token` denominated in `quoteToken` units.
    function convert(address token, uint256 amount, address quoteToken) external view returns (uint256 out, bool ok);

    function isSupported(address token) external view returns (bool);
}
