// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {ReinsurancePool} from "../src/ReinsurancePool.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBrumaVault} from "../src/interface/IBrumaVault.sol";
/**
 * @title VaultHardeningTest
 * @notice Targets the specific branch and function gaps left uncovered by the
 *         existing test suites.  Every test here exercises a path confirmed
 *         missing from the lcov report.
 *
 * VAULT GAPS COVERED (L = line, B = branch):
 *   V1.  lockCollateral: amount == 0 → ZeroAmount
 *   V2.  lockCollateral: empty vault → InsufficientLiquidity
 *   V3.  lockCollateral: amount > available (not util-cap-blocked) → InsufficientLiquidity
 *   V4.  releaseCollateral: payout > amount → revert
 *   V5.  releaseCollateral: locationExposure underflow → revert
 *   V6.  maxWithdraw: caller has zero shares → returns 0
 *   V7.  maxWithdraw: totalLocked >= totalAssets → available == 0, maxWithdraw == 0
 *   V8.  maxRedeem: mirrors maxWithdraw zero-shares path
 *   V9.  deposit: amount == 0 → ZeroAmount
 *   V10. mint: happy path sets shares + lockup (function never called before)
 *   V11. mint: shares == 0 → ZeroAmount
 *   V12. setUtilizationLimits: _maxBps > 10000 → revert
 *   V13. setUtilizationLimits: _targetBps > _maxBps → revert
 *   V14. setMaxLocationExposure: bps > 10000 → revert
 *   V15. availableLiquidity: totalLocked >= totalAssets → returns 0
 *   V16. canUnderwrite: empty vault (assets == 0) → returns false
 *
 * REINSURANCE GAPS COVERED:
 *   R1.  depositYield: msg.value == 0 → ZeroAmount
 *   R2.  claimYield: totalSupply == 0 → returns 0 without revert
 *   R3.  claimYield: accruedYield == 0 (shares exist, no yield deposited) → returns 0
 *   R4.  mint: happy path (ERC-4626 mint instead of deposit)
 *   R5.  mint: sets lockup expiry on minter
 *   R6.  mint: shares == 0 → ZeroAmount
 *   R7.  redeem: happy path after lockup expires
 *   R8.  redeem: blocked during lockup → CapitalLocked
 *   R9.  setLockupPeriod: updates lockupPeriod and emits event
 *   R10. getMetrics: returns correct tuple values
 *   R11. _checkLockup: address that never deposited has expiry == 0, withdraw is unrestricted
 */

contract VaultHardeningTest is Test {
    BrumaVault public vault;
    ReinsurancePool public reinsurance;
    WETH9 public weth;

    address public weatherOptions = address(0xAAA);
    address public guardian = address(0xBBB);
    address public lp = address(0xC1);
    address public reinsurer = makeAddr("reinsurer");
    address public stranger = makeAddr("stranger"); // never deposited

    function setUp() external {
        vm.warp(1_704_067_200);

        weth = new WETH9();
        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "bVault");
        reinsurance = new ReinsurancePool(IERC20(address(weth)), "Bruma RE", "bRE");

        vault.setWeatherOptions(weatherOptions);
        vault.setGuardian(address(this));
        reinsurance.setPrimaryVault(address(vault));
        reinsurance.setGuardian(guardian);

        vm.deal(lp, 500 ether);
        vm.deal(reinsurer, 500 ether);
        vm.deal(stranger, 10 ether);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _depositVault(address who, uint256 amount) internal {
        vm.startPrank(who);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _depositRE(address who, uint256 amount) internal {
        vm.startPrank(who);
        weth.deposit{value: amount}();
        weth.approve(address(reinsurance), amount);
        reinsurance.deposit(amount, who);
        vm.stopPrank();
    }

    function _lock(uint256 amount, bytes32 key) internal {
        vm.prank(weatherOptions);
        vault.lockCollateral(amount, 1, key);
    }

    /*//////////////////////////////////////////////////////////////
                      V1-V5: lockCollateral / releaseCollateral
    //////////////////////////////////////////////////////////////*/

    function test_V1_LockCollateral_ZeroAmount_Reverts() external {
        _depositVault(lp, 100 ether);

        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.ZeroAmount.selector);
        vault.lockCollateral(0, 1, keccak256("loc"));
    }

    function test_V2_LockCollateral_EmptyVault_Reverts() external {
        // vault has no deposits — totalAssets() == 0
        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.InsufficientLiquidity.selector);
        vault.lockCollateral(1 ether, 1, keccak256("loc"));
    }

    function test_V3_LockCollateral_AmountExceedsAvailable_Reverts() external {
        // lockCollateral checks: if (amount > assets - totalLocked) → InsufficientLiquidity
        // This is a RAW available check (assets minus locked), not the util-capped check.
        // To reach it: raise util to 100% so the util check never fires first,
        // then lock 9 of 10 ETH (raw available = 1 ETH), then request 2 ETH.
        _depositVault(lp, 10 ether);
        vault.setMaxLocationExposure(10000); // remove location cap
        vm.prank(address(this));
        vault.setUtilizationLimits(10000, 6000); // raise util ceiling to 100%

        _lock(9 ether, keccak256("a")); // raw available = 10 - 9 = 1 ETH

        // Request 2 ETH: 2 > 1 → InsufficientLiquidity (before util check fires)
        vm.prank(weatherOptions);
        vm.expectRevert(IBrumaVault.InsufficientLiquidity.selector);
        vault.lockCollateral(2 ether, 2, keccak256("b"));
    }

    function test_V4_ReleaseCollateral_PayoutExceedsAmount_Reverts() external {
        _depositVault(lp, 100 ether);
        vault.setMaxLocationExposure(10000);
        bytes32 key = keccak256("loc");
        _lock(10 ether, key);

        // payout (15) > amount (10) — should revert on "Invalid amounts"
        vm.prank(weatherOptions);
        vm.expectRevert();
        vault.releaseCollateral(10 ether, 15 ether, 1, key);
    }

    function test_V5_ReleaseCollateral_LocationExposureUnderflow_Reverts() external {
        _depositVault(lp, 100 ether);
        vault.setMaxLocationExposure(10000);
        bytes32 key1 = keccak256("a");
        bytes32 key2 = keccak256("b");

        _lock(5 ether, key1);
        _lock(5 ether, key2);

        // Try to release 10 ETH from key1 which only has 5 ETH exposure
        vm.prank(weatherOptions);
        vm.expectRevert(); // "Invalid location exposure"
        vault.releaseCollateral(10 ether, 0, 1, key1);
    }

    /*//////////////////////////////////////////////////////////////
                      V6-V8: maxWithdraw / maxRedeem edge cases
    //////////////////////////////////////////////////////////////*/

    function test_V6_MaxWithdraw_ZeroShares_ReturnsZero() external {
        _depositVault(lp, 100 ether);

        // stranger has never deposited — zero shares
        uint256 result = vault.maxWithdraw(stranger);
        assertEq(result, 0, "Zero shares should return 0 maxWithdraw");
    }

    function test_V7_MaxWithdraw_AllCollateralLocked_ReturnsZero() external {
        // maxWithdraw uses: available = totalAssets - totalLocked
        // To reach the `shares == 0 || totalShares == 0` early return is one path,
        // but to reach `available == 0` we need totalLocked >= totalAssets.
        // Strategy: lock 80 ETH (max util on 100 ETH vault), then LP withdraws
        // the remaining unlocked 20 ETH. After withdrawal:
        //   totalAssets = 80, totalLocked = 80 → available = 0 → maxWithdraw = 0.
        _depositVault(lp, 100 ether);
        vault.setMaxLocationExposure(10000);

        _lock(80 ether, keccak256("loc")); // max util — 20 ETH unlocked remains

        // LP withdraws the unlocked portion (20 ETH)
        uint256 unlocked = vault.maxWithdraw(lp);
        assertEq(unlocked, 20 ether, "Should be able to withdraw unlocked 20 ETH first");
        vm.prank(lp);
        vault.withdraw(unlocked, lp, lp);

        // Now totalAssets = 80, totalLocked = 80
        // available = 80 - 80 = 0 → maxWithdraw = 0
        assertEq(vault.totalAssets(), 80 ether, "Only locked collateral remains");
        assertEq(vault.totalLocked(), 80 ether, "All assets are locked");
        assertEq(vault.maxWithdraw(lp), 0, "No available liquidity means maxWithdraw == 0");
    }

    function test_V8_MaxRedeem_ZeroShares_ReturnsZero() external {
        _depositVault(lp, 100 ether);

        uint256 result = vault.maxRedeem(stranger);
        assertEq(result, 0, "Zero shares should return 0 maxRedeem");
    }

    /*//////////////////////////////////////////////////////////////
                      V9-V11: deposit / mint zero-amount guards
    //////////////////////////////////////////////////////////////*/

    function test_V9_Deposit_ZeroAmount_Reverts() external {
        vm.startPrank(lp);
        weth.deposit{value: 1 ether}();
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(IBrumaVault.ZeroAmount.selector);
        vault.deposit(0, lp);
        vm.stopPrank();
    }

    function test_V10_Mint_HappyPath_ReceivesShares() external {
        // mint() is the ERC-4626 shares-in → assets-out variant — never exercised before
        vm.startPrank(lp);
        weth.deposit{value: 10 ether}();
        weth.approve(address(vault), 10 ether);

        uint256 sharesToMint = 1e9; // 1 share-unit at the offset scale
        uint256 assetsRequired = vault.previewMint(sharesToMint);

        uint256 assetsSpent = vault.mint(sharesToMint, lp);
        vm.stopPrank();

        assertEq(vault.balanceOf(lp), sharesToMint, "Should hold requested shares");
        assertEq(assetsSpent, assetsRequired, "Assets spent should match previewMint");
        assertGt(vault.totalAssets(), 0, "Vault should hold assets");
    }

    function test_V11_Mint_ZeroShares_Reverts() external {
        vm.startPrank(lp);
        weth.deposit{value: 1 ether}();
        weth.approve(address(vault), 1 ether);
        vm.expectRevert(IBrumaVault.ZeroAmount.selector);
        vault.mint(0, lp);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      V12-V14: admin config validation
    //////////////////////////////////////////////////////////////*/

    function test_V12_SetUtilizationLimits_MaxBpsAbove10000_Reverts() external {
        vm.expectRevert(); // "Invalid limits"
        vault.setUtilizationLimits(10001, 5000);
    }

    function test_V13_SetUtilizationLimits_TargetAboveMax_Reverts() external {
        vm.expectRevert(); // "Invalid limits"
        vault.setUtilizationLimits(7000, 8000); // target > max
    }

    function test_V14_SetMaxLocationExposure_Above10000_Reverts() external {
        vm.expectRevert(); // "Invalid percentage"
        vault.setMaxLocationExposure(10001);
    }

    /*//////////////////////////////////////////////////////////////
                      V15-V16: availableLiquidity / canUnderwrite edge cases
    //////////////////////////////////////////////////////////////*/

    function test_V15_AvailableLiquidity_WhenLockedEqualsAssets_ReturnsZero() external {
        // availableLiquidity() has two zero-return branches:
        //   (a) if (totalLocked >= assets) return 0
        //   (b) if (totalLocked + available > maxLockable) return maxLockable - totalLocked
        //       which equals 0 when totalLocked == maxLockable
        //
        // Branch (b): 10 ETH vault, lock exactly 8 ETH (the 80% max).
        //   maxLockable = 8, totalLocked = 8 → maxLockable - totalLocked = 0.
        //
        // Branch (a): need totalLocked >= totalAssets. Achieved after LP withdraws
        //   the remaining 2 ETH → totalAssets = 8, totalLocked = 8 → first branch fires.
        _depositVault(lp, 10 ether);
        vault.setMaxLocationExposure(10000);

        _lock(8 ether, keccak256("loc")); // at max utilization

        // Branch (b): availableLiquidity = maxLockable - totalLocked = 8 - 8 = 0
        assertEq(vault.availableLiquidity(), 0, "availableLiquidity should be 0 at max utilization");

        // Now withdraw the unlocked 2 ETH so totalAssets == totalLocked (branch a)
        uint256 withdrawable = vault.maxWithdraw(lp);
        assertEq(withdrawable, 2 ether, "LP can still withdraw the unlocked 2 ETH");
        vm.prank(lp);
        vault.withdraw(withdrawable, lp, lp);

        // Branch (a): totalLocked(8) >= totalAssets(8) → return 0
        assertEq(vault.totalAssets(), 8 ether);
        assertEq(vault.totalLocked(), 8 ether);
        assertEq(vault.availableLiquidity(), 0, "availableLiquidity still 0 after withdrawal");
        assertEq(vault.maxWithdraw(lp), 0, "maxWithdraw is also 0  nothing unlocked left");
    }

    function test_V16_CanUnderwrite_EmptyVault_ReturnsFalse() external {
        // Fresh vault, no deposits — totalAssets() == 0
        bytes32 key = keccak256("loc");
        assertFalse(vault.canUnderwrite(1 ether, key), "Empty vault cannot underwrite");
    }

    /*//////////////////////////////////////////////////////////////
                      R1-R3: ReinsurancePool yield gaps
    //////////////////////////////////////////////////////////////*/

    function test_R1_DepositYield_ZeroValue_Reverts() external {
        vm.expectRevert(ReinsurancePool.ZeroAmount.selector);
        reinsurance.depositYield{value: 0}();
    }

    function test_R2_ClaimYield_NoReinsurers_TotalSupplyZero_ReturnsZero() external {
        // Yield deposited but zero shares exist — claimYield should return 0 gracefully
        reinsurance.depositYield{value: 1 ether}();

        assertEq(reinsurance.totalSupply(), 0, "No reinsurers yet");

        vm.prank(stranger);
        uint256 claimed = reinsurance.claimYield();
        assertEq(claimed, 0, "Should return 0 when totalSupply is zero");
    }

    function test_R3_ClaimYield_NoAccruedYield_ReturnsZero() external {
        // Reinsurer has shares but no yield has been deposited
        _depositRE(reinsurer, 50 ether);

        assertEq(reinsurance.accruedYield(), 0, "No yield deposited yet");

        vm.prank(reinsurer);
        uint256 claimed = reinsurance.claimYield();
        assertEq(claimed, 0, "Should return 0 when accruedYield is zero");
    }

    /*//////////////////////////////////////////////////////////////
                      R4-R6: ReinsurancePool mint path
    //////////////////////////////////////////////////////////////*/

    function test_R4_Mint_HappyPath_ReceivesShares() external {
        // mint() on ReinsurancePool: shares-specified entry, never called before
        vm.startPrank(reinsurer);
        weth.deposit{value: 50 ether}();
        weth.approve(address(reinsurance), 50 ether);

        uint256 sharesToMint = reinsurance.previewDeposit(10 ether);
        uint256 assetsSpent = reinsurance.mint(sharesToMint, reinsurer);
        vm.stopPrank();

        assertEq(reinsurance.balanceOf(reinsurer), sharesToMint, "Should hold minted shares");
        assertApproxEqRel(assetsSpent, 10 ether, 0.01e18, "Assets spent should be ~10 ETH");
    }

    function test_R5_Mint_SetsLockupExpiry() external {
        vm.startPrank(reinsurer);
        weth.deposit{value: 50 ether}();
        weth.approve(address(reinsurance), 50 ether);

        uint256 sharesToMint = reinsurance.previewDeposit(10 ether);
        reinsurance.mint(sharesToMint, reinsurer);
        vm.stopPrank();

        (, uint256 expiry) = reinsurance.isLocked(reinsurer);
        assertEq(expiry, block.timestamp + 30 days, "Mint should set lockup expiry");
    }

    function test_R6_Mint_ZeroShares_Reverts() external {
        vm.startPrank(reinsurer);
        weth.deposit{value: 1 ether}();
        weth.approve(address(reinsurance), 1 ether);
        vm.expectRevert(ReinsurancePool.ZeroAmount.selector);
        reinsurance.mint(0, reinsurer);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      R7-R8: ReinsurancePool redeem path
    //////////////////////////////////////////////////////////////*/

    function test_R7_Redeem_HappyPath_AfterLockup() external {
        // redeem() is the shares-in variant of withdraw — never called before
        _depositRE(reinsurer, 50 ether);

        vm.warp(block.timestamp + 31 days);

        uint256 shares = reinsurance.balanceOf(reinsurer);
        uint256 wethBefore = weth.balanceOf(reinsurer);

        vm.prank(reinsurer);
        uint256 assetsOut = reinsurance.redeem(shares, reinsurer, reinsurer);

        assertApproxEqRel(weth.balanceOf(reinsurer) - wethBefore, 50 ether, 0.01e18, "Should redeem full deposit value");
        assertApproxEqRel(assetsOut, 50 ether, 0.01e18, "Return value should match assets out");
        assertEq(reinsurance.balanceOf(reinsurer), 0, "Shares burned to zero");
    }

    function test_R8_Redeem_DuringLockup_Reverts() external {
        _depositRE(reinsurer, 50 ether);

        uint256 shares = reinsurance.balanceOf(reinsurer);

        vm.prank(reinsurer);
        vm.expectRevert(); // CapitalLocked
        reinsurance.redeem(shares, reinsurer, reinsurer);
    }

    /*//////////////////////////////////////////////////////////////
                      R9: setLockupPeriod
    //////////////////////////////////////////////////////////////*/

    function test_R9_SetLockupPeriod_UpdatesAndEmits() external {
        uint256 newPeriod = 60 days;

        vm.expectEmit(false, false, false, true);
        emit ReinsurancePool.LockupPeriodUpdated(newPeriod);
        reinsurance.setLockupPeriod(newPeriod);

        assertEq(reinsurance.lockupPeriod(), newPeriod, "Lockup period should be updated");

        // Verify new period is applied to next deposit
        _depositRE(reinsurer, 10 ether);
        (, uint256 expiry) = reinsurance.isLocked(reinsurer);
        assertEq(expiry, block.timestamp + 60 days, "New lockup period applied to deposit");
    }

    /*//////////////////////////////////////////////////////////////
                      R10: getMetrics
    //////////////////////////////////////////////////////////////*/

    function test_R10_GetMetrics_ReturnsCorrectValues() external {
        _depositRE(reinsurer, 100 ether);

        // Draw 10 ETH
        vm.prank(guardian);
        reinsurance.fundPrimaryVault(10 ether, "Draw 1");

        // Deposit 2 ETH yield
        reinsurance.depositYield{value: 2 ether}();

        // Claim 1 reinsurer's yield
        vm.prank(reinsurer);
        reinsurance.claimYield();

        (
            uint256 tvl,
            uint256 available,
            uint256 drawn,
            uint256 pendingYield,
            uint256 yieldDistributed,
            uint256 reinsurerProxy
        ) = reinsurance.getMetrics();

        // After 10 ETH draw: pool has 90 ETH WETH
        assertEq(tvl, weth.balanceOf(address(reinsurance)), "TVL should match WETH balance");
        assertEq(drawn, 10 ether, "totalDrawn should be 10 ETH");
        assertEq(yieldDistributed, 2 ether, "Should have distributed 2 ETH yield");
        assertEq(pendingYield, 0, "All yield claimed by sole reinsurer");
        assertGt(reinsurerProxy, 0, "totalSupply proxy should be non-zero");

        // available = tvl - 20% reserve
        uint256 expectedAvailable = tvl - (tvl * reinsurance.minReserveBps()) / 10000;
        assertEq(available, expectedAvailable, "Available capacity should respect reserve floor");
    }

    /*//////////////////////////////////////////////////////////////
                      R11: _checkLockup with zero expiry
    //////////////////////////////////////////////////////////////*/

    function test_R11_CheckLockup_NeverDeposited_NoLock() external {
        // stranger never called deposit/mint — lockupExpiry[stranger] == 0
        // _checkLockup should NOT revert (expiry == 0 means no lockup set)
        _depositRE(reinsurer, 50 ether);

        vm.warp(block.timestamp + 31 days);

        // Cache balance BEFORE the prank so the balanceOf call doesn't consume it
        uint256 reinsurerShares = reinsurance.balanceOf(reinsurer);
        assertGt(reinsurerShares, 0, "Reinsurer should have shares");

        vm.prank(reinsurer);
        reinsurance.transfer(stranger, reinsurerShares);

        // stranger now has shares but lockupExpiry[stranger] == 0 — should redeem freely
        assertGt(reinsurance.balanceOf(stranger), 0, "Stranger should have shares");

        (bool locked,) = reinsurance.isLocked(stranger);
        assertFalse(locked, "Stranger should not be locked (expiry == 0)");

        uint256 strangerShares = reinsurance.balanceOf(stranger);
        uint256 wethBefore = weth.balanceOf(stranger);

        vm.prank(stranger);
        reinsurance.redeem(strangerShares, stranger, stranger);

        assertGt(weth.balanceOf(stranger) - wethBefore, 0, "Stranger should redeem successfully");
    }

    /*//////////////////////////////////////////////////////////////
                      BONUS: getPremiumMultiplier above max util
    //////////////////////////////////////////////////////////////*/

    function test_V17_PremiumMultiplier_AboveMaxUtil_ReturnsCap() external {
        // Force utilization above maxUtilizationBps by temporarily raising the limit,
        // locking more than the old max, then restoring the limit.
        // This exercises the `util > maxUtilizationBps → return 25000` branch.
        _depositVault(lp, 100 ether);
        vault.setMaxLocationExposure(10000);

        // Raise max util to 100% so we can lock 90 ETH
        vault.setUtilizationLimits(10000, 6000);
        _lock(90 ether, keccak256("a")); // 90% utilization

        // Lower max util back to 80% — now locked(90) > maxUtil(80%) of assets(100)
        vault.setUtilizationLimits(8000, 6000);

        // utilizationRate() = 9000 bps > maxUtilizationBps(8000)
        // getPremiumMultiplier should return 25000 (the else branch)
        uint256 multiplier = vault.getPremiumMultiplier();
        assertEq(multiplier, 25000, "Multiplier should be at cap when above max utilization");
    }
}
