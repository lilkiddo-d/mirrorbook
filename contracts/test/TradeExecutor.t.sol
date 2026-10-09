// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {Guardrails} from "../src/Guardrails.sol";
import {ManagerVault} from "../src/ManagerVault.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TradeExecutorTest is Base {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    function _t(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (TradeExecutor.Trade memory) {
        return TradeExecutor.Trade({
            vault: address(vault),
            adapter: address(dex),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            adapterData: ""
        });
    }

    function test_onlyManager() public {
        vm.prank(alice);
        vm.expectRevert(TradeExecutor.OnlyManager.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_unknownVault() public {
        TradeExecutor.Trade memory t = _t(address(usdg), address(aapl), 100e6);
        t.vault = alice;
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.UnknownVault.selector);
        executor.execute(t);
    }

    function test_marketClosed() public {
        vm.warp(SATURDAY);
        _refreshFeeds();
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.MarketClosed.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_holidayClosed() public {
        vm.prank(admin);
        clock.setHoliday(block.timestamp / 1 days, true);
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.MarketClosed.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_expired() public {
        TradeExecutor.Trade memory t = _t(address(usdg), address(aapl), 100e6);
        t.deadline = block.timestamp - 1;
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.Expired.selector);
        executor.execute(t);
    }

    function test_stalePrice() public {
        vm.warp(block.timestamp + 26 hours);
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.StalePrice.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_oraclePausedBlocksTrade() public {
        aapl.setOraclePaused(true);
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.StalePrice.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_pairNotAllowed() public {
        vm.startPrank(manager);
        vm.expectRevert(Guardrails.PairNotAllowed.selector);
        executor.execute(_t(address(aapl), address(nvda), 1e18));
        vm.expectRevert(Guardrails.PairNotAllowed.selector);
        executor.execute(_t(address(usdg), address(0xBEEF), 1e6));
        vm.expectRevert(Guardrails.PairNotAllowed.selector);
        executor.execute(_t(address(0xBEEF), address(usdg), 1e6));
        vm.stopPrank();
    }

    function test_delistedStockCanStillBeSold() public {
        uint256 got = _trade(address(usdg), address(aapl), 1_000e6);
        vm.prank(admin);
        guardrails.setWhitelisted(address(aapl), false);
        vm.prank(manager);
        vm.expectRevert(Guardrails.PairNotAllowed.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
        _trade(address(aapl), address(usdg), got);
    }

    function test_tradeBudget() public {
        for (uint256 i; i < 10; ++i) {
            _trade(address(usdg), address(aapl), 10e6);
        }
        vm.prank(manager);
        vm.expectRevert(Guardrails.TooManyTrades.selector);
        executor.execute(_t(address(usdg), address(aapl), 10e6));
        assertEq(guardrails.tradesToday(address(vault)), 10);
        _warpDays(1);
        assertEq(guardrails.tradesToday(address(vault)), 0);
        _trade(address(usdg), address(aapl), 10e6);
    }

    function test_slippageVsOracle() public {
        dex.setLossBps(101); // config allows 100 bps
        vm.prank(manager);
        vm.expectRevert(); // SlippageExceeded from the vault
        executor.execute(_t(address(usdg), address(aapl), 100e6));
        dex.setLossBps(100);
        _trade(address(usdg), address(aapl), 100e6);
    }

    function test_managerMinOutRespected() public {
        TradeExecutor.Trade memory t = _t(address(usdg), address(aapl), 100e6);
        t.minAmountOut = 0.6e18; // stricter than oracle bound (0.495)
        dex.setLossBps(50);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ManagerVault.SlippageExceeded.selector, 0.4975e18, 0.6e18));
        executor.execute(t);
    }

    function test_positionCap() public {
        vm.prank(manager);
        vm.expectRevert(TradeExecutor.PositionCapExceeded.selector);
        executor.execute(_t(address(usdg), address(aapl), 5_001e6));
        _trade(address(usdg), address(aapl), 5_000e6);
    }

    function test_pause() public {
        vm.expectRevert(TradeExecutor.OnlyGuardian.selector);
        executor.pause();
        vm.prank(guardian);
        executor.pause();
        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
        vm.expectRevert(TradeExecutor.OnlyGuardian.selector);
        executor.unpause();
        vm.prank(guardian);
        executor.unpause();
        _trade(address(usdg), address(aapl), 100e6);
    }

    function test_factoryPauseBlocksTrades() public {
        vm.prank(guardian);
        factory.pause();
        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_vaultPauseBlocksTrades() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.execute(_t(address(usdg), address(aapl), 100e6));
    }

    function test_oracleMinOut() public view {
        (uint256 minOut, bool ok) = executor.oracleMinOut(address(usdg), address(aapl), 200e6, 100);
        assertTrue(ok);
        assertEq(minOut, 0.99e18);
    }
}
