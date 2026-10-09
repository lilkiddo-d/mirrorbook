// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {ManagerVault} from "../src/ManagerVault.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {MockDexAdapter} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract ManagerVaultTest is Base {
    function test_initialState() public view {
        assertEq(vault.manager(), manager);
        assertEq(vault.asset(), address(usdg));
        assertEq(vault.decimals(), 12);
        assertEq(vault.highWaterMark(), 1e18);
        assertEq(vault.managementFeeBps(), 200);
        assertEq(vault.performanceFeeBps(), 2000);
        assertEq(vault.metadataURI(), "ipfs://alpha");
        (uint256 price, bool fresh) = vault.sharePrice();
        assertEq(price, 1e18);
        assertTrue(fresh);
    }

    function test_cannotReinitialize() public {
        ManagerVault.InitParams memory p;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(p);
    }

    function test_implementationLocked() public {
        ManagerVault impl = ManagerVault(factory.vaultImplementation());
        ManagerVault.InitParams memory p;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    function test_depositAndRedeemCash() public {
        uint256 shares = _deposit(alice, 1_000e6);
        assertEq(shares, 1_000e12);
        assertEq(vault.totalAssets(), 1_000e6);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, 1_000e6);
        assertEq(usdg.balanceOf(alice), 1_000e6);
    }

    function test_mintAndWithdraw() public {
        usdg.mint(alice, 500e6);
        vm.startPrank(alice);
        usdg.approve(address(vault), 500e6);
        uint256 assets = vault.mint(100e12, alice);
        assertEq(assets, 100e6);
        uint256 burned = vault.withdraw(50e6, alice, alice);
        assertEq(burned, 50e12);
        vm.stopPrank();
    }

    function test_zeroShareDepositReverts() public {
        usdg.mint(alice, 1);
        vm.startPrank(alice);
        usdg.approve(address(vault), 1);
        vault.deposit(1, alice); // 1 unit -> 1e6 shares, ok
        vm.expectRevert(ManagerVault.ZeroShares.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    function test_navIncludesStocks() public {
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 2_000e6);
        assertEq(aapl.balanceOf(address(vault)), 10e18);
        assertEq(vault.totalAssets(), 10_000e6);
        address[] memory held = vault.heldTokens();
        assertEq(held.length, 1);
        aaplFeed.set(220e8);
        assertEq(vault.totalAssets(), 10_200e6);
    }

    function test_cashOpsClosedWhenMarketClosedWithStocks() public {
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 2_000e6);
        vm.warp(SATURDAY);
        _refreshFeeds();
        assertFalse(vault.cashOpsOpen());
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_cashOnlyVaultOpenOnWeekend() public {
        vm.warp(SATURDAY);
        _refreshFeeds();
        assertTrue(vault.cashOpsOpen());
        _deposit(alice, 100e6);
    }

    function test_cashOpsClosedWhenStale() public {
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 2_000e6);
        vm.warp(block.timestamp + 2 days);
        assertFalse(vault.cashOpsOpen());
        (, bool fresh) = vault.navFresh();
        assertFalse(fresh);
    }

    function test_cashOpsClosedWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        assertFalse(vault.cashOpsOpen());
        vm.prank(guardian);
        vault.unpause();
        vm.prank(guardian);
        factory.pause();
        assertFalse(vault.cashOpsOpen());
    }

    function test_pauseOnlyGuardian() public {
        vm.expectRevert(ManagerVault.OnlyGuardian.selector);
        vault.pause();
        vm.expectRevert(ManagerVault.OnlyGuardian.selector);
        vault.unpause();
    }

    function test_maxWithdrawLimitedByIdleCash() public {
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 5_000e6);
        _trade(address(usdg), address(nvda), 4_000e6);
        assertEq(vault.maxWithdraw(alice), 1_000e6);
        assertApproxEqAbs(vault.maxRedeem(alice), 1_000e12, 1e6);
    }

    function test_inKindRedeemAlwaysAvailable() public {
        _deposit(alice, 10_000e6);
        _deposit(bob, 10_000e6);
        _trade(address(usdg), address(aapl), 5_000e6);
        vm.warp(SATURDAY);
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        factory.pause();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemInKind(shares, alice, alice);
        assertEq(tokens.length, 2);
        assertEq(tokens[1], address(aapl));
        // alice ~50% of 15k cash and 25 AAPL (minus mgmt fee dilution over ~2.9 days)
        assertApproxEqRel(amounts[0], 7_500e6, 0.001e18);
        assertApproxEqRel(amounts[1], 12.5e18, 0.001e18);
        assertEq(usdg.balanceOf(alice), amounts[0]);
        assertEq(aapl.balanceOf(alice), amounts[1]);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_inKindRedeemWithAllowance() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        vault.redeemInKind(shares, bob, alice);
        assertEq(usdg.balanceOf(bob), 1_000e6);
    }

    function test_inKindRedeemZeroReverts() public {
        vm.expectRevert(ManagerVault.ZeroShares.selector);
        vault.redeemInKind(0, alice, alice);
    }

    function test_minHoldLock() public {
        ManagerVault v = _createVault(manager, 0, 0, 1 days);
        vault = v;
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManagerVault.Locked.selector, uint64(block.timestamp + 1 days)));
        vault.redeemInKind(shares, alice, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManagerVault.Locked.selector, uint64(block.timestamp + 1 days)));
        vault.transfer(bob, shares);
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        vm.prank(alice);
        vault.transfer(bob, shares);
        assertEq(vault.maxRedeem(bob), shares);
    }

    function test_complianceGatesDepositAndTransfers() public {
        vm.prank(admin);
        compliance.setEnabled(true);
        assertEq(vault.maxDeposit(alice), 0);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(admin);
        compliance.setAllowed(list, true);
        _deposit(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManagerVault.NotCompliant.selector, bob));
        vault.transfer(bob, 1);
        // exits are never gated
        vm.prank(admin);
        compliance.setAllowed(list, false);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    function test_complianceHookCanBeRemoved() public {
        vm.prank(admin);
        factory.setModule("compliance", address(0));
        _deposit(alice, 100e6);
    }

    function test_executeSwapOnlyExecutor() public {
        vm.prank(manager);
        vm.expectRevert(ManagerVault.OnlyExecutor.selector);
        vault.executeSwap(address(dex), address(usdg), address(aapl), 1, 0, block.timestamp, "");
    }

    function test_executeSwapRejectsUnknownAdapter() public {
        _deposit(alice, 1_000e6);
        MockDexAdapter rogue = new MockDexAdapter(address(oracle));
        vm.prank(address(executor));
        vm.expectRevert(ManagerVault.AdapterNotAllowed.selector);
        vault.executeSwap(address(rogue), address(usdg), address(aapl), 1e6, 0, block.timestamp, "");
    }

    function test_executeSwapParamChecks() public {
        _deposit(alice, 1_000e6);
        vm.startPrank(address(executor));
        vm.expectRevert(ManagerVault.InvalidParam.selector);
        vault.executeSwap(address(dex), address(usdg), address(usdg), 1e6, 0, block.timestamp, "");
        vm.expectRevert(ManagerVault.InvalidParam.selector);
        vault.executeSwap(address(dex), address(usdg), address(aapl), 0, 0, block.timestamp, "");
        vm.expectRevert(ManagerVault.InvalidParam.selector);
        vault.executeSwap(address(dex), address(usdg), address(aapl), 2_000e6, 0, block.timestamp, "");
        vm.stopPrank();
    }

    function test_executeSwapEnforcesMinOut() public {
        _deposit(alice, 1_000e6);
        dex.setLossBps(500);
        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(ManagerVault.SlippageExceeded.selector, 0.95e18, 1e18));
        vault.executeSwap(address(dex), address(usdg), address(aapl), 200e6, 1e18, block.timestamp, "");
    }

    function test_executeSwapCannotPullMoreThanAmountIn() public {
        _deposit(alice, 1_000e6);
        dex.setPullExtra(1);
        vm.prank(address(executor));
        vm.expectRevert(); // allowance is exactly amountIn
        vault.executeSwap(address(dex), address(usdg), address(aapl), 200e6, 0, block.timestamp, "");
    }

    function test_holdingRemovedWhenSoldOut() public {
        _deposit(alice, 1_000e6);
        uint256 got = _trade(address(usdg), address(aapl), 200e6);
        assertTrue(vault.isHeld(address(aapl)));
        _trade(address(aapl), address(usdg), got);
        assertFalse(vault.isHeld(address(aapl)));
        assertEq(vault.heldTokens().length, 0);
    }

    function test_tooManyHoldings() public {
        _deposit(alice, 1_000e6);
        vm.startPrank(address(executor));
        for (uint256 i; i < 10; ++i) {
            address t = address(uint160(0x1000 + i));
            vm.mockCall(t, abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(0));
            vm.mockCall(address(dex), abi.encodeWithSelector(MockDexAdapter.swapExactIn.selector), abi.encode(0));
            vm.mockCall(t, abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)), abi.encode(0));
            vault.executeSwap(address(dex), address(usdg), t, 1, 0, block.timestamp, "");
        }
        vm.expectRevert(ManagerVault.TooManyHoldings.selector);
        vault.executeSwap(address(dex), address(usdg), address(aapl), 1, 0, block.timestamp, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fees

    function test_managementFeeAccruesOverYear() public {
        ManagerVault v = _createVault(manager, 200, 0, 0);
        vault = v;
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        vault.accrueFees();
        uint256 feeShares = vault.balanceOf(manager) + vault.balanceOf(address(collector));
        // holders lose exactly 2% of their claim
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqRel(aliceAssets, 98_000e6, 0.0001e18);
        assertGt(feeShares, 0);
        // protocol cut is 15%
        assertApproxEqRel(vault.balanceOf(address(collector)) * 10_000 / feeShares, 1_500, 0.01e18);
    }

    function test_performanceFeeOverHighWaterMark() public {
        ManagerVault v = _createVault(manager, 0, 2_000, 0);
        vault = v;
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 4_000e6); // 20 AAPL
        aaplFeed.set(240e8); // +800 USDG gain
        vm.warp(block.timestamp + 1);
        vault.accrueFees();
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        // alice keeps 80% of the gain
        assertApproxEqRel(aliceAssets, 10_640e6, 0.0001e18);
        uint256 hwm = vault.highWaterMark();
        assertApproxEqRel(hwm, 1.064e18, 0.0001e18);
        // price falls back: no fee; HWM unchanged
        aaplFeed.set(220e8);
        vm.warp(block.timestamp + 1);
        uint256 supplyBefore = vault.totalSupply();
        vault.accrueFees();
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.highWaterMark(), hwm);
    }

    function test_noPerformanceFeeWhenStale() public {
        ManagerVault v = _createVault(manager, 0, 2_000, 0);
        vault = v;
        _deposit(alice, 10_000e6);
        _trade(address(usdg), address(aapl), 4_000e6);
        aaplFeed.set(240e8);
        vm.warp(block.timestamp + 2 days); // stale
        vault.accrueFees();
        assertEq(vault.balanceOf(manager), 0);
        assertEq(vault.highWaterMark(), 1e18);
    }

    function test_setFeesDecreaseImmediate() public {
        vm.prank(manager);
        vault.setFees(100, 1_000);
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.performanceFeeBps(), 1_000);
    }

    function test_setFeesIncreaseQueued() public {
        vm.prank(manager);
        vault.setFees(200, 2_500);
        assertEq(vault.performanceFeeBps(), 2_000);
        vm.expectRevert(ManagerVault.TooEarly.selector);
        vault.applyPendingFees();
        vm.warp(block.timestamp + 7 days);
        vault.applyPendingFees();
        assertEq(vault.performanceFeeBps(), 2_500);
        vm.expectRevert(ManagerVault.NothingPending.selector);
        vault.applyPendingFees();
    }

    function test_setFeesCapsAndAuth() public {
        vm.prank(manager);
        vm.expectRevert(ManagerVault.InvalidFees.selector);
        vault.setFees(201, 0);
        vm.prank(manager);
        vm.expectRevert(ManagerVault.InvalidFees.selector);
        vault.setFees(0, 2_501);
        vm.expectRevert(ManagerVault.OnlyManager.selector);
        vault.setFees(0, 0);
    }

    function test_createVaultRejectsExcessFees() public {
        vm.expectRevert(ManagerVault.InvalidFees.selector);
        _createVault(manager, 300, 0, 0);
    }

    function test_createVaultRejectsLongHold() public {
        vm.expectRevert(ManagerVault.InvalidParam.selector);
        _createVault(manager, 0, 0, 8 days);
    }

    function test_managerSettings() public {
        vm.startPrank(manager);
        vault.setMinHoldPeriod(2 days);
        assertEq(vault.minHoldPeriod(), 2 days);
        vm.expectRevert(ManagerVault.InvalidParam.selector);
        vault.setMinHoldPeriod(8 days);
        vault.setMetadataURI("ipfs://beta");
        assertEq(vault.metadataURI(), "ipfs://beta");
        vm.stopPrank();
        vm.expectRevert(ManagerVault.OnlyManager.selector);
        vault.setMetadataURI("x");
    }

    function test_verifiedManagerPaysLowerProtocolCut() public {
        assertEq(feeEngine.protocolCutFor(manager), 1_500);
        // simulate verified status
        vm.mockCall(address(hooks), abi.encodeWithSignature("isVerified(address)", manager), abi.encode(true));
        assertEq(feeEngine.protocolCutFor(manager), 1_000);
    }

    function test_tradeThroughExecutorEmitsAndRecords() public {
        _deposit(alice, 10_000e6);
        uint256 out = _trade(address(usdg), address(nvda), 1_000e6);
        assertEq(out, 10e18);
        (,, uint32 lastDay) = tracker.tracks(address(vault));
        assertEq(lastDay, uint32(block.timestamp / 1 days));
    }
}
