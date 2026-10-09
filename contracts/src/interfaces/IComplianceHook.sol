// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pluggable compliance gate. Returning false blocks the action.
interface IComplianceHook {
    function isAllowed(address account, bytes32 action) external view returns (bool);
}
