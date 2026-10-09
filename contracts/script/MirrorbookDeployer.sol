// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Timelock} from "../src/Timelock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {Guardrails} from "../src/Guardrails.sol";
import {FeeEngine} from "../src/FeeEngine.sol";
import {PerformanceTracker} from "../src/PerformanceTracker.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {FollowerStops} from "../src/FollowerStops.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";

/// @notice Deployment + wiring logic shared by script/Deploy.s.sol and the fork tests.
abstract contract MirrorbookDeployer {
    struct Roles {
        address deployer; // temporary admin during wiring
        address guardian; // pause/unpause, market force-close, holiday operator, compliance admin
        address treasury; // protocol fee recipient
        address proposer; // Timelock proposer (and canceller)
        uint256 timelockDelay;
    }

    struct Deployment {
        Timelock timelock;
        OracleAdapter oracle;
        MarketClock marketClock;
        VaultFactory factory;
        Guardrails guardrails;
        FeeEngine feeEngine;
        PerformanceTracker tracker;
        TradeExecutor tradeExecutor;
        FollowerStops followerStops;
        FeeCollector feeCollector;
        ComplianceRegistry compliance;
        ProjectTokenHooks projectHooks;
        DexAdapter dexAdapter;
    }

    bytes32 internal constant ADMIN = 0x00;

    function _deployAll(Roles memory r) internal returns (Deployment memory d) {
        address[] memory proposers = new address[](1);
        proposers[0] = r.proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured operation
        d.timelock = new Timelock(r.timelockDelay, proposers, executors);

        d.oracle = new OracleAdapter(r.deployer);
        d.oracle.setFeed(
            RobinhoodConfig.USDG,
            RobinhoodConfig.USDG_USD_FEED,
            RobinhoodConfig.USDG_MAX_STALENESS,
            RobinhoodConfig.USDG_MAX_ROUND_DEVIATION_BPS,
            false
        );
        d.oracle.setPriceBand(RobinhoodConfig.USDG, 0.97e18, 1.03e18);
        RobinhoodConfig.Stock[] memory stocks = RobinhoodConfig.stocks();
        for (uint256 i; i < stocks.length; ++i) {
            d.oracle.setFeed(
                stocks[i].token,
                stocks[i].feed,
                RobinhoodConfig.STOCK_MAX_STALENESS,
                RobinhoodConfig.STOCK_MAX_ROUND_DEVIATION_BPS,
                true
            );
        }

        d.marketClock = new MarketClock(r.deployer, r.guardian, r.guardian);
        d.factory = new VaultFactory(RobinhoodConfig.USDG, r.deployer, r.guardian);
        d.guardrails = new Guardrails(r.deployer);
        d.feeEngine = new FeeEngine(r.deployer);
        d.tracker = new PerformanceTracker(address(d.factory));
        d.tradeExecutor = new TradeExecutor(address(d.factory));
        d.followerStops = new FollowerStops(address(d.factory));
        d.feeCollector = new FeeCollector(r.deployer, r.treasury);
        d.compliance = new ComplianceRegistry(r.deployer, r.guardian);
        d.projectHooks = new ProjectTokenHooks(r.deployer, RobinhoodConfig.USDG, r.guardian);
        d.dexAdapter = new DexAdapter(RobinhoodConfig.SWAP_ROUTER_02, RobinhoodConfig.UNI_V3_FACTORY, r.deployer);

        d.guardrails.setFactory(address(d.factory));
        d.feeCollector.setFactory(address(d.factory));
        d.factory.initModules(
            VaultFactory.Modules({
                oracle: address(d.oracle),
                guardrails: address(d.guardrails),
                tradeExecutor: address(d.tradeExecutor),
                feeEngine: address(d.feeEngine),
                tracker: address(d.tracker),
                feeCollector: address(d.feeCollector),
                marketClock: address(d.marketClock),
                followerStops: address(d.followerStops),
                compliance: address(d.compliance) // installed but disabled (allows everyone)
            })
        );
        d.factory.setAdapter(address(d.dexAdapter), true);
        for (uint256 i; i < stocks.length; ++i) {
            d.guardrails.setWhitelisted(stocks[i].token, true);
        }
        d.feeEngine.setProjectHooks(address(d.projectHooks));
        d.feeCollector.setProjectHooks(address(d.projectHooks));
        d.projectHooks.setFeeCollector(address(d.feeCollector));
    }

    /// @notice Moves every admin role to the Timelock and removes the deployer.
    function _handoff(Deployment memory d, address deployer) internal {
        address tl = address(d.timelock);
        AccessControl[9] memory acs = [
            AccessControl(address(d.oracle)),
            AccessControl(address(d.marketClock)),
            AccessControl(address(d.factory)),
            AccessControl(address(d.guardrails)),
            AccessControl(address(d.feeEngine)),
            AccessControl(address(d.feeCollector)),
            AccessControl(address(d.compliance)),
            AccessControl(address(d.projectHooks)),
            AccessControl(address(d.dexAdapter))
        ];
        for (uint256 i; i < 9; ++i) {
            acs[i].grantRole(ADMIN, tl);
        }
        bytes32 slasher = d.projectHooks.SLASHER_ROLE();
        d.projectHooks.grantRole(slasher, tl);
        d.projectHooks.renounceRole(slasher, deployer);
        for (uint256 i; i < 9; ++i) {
            acs[i].renounceRole(ADMIN, deployer);
        }
    }
}
