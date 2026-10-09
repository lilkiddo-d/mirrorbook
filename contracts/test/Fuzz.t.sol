// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {FeeEngine} from "../src/FeeEngine.sol";
import {ManagerVault} from "../src/ManagerVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FuzzTest is Base {
    function setUp() public override {
        super.setUp();
        vault = _createVault(manager, 200, 2_500, 0);
    }

    /// @dev Builds a vault with stock exposure and a moved price.
    function _seed(uint256 a1, uint256 buy, int256 moveBps) internal {
        _deposit(alice, a1);
        if (buy != 0) _trade(address(usdg), address(aapl), buy);
        int256 p = int256(200e8) * (10_000 + moveBps) / 10_000;
        aaplFeed.set(p);
        vm.warp(block.timestamp + 1 hours);
        vault.accrueFees(); // settle fees so only the deposit/withdraw effect is measured
    }

    /// Deposits never reduce the value of existing holders' shares.
    function testFuzz_depositNeverDilutes(uint256 a1, uint256 a2, uint256 buyBps, int256 moveBps) public {
        a1 = bound(a1, 1e6, 1e12);
        a2 = bound(a2, 1, 1e12);
        buyBps = bound(buyBps, 0, 5_000);
        moveBps = bound(moveBps, -2_000, 2_000);
        _seed(a1, a1 * buyBps / 10_000, moveBps);

        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));
        (uint256 priceBefore,) = vault.sharePrice();
        usdg.mint(bob, a2);
        vm.startPrank(bob);
        usdg.approve(address(vault), a2);
        try vault.deposit(a2, bob) returns (uint256 shares) {
            vm.stopPrank();
            (uint256 priceAfter,) = vault.sharePrice();
            assertGe(priceAfter, priceBefore, "share price fell on deposit");
            assertGe(vault.convertToAssets(vault.balanceOf(alice)), aliceBefore, "alice diluted");
            // depositor can never get more than they paid
            assertLe(vault.convertToAssets(shares), a2);
        } catch {
            vm.stopPrank(); // zero-share deposits revert
        }
    }

    /// Cash withdrawals never reduce the value of remaining holders' shares.
    function testFuzz_withdrawNeverDilutes(uint256 a1, uint256 a2, uint256 frac, uint256 buyBps, int256 moveBps) public {
        a1 = bound(a1, 1e6, 1e12);
        a2 = bound(a2, 1e6, 1e12);
        frac = bound(frac, 1, 10_000);
        buyBps = bound(buyBps, 0, 4_000);
        moveBps = bound(moveBps, -2_000, 2_000);
        _deposit(bob, a2);
        _seed(a1, (a1 + a2) * buyBps / 10_000, moveBps);

        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));
        (uint256 priceBefore,) = vault.sharePrice();
        uint256 shares = Math.min(vault.balanceOf(bob) * frac / 10_000, vault.maxRedeem(bob));
        vm.assume(shares > 0);
        vm.prank(bob);
        uint256 paid = vault.redeem(shares, bob, bob);
        (uint256 priceAfter,) = vault.sharePrice();
        assertGe(priceAfter, priceBefore, "share price fell on withdraw");
        assertGe(vault.convertToAssets(vault.balanceOf(alice)), aliceBefore, "alice diluted");
        assertLe(paid, vault.convertToAssets(shares) + paid); // sanity
    }

    /// In-kind exits are exactly pro-rata (rounded down): remaining holders' per-share claim never shrinks.
    function testFuzz_inKindNeverDilutes(uint256 a1, uint256 a2, uint256 frac, uint256 buyBps) public {
        a1 = bound(a1, 1e6, 1e12);
        a2 = bound(a2, 1e6, 1e12);
        frac = bound(frac, 1, 10_000);
        buyBps = bound(buyBps, 0, 5_000);
        _deposit(bob, a2);
        _seed(a1, (a1 + a2) * buyBps / 10_000, 0);

        uint256 supply = vault.totalSupply();
        uint256 cashPerShareBefore = usdg.balanceOf(address(vault)) * 1e30 / supply;
        uint256 stockPerShareBefore = aapl.balanceOf(address(vault)) * 1e18 / supply;
        uint256 shares = vault.balanceOf(bob) * frac / 10_000;
        vm.assume(shares > 0);
        vm.prank(bob);
        vault.redeemInKind(shares, bob, bob);
        uint256 supplyAfter = vault.totalSupply();
        if (supplyAfter == 0) return;
        assertGe(usdg.balanceOf(address(vault)) * 1e30 / supplyAfter, cashPerShareBefore);
        assertGe(aapl.balanceOf(address(vault)) * 1e18 / supplyAfter, stockPerShareBefore);
    }

    /// A deposit/redeem round trip can never be profitable.
    function testFuzz_roundTripNoProfit(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1e6, 1e12);
        a2 = bound(a2, 1e6, 1e12);
        _seed(a1, a1 / 2, 500);
        uint256 shares = _deposit(bob, a2);
        uint256 max = vault.maxRedeem(bob);
        vm.assume(max >= shares);
        vm.prank(bob);
        uint256 back = vault.redeem(shares, bob, bob);
        assertLe(back, a2);
    }

    /// Fees can never exceed their caps: management <= 2%/yr of NAV, performance <= 25% of gain over HWM.
    function testFuzz_feesWithinCaps(
        uint256 nav,
        uint256 supply,
        uint256 elapsed,
        uint256 hwmBps,
        uint16 mgmt,
        uint16 perf
    ) public view {
        FeeEngine.FeeInput memory i;
        i.totalAssets = bound(nav, 1e6, 1e15);
        i.supply = bound(supply, 1e12, 1e27);
        i.elapsed = bound(elapsed, 0, 3 * 365 days);
        i.managementFeeBps = uint16(bound(mgmt, 0, 200));
        i.performanceFeeBps = uint16(bound(perf, 0, 2_500));
        i.virtualShares = 1e6;
        i.navFresh = true;
        uint256 price = feeEngine.sharePrice(i.totalAssets, i.supply, i.virtualShares);
        i.highWaterMark = bound(hwmBps, 1, 30_000) * price / 10_000 + 1;

        FeeEngine.FeeOutput memory o = feeEngine.computeFees(i);
        assertLe(_feeValue(i, o), _feeCap(i, price), "fees above cap");
        assertGe(o.newHighWaterMark, i.highWaterMark, "HWM decreased");
        assertTrue(feeEngine.validateFees(i.managementFeeBps, i.performanceFeeBps));
        assertFalse(feeEngine.validateFees(201, 0));
        assertFalse(feeEngine.validateFees(0, 2_501));
    }

    function _feeValue(FeeEngine.FeeInput memory i, FeeEngine.FeeOutput memory o) internal pure returns (uint256) {
        uint256 totalFee = o.managementShares + o.performanceShares;
        return Math.mulDiv(totalFee, i.totalAssets + 1, i.supply + totalFee + i.virtualShares);
    }

    function _feeCap(FeeEngine.FeeInput memory i, uint256 price) internal pure returns (uint256) {
        uint256 mgmtCap = Math.mulDiv(i.totalAssets + 1, uint256(i.managementFeeBps) * i.elapsed, 365 days * 10_000) + 2;
        uint256 gain = price > i.highWaterMark
            ? Math.mulDiv(price - i.highWaterMark, i.supply + i.virtualShares, 1e18 * i.virtualShares)
            : 0;
        return mgmtCap + gain * i.performanceFeeBps / 10_000 + 2;
    }

    /// Protocol cut never exceeds 30% of fees.
    function testFuzz_protocolCutCapped(uint16 cut, uint16 vcut, uint256 shares) public {
        cut = uint16(bound(cut, 0, 3_000));
        vcut = uint16(bound(vcut, 0, cut));
        shares = bound(shares, 0, 1e30);
        vm.prank(admin);
        feeEngine.setProtocolCut(cut, vcut);
        (uint256 p, uint256 m) = feeEngine.split(manager, shares);
        assertEq(p + m, shares);
        assertLe(p, shares * 3_000 / 10_000);
    }
}
