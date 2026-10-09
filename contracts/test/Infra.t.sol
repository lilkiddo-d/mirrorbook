// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {Timelock} from "../src/Timelock.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {MockAggregator, MockERC20, MockStockToken, MockUniFactory, MockSwapRouter} from "./mocks/Mocks.sol";

contract OracleAdapterTest is Base {
    function test_prices() public view {
        (uint256 p, bool ok) = oracle.getPrice(address(aapl));
        assertEq(p, 200e18);
        assertTrue(ok);
        (uint256 out, bool ok2) = oracle.convert(address(usdg), 400e6, address(aapl));
        assertEq(out, 2e18);
        assertTrue(ok2);
        (out,) = oracle.convert(address(aapl), 1e18, address(usdg));
        assertEq(out, 200e6);
        assertTrue(oracle.isSupported(address(aapl)));
        assertFalse(oracle.isSupported(alice));
    }

    function test_unsupported() public view {
        (uint256 p, bool ok) = oracle.getPrice(alice);
        assertEq(p, 0);
        assertFalse(ok);
        (uint256 out, bool ok2) = oracle.convert(alice, 1, address(usdg));
        assertEq(out, 0);
        assertFalse(ok2);
    }

    function test_stale() public {
        vm.warp(block.timestamp + 90_001);
        (, bool ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
        aaplFeed.setUpdatedAt(block.timestamp + 10); // future timestamp
        (, ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
        aaplFeed.setUpdatedAt(0);
        (, ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
    }

    function test_incompleteRound() public {
        aaplFeed.setStartedAt(0);
        (uint256 p, bool ok) = oracle.getPrice(address(aapl));
        assertEq(p, 200e18);
        assertFalse(ok);
    }

    function test_nonPositive() public {
        aaplFeed.set(0);
        (uint256 p, bool ok) = oracle.getPrice(address(aapl));
        assertEq(p, 0);
        assertFalse(ok);
        aaplFeed.set(-1);
        (, ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
    }

    function test_aggregatorReverts() public {
        aaplFeed.setReverts(true);
        (, bool ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
    }

    function test_band() public {
        usdgFeed.set(0.98e8);
        (, bool ok) = oracle.getPrice(address(usdg));
        assertTrue(ok);
        usdgFeed.set(0.965e8);
        (, ok) = oracle.getPrice(address(usdg));
        assertFalse(ok);
        usdgFeed.set(0.98e8);
        usdgFeed.set(1.0e8);
        usdgFeed.set(1.02e8);
        usdgFeed.set(1.035e8);
        (, ok) = oracle.getPrice(address(usdg));
        assertFalse(ok);
    }

    function test_bandValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.InvalidParam.selector);
        oracle.setPriceBand(address(usdg), 2e18, 1e18);
        vm.expectRevert(OracleAdapter.InvalidFeed.selector);
        oracle.setPriceBand(alice, 0, 0);
        vm.stopPrank();
    }

    function test_tokenOraclePaused() public {
        aapl.setOraclePaused(true);
        (, bool ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
        // a token without the flag is fine
        MockERC20 plain = new MockERC20("P", "P", 18);
        vm.prank(admin);
        oracle.setFeed(address(plain), address(aaplFeed), 90_000, 0, true);
        (, ok) = oracle.getPrice(address(plain));
        assertTrue(ok);
    }

    function test_roundDeviation() public {
        aaplFeed.set(260e8); // +30% in one round
        (, bool ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
        aaplFeed.set(270e8); // +3.8%
        (, ok) = oracle.getPrice(address(aapl));
        assertTrue(ok);
        aaplFeed.setRoundReverts(true);
        (, ok) = oracle.getPrice(address(aapl));
        assertTrue(ok);
        aaplFeed.setRoundReverts(false);
        aaplFeed.setRoundId(uint80(1) << 64 | 1); // first round of a phase
        (, ok) = oracle.getPrice(address(aapl));
        assertTrue(ok);
    }

    function test_roundDeviationIgnoresNonPositivePrevious() public {
        aaplFeed.setRoundId(200); // history[199] == 0
        (, bool ok) = oracle.getPrice(address(aapl));
        assertTrue(ok);
    }

    function test_sequencer() public {
        MockAggregator seq = new MockAggregator(0, 0, "seq");
        vm.prank(admin);
        oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        assertFalse(oracle.sequencerUp()); // within grace
        vm.warp(block.timestamp + 1 hours + 1);
        _refreshFeeds();
        assertTrue(oracle.sequencerUp());
        (, bool ok) = oracle.getPrice(address(aapl));
        assertTrue(ok);
        seq.set(1); // down
        assertFalse(oracle.sequencerUp());
        (, ok) = oracle.getPrice(address(aapl));
        assertFalse(ok);
        seq.setReverts(true);
        assertFalse(oracle.sequencerUp());
        seq.setReverts(false);
        seq.set(0);
        seq.setStartedAt(0);
        assertFalse(oracle.sequencerUp());
        vm.prank(admin);
        vm.expectRevert(OracleAdapter.InvalidParam.selector);
        oracle.setSequencerUptimeFeed(address(seq), 2 days);
    }

    function test_setFeedValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(OracleAdapter.InvalidFeed.selector);
        oracle.setFeed(address(0), address(aaplFeed), 1, 0, false);
        vm.expectRevert(OracleAdapter.InvalidFeed.selector);
        oracle.setFeed(address(aapl), address(0), 1, 0, false);
        vm.expectRevert(OracleAdapter.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 0, 0, false);
        vm.expectRevert(OracleAdapter.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 5 days, 0, false);
        vm.expectRevert(OracleAdapter.InvalidParam.selector);
        oracle.setFeed(address(aapl), address(aaplFeed), 1, 10_001, false);
        MockAggregator weird = new MockAggregator(19, 1, "x");
        vm.expectRevert(OracleAdapter.InvalidFeed.selector);
        oracle.setFeed(address(aapl), address(weird), 1, 0, false);
        oracle.removeFeed(address(nvda));
        assertFalse(oracle.isSupported(address(nvda)));
        vm.stopPrank();
    }
}

contract MarketClockTest is Test {
    MarketClock clock;
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    uint256 constant MONDAY = 1_790_553_600; // Mon 2026-09-28 00:00 UTC

    function setUp() public {
        clock = new MarketClock(admin, admin, guardian);
    }

    function test_weeklySchedule() public view {
        assertFalse(clock.isOpenAt(MONDAY)); // Mon 00:00
        assertFalse(clock.isOpenAt(MONDAY + 59 minutes));
        assertTrue(clock.isOpenAt(MONDAY + 1 hours)); // Mon 01:00
        assertTrue(clock.isOpenAt(MONDAY + 2 days + 15 hours)); // Wed
        assertTrue(clock.isOpenAt(MONDAY + 5 days - 1)); // Fri 23:59:59
        assertFalse(clock.isOpenAt(MONDAY + 5 days)); // Sat 00:00
        assertFalse(clock.isOpenAt(MONDAY + 6 days + 12 hours)); // Sun
    }

    function test_isOpenUsesNow() public {
        vm.warp(MONDAY + 2 days);
        assertTrue(clock.isOpen());
    }

    function test_holidayAndForceClose() public {
        uint256 wed = MONDAY + 2 days + 15 hours;
        vm.prank(admin);
        clock.setHoliday(wed / 1 days, true);
        assertFalse(clock.isOpenAt(wed));
        vm.prank(admin);
        clock.setHoliday(wed / 1 days, false);
        assertTrue(clock.isOpenAt(wed));
        vm.prank(guardian);
        clock.setForceClosed(true);
        assertFalse(clock.isOpenAt(wed));
        vm.expectRevert();
        clock.setForceClosed(false);
    }

    function test_setWeeklyClosure() public {
        vm.startPrank(admin);
        clock.setWeeklyClosure(0, 0); // always open
        assertTrue(clock.isOpenAt(MONDAY + 6 days));
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        clock.setWeeklyClosure(7 days, 0);
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        clock.setWeeklyClosure(0, 7 days);
        vm.stopPrank();
    }
}

contract DexAdapterTest is Test {
    DexAdapter adapter;
    MockUniFactory uni;
    MockSwapRouter router;
    MockERC20 a;
    MockERC20 b;
    address admin = makeAddr("admin");

    function setUp() public {
        uni = new MockUniFactory();
        router = new MockSwapRouter();
        adapter = new DexAdapter(address(router), address(uni), admin);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 6);
        uni.setPool(address(a), address(b), 500, address(0x1234));
        b.mint(address(router), 1e30);
        a.mint(address(this), 1e24);
        a.approve(address(adapter), type(uint256).max);
    }

    function test_constructorZero() public {
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        new DexAdapter(address(0), address(uni), admin);
    }

    function test_swap() public {
        uint256 out = adapter.swapExactIn(address(a), address(b), 1e18, 1e18, address(this), block.timestamp, abi.encode(uint24(500)));
        assertEq(out, 1e18);
        assertEq(b.balanceOf(address(this)), 1e18);
        assertEq(a.allowance(address(adapter), address(router)), 0);
    }

    function test_expired() public {
        vm.expectRevert(DexAdapter.Expired.selector);
        adapter.swapExactIn(address(a), address(b), 1, 0, address(this), block.timestamp - 1, abi.encode(uint24(500)));
    }

    function test_feeTier() public {
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.FeeTierNotAllowed.selector, uint24(100)));
        adapter.swapExactIn(address(a), address(b), 1, 0, address(this), block.timestamp, abi.encode(uint24(100)));
        vm.prank(admin);
        adapter.setFeeTier(100, true);
        vm.expectRevert(DexAdapter.PoolMissing.selector);
        adapter.swapExactIn(address(a), address(b), 1, 0, address(this), block.timestamp, abi.encode(uint24(100)));
        vm.expectRevert();
        adapter.setFeeTier(100, false);
    }

    function test_underpaidRouterCaught() public {
        router.setUnderpay(1);
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.InsufficientOutput.selector, 1e18 - 1, 1e18));
        adapter.swapExactIn(address(a), address(b), 1e18, 1e18, address(this), block.timestamp, abi.encode(uint24(500)));
    }
}

contract TimelockFactoryHelper {
    function make(uint256 delay, address[] memory p) external returns (Timelock) {
        return new Timelock(delay, p, p);
    }
}

contract TimelockTest is Test {
    address[] p;
    Timelock t;

    function setUp() public {
        p.push(address(this));
        t = new Timelock(48 hours, p, p);
    }

    function test_constructorFloor() public {
        TimelockFactoryHelper h = new TimelockFactoryHelper();
        vm.expectRevert(Timelock.DelayTooShort.selector);
        h.make(1 days, p);
        assertEq(t.getMinDelay(), 48 hours);
    }

    function test_updateDelayOnlySelf() public {
        vm.expectRevert();
        t.updateDelay(72 hours);
    }

    function test_updateDelayFloor() public {
        bytes memory data = abi.encodeCall(Timelock.updateDelay, (24 hours));
        t.schedule(address(t), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert();
        t.execute(address(t), 0, data, bytes32(0), bytes32(0));
    }

    function test_updateDelayViaTimelock() public {
        bytes memory ok = abi.encodeCall(Timelock.updateDelay, (72 hours));
        t.schedule(address(t), 0, ok, bytes32(0), bytes32(uint256(1)), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        t.execute(address(t), 0, ok, bytes32(0), bytes32(uint256(1)));
        assertEq(t.getMinDelay(), 72 hours);
    }
}

contract ComplianceRegistryTest is Test {
    function test_registry() public {
        address admin = makeAddr("admin");
        ComplianceRegistry r = new ComplianceRegistry(admin, admin);
        assertTrue(r.isAllowed(address(1), r.ACTION_DEPOSIT()));
        vm.prank(admin);
        r.setEnabled(true);
        assertFalse(r.isAllowed(address(1), r.ACTION_DEPOSIT()));
        address[] memory list = new address[](1);
        list[0] = address(1);
        vm.prank(admin);
        r.setAllowed(list, true);
        assertTrue(r.isAllowed(address(1), r.ACTION_CREATE_VAULT()));
        address[] memory big = new address[](201);
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        r.setAllowed(big, true);
        assertEq(r.ACTION_RECEIVE_SHARES(), keccak256("RECEIVE_SHARES"));
    }
}
