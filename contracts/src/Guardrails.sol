// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IManagerVault} from "./interfaces/IManagerVault.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";

/// @title Guardrails
/// @notice Code-enforced risk limits for every ManagerVault:
///         - global stock whitelist (Timelock) and hard ceilings that no manager can exceed
///         - per-vault max position size, max trades per UTC day and max slippage vs oracle
///         Managers may tighten their limits instantly; loosening is queued for LOOSEN_DELAY so
///         followers can exit first.
contract Guardrails is AccessControl {
    uint256 internal constant BPS = 10_000;

    uint16 public constant HARD_MAX_SLIPPAGE_BPS = 500; // 5%
    uint16 public constant HARD_MIN_SLIPPAGE_BPS = 5; // 0.05%
    uint16 public constant HARD_MAX_TRADES_PER_DAY = 50;
    uint16 public constant HARD_MIN_POSITION_BPS = 500; // 5%
    uint256 public constant MAX_HELD_ASSETS = 10;
    uint256 public constant MAX_WHITELIST = 64;
    uint256 public constant LOOSEN_DELAY = 7 days;

    struct Config {
        uint16 maxPositionBps;
        uint16 maxTradesPerDay;
        uint16 maxSlippageBps;
    }

    struct Pending {
        Config config;
        uint64 effectiveAt;
    }

    struct DayCounter {
        uint32 day;
        uint16 count;
    }

    IVaultFactory public factory;
    mapping(address token => bool) public isWhitelisted;
    address[] internal _whitelist;

    mapping(address vault => Config) internal _config;
    mapping(address vault => Pending) public pendingConfig;
    mapping(address vault => DayCounter) public tradeCounter;

    event FactorySet(address indexed factory);
    event StockWhitelisted(address indexed token, bool allowed);
    event ConfigInitialized(address indexed vault, Config config);
    event ConfigUpdated(address indexed vault, Config config);
    event ConfigQueued(address indexed vault, Config config, uint64 effectiveAt);
    event TradeCounted(address indexed vault, uint32 indexed day, uint16 count);

    error FactoryAlreadySet();
    error ZeroAddress();
    error OnlyFactory();
    error OnlyExecutor();
    error OnlyManager();
    error InvalidConfig();
    error TooManyTrades();
    error PairNotAllowed();
    error NothingPending();
    error TooEarly();
    error WhitelistFull();
    error UnsupportedByOracle();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin

    function setFactory(address factory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(factory) != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IVaultFactory(factory_);
        emit FactorySet(factory_);
    }

    function setWhitelisted(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allowed == isWhitelisted[token]) return;
        if (allowed) {
            if (_whitelist.length >= MAX_WHITELIST) revert WhitelistFull();
            if (token == factory.asset() || !IOracleAdapter(factory.oracle()).isSupported(token)) {
                revert UnsupportedByOracle();
            }
            _whitelist.push(token);
        } else {
            uint256 n = _whitelist.length;
            for (uint256 i; i < n; ++i) {
                if (_whitelist[i] == token) {
                    _whitelist[i] = _whitelist[n - 1];
                    _whitelist.pop();
                    break;
                }
            }
        }
        isWhitelisted[token] = allowed;
        emit StockWhitelisted(token, allowed);
    }

    // ------------------------------------------------------------------ config lifecycle

    function validateConfig(Config memory c) public pure returns (bool) {
        return c.maxPositionBps >= HARD_MIN_POSITION_BPS && c.maxPositionBps <= BPS && c.maxTradesPerDay >= 1
            && c.maxTradesPerDay <= HARD_MAX_TRADES_PER_DAY && c.maxSlippageBps >= HARD_MIN_SLIPPAGE_BPS
            && c.maxSlippageBps <= HARD_MAX_SLIPPAGE_BPS;
    }

    function initConfig(address vault, Config calldata c) external {
        if (msg.sender != address(factory)) revert OnlyFactory();
        if (!validateConfig(c)) revert InvalidConfig();
        _config[vault] = c;
        emit ConfigInitialized(vault, c);
    }

    /// @notice Tighter-or-equal configs apply immediately; anything looser is queued for LOOSEN_DELAY.
    function setConfig(address vault, Config calldata c) external {
        if (!factory.isVault(vault) || msg.sender != IManagerVault(vault).manager()) revert OnlyManager();
        if (!validateConfig(c)) revert InvalidConfig();
        Config memory cur = _config[vault];
        if (
            c.maxPositionBps <= cur.maxPositionBps && c.maxTradesPerDay <= cur.maxTradesPerDay
                && c.maxSlippageBps <= cur.maxSlippageBps
        ) {
            _config[vault] = c;
            delete pendingConfig[vault];
            emit ConfigUpdated(vault, c);
        } else {
            uint64 eta = uint64(block.timestamp + LOOSEN_DELAY);
            pendingConfig[vault] = Pending(c, eta);
            emit ConfigQueued(vault, c, eta);
        }
    }

    function applyPendingConfig(address vault) external {
        Pending memory p = pendingConfig[vault];
        // slither-disable-next-line incorrect-equality
        if (p.effectiveAt == 0) revert NothingPending();
        if (block.timestamp < p.effectiveAt) revert TooEarly();
        _config[vault] = p.config;
        delete pendingConfig[vault];
        emit ConfigUpdated(vault, p.config);
    }

    // ------------------------------------------------------------------ trade checks (TradeExecutor)

    /// @notice Counts a trade against today's budget. Reverts once the daily limit is exceeded.
    function consumeTrade(address vault) external {
        if (msg.sender != factory.tradeExecutor()) revert OnlyExecutor();
        uint32 today = uint32(block.timestamp / 1 days);
        DayCounter memory dc = tradeCounter[vault];
        // UTC day-index comparison (daily budget reset), not a balance check.
        // slither-disable-next-line incorrect-equality
        uint16 count = dc.day == today ? dc.count + 1 : 1;
        if (count > _config[vault].maxTradesPerDay) revert TooManyTrades();
        tradeCounter[vault] = DayCounter(today, count);
        emit TradeCounted(vault, today, count);
    }

    /// @notice Only stablecoin <-> stock swaps. Buying requires a whitelisted stock; selling a
    ///         de-listed stock stays possible (if still priced) so managers can unwind.
    function checkPair(address tokenIn, address tokenOut) external view {
        address cash = factory.asset();
        if (tokenIn == cash) {
            if (!isWhitelisted[tokenOut]) revert PairNotAllowed();
        } else if (tokenOut == cash) {
            if (!IOracleAdapter(factory.oracle()).isSupported(tokenIn)) revert PairNotAllowed();
        } else {
            revert PairNotAllowed();
        }
    }

    /// @notice True if `token`'s value in `vault` is within the vault's max position size.
    function positionWithinCap(address vault, address token) external view returns (bool) {
        (uint256 nav, bool fresh) = IManagerVault(vault).navFresh();
        if (!fresh || nav == 0) return false;
        uint256 bal = IERC20(token).balanceOf(vault);
        (uint256 value, bool ok) = IOracleAdapter(factory.oracle()).convert(token, bal, factory.asset());
        if (!ok) return false;
        return value * BPS <= nav * _config[vault].maxPositionBps;
    }

    // ------------------------------------------------------------------ views

    function configOf(address vault) external view returns (Config memory) {
        return _config[vault];
    }

    function whitelist() external view returns (address[] memory) {
        return _whitelist;
    }

    function tradesToday(address vault) external view returns (uint16) {
        DayCounter memory dc = tradeCounter[vault];
        // slither-disable-next-line incorrect-equality
        return dc.day == uint32(block.timestamp / 1 days) ? dc.count : 0;
    }
}
