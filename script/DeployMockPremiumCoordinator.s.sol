// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockPremiumCalculatorConsumer} from "../test/mocks/MockPremiumCalculatorConsumer.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";

/**
 * @title DeployMockPremiumCalculator
 * @notice Deploy MOCK premium calculator for LOCAL TESTING ONLY
 * @dev DO NOT use this for production/testnet - use DeployPremiumConsumer + DeployPremiumCoordinator instead
 */
contract DeployMockPremiumCalculator is Script {
    function run() external returns (address coordinator, address consumer) {
        console.log("=== Deploying MOCK Premium Calculator (TESTING ONLY) ===");
        console.log("Deployer:", msg.sender);
        console.log("WARNING: This is for LOCAL TESTING only!");
        console.log("For testnet/mainnet, use DeployPremiumConsumer.s.sol + DeployPremiumCoordinator.s.sol\n");

        vm.startBroadcast();

        // 1. Deploy Mock Consumer
        MockPremiumCalculatorConsumer consumerContract = new MockPremiumCalculatorConsumer();
        consumer = address(consumerContract);
        console.log("MockPremiumCalculatorConsumer deployed at:", consumer);

        // 2. Deploy Coordinator (with dummy subscription ID for mock)
        PremiumCalculatorCoordinator coordinatorContract = new PremiumCalculatorCoordinator(consumer);
        coordinator = address(coordinatorContract);
        console.log("PremiumCalculatorCoordinator deployed at:", coordinator);

        // 3. Transfer consumer ownership to coordinator
        consumerContract.transferOwnership(coordinator);
        console.log("Consumer ownership transferred to Coordinator");

        vm.stopBroadcast();

        console.log("\n=== Mock Deployment Complete ===");
        console.log("PREMIUM_COORDINATOR:", coordinator);
        console.log("PREMIUM_CONSUMER:", consumer);

        console.log("\n=== For Testing ===");
        console.log("You can now run: forge test -vv");
        console.log("Mock consumer allows manual fulfillment via mockFulfillRequest()");

        return (coordinator, consumer);
    }
}
