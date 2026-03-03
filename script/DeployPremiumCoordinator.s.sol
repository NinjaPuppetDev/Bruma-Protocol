// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";

/**
 * @title DeployPremiumCoordinator
 * @notice Deploy only the PremiumCalculatorCoordinator
 * @dev Step 2 of 3: Deploy coordinator after consumer
 */
contract DeployPremiumCoordinator is Script {
    // UPDATE THIS with your deployed consumer address from Step 1
    address constant PREMIUM_CONSUMER = 0xEB36260fc0647D9ca4b67F40E1310697074897d4;

    function run() external returns (address coordinator) {
        console.log("=== Deploying PremiumCalculatorCoordinator ===");
        console.log("Deployer:", msg.sender);
        console.log("Consumer:", PREMIUM_CONSUMER);

        require(PREMIUM_CONSUMER != address(0), "PREMIUM_CONSUMER not set!");

        vm.startBroadcast();

        // Deploy Coordinator
        PremiumCalculatorCoordinator coordinatorContract = new PremiumCalculatorCoordinator(PREMIUM_CONSUMER);
        coordinator = address(coordinatorContract);

        console.log("\nPremiumCalculatorCoordinator deployed at:", coordinator);
        console.log("Owner:", coordinatorContract.owner());

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("COORDINATOR_ADDRESS:", coordinator);

        console.log("\n=== Next Steps ===");
        console.log("1. Transfer consumer ownership to coordinator:");
        console.log("   cast send %s \\", PREMIUM_CONSUMER);
        console.log("     \"transferOwnership(address)\" \\");
        console.log("     %s \\", coordinator);
        console.log("     --rpc-url sepolia --private-key $PRIVATE_KEY");

        console.log("\n2. Accept ownership from coordinator:");
        console.log("   cast send %s \\", coordinator);
        console.log("     \"acceptConsumerOwnership()\" \\");
        console.log("     --rpc-url sepolia --private-key $PRIVATE_KEY");

        console.log("\n3. Deploy WeatherOptionV3:");
        console.log("   Update DeployWeatherOptionV3.s.sol with:");
        console.log("   PREMIUM_COORDINATOR = %s", coordinator);
        console.log("   PREMIUM_CONSUMER = %s", PREMIUM_CONSUMER);

        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" %s) \\", PREMIUM_CONSUMER);
        console.log("  %s \\", coordinator);
        console.log("  src/PremiumCalculatorCoordinator.sol:PremiumCalculatorCoordinator");

        return coordinator;
    }
}
