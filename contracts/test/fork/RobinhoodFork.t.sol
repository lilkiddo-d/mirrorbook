// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MirrorbookDeployer} from "../../script/MirrorbookDeployer.sol";
import {RobinhoodConfig} from "../../script/RobinhoodConfig.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {ManagerVault} from "../../src/ManagerVault.sol";
import {Guardrails} from "../../src/Guardrails.sol";
import {TradeExecutor} from "../../src/TradeExecutor.sol";
import {PerformanceTracker} from "../../src/PerformanceTracker.sol";
import {Timelock} from "../../src/Timelock.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Runs against Robinhood Chain mainnet state (ROBINHOOD_RPC_URL or the public RPC).
contract RobinhoodForkTest is Test, MirrorbookDeployer {
    // Uniswap v3 USDG/NVDA 0.05% pool — used only as a USDG source via prank (no state assumptions)
    address constant USDG_WHALE = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address proposer = makeAddr("proposer");
    address manager = makeAddr("manager");
    address alice = makeAddr("alice");

    Deployment d;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        assertEq(block.chainid, 4663);
        d = _deployAll(
            Roles({
                deployer: address(this),
                guardian: guardian,
                treasury: treasury,
                proposer: proposer,
                timelockDelay: 48 hours
            })
        );
    }

    function test_fork_officialAddressesAreConsistent() public view {
        assertEq(IERC20Metadata(RobinhoodConfig.USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(RobinhoodConfig.USDG).decimals(), 6);
        assertEq(IAggregatorV3(RobinhoodConfig.USDG_USD_FEED).decimals(), 8);
        RobinhoodConfig.Stock[] memory s = RobinhoodConfig.stocks();
        for (uint256 i; i < s.length; ++i) {
            assertEq(IERC20Metadata(s[i].token).symbol(), s[i].symbol, "token symbol");
            assertEq(IERC20Metadata(s[i].token).decimals(), 18, "stock decimals");
            string memory desc = IAggregatorV3(s[i].feed).description();
            assertTrue(_contains(desc, string.concat(s[i].symbol, " / USD")), string.concat("feed mismatch: ", desc));
            (uint256 p,) = d.oracle.getPrice(s[i].token);
            assertGt(p, 0, "price");
            assertTrue(d.guardrails.isWhitelisted(s[i].token));
        }
        (uint256 usd, bool ok) = d.oracle.getPrice(RobinhoodConfig.USDG);
        assertTrue(ok, "USDG feed must be fresh");
        assertApproxEqRel(usd, 1e18, 0.03e18);
    }

    function test_fork_handoffToTimelock() public {
        _handoff(d, address(this));
        bytes32 admin = 0x00;
        address tl = address(d.timelock);
        assertTrue(d.factory.hasRole(admin, tl));
        assertFalse(d.factory.hasRole(admin, address(this)));
        assertTrue(d.oracle.hasRole(admin, tl));
        assertFalse(d.oracle.hasRole(admin, address(this)));
        assertTrue(d.projectHooks.hasRole(d.projectHooks.SLASHER_ROLE(), tl));
        assertFalse(d.projectHooks.hasRole(d.projectHooks.SLASHER_ROLE(), address(this)));
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), proposer));

        // setProjectToken only through the timelock, after 48h, exactly once
        MockERC20 mirr = new MockERC20("Mirror", "MIRR", 18);
        vm.expectRevert();
        d.projectHooks.setProjectToken(address(mirr));
        bytes memory call = abi.encodeCall(d.projectHooks.setProjectToken, (address(mirr)));
        vm.prank(proposer);
        d.timelock.schedule(address(d.projectHooks), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        d.timelock.execute(address(d.projectHooks), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        d.timelock.execute(address(d.projectHooks), 0, call, bytes32(0), bytes32(0));
        assertEq(d.projectHooks.projectToken(), address(mirr));
    }

    function test_fork_endToEndWithRealPools() public {
        // Test-only: keep the market "open" and tolerate weekend feed age so the test runs any day.
        d.marketClock.setWeeklyClosure(0, 0);
        RobinhoodConfig.Stock[] memory s = RobinhoodConfig.stocks();
        d.oracle.setFeed(RobinhoodConfig.USDG, RobinhoodConfig.USDG_USD_FEED, 4 days, 200, false);
        for (uint256 i; i < s.length; ++i) {
            d.oracle.setFeed(s[i].token, s[i].feed, 4 days, 2_500, true);
        }

        vm.prank(manager);
        ManagerVault vault = ManagerVault(
            d.factory.createVault(
                VaultFactory.CreateParams({
                    name: "Fork Alpha",
                    symbol: "fALPHA",
                    managementFeeBps: 100,
                    performanceFeeBps: 1_000,
                    minHoldPeriod: 0,
                    metadataURI: "",
                    guardrails: Guardrails.Config({maxPositionBps: 6_000, maxTradesPerDay: 5, maxSlippageBps: 500})
                })
            )
        );

        vm.prank(USDG_WHALE);
        IERC20Metadata(RobinhoodConfig.USDG).transfer(alice, 1_000e6);
        vm.startPrank(alice);
        IERC20Metadata(RobinhoodConfig.USDG).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 1_000e6);

        // Buy NVDA through the real Uniswap v3 0.05% pool, bounded by the Chainlink price.
        vm.prank(manager);
        uint256 got = d.tradeExecutor.execute(
            TradeExecutor.Trade({
                vault: address(vault),
                adapter: address(d.dexAdapter),
                tokenIn: RobinhoodConfig.USDG,
                tokenOut: NVDA,
                amountIn: 200e6,
                minAmountOut: 0,
                deadline: block.timestamp + 10 minutes,
                adapterData: abi.encode(uint24(500))
            })
        );
        assertGt(got, 0);
        (uint256 nav, bool fresh) = vault.navFresh();
        assertTrue(fresh);
        console2.log("NAV after buy (USDG 6dp):", nav);
        assertApproxEqRel(nav, 1_000e6, 0.05e18); // within the 5% slippage guardrail

        // Sell it back.
        vm.prank(manager);
        d.tradeExecutor.execute(
            TradeExecutor.Trade({
                vault: address(vault),
                adapter: address(d.dexAdapter),
                tokenIn: NVDA,
                tokenOut: RobinhoodConfig.USDG,
                amountIn: got / 2,
                minAmountOut: 0,
                deadline: block.timestamp + 10 minutes,
                adapterData: abi.encode(uint24(500))
            })
        );

        // Track record + in-kind exit.
        (,, uint32 lastDay) = d.tracker.tracks(address(vault));
        assertEq(lastDay, uint32(block.timestamp / 1 days));
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (address[] memory tokens, uint256[] memory amounts) = vault.redeemInKind(shares, alice, alice);
        assertEq(tokens[1], NVDA);
        assertGt(amounts[1], 0);
        assertEq(IERC20Metadata(NVDA).balanceOf(alice), amounts[1]);
    }

    function test_fork_adapterRejectsBadPrice() public {
        d.marketClock.setWeeklyClosure(0, 0);
        d.oracle.setFeed(RobinhoodConfig.USDG, RobinhoodConfig.USDG_USD_FEED, 4 days, 200, false);
        d.oracle.setFeed(NVDA, RobinhoodConfig.stocks()[1].feed, 4 days, 2_500, true);
        vm.prank(manager);
        ManagerVault vault = ManagerVault(
            d.factory.createVault(
                VaultFactory.CreateParams({
                    name: "Tight",
                    symbol: "T",
                    managementFeeBps: 0,
                    performanceFeeBps: 0,
                    minHoldPeriod: 0,
                    metadataURI: "",
                    guardrails: Guardrails.Config({maxPositionBps: 10_000, maxTradesPerDay: 5, maxSlippageBps: 5})
                })
            )
        );
        vm.prank(USDG_WHALE);
        IERC20Metadata(RobinhoodConfig.USDG).transfer(alice, 1_000e6);
        vm.startPrank(alice);
        IERC20Metadata(RobinhoodConfig.USDG).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
        // 1% fee tier: pool fee alone exceeds a 5 bps slippage budget -> must revert
        vm.prank(manager);
        vm.expectRevert();
        d.tradeExecutor.execute(
            TradeExecutor.Trade({
                vault: address(vault),
                adapter: address(d.dexAdapter),
                tokenIn: RobinhoodConfig.USDG,
                tokenOut: NVDA,
                amountIn: 100e6,
                minAmountOut: 0,
                deadline: block.timestamp + 10 minutes,
                adapterData: abi.encode(uint24(10_000))
            })
        );
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function _contains(string memory h, string memory n) internal pure returns (bool) {
        bytes memory hb = bytes(h);
        bytes memory nb = bytes(n);
        if (nb.length > hb.length) return false;
        for (uint256 i; i <= hb.length - nb.length; ++i) {
            bool ok = true;
            for (uint256 j; j < nb.length; ++j) {
                if (hb[i + j] != nb[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
