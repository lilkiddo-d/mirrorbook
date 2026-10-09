// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";

/// @title MarketClock
/// @notice On-chain trading calendar for tokenized US equities (Chainlink "us_equities_24/5" schedule).
/// @dev Default weekly closure is the conservative UTC envelope of "Fri 20:00 ET -> Sun 20:00 ET" across
///      both DST regimes: [Sat 00:00 UTC, Mon 01:00 UTC). Holidays are flagged per UTC day by an operator.
///      The guardian can force-close the market in an emergency.
contract MarketClock is AccessControl, IMarketClock {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 internal constant WEEK = 7 days;
    /// @dev Unix epoch (1970-01-01) was a Thursday; +3 days aligns the week to Monday 00:00 UTC.
    uint256 internal constant MONDAY_ALIGN = 3 days;

    /// @notice Seconds after Monday 00:00 UTC at which the weekly closure starts.
    uint32 public closeStart = 5 days; // Saturday 00:00 UTC
    /// @notice Length of the weekly closure.
    uint32 public closeDuration = 2 days + 1 hours; // until Monday 01:00 UTC
    bool public forceClosed;
    mapping(uint256 day => bool) public isHoliday;

    event WeeklyClosureSet(uint32 closeStart, uint32 closeDuration);
    event HolidaySet(uint256 indexed day, bool closed);
    event ForceClosedSet(bool closed);

    error InvalidSchedule();

    constructor(address admin, address operator, address guardian) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function isOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    function isOpenAt(uint256 ts) public view returns (bool) {
        if (forceClosed) return false;
        if (isHoliday[ts / 1 days]) return false;
        // Calendar arithmetic on timestamps (not randomness): seconds since Monday 00:00 UTC, then
        // seconds since the weekly closure started.
        uint256 sinceMonday = addmod(ts, MONDAY_ALIGN, WEEK);
        uint256 intoClosure = addmod(sinceMonday, WEEK - closeStart, WEEK);
        return intoClosure >= closeDuration;
    }

    function setWeeklyClosure(uint32 start, uint32 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (start >= WEEK || duration >= WEEK) revert InvalidSchedule();
        closeStart = start;
        closeDuration = duration;
        emit WeeklyClosureSet(start, duration);
    }

    /// @param day UTC day index (timestamp / 86400)
    function setHoliday(uint256 day, bool closed) external onlyRole(OPERATOR_ROLE) {
        isHoliday[day] = closed;
        emit HolidaySet(day, closed);
    }

    function setForceClosed(bool closed) external onlyRole(GUARDIAN_ROLE) {
        forceClosed = closed;
        emit ForceClosedSet(closed);
    }
}
