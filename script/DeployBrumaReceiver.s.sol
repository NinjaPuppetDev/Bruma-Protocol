// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BrumaCCIPReceiver} from "../src/BrumaCCIPReceiver.sol";

/**
 * @title DeployBrumaReceiver
 * @notice Deploys BrumaCCIPReceiver on Avalanche Fuji (destination chain).
 *         Run AFTER DeployBrumaFactory.s.sol on Sepolia.
 *
 * USAGE
 *   forge script script/DeployBrumaReceiver.s.sol \
 *     --rpc-url $FUJI_RPC \
 *     --account <your-account> \
 *     --broadcast \
 *     --verify \
 *     --verifier-url https://api.routescan.io/v2/network/testnet/evm/43113/etherscan \
 *     -vvvv
 *
 * REQUIRED ENV
 *   BRUMA_FACTORY_ADDRESS  — BrumaCCIPEscrowFactory deployed on Sepolia
 *
 * HARDCODED (Avalanche Fuji)
 *   CCIP Router, WETH (wrapped AVAX), Ethereum Sepolia chain selector
 */
contract DeployBrumaReceiver is Script {

    // ── Avalanche Fuji Chainlink addresses ────────────────────────────────────
    address constant CCIP_ROUTER_FUJI = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;

    // Wrapped AVAX on Fuji — this is what CCIP delivers as the bridged token
    // Note: CCIP delivers the canonical wrapped version of the source token.
    // For WETH bridged from Sepolia, Chainlink CCIP delivers WETH on Fuji.
    // Use the CCIP-BnM test token for testnet, or real WETH if available.
    address constant WETH_FUJI = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c; // CCIP-BnM on Fuji (testnet)

    // ── Source chain (Ethereum Sepolia) CCIP selector ─────────────────────────
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    function run() external returns (BrumaCCIPReceiver receiver) {
        address factoryAddress = vm.envAddress("BRUMA_FACTORY_ADDRESS");

        console.log("=== BrumaCCIPReceiver Deployment ===");
        console.log("Network:              Avalanche Fuji");
        console.log("CCIP Router:         ", CCIP_ROUTER_FUJI);
        console.log("WETH (bridged):      ", WETH_FUJI);
        console.log("Source chain:         Ethereum Sepolia");
        console.log("Source selector:     ", SEPOLIA_CHAIN_SELECTOR);
        console.log("Bruma Factory (src): ", factoryAddress);

        require(factoryAddress != address(0), "BRUMA_FACTORY_ADDRESS not set");

        vm.startBroadcast();

        receiver = new BrumaCCIPReceiver(
            CCIP_ROUTER_FUJI,
            WETH_FUJI,
            SEPOLIA_CHAIN_SELECTOR
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Successful ===");
        console.log("BrumaCCIPReceiver:   ", address(receiver));
        console.log("  sourceChainSelector:", receiver.sourceChainSelector());
        console.log("  owner:              ", receiver.owner());

        _printNextSteps(address(receiver), factoryAddress);
        _printVerification(address(receiver));
    }

    function _printNextSteps(address receiverAddr, address factoryAddr) internal pure {
        console.log("\n=== Next Steps ===");

        console.log("\n1. Update config.staging.json with this receiver address.");
        console.log("   This is the _destReceiver buyers pass to deployEscrow().");

        console.log("\n2. When a buyer deploys an escrow on Sepolia using this receiver,");
        console.log("   call registerSender() on this receiver to whitelist it:");
        console.log("   cast send %s \\", receiverAddr);
        console.log("     'registerSender(address,address)' \\");
        console.log("     <escrow-address-on-sepolia> \\");
        console.log("     <buyer-address-on-fuji> \\");
        console.log("     --rpc-url $FUJI_RPC --account <your-account>");

        console.log("\n   TIP: The CRE workflow can automate this by watching");
        console.log("   EscrowDeployed events from the factory on Sepolia:");
        console.log("   Factory:", factoryAddr);

        console.log("\n3. Verify cross-chain flow end-to-end:");
        console.log("   a. Buyer deploys escrow on Sepolia pointing to:", receiverAddr);
        console.log("   b. Buyer transfers Bruma NFT to escrow");
        console.log("   c. Wait for option expiry");
        console.log("   d. CRE workflow calls requestSettlement settle claimAndBridge");
        console.log("   e. CCIP delivers WETH to receiver on Fuji");
        console.log("   f. Receiver forwards WETH to buyer's Fuji address");

        console.log("\n4. Monitor CCIP messages at:");
        console.log("   https://ccip.chain.link");
    }

    function _printVerification(address receiverAddr) internal pure {
        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain 43113 \\");
        console.log("  --watch \\");
        console.log("  --verifier-url https://api.routescan.io/v2/network/testnet/evm/43113/etherscan \\");
        console.log("  --constructor-args $(cast abi-encode \\");
        console.log("    'constructor(address,address,uint64)' \\");
        console.log("    %s %s %s) \\", CCIP_ROUTER_FUJI, WETH_FUJI, SEPOLIA_CHAIN_SELECTOR);
        console.log("  %s \\", receiverAddr);
        console.log("  src/BrumaCCIPReceiver.sol:BrumaCCIPReceiver");
    }
}