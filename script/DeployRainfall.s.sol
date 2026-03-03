// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {RainfallFunctionsConsumer} from "../src/chainlinkfunctions/RainfallConsumer.sol";

contract DeployRainfall is Script {
    function run() external returns (RainfallFunctionsConsumer consumer) {
        vm.startBroadcast();

        consumer = new RainfallFunctionsConsumer();

        vm.stopBroadcast();

        console2.log("RainfallFunctionsConsumer deployed at:");
        console2.log(address(consumer));
    }
}
