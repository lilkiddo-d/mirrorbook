// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {MirrorbookDeployer} from "./MirrorbookDeployer.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";

/// @title Deploy
/// @notice Deploys and wires the whole protocol on Robinhood Chain, hands every admin role to the 48h
///         Timelock and writes deployments/<chainId>.json + app/src/config/deployments.<chainId>.json.
///
/// Signs ONLY through the Foundry keystore account `mirrorbook-deployer` (no private keys anywhere):
///   forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///     --account mirrorbook-deployer --sender <DEPLOYER_ADDRESS> --broadcast --slow --verify --verifier sourcify
/// (Sourcify supports chain 4663 and Blockscout imports its sources; see DEPLOY.md.)
///
/// Optional env: GUARDIAN, TREASURY, TIMELOCK_PROPOSER (default: deployer), TIMELOCK_DELAY (default 48h).
contract Deploy is Script, MirrorbookDeployer {
    function run() external returns (Deployment memory d) {
        // Mainnet (4663) or a local anvil fork of it (any chain id) -- the canonical USDG must exist.
        require(RobinhoodConfig.USDG.code.length != 0, "Deploy: Robinhood Chain state not found");
        address deployer = msg.sender;
        Roles memory r = Roles({
            deployer: deployer,
            guardian: vm.envOr("GUARDIAN", deployer),
            treasury: vm.envOr("TREASURY", deployer),
            proposer: vm.envOr("TIMELOCK_PROPOSER", deployer),
            timelockDelay: vm.envOr("TIMELOCK_DELAY", uint256(48 hours))
        });

        vm.startBroadcast(deployer);
        d = _deployAll(r);
        _handoff(d, deployer);
        vm.stopBroadcast();

        _write(d, r);
    }

    /// @dev Robinhood Chain is an Arbitrum Orbit chain: in the EVM `block.number` is the L1 block. Keepers scan
    ///      logs by L2 block, so ask the node directly.
    function _l2BlockNumber() internal returns (uint256 n) {
        bytes memory raw = vm.rpc("eth_blockNumber", "[]");
        for (uint256 i; i < raw.length; ++i) {
            n = (n << 8) | uint8(raw[i]);
        }
    }

    function _write(Deployment memory d, Roles memory r) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", _l2BlockNumber());
        vm.serializeAddress(k, "asset", RobinhoodConfig.USDG);
        vm.serializeAddress(k, "timelock", address(d.timelock));
        vm.serializeAddress(k, "oracleAdapter", address(d.oracle));
        vm.serializeAddress(k, "marketClock", address(d.marketClock));
        vm.serializeAddress(k, "vaultFactory", address(d.factory));
        vm.serializeAddress(k, "guardrails", address(d.guardrails));
        vm.serializeAddress(k, "feeEngine", address(d.feeEngine));
        vm.serializeAddress(k, "performanceTracker", address(d.tracker));
        vm.serializeAddress(k, "tradeExecutor", address(d.tradeExecutor));
        vm.serializeAddress(k, "followerStops", address(d.followerStops));
        vm.serializeAddress(k, "feeCollector", address(d.feeCollector));
        vm.serializeAddress(k, "complianceRegistry", address(d.compliance));
        vm.serializeAddress(k, "projectTokenHooks", address(d.projectHooks));
        vm.serializeAddress(k, "dexAdapter", address(d.dexAdapter));
        vm.serializeAddress(k, "guardian", r.guardian);
        vm.serializeAddress(k, "treasury", r.treasury);
        string memory json = vm.serializeAddress(k, "timelockProposer", r.proposer);

        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory id = vm.toString(block.chainid);
        string memory suffix = live ? ".json" : ".dry-run.json";
        string memory root = vm.projectRoot();
        vm.writeJson(json, string.concat(root, "/../deployments/", id, suffix));
        vm.writeJson(json, string.concat(root, "/../app/src/config/deployments/", id, suffix));
        console2.log("VaultFactory:", address(d.factory));
        console2.log("Timelock:", address(d.timelock));
        console2.log(live ? "Wrote deployments (broadcast)" : "Dry run: wrote *.dry-run.json only");
    }
}
