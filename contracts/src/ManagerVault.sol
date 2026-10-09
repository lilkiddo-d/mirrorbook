// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {IComplianceHook} from "./interfaces/IComplianceHook.sol";
import {FeeEngine} from "./FeeEngine.sol";

/// @title ManagerVault
/// @notice ERC-4626 vault (stablecoin deposits) whose manager can only trade whitelisted stock tokens
///         through the protocol TradeExecutor. The manager has no withdrawal right over follower assets
///         and the vault exposes no arbitrary-call surface.
///
///         Exits:
///         - `withdraw`/`redeem` (ERC-4626, stablecoin) are served from idle cash at oracle NAV, only
///           while the NAV is fresh and, if the vault holds stocks, the market is open.
///         - `redeemInKind` is ALWAYS available (even when paused or the market is closed): the
///           follower receives a pro-rata slice of every vault holding, so no price is needed.
contract ManagerVault is ERC4626Upgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;
    uint256 public constant MAX_HELD_ASSETS = 10;
    uint32 public constant MAX_MIN_HOLD = 7 days;
    uint256 public constant FEE_INCREASE_DELAY = 7 days;

    bytes32 internal constant ACTION_DEPOSIT = keccak256("DEPOSIT");
    bytes32 internal constant ACTION_RECEIVE_SHARES = keccak256("RECEIVE_SHARES");

    struct InitParams {
        address factory;
        address manager;
        string name;
        string symbol;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        uint32 minHoldPeriod;
        string metadataURI;
    }

    struct PendingFees {
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        uint64 effectiveAt;
    }

    IVaultFactory public factory;
    address public manager;
    uint16 public managementFeeBps;
    uint16 public performanceFeeBps;
    uint32 public minHoldPeriod;
    uint64 public lastFeeAccrual;
    uint256 public highWaterMark;
    PendingFees public pendingFees;
    string public metadataURI;

    mapping(address account => uint64) public unlockTime;
    address[] internal _held;
    mapping(address token => bool) public isHeld;

    event FeesAccrued(uint256 managementShares, uint256 performanceShares, uint256 protocolShares, uint256 highWaterMark);
    event FeesUpdated(uint16 managementFeeBps, uint16 performanceFeeBps);
    event FeesQueued(uint16 managementFeeBps, uint16 performanceFeeBps, uint64 effectiveAt);
    event MinHoldPeriodSet(uint32 period);
    event MetadataURISet(string uri);
    event Swapped(address indexed adapter, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event RedeemedInKind(
        address indexed caller, address indexed receiver, address indexed owner, uint256 shares, address[] tokens, uint256[] amounts
    );
    event HoldingAdded(address indexed token);
    event HoldingRemoved(address indexed token);

    error OnlyManager();
    error OnlyExecutor();
    error OnlyGuardian();
    error InvalidFees();
    error InvalidParam();
    error NothingPending();
    error TooEarly();
    error Locked(uint64 until);
    error AdapterNotAllowed();
    error SlippageExceeded(uint256 received, uint256 minAmountOut);
    error TooManyHoldings();
    error NotCompliant(address account);
    error ZeroShares();

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        IVaultFactory f = IVaultFactory(p.factory);
        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(IERC20(f.asset()));
        __Pausable_init();
        if (!FeeEngine(f.feeEngine()).validateFees(p.managementFeeBps, p.performanceFeeBps)) revert InvalidFees();
        if (p.minHoldPeriod > MAX_MIN_HOLD || p.manager == address(0)) revert InvalidParam();
        factory = f;
        manager = p.manager;
        managementFeeBps = p.managementFeeBps;
        performanceFeeBps = p.performanceFeeBps;
        minHoldPeriod = p.minHoldPeriod;
        metadataURI = p.metadataURI;
        highWaterMark = WAD;
        lastFeeAccrual = uint64(block.timestamp);
    }

    // ================================================================== NAV

    /// @notice Net asset value in stablecoin units and whether every price behind it is trustworthy.
    function navFresh() public view returns (uint256 nav, bool fresh) {
        address cash = asset();
        nav = IERC20(cash).balanceOf(address(this));
        fresh = true;
        uint256 n = _held.length;
        if (n == 0) return (nav, true);
        IOracleAdapter oracle = IOracleAdapter(factory.oracle());
        for (uint256 i; i < n; ++i) {
            address t = _held[i];
            uint256 bal = IERC20(t).balanceOf(address(this));
            // Skipping empty holdings only saves an oracle call; a donation just adds value.
            // slither-disable-next-line incorrect-equality
            if (bal == 0) continue;
            (uint256 v, bool ok) = oracle.convert(t, bal, cash);
            nav += v;
            if (!ok) fresh = false;
        }
    }

    function totalAssets() public view override returns (uint256 nav) {
        (nav,) = navFresh();
    }

    /// @notice Normalized share price (1e18 = launch price), net of not-yet-minted fees.
    function sharePrice() external view returns (uint256 price, bool fresh) {
        uint256 nav;
        uint256 supply;
        (nav, supply, fresh) = _effectiveState();
        price = FeeEngine(factory.feeEngine()).sharePrice(nav, supply, VIRTUAL_SHARES);
    }

    /// @notice Cash deposits/withdrawals need a live price: fresh oracles and, when the vault holds
    ///         stocks, an open market (prevents stale-price arbitrage against other followers).
    function cashOpsOpen() public view returns (bool) {
        if (paused() || factory.paused()) return false;
        (, bool fresh) = navFresh();
        if (!fresh) return false;
        if (_hasStockExposure()) return IMarketClock(factory.marketClock()).isOpen();
        return true;
    }

    function heldTokens() external view returns (address[] memory) {
        return _held;
    }

    // ================================================================== ERC-4626 overrides

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _effectiveState() internal view returns (uint256 nav, uint256 supply, bool fresh) {
        (nav, fresh) = navFresh();
        supply = totalSupply();
        FeeEngine.FeeOutput memory o = FeeEngine(factory.feeEngine()).computeFees(_feeInput(nav, supply, fresh));
        supply += o.managementShares + o.performanceShares;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 nav, uint256 supply,) = _effectiveState();
        return assets.mulDiv(supply + VIRTUAL_SHARES, nav + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 nav, uint256 supply,) = _effectiveState();
        return shares.mulDiv(nav + 1, supply + VIRTUAL_SHARES, rounding);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!_compliant(receiver, ACTION_DEPOSIT) || !cashOpsOpen()) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (block.timestamp < unlockTime[owner] || !cashOpsOpen()) return 0;
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), cash);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (block.timestamp < unlockTime[owner] || !cashOpsOpen()) return 0;
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return Math.min(balanceOf(owner), _convertToShares(cash, Math.Rounding.Floor));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueFees();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueFees();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueFees();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueFees();
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // slither-disable-next-line incorrect-equality
        if (shares == 0) revert ZeroShares();
        uint64 unlock = uint64(block.timestamp + minHoldPeriod);
        if (unlock > unlockTime[receiver]) unlockTime[receiver] = unlock;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Share transfers: the sender must be unlocked (no lock laundering) and, if compliance is on,
    ///      the receiver must be allowed. Mints (fees/deposits) and burns are unaffected.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (block.timestamp < unlockTime[from]) revert Locked(unlockTime[from]);
            if (!_compliant(to, ACTION_RECEIVE_SHARES)) revert NotCompliant(to);
        }
        super._update(from, to, value);
    }

    // ================================================================== in-kind exit

    /// @notice Burn `shares` of `owner` and send `receiver` a pro-rata slice of every holding.
    ///         Never blocked by pause, market hours or oracle state.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (shares == 0) revert ZeroShares();
        if (block.timestamp < unlockTime[owner]) revert Locked(unlockTime[owner]);
        _accrueFees();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        uint256 supply = totalSupply();
        uint256 n = _held.length;
        tokens = new address[](n + 1);
        amounts = new uint256[](n + 1);
        tokens[0] = asset();
        amounts[0] = IERC20(tokens[0]).balanceOf(address(this)).mulDiv(shares, supply);
        for (uint256 i; i < n; ++i) {
            tokens[i + 1] = _held[i];
            amounts[i + 1] = IERC20(_held[i]).balanceOf(address(this)).mulDiv(shares, supply);
        }

        _burn(owner, shares);
        for (uint256 i; i <= n; ++i) {
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransfer(receiver, amounts[i]);
        }
        emit RedeemedInKind(msg.sender, receiver, owner, shares, tokens, amounts);
    }

    // ================================================================== trading (TradeExecutor only)

    /// @notice Swap through a protocol-whitelisted adapter. The executor has already validated the pair,
    ///         market hours, trade budget and computed `minAmountOut` from the oracle; the vault re-checks
    ///         the realised balance deltas so no adapter can take more or return less.
    function executeSwap(
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata data
    ) external nonReentrant whenNotPaused returns (uint256 received) {
        if (msg.sender != factory.tradeExecutor()) revert OnlyExecutor();
        if (!factory.isAdapter(adapter)) revert AdapterNotAllowed();
        if (amountIn == 0 || tokenIn == tokenOut) revert InvalidParam();
        if (tokenOut != asset() && !isHeld[tokenOut]) {
            if (_held.length >= MAX_HELD_ASSETS) revert TooManyHoldings();
            isHeld[tokenOut] = true;
            _held.push(tokenOut);
            emit HoldingAdded(tokenOut);
        }
        received = _swap(adapter, tokenIn, tokenOut, amountIn, minAmountOut, deadline, data);
        emit Swapped(adapter, tokenIn, tokenOut, amountIn, received);
    }

    function _swap(
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata data
    ) internal returns (uint256 received) {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        if (amountIn > inBefore) revert InvalidParam();

        IERC20(tokenIn).forceApprove(adapter, amountIn);
        // The adapter's reported output is deliberately ignored: the vault trusts only its own balance
        // deltas measured around the call. Every vault entry point is nonReentrant and the adapter is
        // whitelisted by governance, so the pre-call balances cannot go stale.
        // slither-disable-next-line unused-return,reentrancy-balance
        IDexAdapter(adapter).swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut, address(this), deadline, data);
        IERC20(tokenIn).forceApprove(adapter, 0);

        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        received = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        // slither-disable-next-line reentrancy-balance
        if (inBefore - inAfter > amountIn) revert InvalidParam();
        // slither-disable-next-line reentrancy-balance
        if (received < minAmountOut) revert SlippageExceeded(received, minAmountOut);
        // slither-disable-next-line incorrect-equality
        if (tokenIn != asset() && inAfter == 0) _removeHolding(tokenIn);
    }

    // ================================================================== fees

    function accrueFees() external nonReentrant {
        _accrueFees();
    }

    function _feeInput(uint256 nav, uint256 supply, bool fresh) internal view returns (FeeEngine.FeeInput memory) {
        return FeeEngine.FeeInput({
            totalAssets: nav,
            supply: supply,
            virtualShares: VIRTUAL_SHARES,
            highWaterMark: highWaterMark,
            elapsed: block.timestamp - lastFeeAccrual,
            navFresh: fresh,
            managementFeeBps: managementFeeBps,
            performanceFeeBps: performanceFeeBps
        });
    }

    /// @dev Runs on every state change, even within the same block: a performance fee that is pending at
    ///      the current price must be crystallized before shares are minted or burned, otherwise it would
    ///      later be charged on the new depositor's capital (or escape on an exit).
    function _accrueFees() internal {
        (uint256 nav, bool fresh) = navFresh();
        FeeEngine engine = FeeEngine(factory.feeEngine());
        FeeEngine.FeeOutput memory o = engine.computeFees(_feeInput(nav, totalSupply(), fresh));
        lastFeeAccrual = uint64(block.timestamp);
        highWaterMark = o.newHighWaterMark;
        uint256 total = o.managementShares + o.performanceShares;
        // slither-disable-next-line incorrect-equality
        if (total == 0) return;
        (uint256 protocolShares, uint256 managerShares) = engine.split(manager, total);
        if (protocolShares != 0) _mint(factory.feeCollector(), protocolShares);
        if (managerShares != 0) _mint(manager, managerShares);
        emit FeesAccrued(o.managementShares, o.performanceShares, protocolShares, o.newHighWaterMark);
    }

    /// @notice Fee cuts apply immediately; any increase is queued for FEE_INCREASE_DELAY.
    function setFees(uint16 mgmtBps, uint16 perfBps) external onlyManager nonReentrant {
        if (!FeeEngine(factory.feeEngine()).validateFees(mgmtBps, perfBps)) revert InvalidFees();
        _accrueFees();
        if (mgmtBps <= managementFeeBps && perfBps <= performanceFeeBps) {
            managementFeeBps = mgmtBps;
            performanceFeeBps = perfBps;
            delete pendingFees;
            emit FeesUpdated(mgmtBps, perfBps);
        } else {
            uint64 eta = uint64(block.timestamp + FEE_INCREASE_DELAY);
            pendingFees = PendingFees(mgmtBps, perfBps, eta);
            emit FeesQueued(mgmtBps, perfBps, eta);
        }
    }

    function applyPendingFees() external nonReentrant {
        PendingFees memory p = pendingFees;
        if (p.effectiveAt == 0) revert NothingPending();
        if (block.timestamp < p.effectiveAt) revert TooEarly();
        _accrueFees();
        managementFeeBps = p.managementFeeBps;
        performanceFeeBps = p.performanceFeeBps;
        delete pendingFees;
        emit FeesUpdated(p.managementFeeBps, p.performanceFeeBps);
    }

    // ================================================================== manager settings

    function setMinHoldPeriod(uint32 period) external onlyManager {
        if (period > MAX_MIN_HOLD) revert InvalidParam();
        minHoldPeriod = period;
        emit MinHoldPeriodSet(period);
    }

    function setMetadataURI(string calldata uri) external onlyManager {
        metadataURI = uri;
        emit MetadataURISet(uri);
    }

    // ================================================================== guardian

    function pause() external {
        if (!factory.isGuardian(msg.sender)) revert OnlyGuardian();
        _pause();
    }

    function unpause() external {
        if (!factory.isGuardian(msg.sender)) revert OnlyGuardian();
        _unpause();
    }

    // ================================================================== internal

    function _hasStockExposure() internal view returns (bool) {
        uint256 n = _held.length;
        for (uint256 i; i < n; ++i) {
            if (IERC20(_held[i]).balanceOf(address(this)) != 0) return true;
        }
        return false;
    }

    function _compliant(address account, bytes32 action) internal view returns (bool) {
        address hook = factory.compliance();
        return hook == address(0) || IComplianceHook(hook).isAllowed(account, action);
    }

    function _removeHolding(address token) internal {
        uint256 n = _held.length;
        for (uint256 i; i < n; ++i) {
            if (_held[i] == token) {
                _held[i] = _held[n - 1];
                _held.pop();
                isHeld[token] = false;
                emit HoldingRemoved(token);
                return;
            }
        }
    }

    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }
}
