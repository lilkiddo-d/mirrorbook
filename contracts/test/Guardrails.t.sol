// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {Guardrails} from "../src/Guardrails.sol";
import {MockStockToken} from "./mocks/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract GuardrailsTest is Base {
    function _cfg(uint16 pos, uint16 trades, uint16 slip) internal pure returns (Guardrails.Config memory) {
        return Guardrails.Config(pos, trades, slip);
    }

    function test_validateConfig() public view {
        assertTrue(guardrails.validateConfig(_cfg(500, 1, 5)));
        assertTrue(guardrails.validateConfig(_cfg(10_000, 50, 500)));
        assertFalse(guardrails.validateConfig(_cfg(499, 1, 5)));
        assertFalse(guardrails.validateConfig(_cfg(10_001, 1, 5)));
        assertFalse(guardrails.validateConfig(_cfg(500, 0, 5)));
        assertFalse(guardrails.validateConfig(_cfg(500, 51, 5)));
        assertFalse(guardrails.validateConfig(_cfg(500, 1, 4)));
        assertFalse(guardrails.validateConfig(_cfg(500, 1, 501)));
    }

    function test_tightenImmediately() public {
        vm.prank(manager);
        guardrails.setConfig(address(vault), _cfg(4_000, 5, 50));
        Guardrails.Config memory c = guardrails.configOf(address(vault));
        assertEq(c.maxPositionBps, 4_000);
        assertEq(c.maxTradesPerDay, 5);
        assertEq(c.maxSlippageBps, 50);
    }

    function test_loosenQueued() public {
        vm.prank(manager);
        guardrails.setConfig(address(vault), _cfg(6_000, 10, 100));
        assertEq(guardrails.configOf(address(vault)).maxPositionBps, 5_000);
        vm.expectRevert(Guardrails.TooEarly.selector);
        guardrails.applyPendingConfig(address(vault));
        vm.warp(block.timestamp + 7 days);
        guardrails.applyPendingConfig(address(vault));
        assertEq(guardrails.configOf(address(vault)).maxPositionBps, 6_000);
        vm.expectRevert(Guardrails.NothingPending.selector);
        guardrails.applyPendingConfig(address(vault));
    }

    function test_setConfigAuthAndValidation() public {
        vm.expectRevert(Guardrails.OnlyManager.selector);
        guardrails.setConfig(address(vault), _cfg(4_000, 5, 50));
        vm.prank(manager);
        vm.expectRevert(Guardrails.OnlyManager.selector);
        guardrails.setConfig(alice, _cfg(4_000, 5, 50));
        vm.prank(manager);
        vm.expectRevert(Guardrails.InvalidConfig.selector);
        guardrails.setConfig(address(vault), _cfg(4_000, 5, 600));
    }

    function test_initConfigOnlyFactory() public {
        vm.expectRevert(Guardrails.OnlyFactory.selector);
        guardrails.initConfig(alice, _cfg(4_000, 5, 50));
    }

    function test_initConfigInvalidViaFactory() public {
        vm.prank(address(factory));
        vm.expectRevert(Guardrails.InvalidConfig.selector);
        guardrails.initConfig(alice, _cfg(1, 5, 50));
    }

    function test_consumeTradeOnlyExecutor() public {
        vm.expectRevert(Guardrails.OnlyExecutor.selector);
        guardrails.consumeTrade(address(vault));
    }

    function test_setFactoryOnce() public {
        vm.prank(admin);
        vm.expectRevert(Guardrails.FactoryAlreadySet.selector);
        guardrails.setFactory(alice);
        Guardrails g = new Guardrails(admin);
        vm.prank(admin);
        vm.expectRevert(Guardrails.ZeroAddress.selector);
        g.setFactory(address(0));
    }

    function test_whitelistManagement() public {
        assertEq(guardrails.whitelist().length, 2);
        vm.startPrank(admin);
        guardrails.setWhitelisted(address(aapl), true); // no-op
        guardrails.setWhitelisted(address(aapl), false);
        assertEq(guardrails.whitelist().length, 1);
        assertFalse(guardrails.isWhitelisted(address(aapl)));
        vm.expectRevert(Guardrails.UnsupportedByOracle.selector);
        guardrails.setWhitelisted(address(0xBEEF), true);
        vm.expectRevert(Guardrails.UnsupportedByOracle.selector);
        guardrails.setWhitelisted(address(usdg), true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        guardrails.setWhitelisted(address(aapl), true);
    }

    function test_whitelistFull() public {
        vm.startPrank(admin);
        for (uint256 i = 2; i < 64; ++i) {
            MockStockToken t = new MockStockToken("X", "X");
            oracle.setFeed(address(t), address(aaplFeed), 90_000, 0, false);
            guardrails.setWhitelisted(address(t), true);
        }
        MockStockToken extra = new MockStockToken("Y", "Y");
        oracle.setFeed(address(extra), address(aaplFeed), 90_000, 0, false);
        vm.expectRevert(Guardrails.WhitelistFull.selector);
        guardrails.setWhitelisted(address(extra), true);
        vm.stopPrank();
    }

    function test_positionWithinCapFalseWhenStale() public {
        _deposit(alice, 1_000e6);
        _trade(address(usdg), address(aapl), 100e6);
        assertTrue(guardrails.positionWithinCap(address(vault), address(aapl)));
        vm.warp(block.timestamp + 2 days);
        assertFalse(guardrails.positionWithinCap(address(vault), address(aapl)));
    }

    function test_positionWithinCapFalseWhenEmpty() public view {
        assertFalse(guardrails.positionWithinCap(address(vault), address(aapl)));
    }
}
