// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Mirrorbook Timelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every Mirrorbook contract. Every admin action waits >= 48h.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }

    /// @dev The delay can only be changed through the timelock itself and never below 48h.
    function updateDelay(uint256 newDelay) public override {
        if (newDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
        super.updateDelay(newDelay);
    }
}
