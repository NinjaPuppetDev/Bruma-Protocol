// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBrumaVault} from "../src/interface/IBrumaVault.sol";

/**
 * @title VaultAdversarialTest (FINAL FIXED VERSION)
 * @notice Tests demonstrating vault protection against attacks
 */
contract VaultAdversarialTest is Test {
    BrumaVault public vault;
    WETH9 public weth;

    address public attacker = address(0xBAD);
    address public victim = address(0x600D);
    address public weatherOptions = address(0xAAA);

    function setUp() external {
        weth = new WETH9();
        vault = new BrumaVault(IERC20(address(weth)), "Weather Vault", "wVault");
        vault.setWeatherOptions(weatherOptions);

        vm.deal(attacker, 2000 ether);
        vm.deal(victim, 1000 ether);
    }

    /**
     * @notice  FIXED: Test shows inflation attack is PROTECTED by virtual offset
     * @dev With _decimalsOffset = 3, first deposit gets 1000 shares (not 1)
     */
    // FINAL CORRECTED TEST - Understanding Virtual Offset Properly
    // Replace test_InflationAttack_PROTECTED in both test files

    function test_InflationAttack_PROTECTED() external {
        console.log("\n=== INFLATION ATTACK PROTECTION TEST ===");

        // Step 1: Attacker makes minimal deposit
        vm.startPrank(attacker);
        weth.deposit{value: 1}();
        weth.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, attacker);
        vm.stopPrank();

        // ✅ With offset = 9, first depositor gets 10^9 shares
        uint256 expectedFirstShares = 10 ** 9; // 1 billion
        assertEq(attackerShares, expectedFirstShares, "First depositor gets 10^9 shares with offset=9");
        console.log("Attacker deposited 1 wei, got shares:", attackerShares);

        // Step 2: Attacker donates large amount to inflate share price
        vm.startPrank(attacker);
        weth.deposit{value: 1000 ether}();
        weth.transfer(address(vault), 1000 ether);
        vm.stopPrank();

        uint256 totalAssets = vault.totalAssets();
        console.log("After donation:");
        console.log("  Total assets:", totalAssets / 1e18, "ETH");
        console.log("  Total shares:", vault.totalSupply());

        // Step 3: Victim deposits (this is the attack target)
        vm.startPrank(victim);
        weth.deposit{value: 999 ether}();
        weth.approve(address(vault), 999 ether);
        uint256 victimShares = vault.deposit(999 ether, victim);
        vm.stopPrank();

        // ✅ CRITICAL: Victim MUST get shares (protection from total loss)
        assertGt(victimShares, 0, " PROTECTED: Victim got shares!");
        console.log(" Victim deposited 999 ETH, got shares:", victimShares);

        // ✅ VERIFY FAIR OWNERSHIP: With proper offset, victim should own ~50% of shares
        uint256 totalShares = vault.totalSupply();
        uint256 victimOwnershipBps = (victimShares * 10000) / totalShares;

        // With offset=9 and 1000 ETH donation, victim should own close to their fair share
        // Victim deposited 999 out of ~2000 total = ~50%
        // Due to virtual offset protection, they should get close to 50% ownership
        assertGt(
            victimOwnershipBps,
            4500, // At least 45% (allows for rounding, but close to 50%)
            " Victim owns ~50% (fair share with high offset protection)"
        );

        //  ECONOMIC VALUE CHECK: Victim can redeem fair value
        uint256 victimRedeemValue = vault.previewRedeem(victimShares);
        console.log("Victim can redeem:", victimRedeemValue / 1e18, "ETH");

        // Victim should be able to redeem close to what they deposited
        assertApproxEqRel(
            victimRedeemValue,
            999 ether,
            0.05e18, // 5% tolerance
            " Victim can redeem ~99% of their deposit"
        );

        console.log("\n INFLATION ATTACK FULLY PREVENTED:");
        console.log("  - High virtual offset (10^9) prevents share dilution");
        console.log("  - Victim owns", victimOwnershipBps / 100, "% of shares (fair)");
        console.log("  - Victim can redeem", victimRedeemValue / 1e18, "ETH (nearly full deposit)");
        console.log("  - Attack is economically infeasible");
    }

    function testFuzz_InflationAttack(uint96 donationAmount) external {
        vm.assume(donationAmount > 1 ether);
        vm.assume(donationAmount < 100 ether);

        vm.deal(attacker, uint256(donationAmount) + 1000 ether);

        vm.startPrank(attacker);
        weth.deposit{value: 1}();
        weth.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();

        vm.startPrank(attacker);
        weth.deposit{value: donationAmount}();
        weth.transfer(address(vault), donationAmount);
        vm.stopPrank();

        uint256 victimDeposit = donationAmount - 1;
        vm.deal(victim, victimDeposit);

        vm.startPrank(victim);
        weth.deposit{value: victimDeposit}();
        weth.approve(address(vault), victimDeposit);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "Victim protected by virtual offset");
    }

    function test_RoundingErrorAmplification() external {
        console.log("\n=== ROUNDING ERROR TEST ===");

        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        uint256 initialAssets = vault.totalAssets();

        for (uint256 i = 0; i < 1000; i++) {
            vm.startPrank(attacker);
            weth.deposit{value: 0.001 ether}();
            uint256 shares = vault.deposit(0.001 ether, attacker);
            vault.redeem(shares, attacker, attacker);
            vm.stopPrank();
        }

        uint256 finalAssets = vault.totalAssets();
        int256 drift = int256(finalAssets) - int256(initialAssets);

        console.log("Initial assets:", initialAssets / 1e18, "WETH");
        console.log("Final assets:", finalAssets / 1e18, "WETH");
        console.log("Drift:", drift);

        assertLt(abs(drift), 0.01 ether, "Rounding error amplification detected");
    }

    function test_CannotWithdrawLockedCollateral() external {
        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        bytes32 locationKey1 = keccak256(abi.encodePacked("10.0", "-75.0"));
        bytes32 locationKey2 = keccak256(abi.encodePacked("20.0", "-80.0"));
        bytes32 locationKey3 = keccak256(abi.encodePacked("30.0", "-85.0"));
        bytes32 locationKey4 = keccak256(abi.encodePacked("40.0", "-90.0"));
        bytes32 locationKey5 = keccak256(abi.encodePacked("50.0", "-95.0"));

        vm.startPrank(weatherOptions);
        vault.lockCollateral(10 ether, 1, locationKey1);
        vault.lockCollateral(10 ether, 2, locationKey2);
        vault.lockCollateral(10 ether, 3, locationKey3);
        vault.lockCollateral(10 ether, 4, locationKey4);
        vault.lockCollateral(10 ether, 5, locationKey5);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 maxWithdraw = vault.maxWithdraw(attacker);

        console.log("Total assets:", vault.totalAssets() / 1e18, "WETH");
        console.log("Locked:", vault.totalLocked() / 1e18, "WETH");
        console.log("Max withdraw:", maxWithdraw / 1e18, "WETH");

        assertEq(maxWithdraw, 50 ether, "Should only withdraw unlocked portion");

        vm.prank(attacker);
        vault.withdraw(maxWithdraw, attacker, attacker);

        assertEq(vault.totalAssets(), 50 ether, "Locked collateral should remain");
    }

    function test_LocationExposureLimitsEnforced() external {
        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        bytes32 locationKey = keccak256(abi.encodePacked("10.0", "-75.0"));

        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.LocationExposureTooHigh.selector);
        vault.lockCollateral(21 ether, 1, locationKey);

        vm.prank(weatherOptions);
        vault.lockCollateral(20 ether, 1, locationKey);

        assertEq(vault.totalLocked(), 20 ether);
    }

    function test_UtilizationLimitsEnforced() external {
        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        bytes32 locationKey1 = keccak256(abi.encodePacked("10.0", "-75.0"));
        bytes32 locationKey2 = keccak256(abi.encodePacked("20.0", "-80.0"));
        bytes32 locationKey3 = keccak256(abi.encodePacked("30.0", "-85.0"));
        bytes32 locationKey4 = keccak256(abi.encodePacked("40.0", "-90.0"));

        vm.startPrank(weatherOptions);
        vault.lockCollateral(20 ether, 1, locationKey1);
        vault.lockCollateral(20 ether, 2, locationKey2);
        vault.lockCollateral(20 ether, 3, locationKey3);
        vault.lockCollateral(20 ether, 4, locationKey4);
        vm.stopPrank();

        assertEq(vault.utilizationRate(), 8000, "Should be at 80% utilization");

        bytes32 locationKey5 = keccak256(abi.encodePacked("50.0", "-95.0"));
        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.UtilizationTooHigh.selector);
        vault.lockCollateral(1 ether, 5, locationKey5);
    }

    function test_PremiumPayoutAccounting() external {
        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        bytes32 locationKey = keccak256(abi.encodePacked("10.0", "-75.0"));

        vm.startPrank(weatherOptions);
        vault.lockCollateral(10 ether, 1, locationKey);
        vm.stopPrank();

        vm.startPrank(address(this));
        weth.deposit{value: 1 ether}();
        weth.transfer(address(vault), 1 ether);
        vm.stopPrank();

        vm.prank(weatherOptions);
        vault.receivePremium(1 ether, 1);

        vm.prank(weatherOptions);
        vault.releaseCollateral(10 ether, 6 ether, 1, locationKey);

        IBrumaVault.VaultMetrics memory m = vault.getMetrics();
        uint256 premiums = m.premiumsEarned;
        uint256 payouts = m.totalPayouts;
        int256 netPnL = m.netPnL;

        assertEq(premiums, 1 ether, "Premiums should be 1 WETH");
        assertEq(payouts, 6 ether, "Payouts should be 6 WETH");
        assertEq(netPnL, -5 ether, "Net PnL should be -5 WETH");
    }

    function test_MultipleOptionsSameLocation() external {
        vm.startPrank(attacker);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        vault.deposit(100 ether, attacker);
        vm.stopPrank();

        bytes32 locationKey = keccak256(abi.encodePacked("10.0", "-75.0"));

        vm.startPrank(weatherOptions);
        vault.lockCollateral(5 ether, 1, locationKey);
        vault.lockCollateral(5 ether, 2, locationKey);
        vault.lockCollateral(5 ether, 3, locationKey);
        vault.lockCollateral(5 ether, 4, locationKey);
        vm.stopPrank();

        assertEq(vault.locationExposure(locationKey), 20 ether, "Location exposure should be 20 WETH");
        assertEq(vault.totalLocked(), 20 ether, "Total locked should be 20 WETH");

        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.LocationExposureTooHigh.selector);
        vault.lockCollateral(1 ether, 5, locationKey);

        vm.prank(weatherOptions);
        vault.releaseCollateral(5 ether, 0, 1, locationKey);

        assertEq(vault.locationExposure(locationKey), 15 ether, "Location exposure should be 15 WETH after release");

        vm.prank(weatherOptions);
        vault.lockCollateral(5 ether, 5, locationKey);

        assertEq(vault.locationExposure(locationKey), 20 ether, "Back to 20 WETH");
    }

    function test_FirstDepositorInflationProtection() external {
        vm.startPrank(attacker);
        weth.deposit{value: 1}();
        weth.approve(address(vault), 1);
        vault.deposit(1, attacker);
        vm.stopPrank();

        vm.startPrank(attacker);
        weth.deposit{value: 1000 ether}();
        weth.transfer(address(vault), 1000 ether);
        vm.stopPrank();

        vm.startPrank(victim);
        weth.deposit{value: 100 ether}();
        weth.approve(address(vault), 100 ether);
        uint256 victimShares = vault.deposit(100 ether, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "Victim should receive shares despite inflation attempt");
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    receive() external payable {}
}
