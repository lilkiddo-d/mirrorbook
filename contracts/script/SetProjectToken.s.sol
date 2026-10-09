// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Timelock} from "../src/Timelock.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";

/// @title SetProjectToken
/// @notice Wires the externally launched $MIRR token into ProjectTokenHooks through the 48h Timelock.
///         Step 1 (proposer):  --sig "schedule(address,uint256)" <TOKEN> <VERIFIED_MIN_STAKE_WEI>
///         Step 2 (anyone, >=48h later): --sig "execute(address,uint256)" <TOKEN> <VERIFIED_MIN_STAKE_WEI>
///         Reads timelock/hooks addresses from deployments/<chainId>.json.
contract SetProjectToken is Script {
    bytes32 internal constant SALT = keccak256("mirrorbook.setProjectToken.v1");

    function _load() internal view returns (Timelock tl, address hooks) {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json")
        );
        tl = Timelock(payable(vm.parseJsonAddress(json, ".timelock")));
        hooks = vm.parseJsonAddress(json, ".projectTokenHooks");
    }

    function _batch(address hooks, address token, uint256 minStake)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](2);
        values = new uint256[](2);
        data = new bytes[](2);
        targets[0] = hooks;
        targets[1] = hooks;
        data[0] = abi.encodeCall(ProjectTokenHooks.setProjectToken, (token));
        data[1] = abi.encodeCall(ProjectTokenHooks.setVerifiedMinStake, (minStake));
    }

    function schedule(address token, uint256 verifiedMinStake) external {
        require(token.code.length != 0, "token has no code");
        (Timelock tl, address hooks) = _load();
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _batch(hooks, token, verifiedMinStake);
        vm.startBroadcast();
        tl.scheduleBatch(t, v, d, bytes32(0), SALT, tl.getMinDelay());
        vm.stopBroadcast();
        console2.log("Scheduled. Executable after (unix):", block.timestamp + tl.getMinDelay());
    }

    function execute(address token, uint256 verifiedMinStake) external {
        (Timelock tl, address hooks) = _load();
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _batch(hooks, token, verifiedMinStake);
        vm.startBroadcast();
        tl.executeBatch(t, v, d, bytes32(0), SALT);
        vm.stopBroadcast();
        console2.log("Project token set:", ProjectTokenHooks(hooks).projectToken());
    }
}
