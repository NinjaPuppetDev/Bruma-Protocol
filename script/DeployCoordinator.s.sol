// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {RainfallCoordinator} from "../src/chainlinkfunctions/RainfallCoordinator.sol";

contract DeployRainfallCoordinator is Script {
    // === CONFIG ===
    address constant CONSUMER = 0x96722110DE16F18d3FF21E070F2251cbf8376f92;

    uint64 constant SUBSCRIPTION_ID = 6256;

    function run() external {
        vm.startBroadcast();

        RainfallCoordinator coordinator = new RainfallCoordinator(CONSUMER, SUBSCRIPTION_ID);

        vm.stopBroadcast();

        console2.log("RainfallCoordinator deployed at:");
        console2.log(address(coordinator));

        console2.log("Using consumer:");
        console2.log(CONSUMER);

        console2.log("Using subscriptionId:");
        console2.logUint(SUBSCRIPTION_ID);
    }
}
