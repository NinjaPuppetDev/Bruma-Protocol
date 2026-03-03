// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployBruma} from "../script/DeployBruma.s.sol";
import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {ReinsurancePool} from "../src/ReinsurancePool.sol";
import {IBrumaVault} from "../src/interface/IBrumaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeploymentTest
 * @notice Fork tests that run the actual DeployBruma script against real chain state
 *         and assert every post-deploy invariant.
 *
 * USAGE:
 *   # Sepolia (primary target)
 *   forge test --match-contract DeploymentTest --fork-url $SEPOLIA_RPC -vvv
 *
 *   # Mainnet (smoke test — coordinators will differ, tested separately)
 *   forge test --match-contract DeploymentTest --fork-url $MAINNET_RPC -vvv
 *
 * ENV VARS REQUIRED:
 *   SEPOLIA_RPC   — Sepolia RPC endpoint (Alchemy / Infura)
 *   MAINNET_RPC   — Mainnet RPC endpoint (optional, only for mainnet group)
 *   DEPLOYER_KEY  — Private key used as msg.sender in script (optional — defaults to
 *                   Foundry's default test sender if not set)
 *
 * FOUNDRY.TOML (add these under [profile.default]):
 *   [rpc_endpoints]
 *   sepolia  = "${SEPOLIA_RPC}"
 *   mainnet  = "${MAINNET_RPC}"
 *
 * HOW IT WORKS:
 *   Each test group creates a fork snapshot, runs DeployBruma.run() via vm.broadcast,
 *   then asserts wiring, immutables, access control, and ERC-4626 health.
 *   No private keys are used — vm.prank(deployer) simulates the deployer.
 */
contract DeploymentTest is Test {
    // ── Known Sepolia addresses (from DeployBruma constants) ─────────────────
    address constant SEPOLIA_RAINFALL_COORDINATOR = 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6;
    address constant SEPOLIA_RAINFALL_CONSUMER = 0x96722110DE16F18d3FF21E070F2251cbf8376f92;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_PREMIUM_COORDINATOR = 0xf322B700c27a8C527F058f48481877855bD84F6e;
    address constant SEPOLIA_PREMIUM_CONSUMER = 0xEB36260fc0647D9ca4b67F40E1310697074897d4;

    // ── Mainnet WETH (canonical) ──────────────────────────────────────────────
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ── Test actors ───────────────────────────────────────────────────────────
    address public deployer = makeAddr("deployer");
    address public guardian = makeAddr("guardian");
    address public lp = makeAddr("lp");
    address public reinsurer = makeAddr("reinsurer");

    /*//////////////////////////////////////////////////////////////
                         SEPOLIA FORK TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Runs DeployBruma on a Sepolia fork and checks all wiring.
     * @dev Run with: forge test --match-test test_Sepolia_DeployScript_Wiring --fork-url $SEPOLIA_RPC -vvv
     */
    function test_Sepolia_DeployScript_Wiring() public {
        _requireFork();

        (Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) = _runDeploy();

        // ── Bruma immutables ──────────────────────────────────────────────────
        assertEq(address(bruma.weth()), SEPOLIA_WETH, "bruma.weth mismatch");
        assertEq(address(bruma.vault()), address(vault), "bruma.vault mismatch");
        assertEq(address(bruma.rainfallCoordinator()), SEPOLIA_RAINFALL_COORDINATOR, "rainfallCoordinator mismatch");
        assertEq(address(bruma.premiumCoordinator()), SEPOLIA_PREMIUM_COORDINATOR, "premiumCoordinator mismatch");

        // ── BrumaVault wiring ─────────────────────────────────────────────────
        assertEq(vault.weatherOptions(), address(bruma), "vault.weatherOptions mismatch");
        assertEq(address(vault.weth()), SEPOLIA_WETH, "vault.weth mismatch");
        assertEq(vault.owner(), deployer, "vault.owner should be deployer");

        // ── ReinsurancePool wiring ────────────────────────────────────────────
        assertEq(reinsurancePool.primaryVault(), address(vault), "reinsurancePool.primaryVault mismatch");
        assertEq(reinsurancePool.owner(), deployer, "reinsurancePool.owner should be deployer");
    }

    function test_Sepolia_ExternalContractsHaveCode() public {
        _requireFork();

        // Verify the Sepolia coordinator/consumer addresses actually have code —
        // catches typos in the constant addresses before you waste gas on a real deploy.
        assertGt(SEPOLIA_RAINFALL_COORDINATOR.code.length, 0, "RainfallCoordinator has no code");
        assertGt(SEPOLIA_RAINFALL_CONSUMER.code.length, 0, "RainfallConsumer has no code");
        assertGt(SEPOLIA_PREMIUM_COORDINATOR.code.length, 0, "PremiumCoordinator has no code");
        assertGt(SEPOLIA_PREMIUM_CONSUMER.code.length, 0, "PremiumConsumer has no code");
        assertGt(SEPOLIA_WETH.code.length, 0, "WETH has no code");
    }

    function test_Sepolia_WETHInterface() public {
        _requireFork();

        // WETH on Sepolia must support deposit() and the standard ERC-20 interface
        // that BrumaVault and Bruma depend on.
        (bool depositOk,) = SEPOLIA_WETH.call{value: 0.001 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(depositOk, "WETH.deposit() failed on Sepolia");

        uint256 bal = IERC20(SEPOLIA_WETH).balanceOf(address(this));
        assertGt(bal, 0, "Should have WETH after deposit");
    }

    function test_Sepolia_VaultDefaultParameters() public {
        _requireFork();

        (, BrumaVault vault,) = _runDeploy();

        assertEq(vault.maxUtilizationBps(), 8000, "Default max utilization should be 80%");
        assertEq(vault.targetUtilizationBps(), 6000, "Default target utilization should be 60%");
        assertEq(vault.maxLocationExposureBps(), 2000, "Default location exposure should be 20%");
        assertEq(vault.reinsuranceYieldBps(), 0, "Reinsurance yield should be inactive at deploy");
        assertEq(vault.reinsurancePool(), address(0), "Reinsurance pool should be unset at deploy");
        assertEq(vault.totalLocked(), 0, "No collateral locked at deploy");
        assertEq(vault.totalAssets(), 0, "Vault should be empty at deploy");
    }

    function test_Sepolia_BrumaDefaultParameters() public {
        _requireFork();

        (Bruma bruma,,) = _runDeploy();

        assertEq(bruma.protocolFeeBps(), 100, "Default protocol fee should be 1%");
        assertEq(bruma.minPremium(), 0.05 ether, "Default min premium should be 0.05 ETH");
        assertEq(bruma.minNotional(), 0.01 ether, "Default min notional should be 0.01 ETH");
        assertTrue(bruma.autoClaimEnabled(), "Auto-claim should be enabled at deploy");
        assertEq(bruma.collectedFees(), 0, "No fees collected at deploy");
        assertEq(bruma.owner(), deployer, "bruma.owner should be deployer");
    }

    function test_Sepolia_ReinsurancePoolDefaultParameters() public {
        _requireFork();

        (,, ReinsurancePool pool) = _runDeploy();

        assertEq(pool.lockupPeriod(), 30 days, "Default lockup should be 30 days");
        assertEq(pool.maxSingleDrawBps(), 5000, "Default max single draw should be 50%");
        assertEq(pool.minReserveBps(), 2000, "Default min reserve should be 20%");
        assertEq(pool.totalDrawn(), 0, "No draws at deploy");
        assertEq(pool.accruedYield(), 0, "No yield at deploy");
        assertEq(pool.totalAssets(), 0, "Pool should be empty at deploy");
    }

    function test_Sepolia_AccessControl_OnlyOwnerFunctions() public {
        _requireFork();

        (Bruma bruma, BrumaVault vault, ReinsurancePool pool) = _runDeploy();
        address attacker = makeAddr("attacker");

        // Vault — owner-only calls should revert from non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        vault.setWeatherOptions(attacker);

        vm.expectRevert();
        vault.setReinsurancePool(attacker);

        vm.expectRevert();
        vault.setReinsuranceYieldBps(100);

        vm.expectRevert();
        vault.setGuardian(attacker);
        vm.stopPrank();

        // Bruma — owner-only calls should revert from non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        bruma.setProtocolFee(500);

        vm.expectRevert();
        bruma.setVault(attacker);
        vm.stopPrank();

        // ReinsurancePool — owner-only calls should revert from non-owner
        vm.startPrank(attacker);
        vm.expectRevert();
        pool.setGuardian(attacker);

        vm.expectRevert();
        pool.setPrimaryVault(attacker);
        vm.stopPrank();
    }

    function test_Sepolia_VaultERC4626_DepositWithdrawRoundtrip() public {
        _requireFork();

        (, BrumaVault vault,) = _runDeploy();

        vm.deal(lp, 10 ether);

        // Wrap ETH → WETH
        vm.startPrank(lp);
        (bool ok,) = SEPOLIA_WETH.call{value: 5 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok, "WETH deposit failed");

        // Approve and deposit into vault
        IERC20(SEPOLIA_WETH).approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, lp);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.totalAssets(), 5 ether, "Vault TVL should be 5 WETH");

        // Withdraw back
        uint256 wethBefore = IERC20(SEPOLIA_WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(5 ether, lp, lp);

        assertApproxEqRel(
            IERC20(SEPOLIA_WETH).balanceOf(lp) - wethBefore, 5 ether, 0.01e18, "Should recover full deposit"
        );
        assertEq(vault.totalAssets(), 0, "Vault should be empty after full withdrawal");
    }

    function test_Sepolia_ReinsurancePool_DepositLockupWithdraw() public {
        _requireFork();

        (,, ReinsurancePool pool) = _runDeploy();

        vm.deal(reinsurer, 10 ether);

        vm.startPrank(reinsurer);
        (bool ok,) = SEPOLIA_WETH.call{value: 5 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        IERC20(SEPOLIA_WETH).approve(address(pool), 5 ether);
        pool.deposit(5 ether, reinsurer);
        vm.stopPrank();

        // Should be locked
        (bool locked, uint256 expiry) = pool.isLocked(reinsurer);
        assertTrue(locked, "Should be locked after deposit");
        assertEq(expiry, block.timestamp + 30 days, "Lockup should be 30 days");

        // Cannot withdraw during lockup
        vm.prank(reinsurer);
        vm.expectRevert();
        pool.withdraw(5 ether, reinsurer, reinsurer);

        // Fast-forward past lockup
        vm.warp(block.timestamp + 31 days);

        uint256 wethBefore = IERC20(SEPOLIA_WETH).balanceOf(reinsurer);
        vm.prank(reinsurer);
        pool.withdraw(5 ether, reinsurer, reinsurer);

        assertApproxEqRel(
            IERC20(SEPOLIA_WETH).balanceOf(reinsurer) - wethBefore,
            5 ether,
            0.01e18,
            "Should recover full reinsurance deposit"
        );
    }

    function test_Sepolia_GuardianSetupFlow() public {
        _requireFork();

        (, BrumaVault vault,) = _runDeploy();

        // Owner sets guardian post-deploy (CRE wallet)
        vm.prank(deployer);
        vault.setGuardian(guardian);

        assertEq(vault.guardian(), guardian, "Guardian should be set");

        // Guardian can adjust utilization limits
        vm.prank(guardian);
        vault.setUtilizationLimits(7500, 5500);

        assertEq(vault.maxUtilizationBps(), 7500, "Guardian should be able to tighten util");
        assertEq(vault.targetUtilizationBps(), 5500);
    }

    function test_Sepolia_ReinsuranceActivationFlow() public {
        _requireFork();

        (, BrumaVault vault, ReinsurancePool pool) = _runDeploy();

        // Step 1: owner activates reinsurance routing
        vm.startPrank(deployer);
        vault.setReinsurancePool(address(pool));
        vault.setReinsuranceYieldBps(500); // 5% of premiums
        vm.stopPrank();

        assertEq(vault.reinsurancePool(), address(pool), "Pool should be set");
        assertEq(vault.reinsuranceYieldBps(), 500, "Yield bps should be set");

        // Step 2: reinsurer deposits
        vm.deal(reinsurer, 20 ether);
        vm.startPrank(reinsurer);
        (bool ok,) = SEPOLIA_WETH.call{value: 10 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        IERC20(SEPOLIA_WETH).approve(address(pool), 10 ether);
        pool.deposit(10 ether, reinsurer);
        vm.stopPrank();

        assertEq(pool.totalAssets(), 10 ether, "Reinsurance pool should have capital");
    }

    /*//////////////////////////////////////////////////////////////
                    MAINNET SMOKE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Smoke test: verifies mainnet WETH behaves identically to Sepolia WETH
     *         and that a vault deployed against it would be ERC-4626 compatible.
     * @dev Run with: forge test --match-test test_Mainnet_WETH --fork-url $MAINNET_RPC -vvv
     */
    function test_Mainnet_WETH_Interface() public {
        _requireFork();
        _requireMainnetWETH();

        // Deposit ETH → WETH
        vm.deal(address(this), 1 ether);
        (bool ok,) = MAINNET_WETH.call{value: 0.5 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok, "WETH.deposit() failed on mainnet");

        uint256 bal = IERC20(MAINNET_WETH).balanceOf(address(this));
        assertEq(bal, 0.5 ether, "Should hold 0.5 WETH after deposit");

        // Withdraw
        (bool wok,) = MAINNET_WETH.call(abi.encodeWithSignature("withdraw(uint256)", 0.5 ether));
        assertTrue(wok, "WETH.withdraw() failed on mainnet");
    }

    /**
     * @notice Deploy BrumaVault against mainnet WETH and verify ERC-4626 mechanics work.
     *         Coordinators are mocked since they don't exist on mainnet yet.
     * @dev Run with: forge test --match-test test_Mainnet_VaultAgainstRealWETH --fork-url $MAINNET_RPC -vvv
     */
    function test_Mainnet_VaultAgainstRealWETH() public {
        _requireFork();
        _requireMainnetWETH();

        // Deploy vault only (no Bruma — coordinators aren't on mainnet)
        vm.prank(deployer);
        BrumaVault vault = new BrumaVault(IERC20(MAINNET_WETH), "Bruma Vault", "bVault");

        assertEq(address(vault.weth()), MAINNET_WETH, "Should use mainnet WETH");

        // Fund and deposit
        vm.deal(lp, 10 ether);
        vm.startPrank(lp);
        (bool ok,) = MAINNET_WETH.call{value: 5 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        IERC20(MAINNET_WETH).approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, lp);
        vm.stopPrank();

        assertGt(shares, 0, "Shares minted against mainnet WETH");
        assertEq(vault.totalAssets(), 5 ether, "TVL reflects mainnet WETH balance");

        // Confirm share → asset round-trip
        assertApproxEqRel(
            vault.convertToAssets(shares), 5 ether, 0.01e18, "convertToAssets should round-trip correctly"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Runs the DeployBruma script as the deployer address and returns
     *      the three deployed contracts.
     *      Uses vm.prank so no private key is needed.
     */
    function _runDeploy() internal returns (Bruma bruma, BrumaVault vault, ReinsurancePool reinsurancePool) {
        vm.deal(deployer, 1 ether); // gas money

        DeployBruma script = new DeployBruma();

        (bruma, vault, reinsurancePool) = script.runTest(deployer);
    }

    /**
     * @dev Skip the test gracefully when not running on a fork.
     *      Prevents false failures in unit-test-only CI runs.
     */
    function _requireFork() internal {
        if (block.chainid == 31337 && block.number < 100) {
            // Local anvil with no fork — skip
            vm.skip(true);
        }
    }

    /**
     * @dev Skip if mainnet WETH has no code (we're on Sepolia fork, not mainnet).
     */
    function _requireMainnetWETH() internal {
        if (MAINNET_WETH.code.length == 0) {
            vm.skip(true);
        }
    }
}
