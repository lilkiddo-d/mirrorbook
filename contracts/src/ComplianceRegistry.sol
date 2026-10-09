// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceHook} from "./interfaces/IComplianceHook.sol";

/// @title ComplianceRegistry
/// @notice Optional allowlist gate for deposits, share transfers and vault creation. OFF by default:
///         while disabled every account is allowed. Exits (redemptions) are never gated so followers
///         can always leave. Plugged into the factory via `setCompliance` (Timelock).
contract ComplianceRegistry is AccessControl, IComplianceHook {
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");

    bytes32 public constant ACTION_DEPOSIT = keccak256("DEPOSIT");
    bytes32 public constant ACTION_RECEIVE_SHARES = keccak256("RECEIVE_SHARES");
    bytes32 public constant ACTION_CREATE_VAULT = keccak256("CREATE_VAULT");

    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address account => bool) public allowed;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin, address complianceAdmin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, complianceAdmin);
    }

    function isAllowed(address account, bytes32) external view returns (bool) {
        return !enabled || allowed[account];
    }

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setAllowed(address[] calldata accounts, bool isAllowed_) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]] = isAllowed_;
            emit AllowedSet(accounts[i], isAllowed_);
        }
    }
}
