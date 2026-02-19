// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PremiumCalculatorConsumer} from "../src/chainlinkfunctions/PremiumCalculatorConsumer.sol";

/**
 * @title DeployPremiumConsumer
 * @notice Deploy only the PremiumCalculatorConsumer (Chainlink Functions consumer)
 * @dev Step 1 of 3: Deploy consumer first
 */
contract DeployPremiumConsumer is Script {
    // Chainlink Functions Router on Sepolia
    address constant FUNCTIONS_ROUTER_SEPOLIA = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;

    // DON ID for Sepolia
    bytes32 constant DON_ID_SEPOLIA = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;

    // Subscription ID - UPDATE THIS!
    uint64 constant SUBSCRIPTION_ID = 6256;

    // Callback gas limit
    uint32 constant CALLBACK_GAS_LIMIT = 300000;

    function run() external returns (address consumer) {
        console.log("=== Deploying PremiumCalculatorConsumer ===");
        console.log("Deployer:", msg.sender);
        console.log("Functions Router:", FUNCTIONS_ROUTER_SEPOLIA);
        console.log("DON ID:", vm.toString(DON_ID_SEPOLIA));
        console.log("Subscription ID:", SUBSCRIPTION_ID);
        console.log("Callback Gas Limit:", CALLBACK_GAS_LIMIT);

        require(SUBSCRIPTION_ID != 0, "SUBSCRIPTION_ID not set!");

        vm.startBroadcast();

        // Deploy Consumer
        PremiumCalculatorConsumer consumerContract =
            new PremiumCalculatorConsumer(FUNCTIONS_ROUTER_SEPOLIA, DON_ID_SEPOLIA, SUBSCRIPTION_ID, CALLBACK_GAS_LIMIT);
        consumer = address(consumerContract);

        console.log("\nPremiumCalculatorConsumer deployed at:", consumer);
        console.log("Owner:", consumerContract.owner());

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("CONSUMER_ADDRESS:", consumer);

        console.log("\n=== Next Steps ===");
        console.log("1. Save this address: PREMIUM_CONSUMER = %s", consumer);
        console.log("2. Deploy coordinator:");
        console.log("   forge script script/DeployPremiumCoordinator.s.sol --rpc-url sepolia --broadcast");
        console.log("3. Transfer consumer ownership to coordinator:");
        console.log("   cast send %s \"transferOwnership(address)\" <COORDINATOR_ADDRESS> --rpc-url sepolia", consumer);
        console.log("4. Accept ownership from coordinator:");
        console.log("   cast send <COORDINATOR_ADDRESS> \"acceptConsumerOwnership()\" --rpc-url sepolia");

        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");

        console.log("  %s \\", consumer);
        console.log("  src/PremiumCalculatorConsumer.sol:PremiumCalculatorConsumer");

        return consumer;
    }
}
