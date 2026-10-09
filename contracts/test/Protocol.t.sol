// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {ManagerVault} from "../src/ManagerVault.sol";
import {PerformanceTracker} from "../src/PerformanceTracker.sol";
import {FollowerStops} from "../src/FollowerStops.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {FeeEngine} from "../src/FeeEngine.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockERC20, MockCompliance} from "./mocks/Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract PerformanceTrackerTest is Base {
    function test_recordOncePerDay() public {
        _deposit(alice, 1_000e6);
        assertTrue(tracker.record(address(vault)));
        assertFalse(tracker.record(address(vault)));
        _warpDays(1);
        assertTrue(tracker.record(address(vault)));
        PerformanceTracker.Snapshot[] memory h = tracker.history(address(vault), 10);
        assertEq(h.length, 2);
        assertEq(h[1].day, h[0].day + 1);
    }

    function test_unknownVault() public {
        vm.expectRevert(PerformanceTracker.UnknownVault.selector);
        tracker.record(alice);
    }

    function test_skipWhenStale() public {
        _deposit(alice, 1_000e6);
        _trade(address(usdg), address(aapl), 100e6);
        vm.warp(block.timestamp + 3 days);
        assertFalse(tracker.record(address(vault)));
    }

    function test_recordMany() public {
        address[] memory vs = new address[](1);
        vs[0] = address(vault);
        assertEq(tracker.recordMany(vs), 1);
        address[] memory big = new address[](51);
        vm.expectRevert(PerformanceTracker.BatchTooLarge.selector);
        tracker.recordMany(big);
    }

    function test_ringBufferWraps() public {
        _deposit(alice, 1_000e6);
        for (uint256 i; i < 405; ++i) {
            tracker.record(address(vault));
            vm.warp(block.timestamp + 1 days);
            usdgFeed.set(1e8);
        }
        (uint16 head, uint16 count,) = tracker.tracks(address(vault));
        assertEq(count, 400);
        assertEq(head, 5);
        PerformanceTracker.Snapshot[] memory h = tracker.history(address(vault), 1_000);
        assertEq(h.length, 400);
        for (uint256 i = 1; i < h.length; ++i) {
            assertEq(h[i].day, h[i - 1].day + 1);
        }
    }

    function test_stats() public {
        ManagerVault v = _createVault(manager, 0, 0, 0);
        vault = v;
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 5_000e6); // 25 AAPL, 50% exposure
        int256[6] memory moves = [int256(210e8), 220e8, 200e8, 180e8, 190e8, 230e8];
        tracker.record(address(vault));
        for (uint256 i; i < moves.length; ++i) {
            vm.warp(block.timestamp + 1 days);
            _refreshFeeds();
            aaplFeed.set(moves[i]);
            tracker.record(address(vault));
        }
        PerformanceTracker.Stats memory s = tracker.stats(address(vault), 30);
        assertEq(s.points, 7);
        // NAV 10000 -> 5000 + 25*230 = 10750
        assertApproxEqAbs(s.totalReturn, 0.075e18, 1e12);
        // peak 10500 (220) -> trough 9500 (180): 9.52%
        assertApproxEqAbs(s.maxDrawdown, uint256(1000e18) / 10500, 1e12);
        assertGt(s.volatility, 0);
        assertGt(s.sharpe, 0);

        PerformanceTracker.Stats memory w = tracker.stats(address(vault), 2);
        assertEq(w.points, 3);
        PerformanceTracker.Stats memory empty = tracker.stats(alice, 30);
        assertEq(empty.points, 0);
    }

    function test_statsFlatAndSingle() public {
        _deposit(alice, 1_000e6);
        tracker.record(address(vault));
        PerformanceTracker.Stats memory one = tracker.stats(address(vault), 30);
        assertEq(one.points, 1);
        _warpDays(1);
        tracker.record(address(vault));
        PerformanceTracker.Stats memory flat = tracker.stats(address(vault), 30);
        assertEq(flat.volatility, 0);
        assertEq(flat.sharpe, 0);
        // window excludes old points
        vm.warp(block.timestamp + 100 days);
        PerformanceTracker.Stats memory none = tracker.stats(address(vault), 30);
        assertEq(none.points, 0);
    }

    function test_statsPositiveFlatCapped() public {
        // monotone constant-growth series -> zero stdev, positive mean -> capped sharpe
        ManagerVault v = _createVault(manager, 0, 0, 0);
        vault = v;
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 5_000e6);
        tracker.record(address(vault));
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        aaplFeed.set(220e8);
        tracker.record(address(vault));
        PerformanceTracker.Stats memory s = tracker.stats(address(vault), 30);
        assertEq(s.sharpe, 100e18);
    }
}

contract FollowerStopsTest is Base {
    function setUp() public override {
        super.setUp();
        vault = _createVault(manager, 0, 0, 0);
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 5_000e6);
        vm.prank(alice);
        vault.approve(address(stops), type(uint256).max);
    }

    function test_setAndCancel() public {
        vm.prank(alice);
        stops.setStop(address(vault), 1_000);
        (uint192 entry, uint16 drop, bool active) = stops.stops(address(vault), alice);
        assertEq(entry, 1e18);
        assertEq(drop, 1_000);
        assertTrue(active);
        assertEq(stops.triggerPrice(address(vault), alice), 0.9e18);
        vm.prank(alice);
        stops.cancelStop(address(vault));
        vm.prank(alice);
        vm.expectRevert(FollowerStops.NoStop.selector);
        stops.cancelStop(address(vault));
    }

    function test_validation() public {
        vm.startPrank(alice);
        vm.expectRevert(FollowerStops.UnknownVault.selector);
        stops.setStop(bob, 1_000);
        vm.expectRevert(FollowerStops.InvalidDrop.selector);
        stops.setStop(address(vault), 99);
        vm.expectRevert(FollowerStops.InvalidDrop.selector);
        stops.setStop(address(vault), 9_001);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(FollowerStops.StalePrice.selector);
        stops.setStop(address(vault), 1_000);
        vm.stopPrank();
    }

    function test_executeCash() public {
        vm.prank(alice);
        stops.setStop(address(vault), 1_000);
        assertFalse(stops.isTriggered(address(vault), alice));
        vm.expectRevert(abi.encodeWithSelector(FollowerStops.NotTriggered.selector, 1e18, 0.9e18));
        stops.execute(address(vault), alice);

        aaplFeed.set(159e8); // NAV 8975 -> below 0.9
        assertTrue(stops.isTriggered(address(vault), alice));
        vm.prank(keeper);
        (uint256 shares, bool inKind, uint256 cashOut) = stops.execute(address(vault), alice);
        assertEq(cashOut, 5_000e6);
        assertGt(shares, 0);
        // only 5000 cash idle -> cannot redeem all in cash -> in kind
        assertTrue(inKind);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(aapl.balanceOf(alice), 25e18);
        assertFalse(stops.isTriggered(address(vault), alice));
        vm.expectRevert(FollowerStops.NoStop.selector);
        stops.execute(address(vault), alice);
    }

    function test_executeCashWhenLiquid() public {
        _deposit(bob, 100_000e6); // plenty of idle cash
        vm.prank(alice);
        stops.setStop(address(vault), 100);
        aaplFeed.set(150e8);
        (, bool inKind, uint256 cashOut) = stops.execute(address(vault), alice);
        assertEq(usdg.balanceOf(alice), cashOut);
        assertFalse(inKind);
        assertGt(usdg.balanceOf(alice), 0);
        assertEq(aapl.balanceOf(alice), 0);
    }

    function test_executeStaleOrNoAllowance() public {
        vm.prank(alice);
        stops.setStop(address(vault), 1_000);
        aaplFeed.set(159e8);
        vm.prank(alice);
        vault.approve(address(stops), 0);
        vm.expectRevert(FollowerStops.NothingToRedeem.selector);
        stops.execute(address(vault), alice);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(FollowerStops.StalePrice.selector);
        stops.execute(address(vault), alice);
    }
}

contract FeeFlowTest is Base {
    MockERC20 mirr;

    function setUp() public override {
        super.setUp();
        mirr = new MockERC20("Mirror", "MIRR", 18);
    }

    function _generateFees() internal {
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        vault.accrueFees();
    }

    function test_harvestToTreasuryWithoutToken() public {
        _generateFees();
        uint256 shares = vault.balanceOf(address(collector));
        assertGt(shares, 0);
        uint256 got = collector.harvest(address(vault), type(uint256).max);
        assertGt(got, 0);
        (uint256 s, uint256 t) = collector.distribute();
        assertEq(s, 0);
        assertEq(t, got);
        assertEq(usdg.balanceOf(treasury), got);
        (s, t) = collector.distribute();
        assertEq(s + t, 0);
    }

    function test_harvestNothingAndUnknown() public {
        assertEq(collector.harvest(address(vault), 1), 0);
        vm.expectRevert(FeeCollector.UnknownVault.selector);
        collector.harvest(alice, 1);
    }

    function test_stakersShareFees() public {
        vm.prank(admin);
        hooks.setProjectToken(address(mirr));
        mirr.mint(bob, 1_000e18);
        vm.startPrank(bob);
        mirr.approve(address(hooks), type(uint256).max);
        hooks.stake(1_000e18);
        vm.stopPrank();

        _generateFees();
        uint256 got = collector.harvest(address(vault), type(uint256).max);
        (uint256 s, uint256 t) = collector.distribute();
        assertEq(s, got / 2);
        assertEq(s + t, got);
        assertApproxEqAbs(hooks.earned(bob), s, 1);
        vm.prank(bob);
        uint256 claimed = hooks.claimRewards();
        assertApproxEqAbs(claimed, s, 1);
        vm.prank(bob);
        assertEq(hooks.claimRewards(), 0);
    }

    function test_collectorAdmin() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.FactoryAlreadySet.selector);
        collector.setFactory(alice);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        collector.setTreasury(address(0));
        collector.setTreasury(bob);
        assertEq(collector.treasury(), bob);
        vm.expectRevert(FeeCollector.InvalidShare.selector);
        collector.setStakerShare(8_001);
        collector.setStakerShare(2_000);
        assertEq(collector.stakerShareBps(), 2_000);
        vm.stopPrank();
        FeeCollector c2 = new FeeCollector(admin, treasury);
        vm.prank(admin);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        c2.setFactory(address(0));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(admin, address(0));
    }

    function test_sweep() public {
        aapl.mint(address(collector), 5e18);
        collector.sweep(address(aapl));
        assertEq(aapl.balanceOf(treasury), 5e18);
        vm.expectRevert(FeeCollector.InvalidShare.selector);
        collector.sweep(address(usdg));
        vm.expectRevert(FeeCollector.InvalidShare.selector);
        collector.sweep(address(vault));
    }

    function test_feeEngineAdmin() public {
        vm.startPrank(admin);
        vm.expectRevert(FeeEngine.InvalidCut.selector);
        feeEngine.setProtocolCut(3_001, 0);
        vm.expectRevert(FeeEngine.InvalidCut.selector);
        feeEngine.setProtocolCut(1_000, 1_001);
        feeEngine.setProtocolCut(3_000, 500);
        assertEq(feeEngine.protocolCutFor(manager), 3_000);
        feeEngine.setProjectHooks(address(0));
        assertEq(feeEngine.protocolCutFor(manager), 3_000);
        vm.stopPrank();
        // reverting hooks fall back to the normal cut
        vm.prank(admin);
        feeEngine.setProjectHooks(address(collector));
        assertEq(feeEngine.protocolCutFor(manager), 3_000);
    }

    function test_feeEngineEdgeCases() public view {
        FeeEngine.FeeOutput memory o = feeEngine.computeFees(
            FeeEngine.FeeInput({
                totalAssets: 1e6,
                supply: 0,
                virtualShares: 1e6,
                highWaterMark: 1e18,
                elapsed: 1 days,
                navFresh: true,
                managementFeeBps: 200,
                performanceFeeBps: 2_500
            })
        );
        assertEq(o.managementShares + o.performanceShares, 0);
        // absurd elapsed: management fraction capped at 10%
        o = feeEngine.computeFees(
            FeeEngine.FeeInput({
                totalAssets: 1e12,
                supply: 1e18,
                virtualShares: 1e6,
                highWaterMark: 1e18,
                elapsed: 1_000 * 365 days,
                navFresh: false,
                managementFeeBps: 200,
                performanceFeeBps: 0
            })
        );
        assertApproxEqRel(o.managementShares, uint256(1e18) / 9, 1e9);
        // gain above HWM but zero perf fee only lifts the HWM
        o = feeEngine.computeFees(
            FeeEngine.FeeInput({
                totalAssets: 2e12,
                supply: 1e18,
                virtualShares: 1e6,
                highWaterMark: 1e18,
                elapsed: 0,
                navFresh: true,
                managementFeeBps: 0,
                performanceFeeBps: 0
            })
        );
        assertEq(o.performanceShares, 0);
        assertApproxEqRel(o.newHighWaterMark, 2e18, 1e9);
    }
}

contract ProjectTokenHooksTest is Base {
    MockERC20 mirr;

    function setUp() public override {
        super.setUp();
        mirr = new MockERC20("Mirror", "MIRR", 18);
        mirr.mint(manager, 1_000e18);
        vm.prank(manager);
        mirr.approve(address(hooks), type(uint256).max);
    }

    function test_disabledUntilSet() public {
        assertEq(hooks.projectToken(), address(0));
        assertFalse(hooks.isVerified(manager));
        vm.startPrank(manager);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.requestUnstake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.withdrawUnstaked();
        vm.stopPrank();
        vm.prank(address(collector));
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.notifyRewardAmount(1);
        vm.prank(admin);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.slash(manager, 1, admin, "x");
    }

    function test_setProjectTokenOnce() public {
        vm.prank(alice);
        vm.expectRevert();
        hooks.setProjectToken(address(mirr));
        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.setProjectToken(address(0));
        hooks.setProjectToken(address(mirr));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(1));
        vm.stopPrank();
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        new ProjectTokenHooks(admin, address(0), guardian);
    }

    function test_stakeVerifyUnstakeSlash() public {
        vm.startPrank(admin);
        hooks.setProjectToken(address(mirr));
        hooks.setVerifiedMinStake(500e18);
        vm.stopPrank();

        vm.startPrank(manager);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        hooks.stake(600e18);
        assertTrue(hooks.isVerified(manager));
        assertEq(feeEngine.protocolCutFor(manager), 1_000);

        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.requestUnstake(700e18);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.requestUnstake(0);
        hooks.requestUnstake(200e18);
        assertFalse(hooks.isVerified(manager));
        vm.expectRevert(ProjectTokenHooks.NotReady.selector);
        hooks.withdrawUnstaked();
        vm.stopPrank();

        // slash 450: 400 from active stake, 50 from cooldown
        vm.prank(admin);
        hooks.slash(manager, 450e18, treasury, "guardrail exploit");
        assertEq(hooks.staked(manager), 0);
        (uint192 cooling,) = hooks.unstaking(manager);
        assertEq(cooling, 150e18);
        assertEq(mirr.balanceOf(treasury), 450e18);

        vm.warp(block.timestamp + 7 days);
        vm.prank(manager);
        hooks.withdrawUnstaked();
        assertEq(mirr.balanceOf(manager), 550e18);
        vm.prank(manager);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.withdrawUnstaked();

        vm.prank(admin);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.slash(manager, 1, address(0), "x");
        // slashing more than exists is bounded
        vm.prank(admin);
        hooks.slash(manager, 1e30, treasury, "nothing left");
    }

    function test_notifyRules() public {
        vm.prank(admin);
        hooks.setProjectToken(address(mirr));
        vm.expectRevert(ProjectTokenHooks.OnlyFeeCollector.selector);
        hooks.notifyRewardAmount(1);
        vm.prank(address(collector));
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        hooks.notifyRewardAmount(1);
    }

    function test_pause() public {
        vm.prank(admin);
        hooks.setProjectToken(address(mirr));
        vm.prank(guardian);
        hooks.pause();
        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hooks.stake(1);
        vm.prank(guardian);
        hooks.unpause();
        vm.prank(manager);
        hooks.stake(1);
    }
}

contract VaultFactoryTest is Base {
    function test_registry() public view {
        assertEq(factory.vaultCount(), 1);
        address[] memory list = factory.vaults(0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], address(vault));
        assertEq(factory.vaults(5, 10).length, 0);
        assertEq(factory.vaultsOf(manager).length, 1);
        assertTrue(factory.isVault(address(vault)));
        assertTrue(factory.isGuardian(guardian));
    }

    function test_pagination() public {
        for (uint256 i; i < 4; ++i) {
            _createVault(manager, 0, 0, 0);
        }
        assertEq(factory.vaults(3, 10).length, 2);
        vm.expectRevert(VaultFactory.PageTooLarge.selector);
        factory.vaults(0, 101);
    }

    function test_complianceGateOnCreate() public {
        MockCompliance c = new MockCompliance();
        c.setBlocked(bob, true);
        vm.prank(admin);
        factory.setModule("compliance", address(c));
        vm.expectRevert(VaultFactory.NotCompliant.selector);
        _createVault(bob, 0, 0, 0);
        _createVault(alice, 0, 0, 0);
    }

    function test_pauseBlocksCreate() public {
        vm.prank(guardian);
        factory.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _createVault(alice, 0, 0, 0);
        vm.prank(guardian);
        factory.unpause();
        _createVault(alice, 0, 0, 0);
    }

    function test_modulesAdmin() public {
        VaultFactory.Modules memory m;
        vm.startPrank(admin);
        vm.expectRevert(VaultFactory.ModulesAlreadySet.selector);
        factory.initModules(m);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setModule("oracle", address(0));
        vm.expectRevert(VaultFactory.UnknownModule.selector);
        factory.setModule("nope", alice);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setAdapter(address(0), true);
        factory.setModule("oracle", address(oracle));
        factory.setModule("guardrails", address(guardrails));
        factory.setModule("tradeExecutor", address(executor));
        factory.setModule("feeEngine", address(feeEngine));
        factory.setModule("tracker", address(tracker));
        factory.setModule("feeCollector", address(collector));
        factory.setModule("marketClock", address(clock));
        factory.setModule("followerStops", address(stops));
        factory.setAdapter(address(dex), false);
        assertFalse(factory.isAdapter(address(dex)));
        vm.stopPrank();

        VaultFactory f2 = new VaultFactory(address(usdg), admin, guardian);
        vm.prank(admin);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        f2.initModules(m);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(address(0), admin, guardian);
    }
}
