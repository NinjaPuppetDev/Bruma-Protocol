// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BrumaCCIPEscrowFactory} from "../src/BrumaCCIPEscrow.sol";

/**
 * @title DeployBrumaFactory
 * @notice Deploys BrumaCCIPEscrowFactory on Ethereum Sepolia.
 *         Run AFTER Bruma and BrumaVault are already deployed.
 *
 * USAGE
 *   forge script script/DeployBrumaFactory.s.sol \
 *     --rpc-url $SEPOLIA_RPC \
 *     --account <your-account> \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * REQUIRED ENV
 *   BRUMA_ADDRESS          — already deployed Bruma.sol
 *   CRE_WORKFLOW_ADDRESS   — CRE workflow EOA / address (authorizedCaller)
 *
 * HARDCODED (Sepolia)
 *   WETH, LINK, CCIP Router — official Chainlink Sepolia addresses
 */
contract DeployBrumaFactory is Script {

    // ── Already deployed (from DeployBruma.s.sol) ─────────────────────────────
    address constant BRUMA_SEPOLIA = 0x762a995182433fDE85dC850Fa8FF6107582110d2; // TODO: fill after deploy

    // ── Sepolia Chainlink / token addresses ───────────────────────────────────
    address constant WETH_SEPOLIA   = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant LINK_SEPOLIA   = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant CCIP_ROUTER_SEPOLIA = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    function run() external returns (BrumaCCIPEscrowFactory factory) {
        // CRE workflow address — the address that will call claimAndBridge()
        // Set via env so it doesn't need to be hardcoded
        address creWorkflow = vm.envAddress("CRE_WORKFLOW_ADDRESS");

        // Allow override of Bruma address via env (falls back to constant)
        address bruma = vm.envOr("BRUMA_ADDRESS", BRUMA_SEPOLIA);

        console.log("=== BrumaCCIPEscrowFactory Deployment ===");
        console.log("Network:        Ethereum Sepolia");
        console.log("Bruma:         ", bruma);
        console.log("WETH:          ", WETH_SEPOLIA);
        console.log("LINK:          ", LINK_SEPOLIA);
        console.log("CCIP Router:   ", CCIP_ROUTER_SEPOLIA);
        console.log("CRE Workflow:  ", creWorkflow);

        require(bruma          != address(0), "BRUMA_ADDRESS not set");
        require(creWorkflow     != address(0), "CRE_WORKFLOW_ADDRESS not set");

        vm.startBroadcast();

        factory = new BrumaCCIPEscrowFactory(
            bruma,
            WETH_SEPOLIA,
            LINK_SEPOLIA,
            CCIP_ROUTER_SEPOLIA,
            creWorkflow          // authorizedCaller = CRE workflow
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Successful ===");
        console.log("BrumaCCIPEscrowFactory:", address(factory));
        console.log("  bruma:           ", factory.bruma());
        console.log("  authorizedCaller:", factory.authorizedCaller());

        _printNextSteps(address(factory));
        _printVerification(address(factory), bruma, creWorkflow);
    }

    function _printNextSteps(address factoryAddr) internal pure {
        console.log("\n=== Next Steps ===");
        console.log("\n1. Update config.staging.json:");
        console.log("   brumaFactoryAddress:", factoryAddr);

        console.log("\n2. Deploy BrumaCCIPReceiver on Avalanche Fuji:");
        console.log("   forge script script/DeployBrumaReceiver.s.sol \\");
        console.log("     --rpc-url $FUJI_RPC --account <your-account> --broadcast --verify");

        console.log("\n3. A cross-chain buyer deploys their personal escrow:");
        console.log("   cast send %s \\", factoryAddr);
        console.log("     'deployAndFundEscrow(uint64,address,uint256)' \\");
        console.log("     14767482510784806043 \\");   // Avalanche Fuji selector
        console.log("     <RECEIVER_ADDRESS_ON_FUJI> \\");
        console.log("     1000000000000000000 \\");    // 1 LINK for fees
        console.log("     --rpc-url $SEPOLIA_RPC --account <buyer-account>");

        console.log("\n4. Buyer transfers their Bruma NFT to the escrow:");
        console.log("   cast send $BRUMA_ADDRESS \\");
        console.log("     'safeTransferFrom(address,address,uint256)' \\");
        console.log("     <buyer-address> <escrow-address> <tokenId> \\");
        console.log("     --rpc-url $SEPOLIA_RPC --account <buyer-account>");

        console.log("\n5. CRE workflow handles the rest automatically.");
    }

    function _printVerification(
        address factoryAddr,
        address bruma,
        address creWorkflow
    ) internal pure {
        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \\");
        console.log("    'constructor(address,address,address,address,address)' \\");
        console.log("  %s \\", factoryAddr);
        console.log("  src/BrumaCCIPEscrow.sol:BrumaCCIPEscrowFactory");
    }
}