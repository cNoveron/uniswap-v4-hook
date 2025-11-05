// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PointsHook.sol";

contract DeployHook is Script {
    function run() external {
        uint privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // TODO: Implement HookMiner logic to generate salt for valid hook address
        PointsHook hook = new PointsHook();

        vm.stopBroadcast();
    }
}