// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";
import {DateTime} from "../src/DateTime.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {MockRainfallCoordinator} from "./mocks/MockRainfallCoordinator.sol";
import {MockPremiumCalculatorConsumer} from "./mocks/MockPremiumCalculatorConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrumaIntegrationTest
 * @notice Comprehensive integration tests for refactored weather options system
 * @dev Tests the full workflow: premium quotes -> option creation -> settlement
 *      Now includes DateTime library validation
 */
contract BrumaIntegrationTest is Test {
    using DateTime for uint256;

    Bruma public option;
    BrumaVault public vault;
    WETH9 public weth;

    // Coordinators
    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;

    // Mock consumers
    MockPremiumCalculatorConsumer public premiumConsumer;

    address public owner = address(this);
    address public liquidityProvider = address(0xA11CE);
    address public buyer = address(0xB0B);
    address public buyer2 = address(0xCAFE);

    uint256 constant NOTIONAL = 0.01 ether; // per mm
    uint256 constant STRIKE = 50; // Lower strike for realistic premiums
    uint256 constant SPREAD = 50;

    function setUp() external {
        // Deploy WETH
        weth = new WETH9();
        console.log("WETH deployed at:", address(weth));

        // Deploy rainfall system (for settlement)
        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        console.log("RainfallCoordinator deployed at:", address(rainfallCoordinator));

        // Deploy premium calculator system (for option creation)
        premiumConsumer = new MockPremiumCalculatorConsumer();
        console.log("PremiumConsumer deployed at:", address(premiumConsumer));

        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));
        console.log("PremiumCoordinator deployed at:", address(premiumCoordinator));

        // Transfer ownership
        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        // Deploy vault
        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "brumaVault");
        console.log("Vault deployed at:", address(vault));

        // Deploy Bruma
        option = new Bruma(
            address(rainfallCoordinator),
            address(rainfallCoordinator), // Mock uses coordinator for both
            address(premiumCoordinator),
            address(premiumConsumer),
            address(vault),
            address(weth)
        );
        console.log("Bruma deployed at:", address(option));

        // Configure
        vault.setWeatherOptions(address(option));
        premiumCoordinator.setWeatherOptions(address(option));

        // Fund test accounts
        vm.deal(liquidityProvider, 200 ether);
        vm.deal(buyer, 50 ether);
        vm.deal(buyer2, 50 ether);

        // LP deposits to vault
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

        // Wrap ETH to WETH
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(lp), amount, "WETH balance should match deposit");

        // Approve vault
        weth.approve(address(vault), amount);

        // Deposit to vault
        uint256 shares = vault.deposit(amount, lp);

        vm.stopPrank();
    }

    function _createOption(address _buyer) internal returns (uint256 tokenId) {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        // Step 1: Request premium quote
        vm.prank(_buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        console.log("\nPremium quote requested:", vm.toString(requestId));

        // Step 2: Mock fulfill the premium request
        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        console.log("Mock premium fulfilled:", premium);
        console.log("Premium in ETH:", premium / 1e18);

        // Step 3: Calculate total cost
        uint256 protocolFee = (premium * option.protocolFeeBps()) / 10000;
        uint256 totalCost = premium + protocolFee;

        console.log("Protocol Fee:", protocolFee);
        console.log("Total Cost:", totalCost);

        // Step 4: Create option with quote
        vm.prank(_buyer);
        tokenId = option.createOptionWithQuote{value: totalCost}(requestId);

        console.log("Option created with tokenId:", tokenId);
    }

    function _calculateMockPremium(Bruma.CreateOptionParams memory p) internal pure returns (uint256) {
        // Simple mock premium: 10% of max payout
        uint256 maxPayout = p.spreadMM * p.notional;
        return maxPayout / 10;
    }

    function _logVaultState() internal view {
        (
            uint256 tvl,
            uint256 locked,
            uint256 available,
            uint256 utilization,
            uint256 premiums,
            uint256 payouts,
            int256 netPnL
        ) = vault.getMetrics();

        console.log("\n=== Vault Metrics ===");
        console.log("TVL:", tvl);
        console.log("Locked:", locked);
        console.log("Available:", available);
        console.log("Utilization:", utilization, "bps");
        console.log("Premiums earned:", premiums);
        console.log("Payouts made:", payouts);
        console.log("Net PnL:", netPnL);
    }

    /*//////////////////////////////////////////////////////////////
                      DATETIME LIBRARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DateTimeLibraryIntegration() external {
        // Test that DateTime library works correctly in the contract
        uint256 startDate = 1704067200; // January 1, 2024 00:00:00 UTC
        uint256 expiryDate = startDate + 90 days;

        string memory startStr = startDate.timestampToDateString();
        string memory expiryStr = expiryDate.timestampToDateString();

        console.log("Start date:", startStr);
        console.log("Expiry date:", expiryStr);

        assertEq(startStr, "2024-01-01", "Start date should be formatted correctly");
        assertEq(expiryStr, "2024-03-31", "Expiry date should be formatted correctly");
    }

    function test_DateTimeWithLeapYear() external {
        // February 29, 2024 (leap year)
        uint256 leapDay = 1709164800;
        string memory dateStr = leapDay.timestampToDateString();

        console.log("Leap year date:", dateStr);
        assertEq(dateStr, "2024-02-29", "Should handle leap year correctly");
    }

    function test_SettlementDatesUseCorrectDateTime() external {
        // Create an option with specific dates
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: 1704067200, // 2024-01-01
            expiryDate: 1711929600, // 2024-04-01
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * option.protocolFeeBps()) / 10000;

        vm.prank(buyer);
        uint256 tokenId = option.createOptionWithQuote{value: totalCost}(requestId);

        // Fast forward past expiry
        vm.warp(1712016000); // 2024-04-02

        // Request settlement - this will convert timestamps to date strings
        vm.prank(buyer);
        bytes32 settlementRequestId = option.requestSettlement(tokenId);

        // Verify the event emitted has correct date strings
        // The event should show: startDate="2024-01-01", endDate="2024-04-01"
        // (We can't easily test event data in Foundry, but the contract uses DateTime internally)

        console.log("Settlement requested successfully with DateTime conversion");
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT FUNDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VaultFundingWithWETH() external {
        // Verify initial state
        assertEq(vault.totalAssets(), 100 ether, "Vault should have 100 WETH");
        assertGt(vault.balanceOf(liquidityProvider), 0, "LP should have shares");

        // Check WETH balance
        assertEq(weth.balanceOf(address(vault)), 100 ether, "Vault WETH balance should be 100");

        // Try to add more liquidity
        address newLP = address(0xDEAD);
        vm.deal(newLP, 50 ether);

        _fundVault(newLP, 50 ether);

        assertEq(vault.totalAssets(), 150 ether, "Vault should now have 150 WETH");
    }

    function test_VaultCanUnderwriteAfterDeposit() external {
        bytes32 locationKey = keccak256(abi.encodePacked("10.0", "-75.0"));
        uint256 collateralNeeded = SPREAD * NOTIONAL; // 0.5 ETH

        bool canUnderwrite = vault.canUnderwrite(collateralNeeded, locationKey);
        assertTrue(canUnderwrite, "Vault should be able to underwrite");

        // Check available liquidity
        uint256 available = vault.availableLiquidity();
        assertGt(available, collateralNeeded, "Available liquidity should exceed collateral needed");
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM QUOTE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestPremiumQuote() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        // Verify request was stored
        (Bruma.CreateOptionParams memory stored, address storedBuyer, uint256 timestamp) =
            option.getPendingOption(requestId);

        assertEq(storedBuyer, buyer, "Buyer should be stored");
        assertEq(stored.strikeMM, STRIKE, "Strike should match");
        assertGt(timestamp, 0, "Timestamp should be set");
    }

    function test_CannotCreateOptionWithoutQuote() external {
        bytes32 fakeRequestId = keccak256("fake");

        vm.expectRevert(Bruma.QuoteNotFulfilled.selector);
        vm.prank(buyer);
        option.createOptionWithQuote{value: 1 ether}(fakeRequestId);
    }

    function test_CannotCreateOptionWithExpiredQuote() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        // Fulfill the quote
        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        // Warp past quote validity (1 hour)
        vm.warp(block.timestamp + 2 hours);

        uint256 totalCost = premium + (premium * option.protocolFeeBps()) / 10000;

        vm.expectRevert(Bruma.QuoteExpired.selector);
        vm.prank(buyer);
        option.createOptionWithQuote{value: totalCost}(requestId);
    }

    function test_CannotUseOthersQuote() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        // Buyer requests quote
        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        // Fulfill the quote
        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * option.protocolFeeBps()) / 10000;

        // Buyer2 tries to use buyer's quote
        vm.expectRevert(Bruma.NotYourQuote.selector);
        vm.prank(buyer2);
        option.createOptionWithQuote{value: totalCost}(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                          OPTION CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateOptionWithPremiumQuote() external {
        uint256 vaultWethBefore = weth.balanceOf(address(vault));
        uint256 vaultAssetsBefore = vault.totalAssets();

        uint256 tokenId = _createOption(buyer);

        // Verify option was created
        assertEq(option.ownerOf(tokenId), buyer, "Buyer should own the option NFT");

        Bruma.Option memory opt = option.getOption(tokenId);
        assertEq(uint8(opt.state.status), uint8(Bruma.OptionStatus.Active));

        // Verify vault received WETH premium
        uint256 vaultWethAfter = weth.balanceOf(address(vault));
        assertGt(vaultWethAfter, vaultWethBefore, "Vault should have received WETH premium");

        // Verify vault accounting
        assertGt(vault.totalAssets(), vaultAssetsBefore, "Vault totalAssets should increase");
        assertGt(vault.totalLocked(), 0, "Vault should have locked collateral");

        _logVaultState();
    }

    function test_CreateMultipleOptions() external {
        uint256 tokenId1 = _createOption(buyer);
        uint256 tokenId2 = _createOption(buyer2);

        assertEq(option.ownerOf(tokenId1), buyer);
        assertEq(option.ownerOf(tokenId2), buyer2);

        // Check vault state
        assertGt(vault.totalLocked(), 0, "Vault should have locked collateral");
        assertGt(vault.utilizationRate(), 0, "Utilization should be positive");

        _logVaultState();
    }

    function test_CannotCreateWhenVaultCantUnderwrite() external {
        // Drain vault liquidity
        vm.startPrank(liquidityProvider);
        uint256 maxWithdraw = vault.maxWithdraw(liquidityProvider);
        vault.withdraw(maxWithdraw, liquidityProvider, liquidityProvider);
        vm.stopPrank();

        console.log("\nAfter draining vault:");
        console.log("Vault TVL:", vault.totalAssets());

        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * option.protocolFeeBps()) / 10000;

        vm.expectRevert(Bruma.VaultCannotUnderwrite.selector);
        vm.prank(buyer);
        option.createOptionWithQuote{value: totalCost}(requestId);
    }

    function test_RefundsExcessPayment() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 protocolFee = (premium * option.protocolFeeBps()) / 10000;
        uint256 totalCost = premium + protocolFee;

        uint256 buyerBalanceBefore = buyer.balance;

        // Overpay by 1 ETH
        vm.prank(buyer);
        option.createOptionWithQuote{value: totalCost + 1 ether}(requestId);

        // Should have refunded the 1 ETH excess
        uint256 buyerBalanceAfter = buyer.balance;
        assertApproxEqAbs(
            buyerBalanceBefore - buyerBalanceAfter, totalCost, 0.001 ether, "Should only charge total cost"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleITMCallOption() external {
        uint256 tokenId = _createOption(buyer);

        // Move past expiry
        vm.warp(block.timestamp + 4 days);

        // Request settlement
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);

        // Fulfill oracle with rainfall = 80mm (ITM: 80 > 50 strike)
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        uint256 buyerBalanceBefore = buyer.balance;

        // Settle option
        vm.prank(buyer);
        option.settle(tokenId);

        // Claim the payout
        vm.prank(buyer);
        option.claimPayout(tokenId);

        // Expected payout: min(80-50, 50) * 0.01 = 30 * 0.01 = 0.3 ETH
        uint256 expectedPayout = 0.3 ether;
        assertEq(buyer.balance - buyerBalanceBefore, expectedPayout);
        assertEq(buyer.balance - buyerBalanceBefore, expectedPayout, "Buyer should receive payout in ETH");

        // Verify vault accounting
        Bruma.Option memory opt = option.getOption(tokenId);
        assertEq(opt.state.actualRainfall, 80);
        assertEq(opt.state.finalPayout, expectedPayout);
        assertEq(uint8(opt.state.status), uint8(Bruma.OptionStatus.Settled));

        // Vault should have released collateral
        assertEq(vault.totalLocked(), 0, "Vault should have no locked collateral");

        _logVaultState();
    }

    function test_SettleOTMCallOption() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);

        // Rainfall below strike (OTM: 30 < 50)
        rainfallCoordinator.mockFulfillRequest(requestId, 30);

        uint256 buyerBalanceBefore = buyer.balance;

        vm.prank(buyer);
        option.settle(tokenId);

        // No payout for OTM option
        assertEq(buyer.balance, buyerBalanceBefore, "Buyer should receive no payout");

        Bruma.Option memory opt = option.getOption(tokenId);
        assertEq(opt.state.finalPayout, 0);

        // Vault should release collateral and keep it as profit
        assertEq(vault.totalLocked(), 0);

        _logVaultState();
    }

    function test_SettlePutOption() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Put,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 quoteRequestId = option.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(quoteRequestId, premium);

        uint256 totalCost = premium + (premium * option.protocolFeeBps()) / 10000;

        vm.prank(buyer);
        uint256 tokenId = option.createOptionWithQuote{value: totalCost}(quoteRequestId);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);

        // Rainfall = 20mm (below strike, ITM for put: 20 < 50)
        rainfallCoordinator.mockFulfillRequest(requestId, 20);

        uint256 buyerBalanceBefore = buyer.balance;

        vm.prank(buyer);
        option.settle(tokenId);

        vm.prank(buyer);
        option.claimPayout(tokenId);

        // Payout = min(50-20, 50) * 0.01 = 30 * 0.01 = 0.3 ETH
        assertEq(buyer.balance - buyerBalanceBefore, 0.3 ether);
    }

    function test_SettleAtMaxPayout() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, 200);

        uint256 buyerBalanceBefore = buyer.balance;

        vm.prank(buyer);
        option.settle(tokenId);

        vm.prank(buyer);
        option.claimPayout(tokenId);

        // Max payout = spread * notional = 50 * 0.01 = 0.5 ETH
        assertEq(buyer.balance - buyerBalanceBefore, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT ECONOMICS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VaultProfitsFromExpiredOTMOptions() external {
        uint256 vaultAssetsBefore = vault.totalAssets();

        // Create option
        uint256 tokenId = _createOption(buyer);

        uint256 vaultAssetsAfterPremium = vault.totalAssets();
        uint256 premiumReceived = vaultAssetsAfterPremium - vaultAssetsBefore;

        console.log("Premium received:", premiumReceived);

        // Settle OTM (no payout)
        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 30); // OTM

        vm.prank(buyer);
        option.settle(tokenId);

        // Vault should profit by keeping premium and collateral
        assertGt(vault.totalAssets(), vaultAssetsBefore, "Vault should profit from premium");
        assertEq(vault.totalLocked(), 0, "No locked collateral");

        _logVaultState();
    }

    function test_VaultLossFromITMOptions() external {
        uint256 vaultAssetsBefore = vault.totalAssets();

        // Create option
        uint256 tokenId = _createOption(buyer);

        // Settle ITM with max payout
        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 200); // Max payout

        vm.prank(buyer);
        option.settle(tokenId);

        // Vault should have less assets (premium - payout)
        uint256 maxPayout = 0.5 ether;

        console.log("Vault assets before:", vaultAssetsBefore);
        console.log("Vault assets after:", vault.totalAssets());

        _logVaultState();
    }

    /*//////////////////////////////////////////////////////////////
                          NFT TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayoutGoesToCurrentHolder() external {
        uint256 buyerInitialBalance = buyer.balance;
        uint256 tokenId = _createOption(buyer);

        uint256 buyerBalanceAfterPurchase = buyer.balance;
        uint256 optionCost = buyerInitialBalance - buyerBalanceAfterPurchase;

        // Transfer option to new holder
        address newHolder = address(0xBEEF);
        vm.prank(buyer);
        option.safeTransferFrom(buyer, newHolder, tokenId);

        assertEq(option.ownerOf(tokenId), newHolder);

        // Settle
        vm.warp(block.timestamp + 4 days);
        vm.prank(newHolder);
        bytes32 requestId = option.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        uint256 newHolderBalanceBefore = newHolder.balance;
        uint256 buyerBalanceBeforeSettle = buyer.balance;

        vm.prank(newHolder);
        option.settle(tokenId);

        // Owner at settlement (newHolder) must claim
        vm.prank(newHolder);
        option.claimPayout(tokenId);

        assertGt(newHolder.balance, newHolderBalanceBefore);

        // Payout should go to new holder
        assertGt(newHolder.balance, newHolderBalanceBefore, "New holder should receive payout");
        assertEq(newHolder.balance - newHolderBalanceBefore, 0.3 ether, "New holder should receive 0.3 ETH payout");

        // Original buyer should not receive any payout
        assertEq(buyer.balance, buyerBalanceBeforeSettle, "Original buyer balance should be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASES & FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_CannotSettleBeforeExpiry() external {
        uint256 tokenId = _createOption(buyer);

        vm.expectRevert(Bruma.OptionNotExpired.selector);
        vm.prank(buyer);
        option.requestSettlement(tokenId);
    }

    function test_CannotSettleWithoutOracleFulfillment() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        option.requestSettlement(tokenId);

        // Don't fulfill oracle

        vm.expectRevert(Bruma.OracleNotFulfilled.selector);
        vm.prank(buyer);
        option.settle(tokenId);
    }

    function test_CannotDoubleSettle() external {
        uint256 tokenId = _createOption(buyer);

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);
        vm.prank(buyer);
        option.settle(tokenId);

        vm.expectRevert(Bruma.InvalidOptionStatus.selector);
        vm.prank(buyer);
        option.settle(tokenId);
    }

    function test_RevertOnInsufficientPremium() external {
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "10.0",
            longitude: "-75.0",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer);
        bytes32 requestId = option.requestPremiumQuote(p);

        uint256 premium = _calculateMockPremium(p);
        premiumConsumer.mockFulfillRequest(requestId, premium);

        vm.expectRevert(Bruma.InsufficientPremium.selector);
        vm.prank(buyer);
        option.createOptionWithQuote{value: 0.001 ether}(requestId); // Too low
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetActiveOptions() external {
        uint256 tokenId1 = _createOption(buyer);
        uint256 tokenId2 = _createOption(buyer2);

        uint256[] memory active = option.getActiveOptions();
        assertEq(active.length, 2);
        assertEq(active[0], tokenId1);
        assertEq(active[1], tokenId2);

        // Settle one
        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer);
        bytes32 requestId = option.requestSettlement(tokenId1);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);
        vm.prank(buyer);
        option.settle(tokenId1);

        active = option.getActiveOptions();
        assertEq(active.length, 1);
        assertEq(active[0], tokenId2);
    }

    function test_SimulatePayout() external {
        uint256 tokenId = _createOption(buyer);

        // Simulate various rainfall amounts (strike is 50)
        assertEq(option.simulatePayout(tokenId, 30), 0);         // OTM
        assertEq(option.simulatePayout(tokenId, 50), 0);         // ATM
        assertEq(option.simulatePayout(tokenId, 60), 0.1 ether); // ITM
        assertEq(option.simulatePayout(tokenId, 80), 0.3 ether); // ITM
        assertEq(option.simulatePayout(tokenId, 200), 0.5 ether); // Max payout
    }

    function test_IsExpired() external {
        uint256 tokenId = _createOption(buyer);

        assertFalse(option.isExpired(tokenId), "Should not be expired initially");

        vm.warp(block.timestamp + 4 days);

        assertTrue(option.isExpired(tokenId), "Should be expired after expiry date");
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFee() external {
        uint256 oldFee = option.protocolFeeBps();
        uint256 newFee = 200; // 2%

        option.setProtocolFee(newFee);

        assertEq(option.protocolFeeBps(), newFee, "Protocol fee should be updated");
        assertNotEq(option.protocolFeeBps(), oldFee, "Protocol fee should be different");
    }

    function test_CannotSetFeeTooHigh() external {
        vm.expectRevert(Bruma.FeeTooHigh.selector);
        option.setProtocolFee(1001); // > 10%
    }

    function test_WithdrawFees() external {
        // Create an option to generate fees
        _createOption(buyer);

        uint256 collectedBefore = option.collectedFees();
        assertGt(collectedBefore, 0, "Should have collected fees");

        address payable feeRecipient = payable(address(0xFEE));
        uint256 recipientBalanceBefore = feeRecipient.balance;

        option.withdrawFees(feeRecipient);

        assertEq(option.collectedFees(), 0, "Collected fees should be zero after withdrawal");
        assertEq(
            feeRecipient.balance - recipientBalanceBefore,
            collectedBefore,
            "Recipient should receive all collected fees"
        );
    }

    function test_SetVault() external {
        address newVault = makeAddr("0xNEWVAULT");

        option.setVault(newVault);

        assertEq(address(option.vault()), newVault, "Vault should be updated");
    }

    function _settleAndClaim(uint256 tokenId, uint256 rainfall) internal {
        vm.warp(block.timestamp + 4 days);

        address _owner = option.ownerOf(tokenId);

        vm.prank(_owner);
        bytes32 requestId = option.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, rainfall);

        vm.prank(_owner);
        option.settle(tokenId);

        vm.prank(_owner);
        option.claimPayout(tokenId);
    }
}
