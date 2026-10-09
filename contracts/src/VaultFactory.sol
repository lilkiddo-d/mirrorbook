// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IComplianceHook} from "./interfaces/IComplianceHook.sol";
import {ManagerVault} from "./ManagerVault.sol";
import {Guardrails} from "./Guardrails.sol";

/// @title VaultFactory
/// @notice Permissionless ManagerVault launcher and protocol registry. Every dependency a vault uses
///         (oracle, DEX adapters, compliance hook, ...) is resolved through this contract, so swapping
///         one is a single Timelock transaction. Guardians can pause new deposits/trades protocol-wide;
///         in-kind exits are never pausable.
contract VaultFactory is IVaultFactory, AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant ACTION_CREATE_VAULT = keccak256("CREATE_VAULT");
    uint256 public constant MAX_PAGE = 100;

    struct Modules {
        address oracle;
        address guardrails;
        address tradeExecutor;
        address feeEngine;
        address tracker;
        address feeCollector;
        address marketClock;
        address followerStops;
        address compliance; // optional
    }

    struct CreateParams {
        string name;
        string symbol;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        uint32 minHoldPeriod;
        string metadataURI;
        Guardrails.Config guardrails;
    }

    address public immutable asset;
    address public immutable vaultImplementation;

    address public oracle;
    address public guardrails;
    address public tradeExecutor;
    address public feeEngine;
    address public tracker;
    address public feeCollector;
    address public marketClock;
    address public followerStops;
    address public compliance;

    mapping(address => bool) public isVault;
    mapping(address => bool) public isAdapter;
    address[] internal _vaults;
    mapping(address manager => address[]) internal _vaultsByManager;

    event ModuleSet(bytes32 indexed key, address indexed value);
    event AdapterSet(address indexed adapter, bool allowed);
    event VaultCreated(address indexed vault, address indexed manager, string name, string symbol, uint256 index);

    error ZeroAddress();
    error NotCompliant();
    error ModulesAlreadySet();
    error PageTooLarge();
    error UnknownModule();

    constructor(address asset_, address admin, address guardian) {
        if (asset_ == address(0) || admin == address(0)) revert ZeroAddress();
        asset = asset_;
        vaultImplementation = address(new ManagerVault());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ------------------------------------------------------------------ admin (Timelock)

    /// @notice One-time wiring at deployment (before admin moves to the Timelock).
    function initModules(Modules calldata m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle != address(0)) revert ModulesAlreadySet();
        if (
            m.oracle == address(0) || m.guardrails == address(0) || m.tradeExecutor == address(0)
                || m.feeEngine == address(0) || m.tracker == address(0) || m.feeCollector == address(0)
                || m.marketClock == address(0) || m.followerStops == address(0)
        ) revert ZeroAddress();
        _set("oracle", m.oracle);
        _set("guardrails", m.guardrails);
        _set("tradeExecutor", m.tradeExecutor);
        _set("feeEngine", m.feeEngine);
        _set("tracker", m.tracker);
        _set("feeCollector", m.feeCollector);
        _set("marketClock", m.marketClock);
        _set("followerStops", m.followerStops);
        _set("compliance", m.compliance);
    }

    /// @notice Swap a module (e.g. a new OracleAdapter). Compliance may be set to address(0) (off).
    function setModule(bytes32 key, address value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value == address(0) && key != "compliance") revert ZeroAddress();
        _set(key, value);
    }

    function setAdapter(address adapter, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        isAdapter[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function isGuardian(address account) external view returns (bool) {
        return hasRole(GUARDIAN_ROLE, account);
    }

    function paused() public view override(IVaultFactory, Pausable) returns (bool) {
        return super.paused();
    }

    // ------------------------------------------------------------------ vaults

    function createVault(CreateParams calldata p) external whenNotPaused returns (address vault) {
        address hook = compliance;
        if (hook != address(0) && !IComplianceHook(hook).isAllowed(msg.sender, ACTION_CREATE_VAULT)) {
            revert NotCompliant();
        }
        vault = Clones.clone(vaultImplementation);
        isVault[vault] = true;
        uint256 index = _vaults.length;
        _vaults.push(vault);
        _vaultsByManager[msg.sender].push(vault);

        ManagerVault(vault).initialize(
            ManagerVault.InitParams({
                factory: address(this),
                manager: msg.sender,
                name: p.name,
                symbol: p.symbol,
                managementFeeBps: p.managementFeeBps,
                performanceFeeBps: p.performanceFeeBps,
                minHoldPeriod: p.minHoldPeriod,
                metadataURI: p.metadataURI
            })
        );
        Guardrails(guardrails).initConfig(vault, p.guardrails);
        emit VaultCreated(vault, msg.sender, p.name, p.symbol, index);
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaults(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        if (limit > MAX_PAGE) revert PageTooLarge();
        uint256 n = _vaults.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = _vaults[i];
        }
    }

    function vaultsOf(address manager) external view returns (address[] memory) {
        return _vaultsByManager[manager];
    }

    // ------------------------------------------------------------------ internal

    function _set(bytes32 key, address value) internal {
        if (key == "oracle") oracle = value;
        else if (key == "guardrails") guardrails = value;
        else if (key == "tradeExecutor") tradeExecutor = value;
        else if (key == "feeEngine") feeEngine = value;
        else if (key == "tracker") tracker = value;
        else if (key == "feeCollector") feeCollector = value;
        else if (key == "marketClock") marketClock = value;
        else if (key == "followerStops") followerStops = value;
        else if (key == "compliance") compliance = value;
        else revert UnknownModule();
        emit ModuleSet(key, value);
    }
}
