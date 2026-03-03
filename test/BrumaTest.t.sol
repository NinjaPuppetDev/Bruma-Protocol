// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {IBruma} from "../src/interface/IBruma.sol";
import {IBrumaVault} from "../src/interface/IBrumaVault.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";
import {DateTime} from "../src/DateTime.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {MockRainfallCoordinator} from "./mocks/MockRainfallCoordinator.sol";
import {MockPremiumCalculatorConsumer} from "./mocks/MockPremiumCalculatorConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrumaIntegrationTest
 * @notice Comprehensive integration tests for the Bruma weather options system.
 *
 * CHANGES vs original:
 *   - _logVaultState() updated: getMetrics() returns IBrumaVault.VaultMetrics struct,
 *     not a positional tuple. All destructuring replaced with struct field access.
 *   - All IBruma.* type references kept (types live in the interface).
 *   - `deployer` kept (not `owner`) to avoid shadowing.
 */
contract BrumaIntegrationTest is Test {
    using DateTime for uint256;

    Bruma public bruma;
    BrumaVault public vault;
    WETH9 public weth;

    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;
    MockPremiumCalculatorConsumer public premiumConsumer;

    address public deployer = address(this);
    address public liquidityProvider = address(0xA11CE);
    address public buyer = address(0xB0B);
    address public buyer2 = address(0xCAFE);

    uint256 constant NOTIONAL = 0.01 ether;
    uint256 constant STRIKE = 50;
    uint256 constant SPREAD = 50;

    function setUp() external {
        weth = new WETH9();
        console.log("WETH deployed at:", address(weth));

        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        console.log("RainfallCoordinator deployed at:", address(rainfallCoordinator));

        premiumConsumer = new MockPremiumCalculatorConsumer();
        console.log("PremiumConsumer deployed at:", address(premiumConsumer));

        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));
        console.log("PremiumCoordinator deployed at:", address(premiumCoordinator));

        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "brumaVault");
        console.log("Vault deployed at:", address(vault));

        bruma = new Bruma(
            address(rainfallCoordinator),
            address(rainfallCoordinator),
            address(premiumCoordinator),
            address(premiumConsumer),
            address(vault),
            address(weth)
        );
        console.log("Bruma deployed at:", address(bruma));

        vault.setWeatherOptions(address(bruma));
        premiumCoordinator.setWeatherOptions(address(bruma));

        vm.deal(liquidityProvider, 200 ether);
        vm.deal(buyer, 50 ether);
        vm.deal(buyer2, 50 ether);

        _fundVault(liquidityProvider, 100 ether);

        console.log("\n=== Initial State ===");
        console.log("Vault TVL:", vault.totalAssets() / 1e18, "WETH");
        console.log("Vault shares:", vault.totalSupply() / 1e18);
        console.log("LP balance:", vault.balanceOf(liquidityProvider) / 1e18, "shares");
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _fundVault(address lp, uint256 amount) internal {
        vm.startPrank(lp);
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(lp), amount, "WETH balance should match deposit");
        weth.approve(address(vault), amount);
        vault.deposit(amount, lp);
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

        console.log("\nPremium quote requested:", vm.toString(requestId));

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        console.log("Mock premium fulfilled:", premium);
        console.log("Premium in ETH:", premium / 1e18);

        uint256 protocolFee = (premium * bruma.protocolFeeBps()) / 10000;
        uint256 totalCost = premium + protocolFee;

        console.log("Protocol Fee:", protocolFee);
        console.log("Total Cost:", totalCost);

        vm.prank(_buyer);
        tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);

        console.log("Option created with tokenId:", tokenId);
    }

    function _calculateMockPremium(IBruma.CreateOptionParams memory p) internal pure returns (uint256) {
        return (p.spreadMM * p.notional) / 10;
    }

    /**
     * @dev getMetrics() returns IBrumaVault.VaultMetrics struct — access fields directly.
     *      Do NOT destructure as a positional tuple.
     */
    function _logVaultState() internal view {
        IBrumaVault.VaultMetrics memory m = vault.getMetrics();

        console.log("\n=== Vault Metrics ===");
        console.log("TVL:         ", m.tvl);
        console.log("Locked:      ", m.locked);
        console.log("Available:   ", m.available);
        console.log("Utilization: ", m.utilizationBps, "bps");
        console.log("Premiums:    ", m.premiumsEarned);
        console.log("Payouts:     ", m.totalPayouts);
        console.log("Reinsurance: ", m.reinsuranceReceived);
        if (m.netPnL >= 0) {
            console.log("Net PnL: +", uint256(m.netPnL));
        } else {
            console.log("Net PnL: -", uint256(-m.netPnL));
        }
    }

    /*//////////////////////////////////////////////////////////////
                      DATETIME LIBRARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DateTimeLibraryIntegration() external {
        uint256 startDate = 1_704_067_200; // 2024-01-01
        uint256 expiryDate = startDate + 90 days;

        string memory startStr = startDate.timestampToDateString();
        string memory expiryStr = expiryDate.timestampToDateString();

        console.log("Start date:", startStr);
        console.log("Expiry date:", expiryStr);

        assertEq(startStr, "2024-01-01", "Start date wrong");
        assertEq(expiryStr, "2024-03-31", "Expiry date wrong");
    }

    function test_DateTimeWithLeapYear() external {
        uint256 leapDay = 1_709_164_800; // 2024-02-29
        string memory dateStr = leapDay.timestampToDateString();
        console.log("Leap year date:", dateStr);
        assertEq(dateStr, "2024-02-29", "Should handle leap year correctly");
    }

    function test_SettlementDatesUseCorrectDateTime() external {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: 1_704_067_200, // 2024-01-01
            expiryDate: 1_711_929_600, // 2024-04-01
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.prank(buyer);
        uint256 tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);

        vm.warp(1_712_016_000); // 2024-04-02

        vm.prank(buyer);
        bruma.requestSettlement(tokenId);

        console.log("Settlement requested successfully with DateTime conversion");
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT FUNDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VaultFundingWithWETH() external {
        assertEq(vault.totalAssets(), 100 ether, "Vault should have 100 WETH");
        assertGt(vault.balanceOf(liquidityProvider), 0, "LP should have shares");
        assertEq(weth.balanceOf(address(vault)), 100 ether, "Vault WETH balance should be 100");

        address newLP = address(0xDEAD);
        vm.deal(newLP, 50 ether);
        _fundVault(newLP, 50 ether);

        assertEq(vault.totalAssets(), 150 ether, "Vault should now have 150 WETH");
    }

    function test_VaultCanUnderwriteAfterDeposit() external {
        bytes32 locationKey = keccak256(abi.encodePacked("10.0", "-75.0"));
        uint256 collateralNeeded = SPREAD * NOTIONAL;

        assertTrue(vault.canUnderwrite(collateralNeeded, locationKey), "Vault should be able to underwrite");
        assertGt(vault.availableLiquidity(), collateralNeeded, "Available liquidity should exceed collateral");
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM QUOTE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestPremiumQuote() external {
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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        Bruma.PendingQuote memory pq = bruma.getPendingQuote(requestId);

        assertEq(pq.buyer, buyer, "Buyer should be stored");
        assertEq(pq.strikeMM, STRIKE, "Strike should match");
        assertGt(pq.timestamp, 0, "Timestamp should be set");
    }

    function test_CannotCreateOptionWithoutQuote() external {
        bytes32 fakeRequestId = keccak256("fake");

        vm.expectRevert(IBruma.QuoteNotFulfilled.selector);
        vm.prank(buyer);
        bruma.createOptionWithQuote{value: 1 ether}(fakeRequestId);
    }

    function test_CannotCreateOptionWithExpiredQuote() external {
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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        vm.warp(block.timestamp + 2 hours);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.expectRevert(IBruma.QuoteExpired.selector);
        vm.prank(buyer);
        bruma.createOptionWithQuote{value: totalCost}(requestId);
    }

    function test_CannotUseOthersQuote() external {
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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.expectRevert(IBruma.NotYourQuote.selector);
        vm.prank(buyer2);
        bruma.createOptionWithQuote{value: totalCost}(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                          OPTION CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateOptionWithPremiumQuote() external {
        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultAssetsBefore = vault.totalAssets();

        uint256 tokenId = _createOption(buyer);

        assertEq(bruma.ownerOf(tokenId), buyer, "Buyer should own the option NFT");

        IBruma.Option memory opt = bruma.getOption(tokenId);
        assertEq(uint8(opt.state.status), uint8(IBruma.OptionStatus.Active));

        assertGt(weth.balanceOf(address(vault)), vaultWethBefore, "Vault should have received WETH premium");
        assertGt(vault.totalAssets(), vaultAssetsBefore, "Vault totalAssets should increase");
        assertGt(vault.totalLocked(), 0, "Vault should have locked collateral");

        _logVaultState();
    }

    function test_CreateMultipleOptions() external {
        uint256 tokenId1 = _createOption(buyer);
        uint256 tokenId2 = _createOption(buyer2);

        assertEq(bruma.ownerOf(tokenId1), buyer);
        assertEq(bruma.ownerOf(tokenId2), buyer2);
        assertGt(vault.totalLocked(), 0, "Vault should have locked collateral");
        assertGt(vault.utilizationRate(), 0, "Utilization should be positive");

        _logVaultState();
    }

    function test_CannotCreateWhenVaultCantUnderwrite() external {
        vm.startPrank(liquidityProvider);
        uint256 maxWithdraw = vault.maxWithdraw(liquidityProvider);
        vault.withdraw(maxWithdraw, liquidityProvider, liquidityProvider);
        vm.stopPrank();

        console.log("\nAfter draining vault:");
        console.log("Vault TVL:", vault.totalAssets());

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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.expectRevert(IBruma.VaultCannotUnderwrite.selector);
        vm.prank(buyer);
        bruma.createOptionWithQuote{value: totalCost}(requestId);
    }

    function test_RefundsExcessPayment() external {
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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 protocolFee = (premium * bruma.protocolFeeBps()) / 10000;
        uint256 totalCost = premium + protocolFee;
        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        bruma.createOptionWithQuote{value: totalCost + 1 ether}(requestId);

        assertApproxEqAbs(balBefore - buyer.balance, totalCost, 0.001 ether, "Should only charge total cost");
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleITMCallOption() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, 80); // ITM: 80 > 50

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        bruma.settle(tokenId);

        vm.prank(buyer);
        bruma.claimPayout(tokenId);

        uint256 expectedPayout = 0.3 ether; // min(80-50, 50) * 0.01

        assertEq(buyer.balance - balBefore, expectedPayout, "Buyer should receive payout in ETH");

        IBruma.Option memory opt = bruma.getOption(tokenId);
        assertEq(opt.state.actualRainfall, 80);
        assertEq(opt.state.finalPayout, expectedPayout);
        assertEq(uint8(opt.state.status), uint8(IBruma.OptionStatus.Settled));
        assertEq(vault.totalLocked(), 0, "Vault should have no locked collateral");

        _logVaultState();
    }

    function test_SettleOTMCallOption() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, 30); // OTM: 30 < 50

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        bruma.settle(tokenId);

        assertEq(buyer.balance, balBefore, "Buyer should receive no payout");

        IBruma.Option memory opt = bruma.getOption(tokenId);
        assertEq(opt.state.finalPayout, 0);
        assertEq(vault.totalLocked(), 0);

        _logVaultState();
    }

    function test_SettlePutOption() external {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Put,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 quoteRequestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(quoteRequestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.prank(buyer);
        uint256 tokenId = bruma.createOptionWithQuote{value: totalCost}(quoteRequestId);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, 20); // ITM for put: 20 < 50

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        bruma.settle(tokenId);

        vm.prank(buyer);
        bruma.claimPayout(tokenId);

        assertEq(buyer.balance - balBefore, 0.3 ether, "Put payout should be 0.3 ETH");
    }

    function test_SettleAtMaxPayout() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, 200);

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        bruma.settle(tokenId);

        vm.prank(buyer);
        bruma.claimPayout(tokenId);

        assertEq(buyer.balance - balBefore, 0.5 ether, "Max payout should be 0.5 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT ECONOMICS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VaultProfitsFromExpiredOTMOptions() external {
        uint256 vaultAssetsBefore = vault.totalAssets();

        uint256 tokenId = _createOption(buyer);

        uint256 premiumReceived = vault.totalAssets() - vaultAssetsBefore;
        console.log("Premium received:", premiumReceived);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 30); // OTM

        vm.prank(buyer);
        bruma.settle(tokenId);

        assertGt(vault.totalAssets(), vaultAssetsBefore, "Vault should profit from premium");
        assertEq(vault.totalLocked(), 0);

        _logVaultState();
    }

    function test_VaultLossFromITMOptions() external {
        uint256 vaultAssetsBefore = vault.totalAssets();

        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 200); // max payout

        vm.prank(buyer);
        bruma.settle(tokenId);

        console.log("Vault assets before:", vaultAssetsBefore);
        console.log("Vault assets after: ", vault.totalAssets());

        _logVaultState();
    }

    /*//////////////////////////////////////////////////////////////
                          NFT TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayoutGoesToCurrentHolder() external {
        uint256 tokenId = _createOption(buyer);

        address newHolder = address(0xBEEF);
        vm.prank(buyer);
        bruma.safeTransferFrom(buyer, newHolder, tokenId);
        assertEq(bruma.ownerOf(tokenId), newHolder);

        vm.warp(block.timestamp + 4 days);
        vm.prank(newHolder);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        uint256 holderBefore = newHolder.balance;
        uint256 buyerBefore = buyer.balance;

        vm.prank(newHolder);
        bruma.settle(tokenId);

        vm.prank(newHolder);
        bruma.claimPayout(tokenId);

        assertEq(newHolder.balance - holderBefore, 0.3 ether, "New holder should receive payout");
        assertEq(buyer.balance, buyerBefore, "Original buyer balance should be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASES & FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_CannotSettleBeforeExpiry() external {
        uint256 tokenId = _createOption(buyer);

        vm.expectRevert(IBruma.OptionNotExpired.selector);
        vm.prank(buyer);
        bruma.requestSettlement(tokenId);
    }

    function test_CannotSettleWithoutOracleFulfillment() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bruma.requestSettlement(tokenId);

        vm.expectRevert(IBruma.OracleNotFulfilled.selector);
        vm.prank(buyer);
        bruma.settle(tokenId);
    }

    function test_CannotDoubleSettle() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        vm.prank(buyer);
        bruma.settle(tokenId);

        vm.expectRevert(IBruma.InvalidOptionStatus.selector);
        vm.prank(buyer);
        bruma.settle(tokenId);
    }

    function test_RevertOnInsufficientPremium() external {
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

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        vm.expectRevert(IBruma.InsufficientPremium.selector);
        vm.prank(buyer);
        bruma.createOptionWithQuote{value: 0.001 ether}(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetActiveOptions() external {
        uint256 tokenId1 = _createOption(buyer);
        uint256 tokenId2 = _createOption(buyer2);

        uint256[] memory active = bruma.getActiveOptions();
        assertEq(active.length, 2);
        assertEq(active[0], tokenId1);
        assertEq(active[1], tokenId2);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = bruma.requestSettlement(tokenId1);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        vm.prank(buyer);
        bruma.settle(tokenId1);

        active = bruma.getActiveOptions();
        assertEq(active.length, 1);
        assertEq(active[0], tokenId2);
    }

    function test_SimulatePayout() external {
        uint256 tokenId = _createOption(buyer);

        assertEq(bruma.simulatePayout(tokenId, 30), 0, "OTM should be zero");
        assertEq(bruma.simulatePayout(tokenId, 50), 0, "ATM should be zero");
        assertEq(bruma.simulatePayout(tokenId, 60), 0.1 ether, "10mm ITM wrong");
        assertEq(bruma.simulatePayout(tokenId, 80), 0.3 ether, "30mm ITM wrong");
        assertEq(bruma.simulatePayout(tokenId, 200), 0.5 ether, "Max payout wrong");
    }

    function test_IsExpired() external {
        uint256 tokenId = _createOption(buyer);

        assertFalse(bruma.isExpired(tokenId), "Should not be expired initially");

        vm.warp(block.timestamp + 4 days);

        assertTrue(bruma.isExpired(tokenId), "Should be expired after expiry date");
    }

    function test_GetMetrics_ReturnsStruct() external {
        _createOption(buyer);

        IBrumaVault.VaultMetrics memory m = vault.getMetrics();

        assertGt(m.tvl, 0, "TVL should be positive");
        assertGt(m.locked, 0, "Some collateral locked");
        assertGt(m.premiumsEarned, 0, "Premium should have been earned");
        assertEq(m.netPnL, int256(m.premiumsEarned) - int256(m.totalPayouts), "netPnL invariant");
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFee() external {
        uint256 oldFee = bruma.protocolFeeBps();
        bruma.setProtocolFee(200); // 2%

        assertEq(bruma.protocolFeeBps(), 200, "Protocol fee should be updated");
        assertNotEq(bruma.protocolFeeBps(), oldFee, "Protocol fee should differ from old");
    }

    function test_CannotSetFeeTooHigh() external {
        vm.expectRevert(IBruma.FeeTooHigh.selector);
        bruma.setProtocolFee(1001);
    }

    function test_WithdrawFees() external {
        _createOption(buyer);

        uint256 collected = bruma.collectedFees();
        assertGt(collected, 0, "Should have collected fees");

        address payable feeRecipient = payable(address(0xFEE));
        uint256 recipientBefore = feeRecipient.balance;

        bruma.withdrawFees(feeRecipient);

        assertEq(bruma.collectedFees(), 0, "Collected fees should be zero after withdrawal");
        assertEq(feeRecipient.balance - recipientBefore, collected, "Recipient should receive all collected fees");
    }

    function test_SetVault() external {
        address newVault = makeAddr("0xNEWVAULT");
        bruma.setVault(newVault);
        assertEq(address(bruma.vault()), newVault, "Vault should be updated");
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL UTILS
    //////////////////////////////////////////////////////////////*/

    function _settleAndClaim(uint256 tokenId, uint256 rainfall) internal {
        vm.warp(block.timestamp + 4 days);

        address nftOwner = bruma.ownerOf(tokenId);

        vm.prank(nftOwner);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, rainfall);

        vm.prank(nftOwner);
        bruma.settle(tokenId);

        vm.prank(nftOwner);
        bruma.claimPayout(tokenId);
    }
}
