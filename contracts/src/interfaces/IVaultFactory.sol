// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The factory doubles as the protocol registry every vault reads its dependencies from,
///         which is what makes the oracle, DEX adapter and compliance hook swappable (via Timelock).
interface IVaultFactory {
    function asset() external view returns (address);
    function oracle() external view returns (address);
    function guardrails() external view returns (address);
    function tradeExecutor() external view returns (address);
    function feeEngine() external view returns (address);
    function tracker() external view returns (address);
    function feeCollector() external view returns (address);
    function compliance() external view returns (address);
    function marketClock() external view returns (address);
    function followerStops() external view returns (address);
    function isVault(address vault) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function paused() external view returns (bool);
    function isGuardian(address account) external view returns (bool);
}
