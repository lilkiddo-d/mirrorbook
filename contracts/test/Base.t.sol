// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {ManagerVault} from "../src/ManagerVault.sol";
import {Guardrails} from "../src/Guardrails.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {PerformanceTracker} from "../src/PerformanceTracker.sol";
import {FeeEngine} from "../src/FeeEngine.sol";
import {FollowerStops} from "../src/FollowerStops.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {MockERC20, MockStockToken, MockAggregator, MockDexAdapter} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    // Wed 2026-09-30 15:00 UTC (market open)
    uint256 internal constant T0 = 1_790_780_400;
    // Sat 2026-10-03 12:00 UTC (weekly closure)
    uint256 internal constant SATURDAY = 1_790_553_600 + 5 days + 12 hours;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal usdg;
    MockStockToken internal aapl;
    MockStockToken internal nvda;
    MockAggregator internal usdgFeed;
    MockAggregator internal aaplFeed;
    MockAggregator internal nvdaFeed;

    VaultFactory internal factory;
    Guardrails internal guardrails;
    TradeExecutor internal executor;
    PerformanceTracker internal tracker;
    FeeEngine internal feeEngine;
    FollowerStops internal stops;
    MarketClock internal clock;
    OracleAdapter internal oracle;
    FeeCollector internal collector;
    ProjectTokenHooks internal hooks;
    ComplianceRegistry internal compliance;
    MockDexAdapter internal dex;

    ManagerVault internal vault;

    function setUp() public virtual {
        vm.warp(T0);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockStockToken("Apple", "AAPL");
        nvda = new MockStockToken("NVIDIA", "NVDA");
        usdgFeed = new MockAggregator(8, 1e8, "USDG / USD");
        aaplFeed = new MockAggregator(8, 200e8, "Robinhood AAPL / USD");
        nvdaFeed = new MockAggregator(8, 100e8, "Robinhood NVDA / USD");

        vm.startPrank(admin);
        oracle = new OracleAdapter(admin);
        oracle.setFeed(address(usdg), address(usdgFeed), 90_000, 200, false);
        oracle.setPriceBand(address(usdg), 0.97e18, 1.03e18);
        oracle.setFeed(address(aapl), address(aaplFeed), 90_000, 2_500, true);
        oracle.setFeed(address(nvda), address(nvdaFeed), 90_000, 2_500, true);

        clock = new MarketClock(admin, admin, guardian);
        factory = new VaultFactory(address(usdg), admin, guardian);
        guardrails = new Guardrails(admin);
        feeEngine = new FeeEngine(admin);
        tracker = new PerformanceTracker(address(factory));
        executor = new TradeExecutor(address(factory));
        stops = new FollowerStops(address(factory));
        collector = new FeeCollector(admin, treasury);
        compliance = new ComplianceRegistry(admin, admin);
        hooks = new ProjectTokenHooks(admin, address(usdg), guardian);
        dex = new MockDexAdapter(address(oracle));

        guardrails.setFactory(address(factory));
        collector.setFactory(address(factory));
        factory.initModules(
            VaultFactory.Modules({
                oracle: address(oracle),
                guardrails: address(guardrails),
                tradeExecutor: address(executor),
                feeEngine: address(feeEngine),
                tracker: address(tracker),
                feeCollector: address(collector),
                marketClock: address(clock),
                followerStops: address(stops),
                compliance: address(compliance)
            })
        );
        factory.setAdapter(address(dex), true);
        guardrails.setWhitelisted(address(aapl), true);
        guardrails.setWhitelisted(address(nvda), true);
        feeEngine.setProjectHooks(address(hooks));
        collector.setProjectHooks(address(hooks));
        hooks.setFeeCollector(address(collector));
        vm.stopPrank();

        // DEX inventory
        usdg.mint(address(dex), 1e15);
        aapl.mint(address(dex), 1e30);
        nvda.mint(address(dex), 1e30);

        vault = _createVault(manager, 200, 2000, 0);
    }

    function _defaultRails() internal pure returns (Guardrails.Config memory) {
        return Guardrails.Config({maxPositionBps: 5_000, maxTradesPerDay: 10, maxSlippageBps: 100});
    }

    function _createVault(address who, uint16 mgmt, uint16 perf, uint32 minHold) internal returns (ManagerVault) {
        vm.prank(who);
        address v = factory.createVault(
            VaultFactory.CreateParams({
                name: "Mirror Alpha",
                symbol: "mALPHA",
                managementFeeBps: mgmt,
                performanceFeeBps: perf,
                minHoldPeriod: minHold,
                metadataURI: "ipfs://alpha",
                guardrails: _defaultRails()
            })
        );
        return ManagerVault(v);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _trade(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        vm.prank(manager);
        return executor.execute(
            TradeExecutor.Trade({
                vault: address(vault),
                adapter: address(dex),
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: 0,
                deadline: block.timestamp + 1 hours,
                adapterData: ""
            })
        );
    }

    /// @dev Move all feeds' timestamps to now (keeps them fresh after warps).
    function _refreshFeeds() internal {
        usdgFeed.set(usdgFeed.answer());
        aaplFeed.set(aaplFeed.answer());
        nvdaFeed.set(nvdaFeed.answer());
    }

    function _warpDays(uint256 d) internal {
        vm.warp(block.timestamp + d * 1 days);
        _refreshFeeds();
    }
}
