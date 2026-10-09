// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {ManagerVault} from "../../src/ManagerVault.sol";
import {TradeExecutor} from "../../src/TradeExecutor.sol";
import {MockERC20, MockStockToken, MockAggregator, MockDexAdapter} from "../mocks/Mocks.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {Guardrails} from "../../src/Guardrails.sol";

/// @dev Drives a vault through deposits, exits, manager trades, price moves, time and manager attacks.
contract VaultHandler is Test {
    ManagerVault public vault;
    TradeExecutor public executor;
    OracleAdapter public oracle;
    MockDexAdapter public dex;
    MockERC20 public usdg;
    MockStockToken public aapl;
    MockStockToken public nvda;
    MockAggregator public aaplFeed;
    MockAggregator public nvdaFeed;
    MockAggregator public usdgFeed;
    address public manager;
    address[3] public actors;

    // ghosts
    bool public attackSucceeded;
    bool public slippageViolated;
    bool public dilutionObserved;
    uint256 public trades;

    struct Deps {
        ManagerVault vault;
        TradeExecutor executor;
        OracleAdapter oracle;
        MockDexAdapter dex;
        MockERC20 usdg;
        MockStockToken aapl;
        MockStockToken nvda;
        MockAggregator aaplFeed;
        MockAggregator nvdaFeed;
        MockAggregator usdgFeed;
        address manager;
    }

    constructor(Deps memory d) {
        vault = d.vault;
        executor = d.executor;
        oracle = d.oracle;
        dex = d.dex;
        usdg = d.usdg;
        aapl = d.aapl;
        nvda = d.nvda;
        aaplFeed = d.aaplFeed;
        nvdaFeed = d.nvdaFeed;
        usdgFeed = d.usdgFeed;
        manager = d.manager;
        actors = [makeAddr("f1"), makeAddr("f2"), makeAddr("f3")];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _claim(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    function _othersClaims(address except) internal view returns (uint256[3] memory c) {
        for (uint256 i; i < 3; ++i) {
            if (actors[i] != except) c[i] = _claim(actors[i]);
        }
    }

    function _checkNoDilution(address except, uint256[3] memory before) internal {
        for (uint256 i; i < 3; ++i) {
            if (actors[i] != except && _claim(actors[i]) + 1 < before[i]) dilutionObserved = true;
        }
    }

    function deposit(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1e6, 1e11);
        vault.accrueFees();
        if (vault.maxDeposit(who) == 0) return;
        uint256[3] memory before = _othersClaims(who);
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
        _checkNoDilution(who, before);
    }

    function redeemCash(uint256 seed, uint256 frac) external {
        address who = _actor(seed);
        vault.accrueFees();
        uint256 shares = vault.maxRedeem(who) * bound(frac, 1, 100) / 100;
        if (shares == 0) return;
        uint256[3] memory before = _othersClaims(who);
        vm.prank(who);
        vault.redeem(shares, who, who);
        _checkNoDilution(who, before);
    }

    function redeemInKind(uint256 seed, uint256 frac) external {
        address who = _actor(seed);
        uint256 shares = vault.balanceOf(who) * bound(frac, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(who);
        vault.redeemInKind(shares, who, who);
    }

    function trade(uint256 seed, uint256 amount, uint256 lossBps) external {
        dex.setLossBps(bound(lossBps, 0, 300));
        bool buy = seed % 2 == 0;
        MockStockToken stock = (seed / 2) % 2 == 0 ? aapl : nvda;
        address tokenIn = buy ? address(usdg) : address(stock);
        address tokenOut = buy ? address(stock) : address(usdg);
        uint256 bal = MockERC20(tokenIn).balanceOf(address(vault));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        (uint256 oracleMin,) = executor.oracleMinOut(tokenIn, tokenOut, amount, 100);
        uint256 outBefore = MockERC20(tokenOut).balanceOf(address(vault));
        vm.prank(manager);
        try executor.execute(
            TradeExecutor.Trade({
                vault: address(vault),
                adapter: address(dex),
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amount,
                minAmountOut: 0,
                deadline: block.timestamp,
                adapterData: ""
            })
        ) returns (uint256 out) {
            trades++;
            if (out < oracleMin || MockERC20(tokenOut).balanceOf(address(vault)) - outBefore < oracleMin) {
                slippageViolated = true;
            }
        } catch {}
    }

    function movePrice(uint256 seed, int256 bps) external {
        bps = bound(bps, -1_000, 1_000);
        MockAggregator f = seed % 2 == 0 ? aaplFeed : nvdaFeed;
        f.set(f.answer() * (10_000 + bps) / 10_000);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
        usdgFeed.set(usdgFeed.answer());
        aaplFeed.set(aaplFeed.answer());
        nvdaFeed.set(nvdaFeed.answer());
    }

    /// The manager tries every non-trade path to move vault assets.
    function managerAttack(uint256 seed) external {
        address victim = _actor(seed);
        uint256 vb = vault.balanceOf(victim);
        address cash = address(usdg);
        vm.startPrank(manager);
        if (_ok(address(vault), abi.encodeCall(ManagerVault.executeSwap, (address(dex), cash, address(aapl), 1, 0, block.timestamp, "")))) attackSucceeded = true;
        if (vb != 0 && _ok(address(vault), abi.encodeCall(ManagerVault.redeemInKind, (vb, manager, victim)))) attackSucceeded = true;
        if (vb != 0 && _ok(address(vault), abi.encodeCall(ManagerVault.redeem, (vb, manager, victim)))) attackSucceeded = true;
        if (vb != 0 && _ok(address(vault), abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, manager, vb))) attackSucceeded = true;
        // trade via a non-whitelisted adapter, or into a non-whitelisted token
        if (_ok(address(executor), abi.encodeCall(TradeExecutor.execute, (TradeExecutor.Trade(address(vault), manager, cash, address(aapl), 1e6, 0, block.timestamp, ""))))) attackSucceeded = true;
        if (_ok(address(executor), abi.encodeCall(TradeExecutor.execute, (TradeExecutor.Trade(address(vault), address(dex), cash, manager, 1e6, 0, block.timestamp, ""))))) attackSucceeded = true;
        vm.stopPrank();
    }

    function _ok(address target, bytes memory data) internal returns (bool success) {
        (success,) = target.call(data);
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract VaultInvariantTest is Base {
    VaultHandler handler;
    uint256 usdgIssued;

    function setUp() public override {
        super.setUp();
        vault = _createVault(manager, 200, 2_000, 0);
        vm.prank(manager);
        guardrails.setConfig(address(vault), Guardrails.Config(5_000, 10, 100));
        vm.startPrank(admin);
        clock.setWeeklyClosure(0, 0); // keep the market open so trades exercise every path
        vm.stopPrank();
        handler = new VaultHandler(
            VaultHandler.Deps(vault, executor, oracle, dex, usdg, aapl, nvda, aaplFeed, nvdaFeed, usdgFeed, manager)
        );
        // the DEX inventory is the only external source of tokens besides follower deposits
        targetContract(address(handler));
    }

    /// The manager can never take assets out of the vault: their wallet never holds vault assets.
    function invariant_managerNeverReceivesAssets() public view {
        assertEq(usdg.balanceOf(manager), 0);
        assertEq(aapl.balanceOf(manager), 0);
        assertEq(nvda.balanceOf(manager), 0);
        assertFalse(handler.attackSucceeded(), "manager attack path succeeded");
    }

    /// Every executed trade returned at least the oracle-implied minimum.
    function invariant_tradesWithinSlippage() public view {
        assertFalse(handler.slippageViolated());
    }

    /// Deposits and cash withdrawals never reduce other followers' claims.
    function invariant_noDilution() public view {
        assertFalse(handler.dilutionObserved());
    }

    /// Vault only holds the stablecoin plus whitelisted stocks, and outstanding shares are backed.
    function invariant_backing() public view {
        address[] memory held = vault.heldTokens();
        assertLe(held.length, 10);
        for (uint256 i; i < held.length; ++i) {
            assertTrue(held[i] == address(aapl) || held[i] == address(nvda));
        }
        if (vault.totalSupply() > 1e9) assertGt(vault.totalAssets(), 0);
    }
}
