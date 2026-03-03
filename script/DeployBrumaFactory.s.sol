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
 *   WETH, CCIP-BnM, LINK, CCIP Router — official Chainlink Sepolia addresses
 */
contract DeployBrumaFactory is Script {
    // ── Already deployed ──────────────────────────────────────────────────────
    address constant BRUMA_SEPOLIA = 0xB8171af0ecb428a74626C63dA843dc7840D409da;

    // ── Sepolia Chainlink / token addresses ───────────────────────────────────
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    // CCIP-BnM on Sepolia — the CCIP-supported testnet token for cross-chain transfers
    // Supported on: Sepolia → Fuji, Sepolia → Amoy, Sepolia → Arbitrum Sepolia, etc.
    // drip() mints 1 CCIP-BnM for free on testnet
    address constant CCIP_BNM_SEPOLIA = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;

    address constant LINK_SEPOLIA = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant CCIP_ROUTER_SEPOLIA = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    function run() external returns (BrumaCCIPEscrowFactory factory) {
        address creWorkflow = 0xc022d2263835D14D5AcA7E3f45ADA019D1E23D9e;
        address bruma = 0xB8171af0ecb428a74626C63dA843dc7840D409da;

        console.log("=== BrumaCCIPEscrowFactory Deployment ===");
        console.log("Network:        Ethereum Sepolia");
        console.log("Bruma:         ", bruma);
        console.log("WETH:          ", WETH_SEPOLIA);
        console.log("CCIP-BnM:      ", CCIP_BNM_SEPOLIA);
        console.log("LINK:          ", LINK_SEPOLIA);
        console.log("CCIP Router:   ", CCIP_ROUTER_SEPOLIA);
        console.log("CRE Workflow:  ", creWorkflow);

        require(bruma != address(0), "BRUMA_ADDRESS not set");
        require(creWorkflow != address(0), "CRE_WORKFLOW_ADDRESS not set");

        vm.startBroadcast();

        factory = new BrumaCCIPEscrowFactory(
            bruma,
            WETH_SEPOLIA,
            CCIP_BNM_SEPOLIA, // ← new param
            LINK_SEPOLIA,
            CCIP_ROUTER_SEPOLIA,
            creWorkflow
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Successful ===");
        console.log("BrumaCCIPEscrowFactory:", address(factory));
        console.log("  bruma:           ", factory.bruma());
        console.log("  ccipBnM:         ", factory.ccipBnM());
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
        console.log("     14767482510784806043 \\"); // Avalanche Fuji selector
        console.log("     <RECEIVER_ADDRESS_ON_FUJI> \\");
        console.log("     1000000000000000000 \\"); // 1 LINK for fees
        console.log("     --rpc-url $SEPOLIA_RPC --account <buyer-account>");

        console.log("\n4. Buyer transfers their Bruma NFT to the escrow:");
        console.log("   cast send $BRUMA_ADDRESS \\");
        console.log("     'safeTransferFrom(address,address,uint256)' \\");
        console.log("     <buyer-address> <escrow-address> <tokenId> \\");
        console.log("     --rpc-url $SEPOLIA_RPC --account <buyer-account>");

        console.log("\n5. After settlement, owner withdraws ETH locally:");
        console.log("   cast send <escrow-address> 'withdrawETH(uint256)' <tokenId> \\");
        console.log("     --rpc-url $SEPOLIA_RPC --account <buyer-account>");

        console.log("\n6. CRE workflow calls claimAndBridge() to bridge CCIP-BnM cross-chain.");
    }

    function _printVerification(address factoryAddr, address bruma, address creWorkflow) internal pure {
        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --watch \\");
        console.log("  --constructor-args $(cast abi-encode \\");
        console.log("    'constructor(address,address,address,address,address,address)' \\");
        console.log("  %s \\", factoryAddr);
        console.log("  src/BrumaCCIPEscrow.sol:BrumaCCIPEscrowFactory");
    }
}
