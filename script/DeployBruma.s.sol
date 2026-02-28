// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {ReinsurancePool} from "../src/ReinsurancePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployBruma
 * @notice Full deployment: BrumaVault + ReinsurancePool + Bruma core.
 *
 * ARCHITECTURE AFTER DEPLOY:
 *
 *   [Buyer] ──premium──► [Bruma] ──lockCollateral──► [BrumaVault]
 *                                 ──receivePremium──► [BrumaVault]
 *
 *   [CRE onRiskCron] ──fundPrimaryVault──► [ReinsurancePool] ──WETH──► [BrumaVault]
 *
 * POST-DEPLOY MANUAL STEPS (printed at end):
 *   1. Set CRE guardian on ReinsurancePool  →  reinsurancePool.setGuardian(creWallet)
 *   2. Fund BrumaVault with WETH            →  vault.deposit(...)
 *   3. (Optional) Fund ReinsurancePool      →  reinsurancePool.deposit(...)
 *   4. Deploy & register CRE job            →  see console output
 *
 * USAGE:
 *   # Production deploy (Sepolia)
 *   forge script script/DeployBruma.s.sol --rpc-url $SEPOLIA_RPC --broadcast
 *
 *   # Tests use runTest(deployer) which swaps broadcast for prank
 */
contract DeployBruma is Script {
    // ── Existing Sepolia infrastructure ───────────────────────────────────────
    address constant RAINFALL_COORDINATOR = 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6;
    address constant RAINFALL_CONSUMER = 0x96722110DE16F18d3FF21E070F2251cbf8376f92;
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant PREMIUM_COORDINATOR = 0xf322B700c27a8C527F058f48481877855bD84F6e;
    address constant PREMIUM_CONSUMER = 0xEB36260fc0647D9ca4b67F40E1310697074897d4;

    // ── CRE guardian wallet ────────────────────────────────────────────────────
    // Set this to the wallet address that your CRE `onRiskCron` job will use
    // to sign transactions. Leave as address(0) to skip guardian setup during
    // deployment and call reinsurancePool.setGuardian() manually afterward.
    address constant CRE_GUARDIAN = 0xE0e3B90A377F49b1248b9fEADf4D387Fe0a3697c;

    /*//////////////////////////////////////////////////////////////
                            ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Production entry point — wraps _deploy() in vm.startBroadcast().
     *         Run with: forge script script/DeployBruma.s.sol --rpc-url $RPC --broadcast
     */
    function run() external returns (Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) {
        _preflightChecks();

        console.log("=== Bruma Full Deployment (with ReinsurancePool) ===");
        console.log("Deployer            :", msg.sender);
        console.log("RainfallCoordinator :", RAINFALL_COORDINATOR);
        console.log("RainfallConsumer    :", RAINFALL_CONSUMER);
        console.log("PremiumCoordinator  :", PREMIUM_COORDINATOR);
        console.log("PremiumConsumer     :", PREMIUM_CONSUMER);
        console.log("WETH (Sepolia)      :", WETH_SEPOLIA);

        vm.startBroadcast();
        (bruma, vault, reinsurancePool) = _deploy();
        vm.stopBroadcast();

        _verify(bruma, vault, reinsurancePool);
        _printSummary(bruma, vault, reinsurancePool);
        _printNextSteps(address(bruma), address(vault), address(reinsurancePool));
        _printVerificationCommands(address(bruma), address(vault), address(reinsurancePool));
    }

    /**
     * @notice Test entry point — wraps _deploy() in vm.startPrank(deployer).
     *         Avoids the broadcast/prank incompatibility in Foundry fork tests.
     *         Call from tests instead of run().
     */
    function runTest(address _deployer)
        external
        returns (Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool)
    {
        vm.startPrank(_deployer);
        (bruma, vault, reinsurancePool) = _deploy();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         CORE DEPLOYMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys and wires all three contracts.
     *      Caller is responsible for wrapping with broadcast or prank.
     *      msg.sender at call time becomes the owner of all contracts.
     */
    function _deploy() internal returns (Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) {
        // ── 1. Deploy BrumaVault ───────────────────────────────────────────────
        console.log("\n[1/6] Deploying BrumaVault...");
        vault = new BrumaVault(IERC20(WETH_SEPOLIA), "Bruma Weather Options Vault", "bVault");
        console.log("    BrumaVault          :", address(vault));

        // ── 2. Deploy ReinsurancePool ─────────────────────────────────────────
        console.log("\n[2/6] Deploying ReinsurancePool...");
        reinsurancePool = new ReinsurancePool(IERC20(WETH_SEPOLIA), "Bruma Reinsurance Pool", "bRe");
        console.log("    ReinsurancePool     :", address(reinsurancePool));

        // ── 3. Deploy Bruma core ──────────────────────────────────────────────
        console.log("\n[3/6] Deploying Bruma...");
        bruma = new Bruma(
            RAINFALL_COORDINATOR, RAINFALL_CONSUMER, PREMIUM_COORDINATOR, PREMIUM_CONSUMER, address(vault), WETH_SEPOLIA
        );
        console.log("    Bruma               :", address(bruma));

        // ── 4. Wire BrumaVault ────────────────────────────────────────────────
        console.log("\n[4/6] Configuring BrumaVault...");
        vault.setWeatherOptions(address(bruma));
        console.log("    vault.weatherOptions set to Bruma");

        // ── 5. Wire ReinsurancePool ───────────────────────────────────────────
        console.log("\n[5/6] Configuring ReinsurancePool...");
        reinsurancePool.setPrimaryVault(address(vault));
        console.log("    reinsurancePool.primaryVault set to BrumaVault");

        if (CRE_GUARDIAN != address(0)) {
            reinsurancePool.setGuardian(CRE_GUARDIAN);
            console.log("    reinsurancePool.guardian set to CRE_GUARDIAN:", CRE_GUARDIAN);
        } else {
            console.log("    WARNING: CRE_GUARDIAN is address(0).");
            console.log("    Call reinsurancePool.setGuardian(<cre-wallet>) manually.");
        }

        // ── 6. Wire PremiumCoordinator (best-effort) ──────────────────────────
        console.log("\n[6/6] Configuring PremiumCoordinator (best-effort)...");
        (bool ok,) = PREMIUM_COORDINATOR.call(abi.encodeWithSignature("setWeatherOptions(address)", address(bruma)));
        if (ok) {
            console.log("    PremiumCoordinator.weatherOptions set to Bruma");
        } else {
            console.log("    WARNING: Could not configure PremiumCoordinator automatically.");
            console.log("    Call setWeatherOptions(bruma) on it manually if required.");
        }
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _preflightChecks() internal pure {
        require(RAINFALL_COORDINATOR != address(0), "RAINFALL_COORDINATOR must not be address(0)");
        require(RAINFALL_CONSUMER != address(0), "RAINFALL_CONSUMER must not be address(0)");
        require(PREMIUM_COORDINATOR != address(0), "PREMIUM_COORDINATOR must not be address(0)");
        require(PREMIUM_CONSUMER != address(0), "PREMIUM_CONSUMER must not be address(0)");
        require(WETH_SEPOLIA != address(0), "WETH_SEPOLIA must not be address(0)");
    }

    function _verify(Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) internal view {
        console.log("\n=== Post-Deploy Verification ===");

        require(address(bruma.vault()) == address(vault), "Bruma.vault mismatch");
        require(address(bruma.weth()) == WETH_SEPOLIA, "Bruma.weth mismatch");
        require(address(bruma.rainfallCoordinator()) == RAINFALL_COORDINATOR, "rainfallCoordinator mismatch");
        require(address(bruma.premiumCoordinator()) == PREMIUM_COORDINATOR, "premiumCoordinator mismatch");
        console.log("  [OK] Bruma wiring");

        require(vault.weatherOptions() == address(bruma), "vault.weatherOptions mismatch");
        require(address(vault.weth()) == WETH_SEPOLIA, "vault.weth mismatch");
        console.log("  [OK] BrumaVault wiring");

        require(reinsurancePool.primaryVault() == address(vault), "reinsurancePool.primaryVault mismatch");
        console.log("  [OK] ReinsurancePool wiring");

        console.log("  All checks passed!");
    }

    function _printSummary(Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) internal view {
        console.log("\n=== Deployed Contracts ===");
        console.log("  Bruma              :", address(bruma));
        console.log("  BrumaVault         :", address(vault));
        console.log("  ReinsurancePool    :", address(reinsurancePool));
        console.log("  Owner              :", bruma.owner());
        console.log("  Min Premium        :", bruma.minPremium(), "wei");
        console.log("  Min Notional       :", bruma.minNotional(), "wei");
        console.log("  Protocol Fee (bps) :", bruma.protocolFeeBps());
        console.log("  Max Utilization    :", vault.maxUtilizationBps(), "bps");
        console.log("  Lockup Period      :", reinsurancePool.lockupPeriod(), "seconds");
        console.log("  Max Single Draw    :", reinsurancePool.maxSingleDrawBps(), "bps");
        console.log("  Min Reserve        :", reinsurancePool.minReserveBps(), "bps");
    }

    function _printNextSteps(address brumaAddr, address vaultAddr, address reinsuranceAddr) internal pure {
        console.log("\n=== Next Steps ===");

        console.log("\n-- 1. Set the CRE guardian on ReinsurancePool (if not set above) --");
        console.log("   cast send %s 'setGuardian(address)' <CRE_WALLET>", reinsuranceAddr);
        console.log("   --rpc-url $RPC --account <deployer-keystore>");

        console.log("\n-- 2. Wrap ETH -> WETH --");
        console.log("   cast send %s 'deposit()' --value 5ether", WETH_SEPOLIA);
        console.log("   --rpc-url $RPC --account <your-keystore>");

        console.log("\n-- 3. Fund BrumaVault (primary liquidity) --");
        console.log("   cast send %s 'approve(address,uint256)' %s 3000000000000000000", WETH_SEPOLIA, vaultAddr);
        console.log("   --rpc-url $RPC --account <your-keystore>");
        console.log("   cast send %s 'deposit(uint256,address)' 3000000000000000000 <YOUR_ADDRESS>", vaultAddr);
        console.log("   --rpc-url $RPC --account <your-keystore>");

        console.log("\n-- 4. Fund ReinsurancePool (tail-risk capital, 30-day lockup) --");
        console.log("   cast send %s 'approve(address,uint256)' %s 2000000000000000000", WETH_SEPOLIA, reinsuranceAddr);
        console.log("   --rpc-url $RPC --account <your-keystore>");
        console.log("   cast send %s 'deposit(uint256,address)' 2000000000000000000 <YOUR_ADDRESS>", reinsuranceAddr);
        console.log("   --rpc-url $RPC --account <your-keystore>");

        console.log("\n-- 5. Deploy & register your CRE onRiskCron job --");
        console.log("   The job should call:");
        console.log("     reinsurancePool.fundPrimaryVault(amount, reason)");
        console.log("   Trigger condition (example logic in your CRE script):");
        console.log("     vault.utilizationRate() > 7500   (75% utilization threshold)");
        console.log("   CRE job signer must match the guardian address set in step 1.");

        console.log("\n-- 6. Request a premium quote --");
        console.log("   NOW=$(cast block latest --field timestamp --rpc-url $RPC)");
        console.log("   EXPIRY=$((NOW + 259200))  # 3 days");
        console.log(
            "   cast send %s 'requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))' \\",
            brumaAddr
        );
        console.log("     '(0,\"10.0\",\"-75.0\",'$NOW','$EXPIRY',100,50,10000000000000000)' \\");
        console.log("     --rpc-url $RPC --account <your-keystore>");

        console.log("\n-- 7. After Chainlink fulfills the premium, create the option --");
        console.log("   cast send %s 'createOptionWithQuote(bytes32)' <REQUEST_ID> \\", brumaAddr);
        console.log("     --value <total_cost_wei> --rpc-url $RPC --account <your-keystore>");
    }

    function _printVerificationCommands(address brumaAddr, address vaultAddr, address reinsuranceAddr) internal pure {
        console.log("\n=== Etherscan Verification Commands ===");

        console.log("\n# BrumaVault:");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia --watch \\");
        console.log("  --constructor-args $(cast abi-encode 'constructor(address,string,string)' \\");
        console.log("    %s 'Bruma Weather Options Vault' 'bVault') \\", WETH_SEPOLIA);
        console.log("  %s \\", vaultAddr);
        console.log("  src/BrumaVault.sol:BrumaVault");

        console.log("\n# ReinsurancePool:");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia --watch \\");
        console.log("  --constructor-args $(cast abi-encode 'constructor(address,string,string)' \\");
        console.log("    %s 'Bruma Reinsurance Pool' 'bRe') \\", WETH_SEPOLIA);
        console.log("  %s \\", reinsuranceAddr);
        console.log("  src/ReinsurancePool.sol:ReinsurancePool");

        console.log("\n# Bruma:");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia --watch \\");
        console.log("  --constructor-args $(cast abi-encode \\");
        console.log("    'constructor(address,address,address,address,address,address)' \\");
        console.log("    %s %s %s \\", RAINFALL_COORDINATOR, RAINFALL_CONSUMER, PREMIUM_COORDINATOR);
        console.log("    %s <VAULT_ADDR> %s) \\", PREMIUM_CONSUMER, WETH_SEPOLIA);
        console.log("  %s \\", brumaAddr);
        console.log("  src/Bruma.sol:Bruma");
    }
}
