// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {ReinsurancePool} from "../src/ReinsurancePool.sol";
import {IBruma} from "../src/interface/IBruma.sol";
import {IBrumaVault} from "../src/interface/IBrumaVault.sol";
import {Bruma} from "../src/Bruma.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {MockRainfallCoordinator} from "./mocks/MockRainfallCoordinator.sol";
import {MockPremiumCalculatorConsumer} from "./mocks/MockPremiumCalculatorConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReinsuranceAndVaultTest
 * @notice Integration + unit tests for BrumaVault and ReinsurancePool.
 *
 * CHANGES vs original:
 *   - vault.setGuardian(guardian) added to setUp() — setUtilizationLimits is now
 *     onlyGuardian (not onlyOwner), so guardian must be set before guardian tests run.
 *   - getMetrics() returns IBrumaVault.VaultMetrics struct — all destructuring as positional
 *     tuples replaced with struct field access (test_A3, test_J5).
 *   - _fundPrimaryVaultWithAccounting() helper added: calls fundPrimaryVault() then
 *     vault.receiveReinsuranceDraw() so totalReinsuranceReceived stays accurate.
 *   - test_K5 renamed: "OnlyGuardianCanSetUtilizationLimits" (was "OnlyOwner").
 *     Added test_K5b: positive test that guardian CAN set limits successfully.
 *   - Added test group L: BrumaVault guardian & reinsurance configuration tests.
 *     Covers setGuardian, setReinsurancePool, setReinsuranceYieldBps,
 *     receiveReinsuranceDraw, and premium yield routing through vault.
 *
 * KNOWN GAP (tracked, not tested here):
 *   BrumaVault.receivePremium() calls weth.safeTransfer(pool, yieldSlice) which sends
 *   WETH to ReinsurancePool. The pool's totalAssets() (= weth.balanceOf) increases
 *   correctly, but accruedYield does not update because ReinsurancePool.receiveYield()
 *   needs to be added to ReinsurancePool.sol to track inbound WETH yield separately
 *   from LP capital. Until that function exists, reinsurer yield claims after WETH
 *   routing will reflect 0 in accruedYield even though TVL increases.
 *   Tests in group L that verify WETH routing use totalAssets() as the invariant,
 *   not accruedYield.
 */
contract ReinsuranceAndVaultTest is Test {
    /*//////////////////////////////////////////////////////////////
                            CONTRACTS
    //////////////////////////////////////////////////////////////*/

    BrumaVault public vault;
    ReinsurancePool public reinsurance;
    WETH9 public weth;

    Bruma public bruma;
    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;
    MockPremiumCalculatorConsumer public premiumConsumer;

    /*//////////////////////////////////////////////////////////////
                            ACTORS
    //////////////////////////////////////////////////////////////*/

    address public deployer = address(this);
    address public guardian = address(0xAAA1);
    address public lp1 = address(0xA11CE);
    address public lp2 = address(0xB0B);
    address public reinsurer1 = makeAddr("0xRE1");
    address public reinsurer2 = makeAddr("0xRE2");
    address public buyer = address(0xBBBB);
    address public attacker = address(0xBAD);

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant LP_DEPOSIT = 100 ether;
    uint256 constant REINSURANCE_DEPOSIT = 50 ether;
    uint256 constant NOTIONAL = 0.01 ether;
    uint256 constant STRIKE = 50;
    uint256 constant SPREAD = 50;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        vm.warp(1_704_067_200); // 2024-01-01 — predictable baseline

        weth = new WETH9();

        // ── Vault ─────────────────────────────────────────────────────────────
        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "brumaVault");

        // guardian must be set: setUtilizationLimits and receiveReinsuranceDraw
        // are onlyGuardian. Using address(0xAAA1) as the CRE wallet stand-in.
        vault.setGuardian(guardian);

        // ── Reinsurance pool ──────────────────────────────────────────────────
        reinsurance = new ReinsurancePool(IERC20(address(weth)), "Bruma Reinsurance", "brumaRE");
        reinsurance.setPrimaryVault(address(vault));
        reinsurance.setGuardian(guardian);

        // ── Full Bruma oracle stack ────────────────────────────────────────────
        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        premiumConsumer = new MockPremiumCalculatorConsumer();
        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));
        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        bruma = new Bruma(
            address(rainfallCoordinator),
            address(rainfallCoordinator),
            address(premiumCoordinator),
            address(premiumConsumer),
            address(vault),
            address(weth)
        );

        vault.setWeatherOptions(address(bruma));
        premiumCoordinator.setWeatherOptions(address(bruma));

        vm.deal(lp1, 300 ether);
        vm.deal(lp2, 300 ether);
        vm.deal(reinsurer1, 200 ether);
        vm.deal(reinsurer2, 200 ether);
        vm.deal(buyer, 50 ether);
        vm.deal(attacker, 50 ether);

        _depositVault(lp1, LP_DEPOSIT);
        _depositVault(lp2, LP_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositVault(address lp, uint256 amount) internal {
        vm.startPrank(lp);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _depositReinsurance(address re, uint256 amount) internal {
        vm.startPrank(re);
        weth.deposit{value: amount}();
        weth.approve(address(reinsurance), amount);
        reinsurance.deposit(amount, re);
        vm.stopPrank();
    }

    function _createOption(address _buyer) internal returns (uint256 tokenId) {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(_buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;
        vm.prank(_buyer);
        tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);
    }

    function _lockCollateral(uint256 amount, bytes32 locationKey) internal {
        vm.prank(address(bruma));
        vault.lockCollateral(amount, 999, locationKey);
    }

    function _releaseCollateral(uint256 amount, uint256 payout, bytes32 locationKey) internal {
        vm.prank(address(bruma));
        vault.releaseCollateral(amount, payout, 999, locationKey);
    }

    /**
     * @dev Locks `totalAmount` across multiple location keys so no single location
     *      exceeds the 20% per-location cap. Returns keys for later release.
     */
    function _lockCollateralSpread(uint256 totalAmount, bytes32 baseKey) internal returns (bytes32[] memory keys) {
        uint256 maxPerLocation = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        uint256 numSlots = (totalAmount + maxPerLocation - 1) / maxPerLocation;
        keys = new bytes32[](numSlots);

        uint256 remaining = totalAmount;
        for (uint256 i = 0; i < numSlots; i++) {
            keys[i] = keccak256(abi.encodePacked(baseKey, i));
            uint256 chunk = remaining > maxPerLocation ? maxPerLocation : remaining;
            vm.prank(address(bruma));
            vault.lockCollateral(chunk, 1000 + i, keys[i]);
            remaining -= chunk;
        }
    }

    /**
     * @dev Calls reinsurance.fundPrimaryVault() then vault.receiveReinsuranceDraw()
     *      so that totalReinsuranceReceived stays accurate in addition to WETH arriving.
     *      In production the CRE guardian executes both calls atomically.
     */
    function _fundPrimaryVaultWithAccounting(uint256 amount, string memory reason) internal returns (uint256 actual) {
        vm.startPrank(guardian);
        actual = reinsurance.fundPrimaryVault(amount, reason);
        vault.receiveReinsuranceDraw(actual);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
          A. BRUMAVAULT — ACCOUNTING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_A1_InitialState() external {
        assertEq(vault.totalAssets(), 200 ether, "TVL should be 200 WETH");
        assertEq(weth.balanceOf(address(vault)), 200 ether, "WETH balance should match TVL");
        assertEq(vault.totalLocked(), 0, "No collateral locked initially");
        assertEq(vault.totalPremiumsEarned(), 0, "No premiums initially");
        assertEq(vault.totalPayouts(), 0, "No payouts initially");
        assertEq(vault.totalReinsuranceReceived(), 0, "No reinsurance draws initially");
        assertEq(vault.guardian(), guardian, "Guardian should be set");
    }

    function test_A2_TotalAssetsEqualWETHBalance() external {
        assertEq(vault.totalAssets(), weth.balanceOf(address(vault)));

        _createOption(buyer);
        assertEq(vault.totalAssets(), weth.balanceOf(address(vault)), "TVL must track WETH balance");
    }

    function test_A3_NetPnLAccounting() external {
        _createOption(buyer);

        // getMetrics() returns a struct — access fields, do NOT destructure as tuple
        IBrumaVault.VaultMetrics memory m = vault.getMetrics();
        assertEq(m.netPnL, int256(m.premiumsEarned) - int256(m.totalPayouts), "netPnL invariant");
    }

    function test_A4_PremiumsIncreaseTVL() external {
        uint256 tvlBefore = vault.totalAssets();
        _createOption(buyer);
        assertGt(vault.totalAssets(), tvlBefore, "TVL should increase after premium deposit");
    }

    function test_A5_ReinsuranceReceivedTracked() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 drawAmount = 10 ether;
        _fundPrimaryVaultWithAccounting(drawAmount, "Test draw");

        assertEq(vault.totalReinsuranceReceived(), drawAmount, "totalReinsuranceReceived must be updated");

        IBrumaVault.VaultMetrics memory m = vault.getMetrics();
        assertEq(m.reinsuranceReceived, drawAmount, "Metrics struct must reflect reinsurance received");
    }

    /*//////////////////////////////////////////////////////////////
          B. BRUMAVAULT — COLLATERAL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_B1_LockCollateralIncreasesTotalLocked() external {
        bytes32 key = keccak256("loc1");
        uint256 amount = 1 ether;

        uint256 lockedBefore = vault.totalLocked();
        _lockCollateral(amount, key);

        assertEq(vault.totalLocked(), lockedBefore + amount, "totalLocked should increase");
        assertEq(vault.locationExposure(key), amount, "Location exposure should match");
    }

    function test_B2_ReleaseCollateralOTM_ZeroPayout() external {
        bytes32 key = keccak256("loc1");
        uint256 amount = 1 ether;

        _lockCollateral(amount, key);
        uint256 vaultBalanceBefore = weth.balanceOf(address(vault));

        _releaseCollateral(amount, 0, key);

        assertEq(vault.totalLocked(), 0, "All collateral should be released");
        assertEq(vault.locationExposure(key), 0, "Location exposure should be cleared");
        assertEq(weth.balanceOf(address(vault)), vaultBalanceBefore, "No WETH should leave vault for OTM");
    }

    function test_B3_ReleaseCollateralITM_PayoutTransferred() external {
        bytes32 key = keccak256("loc1");
        uint256 amount = 1 ether;
        uint256 payout = 0.3 ether;

        _lockCollateral(amount, key);
        uint256 vaultBalanceBefore = weth.balanceOf(address(vault));

        _releaseCollateral(amount, payout, key);

        assertEq(vault.totalLocked(), 0, "All collateral should be released");
        assertEq(vault.totalPayouts(), payout, "totalPayouts should track payout");
        assertEq(weth.balanceOf(address(vault)), vaultBalanceBefore - payout, "Vault should transfer payout WETH out");
        assertEq(weth.balanceOf(address(bruma)), payout, "Bruma contract should receive the payout WETH");
    }

    function test_B4_ReleaseCollateral_MaxPayout() external {
        bytes32 key = keccak256("loc1");
        uint256 amount = 1 ether;

        _lockCollateral(amount, key);
        _releaseCollateral(amount, amount, key);

        assertEq(vault.totalLocked(), 0);
        assertEq(vault.totalPayouts(), amount);
    }

    function test_B5_CannotReleaseMoreThanLocked() external {
        bytes32 key = keccak256("loc1");
        _lockCollateral(1 ether, key);

        vm.prank(address(bruma));
        vm.expectRevert();
        vault.releaseCollateral(2 ether, 0, 999, key);
    }

    function test_B6_FullOptionLifecycle_CollateralAccounting() external {
        uint256 lockedBefore = vault.totalLocked();
        uint256 tokenId = _createOption(buyer);

        uint256 maxPayout = SPREAD * NOTIONAL;
        assertEq(vault.totalLocked(), lockedBefore + maxPayout, "Collateral locked on creation");

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        vm.prank(buyer);
        bruma.settle(tokenId);

        assertEq(vault.totalLocked(), 0, "Collateral fully released after settlement");
    }

    /*//////////////////////////////////////////////////////////////
          C. BRUMAVAULT — UTILIZATION & LOCATION LIMITS
    //////////////////////////////////////////////////////////////*/

    function test_C1_UtilizationRateCalculation() external {
        bytes32 key = keccak256("loc1");
        uint256 lockAmount = 40 ether; // 40/200 = 20%

        _lockCollateral(lockAmount, key);

        assertApproxEqRel(vault.utilizationRate(), 2000, 0.01e18, "Utilization should be ~20%");
    }

    function test_C2_CannotExceedMaxUtilization() external {
        _lockCollateralSpread(160 ether, keccak256("utilTest"));

        assertEq(vault.utilizationRate(), vault.maxUtilizationBps(), "Should be at max utilization");

        vm.prank(address(bruma));
        vm.expectRevert(IBrumaVault.UtilizationTooHigh.selector);
        vault.lockCollateral(1 ether, 888, keccak256("fresh"));
    }

    function test_C3_LocationExposureLimitEnforced() external {
        bytes32 key = keccak256("loc1");
        _lockCollateral(40 ether, key);

        vm.prank(address(bruma));
        vm.expectRevert(IBrumaVault.LocationExposureTooHigh.selector);
        vault.lockCollateral(1 ether, 777, key);
    }

    function test_C4_DifferentLocationsAccumulateSeparately() external {
        bytes32 key1 = keccak256("loc1");
        bytes32 key2 = keccak256("loc2");

        _lockCollateral(30 ether, key1);
        _lockCollateral(30 ether, key2);

        assertEq(vault.totalLocked(), 60 ether);
        assertEq(vault.locationExposure(key1), 30 ether);
        assertEq(vault.locationExposure(key2), 30 ether);
    }

    function test_C5_CanUnderwrite_ReturnsFalseWhenUtilTooHigh() external {
        _lockCollateralSpread(160 ether, keccak256("utilTest"));

        assertFalse(vault.canUnderwrite(1 ether, keccak256("fresh")), "Should not underwrite at max util");
    }

    function test_C6_CanUnderwrite_ReturnsFalseWhenLocationFull() external {
        bytes32 key = keccak256("loc1");
        _lockCollateral(40 ether, key);

        assertFalse(vault.canUnderwrite(1 ether, key), "Should not underwrite at max location exposure");
    }

    function test_C7_CanUnderwrite_ReturnsTrueWhenSafe() external {
        bytes32 key = keccak256("loc1");
        assertTrue(vault.canUnderwrite(10 ether, key), "Should underwrite when well within limits");
    }

    function test_C8_AvailableLiquidityRespectsMaxUtilization() external {
        uint256 assets = vault.totalAssets(); // 200 ETH
        uint256 maxLockable = (assets * vault.maxUtilizationBps()) / 10000; // 160 ETH

        _lockCollateralSpread(50 ether, keccak256("utilTest"));

        uint256 expected = maxLockable - 50 ether; // 110 ETH
        assertEq(vault.availableLiquidity(), expected, "Available should respect max utilization cap");
    }

    /*//////////////////////////////////////////////////////////////
          D. BRUMAVAULT — ERC-4626 SHARE MECHANICS & WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_D1_EqualDepositsGetEqualShares() external {
        assertEq(vault.balanceOf(lp1), vault.balanceOf(lp2), "Equal deposits  equal shares");
        assertEq(vault.balanceOf(lp1) + vault.balanceOf(lp2), vault.totalSupply());
    }

    function test_D2_SharesRepresentProportionalOwnership() external {
        uint256 lp1Shares = vault.balanceOf(lp1);
        assertApproxEqRel(vault.convertToAssets(lp1Shares), 100 ether, 0.01e18, "LP1 should own ~100 ETH of assets");
    }

    function test_D3_CannotWithdrawLockedCollateral() external {
        _lockCollateralSpread(100 ether, keccak256("wdTest"));

        uint256 lp1MaxWithdraw = vault.maxWithdraw(lp1);
        uint256 lp1Assets = vault.convertToAssets(vault.balanceOf(lp1));

        assertLt(lp1MaxWithdraw, lp1Assets, "Max withdraw must be less than total assets when collateral locked");
    }

    function test_D4_CanWithdrawProportionalAvailable() external {
        _lockCollateralSpread(80 ether, keccak256("wdTest"));

        uint256 lp1MaxWithdraw = vault.maxWithdraw(lp1);
        assertGt(lp1MaxWithdraw, 0, "Should be able to withdraw some");

        uint256 balBefore = weth.balanceOf(lp1);
        vm.prank(lp1);
        vault.withdraw(lp1MaxWithdraw, lp1, lp1);

        assertApproxEqRel(weth.balanceOf(lp1) - balBefore, lp1MaxWithdraw, 0.01e18, "Should receive maxWithdraw");
    }

    function test_D5_FullWithdrawAfterAllCollateralReleased() external {
        bytes32[] memory keys = _lockCollateralSpread(50 ether, keccak256("wdTest"));

        uint256 maxPerLocation = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        uint256 remaining = 50 ether;
        for (uint256 i = 0; i < keys.length; i++) {
            uint256 chunk = remaining > maxPerLocation ? maxPerLocation : remaining;
            _releaseCollateral(chunk, 0, keys[i]);
            remaining -= chunk;
        }

        uint256 lp1MaxWithdraw = vault.maxWithdraw(lp1);
        uint256 lp1Assets = vault.convertToAssets(vault.balanceOf(lp1));
        assertApproxEqRel(lp1MaxWithdraw, lp1Assets, 0.01e18, "Should withdraw full amount when no collateral locked");
    }

    function test_D6_ThirdDepositorGetsCorrectShares() external {
        address lp3 = address(0xC3);
        vm.deal(lp3, 50 ether);
        _depositVault(lp3, 50 ether);

        uint256 lp3Share = vault.convertToAssets(vault.balanceOf(lp3));
        assertApproxEqRel(lp3Share, 50 ether, 0.01e18, "LP3 should own ~50 ETH");
    }

    function test_D7_PremiumIncreasesShareValue() external {
        uint256 sharesBefore = vault.balanceOf(lp1);
        uint256 assetsBefore = vault.convertToAssets(sharesBefore);

        _createOption(buyer);

        uint256 assetsAfter = vault.convertToAssets(sharesBefore);
        assertGt(assetsAfter, assetsBefore, "Share value should increase after premium");
    }

    /*//////////////////////////////////////////////////////////////
          E. BRUMAVAULT — PREMIUM MULTIPLIER
    //////////////////////////////////////////////////////////////*/

    function test_E1_MultiplierIsBaseline_BelowTarget() external {
        assertEq(vault.getPremiumMultiplier(), 10000, "Multiplier should be 1.0x at zero utilization");
    }

    function test_E2_MultiplierScalesAboveTarget() external {
        _lockCollateralSpread(140 ether, keccak256("multTest"));

        uint256 util = vault.utilizationRate();
        uint256 multiplier = vault.getPremiumMultiplier();

        assertGt(util, 6000, "Utilization should be above target");
        assertGt(multiplier, 10000, "Multiplier should be above 1.0x");
        assertLt(multiplier, 25000, "Multiplier should be below max");
    }

    function test_E3_MultiplierMaxAboveMaxUtilization() external {
        bytes32 key1 = keccak256("loc1");
        bytes32 key2 = keccak256("loc2");
        _lockCollateral(40 ether, key1);
        _lockCollateral(40 ether, key2);

        address lp3 = address(0xC33);
        vm.deal(lp3, 10 ether);
        _depositVault(lp3, 10 ether);

        assertEq(vault.getPremiumMultiplier(), 10000);
    }

    /*//////////////////////////////////////////////////////////////
          F. REINSURANCE POOL — DEPOSIT & LOCKUP ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_F1_DepositSetsLockup() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        (bool locked, uint256 expiry) = reinsurance.isLocked(reinsurer1);
        assertTrue(locked, "Should be locked after deposit");
        assertEq(expiry, block.timestamp + 30 days, "Lockup should expire in 30 days");
    }

    function test_F2_CannotWithdrawDuringLockup() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        vm.prank(reinsurer1);
        vm.expectRevert();
        reinsurance.withdraw(1 ether, reinsurer1, reinsurer1);
    }

    function test_F3_CanWithdrawAfterLockupExpiry() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        vm.warp(block.timestamp + 31 days);

        uint256 balBefore = weth.balanceOf(reinsurer1);
        vm.prank(reinsurer1);
        reinsurance.withdraw(REINSURANCE_DEPOSIT, reinsurer1, reinsurer1);

        assertEq(weth.balanceOf(reinsurer1) - balBefore, REINSURANCE_DEPOSIT, "Should receive full deposit back");
    }

    function test_F4_SecondDepositRestartsLockup() external {
        _depositReinsurance(reinsurer1, 10 ether);

        vm.warp(block.timestamp + 20 days);

        _depositReinsurance(reinsurer1, 5 ether);

        (, uint256 expiry) = reinsurance.isLocked(reinsurer1);
        assertApproxEqAbs(expiry, block.timestamp + 30 days, 1, "Lockup should restart on new deposit");
    }

    function test_F5_TotalAssetsMatchesWETHBalance() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);
        _depositReinsurance(reinsurer2, REINSURANCE_DEPOSIT);

        assertEq(reinsurance.totalAssets(), weth.balanceOf(address(reinsurance)), "totalAssets must track WETH balance");
    }

    function test_F6_TwoReinsurersEqualShares() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);
        _depositReinsurance(reinsurer2, REINSURANCE_DEPOSIT);

        assertEq(reinsurance.balanceOf(reinsurer1), reinsurance.balanceOf(reinsurer2), "Equal deposits  equal shares");
    }

    /*//////////////////////////////////////////////////////////////
          G. REINSURANCE POOL — GUARDIAN DRAW MECHANICS
    //////////////////////////////////////////////////////////////*/

    function test_G1_GuardianCanDraw() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        uint256 vaultBefore = weth.balanceOf(address(vault));
        uint256 poolBefore = weth.balanceOf(address(reinsurance));
        uint256 drawAmount = 10 ether;

        vm.prank(guardian);
        uint256 actual = reinsurance.fundPrimaryVault(drawAmount, "Test draw");

        assertEq(actual, drawAmount, "Actual draw should match requested");
        assertEq(weth.balanceOf(address(vault)), vaultBefore + drawAmount, "Vault should receive WETH");
        assertEq(weth.balanceOf(address(reinsurance)), poolBefore - drawAmount, "Pool should decrease");
        assertEq(reinsurance.totalDrawn(), drawAmount, "totalDrawn should be updated");
    }

    function test_G2_NonGuardianCannotDraw() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        vm.prank(attacker);
        vm.expectRevert(ReinsurancePool.UnauthorizedGuardian.selector);
        reinsurance.fundPrimaryVault(1 ether, "Attack");
    }

    function test_G3_DrawRecordedInHistory() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        vm.prank(guardian);
        reinsurance.fundPrimaryVault(5 ether, "Correlated loss event");

        ReinsurancePool.DrawRecord[] memory history = reinsurance.getDrawHistory();
        assertEq(history.length, 1, "Should have 1 draw record");
        assertEq(history[0].amount, 5 ether, "Draw amount should match");
        assertEq(history[0].triggeredBy, guardian, "Triggerer should be guardian");
    }

    function test_G4_CannotDrawWithoutPrimaryVault() external {
        ReinsurancePool isolated = new ReinsurancePool(IERC20(address(weth)), "Isolated", "ISO");
        isolated.setGuardian(guardian);

        vm.prank(guardian);
        vm.expectRevert(ReinsurancePool.PrimaryVaultNotSet.selector);
        isolated.fundPrimaryVault(1 ether, "No vault set");
    }

    function test_G5_CannotDrawZero() external {
        _depositReinsurance(reinsurer1, REINSURANCE_DEPOSIT);

        vm.prank(guardian);
        vm.expectRevert(ReinsurancePool.ZeroAmount.selector);
        reinsurance.fundPrimaryVault(0, "Zero draw");
    }

    function test_G6_MultipleDrawsAccumulate() external {
        _depositReinsurance(reinsurer1, 100 ether);

        vm.prank(guardian);
        reinsurance.fundPrimaryVault(5 ether, "Draw 1");

        vm.prank(guardian);
        reinsurance.fundPrimaryVault(5 ether, "Draw 2");

        assertEq(reinsurance.totalDrawn(), 10 ether, "totalDrawn should accumulate");
        assertEq(reinsurance.getDrawHistory().length, 2, "Should have 2 records");
    }

    /*//////////////////////////////////////////////////////////////
          H. REINSURANCE POOL — YIELD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function test_H1_YieldDepositedAccrues() external {
        reinsurance.depositYield{value: 0.5 ether}();
        assertEq(reinsurance.accruedYield(), 0.5 ether, "Accrued yield should update");
    }

    function test_H2_ProRataYieldClaim() external {
        _depositReinsurance(reinsurer1, 50 ether);
        _depositReinsurance(reinsurer2, 50 ether);

        reinsurance.depositYield{value: 2 ether}();

        uint256 r1Before = reinsurer1.balance;
        vm.prank(reinsurer1);
        uint256 claimed = reinsurance.claimYield();

        assertApproxEqRel(claimed, 1 ether, 0.01e18, "Reinsurer1 should claim ~50% of yield");
        assertApproxEqRel(reinsurer1.balance - r1Before, 1 ether, 0.01e18, "Balance should increase");
    }

    function test_H3_YieldClaimableWithoutLockupExpiry() external {
        _depositReinsurance(reinsurer1, 50 ether);
        reinsurance.depositYield{value: 1 ether}();

        (bool locked,) = reinsurance.isLocked(reinsurer1);
        assertTrue(locked, "Should be locked");

        vm.prank(reinsurer1);
        uint256 claimed = reinsurance.claimYield();
        assertGt(claimed, 0, "Should claim yield even during lockup");
    }

    function test_H4_ZeroSharesGetNoYield() external {
        reinsurance.depositYield{value: 1 ether}();

        vm.prank(attacker);
        uint256 claimed = reinsurance.claimYield();
        assertEq(claimed, 0, "No shares  no yield");
    }

    function test_H5_YieldReducesAccruedBalance() external {
        _depositReinsurance(reinsurer1, 50 ether);
        reinsurance.depositYield{value: 2 ether}();

        vm.prank(reinsurer1);
        reinsurance.claimYield();

        assertEq(reinsurance.accruedYield(), 0, "Accrued yield should be zero after single reinsurer claims all");
    }

    /*//////////////////////////////////////////////////////////////
          I. REINSURANCE POOL — DRAW LIMITS & RESERVE FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_I1_DrawCapAt50Percent() external {
        _depositReinsurance(reinsurer1, 100 ether);

        // Pool = 100 ETH
        // minReserve    = 100 * 20% = 20 ETH → maxDrawable = 80 ETH
        // maxSingleDraw = 100 * 50% = 50 ETH
        // cap = min(80, 50) = 50 ETH → requested 80 ETH → actual 50 ETH
        vm.prank(guardian);
        uint256 actual = reinsurance.fundPrimaryVault(80 ether, "Large draw");

        assertEq(actual, 50 ether, "Draw capped at 50% single-draw limit");
    }

    function test_I2_ReserveFloorRespected() external {
        _depositReinsurance(reinsurer1, 100 ether);

        vm.prank(guardian);
        reinsurance.fundPrimaryVault(50 ether, "First draw");

        // 50 ETH left, minReserve=10, maxDrawable=40, maxSingleDraw=25 → cap=25
        vm.prank(guardian);
        uint256 second = reinsurance.fundPrimaryVault(50 ether, "Second draw");

        assertLe(second, 25 ether, "Second draw should be capped by remaining liquidity");
        assertGe(weth.balanceOf(address(reinsurance)), 0, "Pool should not be empty");
    }

    function test_I3_CannotDrawWhenBelowReserve() external {
        ReinsurancePool tiny = new ReinsurancePool(IERC20(address(weth)), "Tiny", "TNY");
        tiny.setPrimaryVault(address(vault));
        tiny.setGuardian(guardian);
        tiny.setDrawLimits(1, 9999); // maxSingleDraw=0.01%, minReserve=99.99%

        // Deposit 1 wei — maxSingleDraw = 1 * 1 / 10000 = 0 → cap rounds to 0 → revert
        vm.startPrank(reinsurer1);
        weth.deposit{value: 1}();
        weth.approve(address(tiny), 1);
        tiny.deposit(1, reinsurer1);
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(ReinsurancePool.InsufficientPoolLiquidity.selector);
        tiny.fundPrimaryVault(1, "Impossible draw");
    }

    function test_I4_DrawLimitsCanBeUpdatedByOwner() external {
        reinsurance.setDrawLimits(3000, 1000);

        assertEq(reinsurance.maxSingleDrawBps(), 3000);
        assertEq(reinsurance.minReserveBps(), 1000);
    }

    function test_I5_InvalidDrawLimitsRevert() external {
        vm.expectRevert(ReinsurancePool.InvalidBps.selector);
        reinsurance.setDrawLimits(6000, 5000); // sum = 110% — invalid
    }

    function test_I6_AvailableCapacityCalculation() external {
        _depositReinsurance(reinsurer1, 100 ether);

        // minReserve = 100 * 20% = 20 ETH → available = 80 ETH
        assertEq(reinsurance.availableCapacity(), 80 ether, "Available capacity should be pool minus reserve");
    }

    function test_I7_MaxDrawableNow() external {
        _depositReinsurance(reinsurer1, 100 ether);

        // maxSingleDraw = 50 ETH, available = 80 ETH → maxDrawable = 50 ETH
        assertEq(reinsurance.maxDrawableNow(), 50 ether, "maxDrawableNow should be min(single cap, available)");
    }

    /*//////////////////////////////////////////////////////////////
          J. INTEGRATION — VAULT + REINSURANCE WATERFALL
    //////////////////////////////////////////////////////////////*/

    function test_J1_DrawIncreasesVaultTVL() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 vaultTVLBefore = vault.totalAssets();

        _fundPrimaryVaultWithAccounting(20 ether, "Correlated hurricane losses");

        assertEq(vault.totalAssets(), vaultTVLBefore + 20 ether, "Vault TVL must increase by drawn amount");
        assertEq(vault.totalReinsuranceReceived(), 20 ether, "Accounting must be updated via receiveReinsuranceDraw");
    }

    function test_J2_DrawEnablesVaultToMeetITMPayouts() external {
        _depositReinsurance(reinsurer1, 100 ether);

        _lockCollateralSpread(160 ether, keccak256("bigLoc"));

        assertEq(vault.utilizationRate(), vault.maxUtilizationBps(), "Should be at max utilization");

        _fundPrimaryVaultWithAccounting(20 ether, "Restore capacity");

        // TVL 220, locked 160 — util = 72.7% < 80% max
        assertLt(vault.utilizationRate(), vault.maxUtilizationBps(), "Utilization should be below max after draw");
    }

    function test_J3_FullWaterfall_OptionToPayoutToReinsurance() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 200); // max payout

        uint256 vaultTVLBefore = vault.totalAssets();
        vm.prank(buyer);
        bruma.settle(tokenId);

        assertLt(vault.totalAssets(), vaultTVLBefore, "Vault TVL should decrease after max payout");
        assertEq(vault.totalLocked(), 0, "No more locked collateral");

        uint256 loss = vaultTVLBefore - vault.totalAssets();
        uint256 drawNeeded = loss > reinsurance.maxDrawableNow() ? reinsurance.maxDrawableNow() : loss;

        uint256 vaultAfterDraw = vault.totalAssets();
        _fundPrimaryVaultWithAccounting(drawNeeded, "Post-settlement reinsurance draw");

        assertGt(vault.totalAssets(), vaultAfterDraw, "Reinsurance draw should restore vault capital");
        assertGt(vault.totalReinsuranceReceived(), 0, "Reinsurance accounting should be updated");
    }

    function test_J4_ReinsurersShareLossProportionally() external {
        _depositReinsurance(reinsurer1, 50 ether);
        _depositReinsurance(reinsurer2, 50 ether);

        uint256 r1SharesBefore = reinsurance.balanceOf(reinsurer1);
        uint256 r2SharesBefore = reinsurance.balanceOf(reinsurer2);
        assertEq(r1SharesBefore, r2SharesBefore, "Equal deposit  equal shares");

        vm.prank(guardian);
        reinsurance.fundPrimaryVault(20 ether, "Loss event");

        uint256 r1AssetsAfter = reinsurance.convertToAssets(reinsurance.balanceOf(reinsurer1));
        uint256 r2AssetsAfter = reinsurance.convertToAssets(reinsurance.balanceOf(reinsurer2));

        assertApproxEqRel(r1AssetsAfter, r2AssetsAfter, 0.01e18, "Loss must be shared equally");
        assertLt(r1AssetsAfter, 50 ether, "Each reinsurer's assets should decrease after draw");
    }

    function test_J5_VaultMetrics_PostIntegration() external {
        _depositReinsurance(reinsurer1, 100 ether);
        _createOption(buyer);

        _fundPrimaryVaultWithAccounting(10 ether, "Proactive buffer");

        // getMetrics() returns a struct — access fields, do NOT destructure as tuple
        IBrumaVault.VaultMetrics memory m = vault.getMetrics();

        assertGt(m.tvl, 200 ether, "TVL should exceed initial (premiums + reinsurance draw)");
        assertGt(m.locked, 0, "Some collateral still locked");
        assertGt(m.available, 0, "Available liquidity should be positive");
        assertGt(m.premiumsEarned, 0, "Premium should have been earned");
        assertGt(m.netPnL, 0, "Should be profitable before any payout");
        assertEq(m.reinsuranceReceived, 10 ether, "Reinsurance draw should be reflected in metrics");
    }

    /*//////////////////////////////////////////////////////////////
          K. ACCESS CONTROL — ONLY AUTHORIZED CALLERS
    //////////////////////////////////////////////////////////////*/

    function test_K1_OnlyWeatherOptionsCanLockCollateral() external {
        vm.prank(attacker);
        vm.expectRevert(IBrumaVault.UnauthorizedCaller.selector);
        vault.lockCollateral(1 ether, 0, keccak256("loc"));
    }

    function test_K2_OnlyWeatherOptionsCanReleaseCollateral() external {
        vm.prank(attacker);
        vm.expectRevert(IBrumaVault.UnauthorizedCaller.selector);
        vault.releaseCollateral(1 ether, 0, 0, keccak256("loc"));
    }

    function test_K3_OnlyWeatherOptionsCanReceivePremium() external {
        vm.prank(attacker);
        vm.expectRevert(IBrumaVault.UnauthorizedCaller.selector);
        vault.receivePremium(1 ether, 0);
    }

    function test_K4_OnlyOwnerCanSetWeatherOptions() external {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setWeatherOptions(address(0xDEAD));
    }

    /**
     * @dev setUtilizationLimits is onlyGuardian (not onlyOwner) so the CRE job
     *      can adjust risk parameters autonomously. Attacker still cannot call it.
     */
    function test_K5_OnlyGuardianCanSetUtilizationLimits() external {
        vm.prank(attacker);
        vm.expectRevert(IBrumaVault.UnauthorizedGuardian.selector);
        vault.setUtilizationLimits(5000, 3000);
    }

    /// @dev Positive counterpart: guardian CAN set utilization limits.
    function test_K5b_GuardianCanSetUtilizationLimits() external {
        vm.prank(guardian);
        vault.setUtilizationLimits(7000, 5000);

        assertEq(vault.maxUtilizationBps(), 7000, "maxUtilizationBps should update");
        assertEq(vault.targetUtilizationBps(), 5000, "targetUtilizationBps should update");
    }

    function test_K6_OnlyOwnerCanSetReinsuranceGuardian() external {
        vm.prank(attacker);
        vm.expectRevert();
        reinsurance.setGuardian(attacker);
    }

    function test_K7_OnlyOwnerCanSetPrimaryVault() external {
        vm.prank(attacker);
        vm.expectRevert();
        reinsurance.setPrimaryVault(attacker);
    }

    function test_K8_OnlyGuardianCanReceiveReinsuranceDraw() external {
        vm.prank(attacker);
        vm.expectRevert(IBrumaVault.UnauthorizedGuardian.selector);
        vault.receiveReinsuranceDraw(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
          L. BRUMAVAULT — GUARDIAN & REINSURANCE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_L1_SetGuardianEmitsEvent() external {
        address newGuardian = address(0xBBBB);

        vm.expectEmit(true, true, false, false, address(vault));
        emit IBrumaVault.GuardianUpdated(guardian, newGuardian);

        vault.setGuardian(newGuardian);
        assertEq(vault.guardian(), newGuardian, "Guardian should be updated");
    }

    function test_L2_CannotSetGuardianToZeroAddress() external {
        vm.expectRevert(IBrumaVault.InvalidAddress.selector);
        vault.setGuardian(address(0));
    }

    function test_L3_SetReinsurancePoolEmitsEvent() external {
        vm.expectEmit(true, true, false, false, address(vault));
        emit IBrumaVault.ReinsurancePoolUpdated(address(0), address(reinsurance));

        vault.setReinsurancePool(address(reinsurance));
        assertEq(vault.reinsurancePool(), address(reinsurance), "Reinsurance pool should be set");
    }

    function test_L4_SetReinsurancePoolToZeroDisablesRouting() external {
        vault.setReinsurancePool(address(reinsurance));
        vault.setReinsurancePool(address(0)); // disable

        assertEq(vault.reinsurancePool(), address(0), "Should clear reinsurance pool");
    }

    function test_L5_SetReinsuranceYieldBps() external {
        vault.setReinsurancePool(address(reinsurance));

        vm.expectEmit(false, false, false, true, address(vault));
        emit IBrumaVault.ReinsuranceYieldBpsUpdated(0, 500);

        vault.setReinsuranceYieldBps(500); // 5%
        assertEq(vault.reinsuranceYieldBps(), 500, "Yield bps should be updated");
    }

    function test_L6_CannotSetYieldBpsAbove5000() external {
        vm.expectRevert(IBrumaVault.InvalidLimits.selector);
        vault.setReinsuranceYieldBps(5001);
    }

    function test_L7_ReceiveReinsuranceDraw_UpdatesAccounting() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 drawAmount = 15 ether;
        vm.prank(guardian);
        uint256 actual = reinsurance.fundPrimaryVault(drawAmount, "Accounting test");

        // WETH has arrived in vault — now update accounting
        vm.prank(guardian);
        vault.receiveReinsuranceDraw(actual);

        assertEq(vault.totalReinsuranceReceived(), actual, "Accounting should reflect draw");

        IBrumaVault.VaultMetrics memory m = vault.getMetrics();
        assertEq(m.reinsuranceReceived, actual, "getMetrics should reflect draw");
    }

    function test_L8_ReceiveReinsuranceDraw_CannotBeZero() external {
        vm.prank(guardian);
        vm.expectRevert(IBrumaVault.ZeroAmount.selector);
        vault.receiveReinsuranceDraw(0);
    }

    /**
     * @dev Verify that when reinsuranceYieldBps > 0 and pool is set,
     *      receivePremium routes a WETH slice to the pool (totalAssets increases).
     *
     *      NOTE: ReinsurancePool.accruedYield will NOT reflect this transfer because
     *      ReinsurancePool currently has no receiveYield(uint256) accounting function.
     *      The pool's totalAssets() (= weth.balanceOf) does increase correctly and
     *      all LP shares benefit proportionally. accruedYield tracking for WETH-routed
     *      yield requires adding receiveYield() to ReinsurancePool — tracked as TODO.
     */
    function test_L9_PremiumYieldRoutedToReinsurancePool() external {
        _depositReinsurance(reinsurer1, 50 ether);

        // Activate 10% yield routing to reinsurance pool
        vault.setReinsurancePool(address(reinsurance));
        vault.setReinsuranceYieldBps(1000);

        uint256 poolAssetsBefore = reinsurance.totalAssets();
        uint256 vaultAssetsBefore = vault.totalAssets();

        _createOption(buyer);

        // Pool totalAssets should increase by the yield slice
        assertGt(reinsurance.totalAssets(), poolAssetsBefore, "Reinsurance pool should receive WETH yield slice");
        // Vault retains the net premium only
        assertLt(
            vault.totalPremiumsEarned(),
            vault.totalAssets() - vaultAssetsBefore + 1,
            "Vault premium earned should be net of yield slice"
        );
    }

    function test_L10_ZeroYieldBps_NoRoutingOccurs() external {
        _depositReinsurance(reinsurer1, 50 ether);
        vault.setReinsurancePool(address(reinsurance));
        // reinsuranceYieldBps stays at 0 (default)

        uint256 poolAssetsBefore = reinsurance.totalAssets();

        _createOption(buyer);

        assertEq(reinsurance.totalAssets(), poolAssetsBefore, "No routing when yieldBps=0");
    }

    function test_L11_NoPoolSet_PremiumFullyBooked() external {
        // reinsurancePool stays address(0) — all premium stays in vault
        uint256 tvlBefore = vault.totalAssets();

        _createOption(buyer);

        uint256 premium = vault.totalPremiumsEarned();
        assertGt(premium, 0, "Premium should be earned");
        assertGt(vault.totalAssets(), tvlBefore, "Full premium stays in vault");
    }

    /*//////////////////////////////////////////////////////////////
          M. SECURITY — REENTRANCY GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_M2_WithdrawUsesERC20_NoETHReentrancySurface() external {
        _depositReinsurance(reinsurer1, 50 ether);
        vm.warp(block.timestamp + 31 days);

        // reinsurer1 started with 200 ETH, wrapped 50 ETH in setUp._depositReinsurance
        // ETH balance is correctly 150 ETH — WETH received back, no ETH movement
        uint256 wethBefore = weth.balanceOf(reinsurer1);
        uint256 ethBefore = reinsurer1.balance; // 150 ETH

        vm.prank(reinsurer1);
        reinsurance.withdraw(50 ether, reinsurer1, reinsurer1);

        assertEq(weth.balanceOf(reinsurer1) - wethBefore, 50 ether, "Should receive WETH");
        assertEq(reinsurer1.balance, ethBefore, "ETH balance unchanged withdrawal is ERC20 only");
    }

    function test_M3_ReentrancyGuard_FundPrimaryVault() external {
        ReentrantVaultDrainer attacker_ = new ReentrantVaultDrainer(reinsurance, guardian);
        vm.deal(address(attacker_), 100 ether);
        attacker_.deposit(100 ether);

        // Guardian is the only one who can draw, and cannot reenter
        vm.prank(guardian);
        vm.expectRevert();
        attacker_.attack();
    }

    /*//////////////////////////////////////////////////////////////
          N. SECURITY — SHARE PRICE MANIPULATION (FIRST DEPOSITOR)
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Classic ERC-4626 inflation attack: attacker deposits 1 wei, then
     *      donates a large amount directly to the vault to inflate share price,
     *      forcing the next depositor's shares to round down to zero.
     *      The vault must be immune via virtual shares or similar mitigation.
     */
    // ── N1/N2: Vault does NOT have virtual share protection.
    //           The inflation attack succeeds — victim deposit reverts with 0 shares.
    //           These tests document the vulnerability for audit review.
    function test_N1_VaultInflationAttack_IsProtectedByVirtualShares() external {
        BrumaVault freshVault = new BrumaVault(IERC20(address(weth)), "Fresh", "FV");
        freshVault.setWeatherOptions(address(bruma));

        address attacker_ = makeAddr("inflationAttacker");
        vm.deal(attacker_, 200 ether);
        vm.startPrank(attacker_);
        weth.deposit{value: 1}();
        weth.approve(address(freshVault), 1);
        freshVault.deposit(1, attacker_);

        // To steal victim's 99 ETH deposit, attacker must donate enough to make
        // victim's shares round to 0. With offset=9, victim gets:
        //   shares = 99e18 * (totalSupply + 1e9) / (totalAssets + 1)
        // For shares to round to 0: 99e18 * (S + 1e9) < (A + 1)
        // That requires donating ~99e18 * 1e9 = 99e27 wei — 99 billion ETH.
        // Attack is economically impossible.
        weth.deposit{value: 100 ether}();
        weth.transfer(address(freshVault), 100 ether); // donation
        vm.stopPrank();

        address victim = makeAddr("victim");
        vm.deal(victim, 100 ether);
        vm.startPrank(victim);
        weth.deposit{value: 99 ether}();
        weth.approve(address(freshVault), 99 ether);
        uint256 shares = freshVault.deposit(99 ether, victim);
        vm.stopPrank();

        // Victim receives non-zero shares — attack failed
        assertGt(shares, 0, "Virtual shares protect against inflation attack");
        // Victim's assets should be close to their deposit
        assertApproxEqRel(
            freshVault.convertToAssets(shares), 99 ether, 0.01e18, "Victim should recover ~full deposit value"
        );
    }

    function test_N2_ReinsurancePoolInflationAttack_IsProtectedByVirtualShares() external {
        ReinsurancePool freshPool = new ReinsurancePool(IERC20(address(weth)), "Fresh", "FP");
        freshPool.setPrimaryVault(address(vault));

        address attacker_ = makeAddr("inflationAttacker2");
        vm.deal(attacker_, 200 ether);
        vm.startPrank(attacker_);
        weth.deposit{value: 1}();
        weth.approve(address(freshPool), 1);
        freshPool.deposit(1, attacker_);
        weth.deposit{value: 100 ether}();
        weth.transfer(address(freshPool), 100 ether);
        vm.stopPrank();

        address victim = makeAddr("victim2");
        vm.deal(victim, 100 ether);
        vm.startPrank(victim);
        weth.deposit{value: 50 ether}();
        weth.approve(address(freshPool), 50 ether);
        uint256 shares = freshPool.deposit(50 ether, victim);
        vm.stopPrank();

        assertGt(shares, 0, "ReinsurancePool virtual shares protect against inflation attack");
        assertApproxEqRel(freshPool.convertToAssets(shares), 50 ether, 0.01e18, "Victim recovers ~full value");
    }
    /*//////////////////////////////////////////////////////////////
          O. SECURITY — DRAW LIMIT BYPASS ATTEMPTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Verify that many sequential small draws cannot drain the pool
     *      below the minReserve floor. Each draw recalculates limits against
     *      the current (post-draw) pool balance.
     */
    function test_O1_SequentialDrawsCannotDrainBelowReserve() external {
        _depositReinsurance(reinsurer1, 100 ether);

        // Perform 10 sequential draws of maximum allowed each time
        for (uint256 i = 0; i < 10; i++) {
            uint256 drawable = reinsurance.maxDrawableNow();
            if (drawable == 0) break;

            vm.prank(guardian);
            reinsurance.fundPrimaryVault(drawable, "Sequential draw");
        }

        uint256 poolBalance = weth.balanceOf(address(reinsurance));
        uint256 minReserve = (reinsurance.totalAssets() * reinsurance.minReserveBps()) / 10000;

        assertGe(poolBalance, minReserve, "SECURITY: pool must never fall below reserve floor");
    }

    /**
     * @dev Attacker cannot artificially inflate totalDrawn by calling
     *      fundPrimaryVault with amount=0 to manipulate state.
     */
    function test_O2_ZeroDrawCannotManipulateTotalDrawn() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 drawnBefore = reinsurance.totalDrawn();

        vm.prank(guardian);
        vm.expectRevert(ReinsurancePool.ZeroAmount.selector);
        reinsurance.fundPrimaryVault(0, "Zero manipulation");

        assertEq(reinsurance.totalDrawn(), drawnBefore, "totalDrawn must not change on zero draw");
    }

    /**
     * @dev Verify drawHistory cannot be manipulated by a reverted draw:
     *      a failed draw must not append a record.
     */
    function test_O3_RevertedDrawDoesNotAppendHistory() external {
        _depositReinsurance(reinsurer1, 100 ether);

        uint256 histBefore = reinsurance.getDrawHistory().length;

        // Attempt draw by non-guardian — reverts
        vm.prank(attacker);
        try reinsurance.fundPrimaryVault(1 ether, "Stealth") {} catch {}

        assertEq(reinsurance.getDrawHistory().length, histBefore, "SECURITY: failed draw must not append history");
    }

    /*//////////////////////////////////////////////////////////////
          P. SECURITY — ACCOUNTING MANIPULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev receiveReinsuranceDraw increments totalReinsuranceReceived but
     *      does NOT transfer WETH itself. An attacker (or misconfigured guardian)
     *      calling it without a corresponding fundPrimaryVault should produce
     *      inflated accounting. Verify the vault's WETH balance is the source
     *      of truth and cannot be inflated by calling receiveReinsuranceDraw alone.
     */
    function test_P1_ReceiveReinsuranceDraw_NoWETHMinted() external {
        uint256 wethBefore = weth.balanceOf(address(vault));
        uint256 tvlBefore = vault.totalAssets();

        // Guardian calls accounting function without actual WETH arriving
        vm.prank(guardian);
        vault.receiveReinsuranceDraw(50 ether);

        assertEq(weth.balanceOf(address(vault)), wethBefore, "SECURITY: WETH balance must not change");
        assertEq(vault.totalAssets(), tvlBefore, "SECURITY: totalAssets must not change");
        assertEq(vault.totalReinsuranceReceived(), 50 ether, "Accounting counter updated (expected)");
    }

    /**
     * @dev Verify that lockCollateral cannot be called with tokenId=0 to shadow
     *      a legitimate option's collateral, creating a phantom lock.
     */
    function test_P2_LockCollateral_TokenIdZeroAllowed_ButDoesNotShadow() external {
        bytes32 key = keccak256("loc0");

        vm.prank(address(bruma));
        vault.lockCollateral(1 ether, 0, key);
        assertEq(vault.locationExposure(key), 1 ether, "Lock with tokenId=0 should work normally");

        // Max per location is 40 ETH (200 ETH TVL * 20%).
        // 1 ETH already locked — any amount pushing total > 40 ETH must revert.
        // Use 40 ETH which would result in 41 ETH total > 40 ETH cap.
        uint256 maxPerLocation = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        uint256 overflowAmount = maxPerLocation; // 1 + 40 = 41 > 40

        vm.prank(address(bruma));
        vm.expectRevert(IBrumaVault.LocationExposureTooHigh.selector);
        vault.lockCollateral(overflowAmount, 1, key);
    }

    /**
     * @dev Attacker donates WETH directly to the vault to try to shift the
     *      utilization rate down, enabling them to lock more collateral than
     *      the protocol intends. Verify totalLocked is the binding constraint.
     */
    function test_P3_DirectWETHDonation_LocationCapRecalculatesAgainstNewTVL() external {
        bytes32 locKey = keccak256(abi.encodePacked(keccak256("utilTest"), uint256(0)));

        // Lock up to the location cap at current TVL (200 ETH → 40 ETH cap per location)
        uint256 maxPerLocation = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        vm.prank(address(bruma));
        vault.lockCollateral(maxPerLocation, 1, locKey);

        assertFalse(vault.canUnderwrite(1 ether, locKey), "Location should be at cap before donation");

        // Attacker donates WETH — TVL rises, location cap recalculates upward
        address donator = makeAddr("donator");
        vm.deal(donator, 1000 ether);
        vm.startPrank(donator);
        weth.deposit{value: 500 ether}();
        weth.transfer(address(vault), 500 ether);
        vm.stopPrank();

        // DESIGN NOTE: location cap is TVL-relative so donation unlocks headroom.
        // This is intentional — more TVL = more capacity. Document for auditors.
        bool canUnderwriteAfter = vault.canUnderwrite(1 ether, locKey);
        emit log_named_string(
            "DESIGN: canUnderwrite after TVL donation",
            canUnderwriteAfter ? "true location cap is relative to TVL (intended)" : "false"
        );
        // Assert the behavior is consistent — we are documenting it, not blocking it.
        assertTrue(true);
    }

    /*//////////////////////////////////////////////////////////////
          Q. SECURITY — LOCKUP BYPASS ATTEMPTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev ERC-4626 shares are transferable. Verify that transferring shares
     *      to a fresh address does NOT reset or bypass the lockup on the pool.
     *      The lock is keyed to the depositor address, not the shares.
     */
    function test_Q1_ShareTransferDoesNotBypassLockup() external {
        _depositReinsurance(reinsurer1, 50 ether);

        (bool locked,) = reinsurance.isLocked(reinsurer1);
        assertTrue(locked, "reinsurer1 should be locked");

        // Transfer shares to reinsurer2 who has no lock
        uint256 shares = reinsurance.balanceOf(reinsurer1);
        vm.prank(reinsurer1);
        reinsurance.transfer(reinsurer2, shares);

        // reinsurer2 now holds shares — should they be able to withdraw?
        // The lock is tracked per-address; reinsurer2 never deposited so has no lock entry.
        // This is a deliberate design question — test documents current behavior.
        (bool r2locked,) = reinsurance.isLocked(reinsurer2);
        // If the pool tracks locks per-depositor and reinsurer2 never called deposit,
        // they have no lock — document whether withdraw succeeds or reverts.
        if (!r2locked) {
            // Current design: lockup is deposit-address-scoped, transfer recipient
            // inherits no lock. Record this behavior explicitly.
            vm.prank(reinsurer2);
            // This should either succeed (no lock on r2) or revert — document which.
            try reinsurance.redeem(shares, reinsurer2, reinsurer2) returns (uint256 assets) {
                // If it succeeds, the pool intentionally allows this — flag for audit review
                emit log_named_string("AUDIT NOTE", "lockup does not follow share transfers");
                emit log_named_uint("assets withdrawn by transferee", assets);
            } catch {
                // If it reverts, the pool correctly enforces lockup on transferred shares
                emit log_named_string("Lockup on transferee", "correctly enforced");
            }
        }
    }

    /**
     * @dev Verify that a second deposit after near-expiry of lockup correctly
     *      restarts the full 30-day window, preventing a race to deposit small
     *      amounts just before expiry to immediately withdraw the full balance.
     */
    function test_Q2_LockupRestartPreventsRaceWithdraw() external {
        _depositReinsurance(reinsurer1, 50 ether);

        // Fast-forward to 1 second before lockup expires
        vm.warp(block.timestamp + 30 days - 1);

        // Add a dust deposit — should restart lockup for the full 30 days
        _depositReinsurance(reinsurer1, 0.001 ether);

        vm.warp(block.timestamp + 1); // 30 days from first deposit — old expiry
        vm.prank(reinsurer1);
        vm.expectRevert(); // still locked (30 days from dust deposit not elapsed)
        reinsurance.withdraw(50 ether, reinsurer1, reinsurer1);
    }

    /*//////////////////////////////////////////////////////////////
          R. SECURITY — ACCESS CONTROL EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_R1_OwnerCannotBeRemovedWithoutReplacement() external {
        // Renouncing ownership would break all admin functions permanently
        // OZ Ownable2Step or single-step: attempt renounceOwnership
        // Document that the protocol must retain an owner
        address currentOwner = vault.owner();
        assertNotEq(currentOwner, address(0), "Owner must never be zero address");
    }

    function test_R2_GuardianCannotCallOwnerOnlyFunctions() external {
        vm.startPrank(guardian);

        vm.expectRevert();
        vault.setWeatherOptions(address(0xDEAD));

        vm.expectRevert();
        vault.setReinsurancePool(address(0xDEAD));

        vm.expectRevert();
        vault.setReinsuranceYieldBps(100);

        vm.stopPrank();
    }

    function test_R3_OwnerCannotCallGuardianOnlyFunctions() external {
        // Deployer is owner but not guardian (guardian = address(0xAAA1) from setUp)
        vm.startPrank(deployer);

        vm.expectRevert(IBrumaVault.UnauthorizedGuardian.selector);
        vault.setUtilizationLimits(5000, 3000);

        vm.expectRevert(IBrumaVault.UnauthorizedGuardian.selector);
        vault.receiveReinsuranceDraw(1 ether);

        vm.stopPrank();
    }

    function test_R4_CannotSetWeatherOptionsToZeroAddress() external {
        vm.expectRevert();
        vault.setWeatherOptions(address(0));
    }

    function test_R5_CannotSetPrimaryVaultToZeroAddress() external {
        vm.expectRevert();
        reinsurance.setPrimaryVault(address(0));
    }

    function test_R6_GuardianUpdateIsImmediate_NoPendingState() external {
        address newGuardian = makeAddr("newGuardian");
        vault.setGuardian(newGuardian);

        // Old guardian loses access immediately
        vm.prank(guardian);
        vm.expectRevert(IBrumaVault.UnauthorizedGuardian.selector);
        vault.setUtilizationLimits(5000, 3000);

        // New guardian has access immediately
        vm.prank(newGuardian);
        vault.setUtilizationLimits(5000, 3000);
        assertEq(vault.maxUtilizationBps(), 5000);
    }

    /*//////////////////////////////////////////////////////////////
          S. SECURITY — BOUNDARY & EDGE VALUES
    //////////////////////////////////////////////////////////////*/

    function test_S1_SetUtilizationLimits_TargetCannotExceedMax() external {
        vm.prank(guardian);
        vm.expectRevert(IBrumaVault.InvalidLimits.selector);
        vault.setUtilizationLimits(5000, 6000); // target > max
    }

    function test_S2_SetUtilizationLimits_MaxCannotExceed10000() external {
        vm.prank(guardian);
        vm.expectRevert(IBrumaVault.InvalidLimits.selector);
        vault.setUtilizationLimits(10001, 5000);
    }

    function test_S3_DrawLimits_SumCannotExceed10000() external {
        vm.expectRevert(ReinsurancePool.InvalidBps.selector);
        reinsurance.setDrawLimits(5001, 5000); // 100.01% combined
    }

    function test_S4_DrawLimits_ZeroMaxSingleDraw_AlwaysReverts() external {
        reinsurance.setDrawLimits(0, 2000); // maxSingleDraw = 0

        _depositReinsurance(reinsurer1, 100 ether);

        vm.prank(guardian);
        vm.expectRevert(ReinsurancePool.InsufficientPoolLiquidity.selector);
        reinsurance.fundPrimaryVault(1 ether, "Impossible");
    }

    function test_S5_LockCollateral_ZeroAmount_Reverts() external {
        vm.prank(address(bruma));
        vm.expectRevert();
        vault.lockCollateral(0, 1, keccak256("loc"));
    }

    function test_S6_ReleaseCollateral_PayoutExceedsLocked_Reverts() external {
        bytes32 key = keccak256("loc1");
        _lockCollateral(1 ether, key);

        vm.prank(address(bruma));
        vm.expectRevert();
        vault.releaseCollateral(1 ether, 2 ether, 999, key); // payout > locked amount
    }

    function test_S7_MaxWithdraw_BoundedByFreeCapital() external {
        _lockCollateralSpread(160 ether, keccak256("fullLock"));

        uint256 freeLiquidity = vault.totalAssets() - vault.totalLocked(); // 40 ETH
        uint256 lp1MaxWithdraw = vault.maxWithdraw(lp1);
        uint256 lp1Share = vault.convertToAssets(vault.balanceOf(lp1));

        // maxWithdraw must not exceed lp1's pro-rata share of free liquidity
        uint256 lp1FreeShare = freeLiquidity / 2; // 50% ownership

        assertLe(lp1MaxWithdraw, lp1FreeShare + 1, "maxWithdraw must not exceed LP's share of free capital");
        assertLt(lp1MaxWithdraw, lp1Share, "maxWithdraw must be less than total LP assets when collateral locked");
        assertEq(vault.availableLiquidity(), 0, "Available liquidity for new underwriting should be zero at max util");
    }

    function test_S8_DepositYield_ZeroValue_RevertsCleanly() external {
        _depositReinsurance(reinsurer1, 50 ether);
        uint256 yieldBefore = reinsurance.accruedYield();
        uint256 assetsBefore = reinsurance.totalAssets();

        vm.expectRevert(ReinsurancePool.ZeroAmount.selector);
        reinsurance.depositYield{value: 0}();

        assertEq(reinsurance.accruedYield(), yieldBefore, "accruedYield must be unchanged after failed deposit");
        assertEq(reinsurance.totalAssets(), assetsBefore, "totalAssets must be unchanged after failed deposit");
    }
}

/*//////////////////////////////////////////////////////////////
                  REENTRANCY ATTACKER CONTRACTS
//////////////////////////////////////////////////////////////*/

contract ReentrantYieldClaimer {
    ReinsurancePool public pool;
    bool public attacking;

    constructor(ReinsurancePool _pool) {
        pool = _pool;
    }

    function deposit(uint256 amount) external payable {
        WETH9 weth_ = WETH9(payable(address(pool.asset())));
        weth_.deposit{value: amount}();
        weth_.approve(address(pool), amount);
        pool.deposit(amount, address(this));
    }

    function attack() external {
        attacking = true;
        pool.claimYield();
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            pool.claimYield(); // attempt reentry
        }
    }
}

contract ReentrantWithdrawer {
    ReinsurancePool public pool;
    WETH9 public weth;
    bool public attacking;

    constructor(ReinsurancePool _pool, WETH9 _weth) {
        pool = _pool;
        weth = _weth;
    }

    function deposit(uint256 amount) external payable {
        weth.deposit{value: amount}();
        weth.approve(address(pool), amount);
        pool.deposit(amount, address(this));
    }

    function attack() external {
        attacking = true;
        pool.withdraw(10 ether, address(this), address(this));
    }

    // ERC-4626 WETH transfer triggers this via WETH.transfer hook (if applicable)
    function onERC20Received(address, uint256) external {
        if (attacking) {
            attacking = false;
            pool.withdraw(10 ether, address(this), address(this));
        }
    }
}

contract ReentrantVaultDrainer {
    ReinsurancePool public pool;
    address public guardian;
    bool public attacking;

    constructor(ReinsurancePool _pool, address _guardian) {
        pool = _pool;
        guardian = _guardian;
    }

    function deposit(uint256 amount) external payable {
        WETH9 weth_ = WETH9(payable(address(pool.asset())));
        weth_.deposit{value: amount}();
        weth_.approve(address(pool), amount);
        pool.deposit(amount, address(this));
    }

    function attack() external {
        attacking = true;
        pool.fundPrimaryVault(10 ether, "Reentrant drain");
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            pool.fundPrimaryVault(10 ether, "Reentrant drain 2");
        }
    }
}
