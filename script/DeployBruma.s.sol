// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployWeatherOptionV3Fixed
 * @notice Fixed deployment script with proper verification
 */
contract DeployBruma is Script {
    // Existing Sepolia contracts (for rainfall measurement/settlement)
    address constant RAINFALL_COORDINATOR = 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6;
    address constant RAINFALL_CONSUMER = 0x96722110DE16F18d3FF21E070F2251cbf8376f92;

    // WETH on Sepolia
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    // Premium Calculator contracts
    address constant PREMIUM_COORDINATOR = 0xf322B700c27a8C527F058f48481877855bD84F6e;
    address constant PREMIUM_CONSUMER = 0xEB36260fc0647D9ca4b67F40E1310697074897d4;

    function run() external returns (Bruma weatherOption, BrumaVault vault) {
        address deployer = msg.sender;

        console.log("=== WeatherOptionV3 Deployment (FIXED) ===");
        console.log("Deployer:", deployer);
        console.log("RainfallCoordinator:", RAINFALL_COORDINATOR);
        console.log("RainfallConsumer:", RAINFALL_CONSUMER);
        console.log("WETH:", WETH_SEPOLIA);
        console.log("PremiumCoordinator:", PREMIUM_COORDINATOR);
        console.log("PremiumConsumer:", PREMIUM_CONSUMER);

        // Validate addresses
        require(PREMIUM_COORDINATOR != address(0), "PREMIUM_COORDINATOR not set!");
        require(PREMIUM_CONSUMER != address(0), "PREMIUM_CONSUMER not set!");

        vm.startBroadcast();

        // 1. Deploy Vault
        console.log("\n[1/5] Deploying Vault...");
        vault = new BrumaVault(IERC20(WETH_SEPOLIA), "Weather Options Vault", "wopVault");
        console.log("    Vault deployed at:", address(vault));

        // 2. Deploy WeatherOptionV3
        console.log("\n[2/5] Deploying WeatherOptionV3...");
        weatherOption = new Bruma(
            RAINFALL_COORDINATOR, 
            RAINFALL_CONSUMER, 
            PREMIUM_COORDINATOR, 
            PREMIUM_CONSUMER, 
            address(vault), 
            WETH_SEPOLIA
        );
        console.log("    WeatherOptionV3 deployed at:", address(weatherOption));

        // 3. Configure Vault to point to WeatherOption
        console.log("\n[3/5] Configuring Vault...");
        vault.setWeatherOptions(address(weatherOption));
        console.log("    Vault.weatherOptions set to:", address(weatherOption));

        // 4. Configure Premium Coordinator
        console.log("\n[4/5] Configuring Premium Coordinator...");
        (bool success,) = PREMIUM_COORDINATOR.call(
            abi.encodeWithSignature("setWeatherOptions(address)", address(weatherOption))
        );
        if (success) {
            console.log("    PremiumCoordinator.weatherOptions set to:", address(weatherOption));
        } else {
            console.log("    WARNING: Could not configure PremiumCoordinator");
            console.log("    You may need to call setWeatherOptions manually");
        }

        // 5. Verify configuration
        console.log("\n[5/5] Verifying Configuration...");
        _verifyDeployment(weatherOption, vault);

        vm.stopBroadcast();

        console.log("\n=== Deployment Successful ===");
        _printSummary(weatherOption, vault);
        _printNextSteps(address(vault));
        _printVerificationCommands(address(vault), address(weatherOption));

        return (weatherOption, vault);
    }

    function _verifyDeployment(Bruma weatherOption, BrumaVault vault) internal view {
        console.log("    Checking WeatherOptionV3:");
        console.log("      - owner:", weatherOption.owner());
        console.log("      - vault:", address(weatherOption.vault()));
        console.log("      - weth:", address(weatherOption.weth()));
        console.log("      - rainfallCoordinator:", address(weatherOption.rainfallCoordinator()));
        console.log("      - premiumCoordinator:", address(weatherOption.premiumCoordinator()));
        console.log("      - protocolFeeBps:", weatherOption.protocolFeeBps());
        console.log("      - minPremium:", weatherOption.minPremium());
        console.log("      - minNotional:", weatherOption.minNotional());

        console.log("\n    Checking Vault:");
        console.log("      - owner:", vault.owner());
        console.log("      - weatherOptions:", vault.weatherOptions());
        console.log("      - weth:", address(vault.weth()));
        console.log("      - totalAssets:", vault.totalAssets());
        console.log("      - maxUtilizationBps:", vault.maxUtilizationBps());

        // Validate critical connections
        require(address(weatherOption.vault()) == address(vault), "Vault not set correctly on WeatherOption!");
        require(vault.weatherOptions() == address(weatherOption), "WeatherOption not set correctly on Vault!");
        
        console.log("\n     All configurations verified!");
    }

    function _printSummary(Bruma weatherOption, BrumaVault vault) internal view {
        console.log("Deployed Contracts:");
        console.log("  Bruma:", address(weatherOption));
        console.log("  Vault:", address(vault));
        console.log("  Owner:", weatherOption.owner());
        uint256 minPremium = weatherOption.minPremium();
        console.log("  Min Premium:", minPremium, "wei");
        console.log("    (", minPremium / 1e18, "ETH)");
        uint256 minNotional = weatherOption.minNotional();
        console.log("  Min Notional:", minNotional, "wei");
        console.log("    (", minNotional / 1e18, "ETH)");
    }

    function _printNextSteps(address vaultAddr) internal pure {
        console.log("\n=== Next Steps ===");
        console.log("\n1. Fund the Vault with WETH:");
        console.log("   # Wrap ETH to WETH");
        console.log("   cast send %s 'deposit()' --value 2ether --rpc-url $RPC --account rainfall-deployer", WETH_SEPOLIA);
        console.log("\n   # Approve vault");
        console.log("   cast send %s 'approve(address,uint256)' %s 2000000000000000000 --rpc-url $RPC --account rainfall-deployer", WETH_SEPOLIA, vaultAddr);
        console.log("\n   # Deposit to vault");
        console.log("   cast send %s 'deposit(uint256,address)' 2000000000000000000 $YOUR_ADDRESS --rpc-url $RPC --account rainfall-deployer", vaultAddr);
        
        console.log("\n2. Request a premium quote:");
        console.log("   NOW=$(cast block latest --field timestamp --rpc-url $RPC)");
        console.log("   EXPIRY=$((NOW + 259200))  # 3 days");
        console.log("   cast send $BRUMA 'requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))(bytes32)' \\");
        console.log("     '(0,\"10.0\",\"-75.0\",'$NOW','$EXPIRY',100,50,10000000000000000)' \\");
        console.log("     --rpc-url $RPC --account rainfall-deployer");
        
        console.log("\n3. After Chainlink fulfills, create the option:");
        console.log("   cast send $BRUMA 'createOptionWithQuote(bytes32)' <request_id> \\");
        console.log("     --value <total_cost> --rpc-url $RPC --account rainfall-deployer");
    }

    function _printVerificationCommands(address vaultAddr, address optionAddr) internal pure {
        console.log("\n=== Verification Commands ===");

        console.log("\n# Verify Vault:");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode 'constructor(address,string,string)' %s 'Weather Options Vault' 'wopVault') \\", WETH_SEPOLIA);
        console.log("  %s \\", vaultAddr);
        console.log("  src/WeatherOptionsVault.sol:WeatherOptionsVault");

        console.log("\n# Verify WeatherOptionV3:");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode 'constructor(address,address,address,address,address,address)'");
        console.log(RAINFALL_COORDINATOR);
        console.log(RAINFALL_CONSUMER);
        console.log(PREMIUM_COORDINATOR);
        console.log(PREMIUM_CONSUMER);
        console.log(vaultAddr);
        console.log(WETH_SEPOLIA);
        console.log(") \\");
        console.log(optionAddr);
        console.log("  src/WeatherOptionV3.sol:WeatherOptionV3");
    }
}