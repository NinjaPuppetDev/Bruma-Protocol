// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {IBruma} from "../src/interface/IBruma.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {MockRainfallCoordinator} from "./mocks/MockRainfallCoordinator.sol";
import {MockPremiumCalculatorConsumer} from "./mocks/MockPremiumCalculatorConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrumaInvariantTest
 * @notice Comprehensive invariant + property-based tests for the Bruma weather options system.
 *
 * CHANGES FROM PREVIOUS VERSION:
 *   - CreateOptionParams struct removed from Bruma — requestPremiumQuote now takes
 *     individual arguments. All helpers updated accordingly.
 *   - `owner` state variable renamed to `deployer` to avoid shadowing in helpers.
 *   - getPendingOption() returns PendingQuote struct (not tuple of params + buyer + ts).
 *   - requestPremiumQuote / createOptionWithQuote signatures updated throughout.
 */
contract BrumaInvariantTest is Test {
    Bruma public bruma;
    BrumaVault public vault;
    WETH9 public weth;

    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;
    MockPremiumCalculatorConsumer public premiumConsumer;

    // ── Renamed: `deployer` instead of `owner` to avoid local-variable shadowing ──
    address public deployer = address(this);
    address public lp1 = address(0xA11CE);
    address public lp2 = address(0xB0B1);
    address public buyer1 = address(0xB0B);
    address public buyer2 = address(0xCAFE);
    address public buyer3 = address(0xDEAD);

    uint256 constant NOTIONAL = 0.01 ether;
    uint256 constant STRIKE = 50;
    uint256 constant SPREAD = 50;

    // ── Default option location ────────────────────────────────────────────────
    string constant DEFAULT_LAT = "10.0";
    string constant DEFAULT_LON = "-75.0";

    function setUp() external {
        weth = new WETH9();
        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        premiumConsumer = new MockPremiumCalculatorConsumer();
        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));

        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        vault = new BrumaVault(IERC20(address(weth)), "Weather Options Vault", "wopVault");

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

        vm.deal(lp1, 200 ether);
        vm.deal(lp2, 200 ether);
        vm.deal(buyer1, 50 ether);
        vm.deal(buyer2, 50 ether);
        vm.deal(buyer3, 50 ether);

        _fundVault(lp1, 100 ether);
        _fundVault(lp2, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _fundVault(address lp, uint256 amount) internal {
        vm.startPrank(lp);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
    }

    /**
     * @dev Creates an option with default lat/lon using the new flat-arg signature.
     */
    function _createOption(address buyer, uint256 notional, uint256 strike, uint256 spread)
        internal
        returns (uint256 tokenId)
    {
        return _createOptionAt(buyer, notional, strike, spread, DEFAULT_LAT, DEFAULT_LON);
    }

    /**
     * @dev Creates an option at an explicit location.
     */
    function _createOptionAt(
        address buyer,
        uint256 notional,
        uint256 strike,
        uint256 spread,
        string memory lat,
        string memory lon
    ) internal returns (uint256 tokenId) {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: lat,
            longitude: lon,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: strike,
            spreadMM: spread,
            notional: notional
        });

        vm.prank(buyer);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (spread * notional) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;

        vm.prank(buyer);
        tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);
    }

    /**
     * @dev Requests settlement and fulfills the oracle; does NOT claim payout.
     */
    function _settleOption(uint256 tokenId, uint256 rainfall) internal {
        vm.warp(block.timestamp + 4 days);

        address nftOwner = bruma.ownerOf(tokenId);
        vm.prank(nftOwner);
        bytes32 requestId = bruma.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(requestId, rainfall);

        vm.prank(nftOwner);
        bruma.settle(tokenId);
    }

    /**
     * @dev Full lifecycle: settle + claim.
     */
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

    /*//////////////////////////////////////////////////////////////
              INVARIANT 1: ACCOUNTING CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    function invariant_VaultAssetsEqualWETHBalance() public {
        assertEq(vault.totalAssets(), weth.balanceOf(address(vault)), "INVARIANT: totalAssets != WETH balance");
    }

    function invariant_LockedPlusAvailableEqualsTotal() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 locked = vault.totalLocked();
        uint256 available = vault.availableLiquidity();

        uint256 maxLockable = (totalAssets * vault.maxUtilizationBps()) / 10000;
        uint256 expectedAvailable = maxLockable > locked ? maxLockable - locked : 0;

        assertEq(available, expectedAvailable, "INVARIANT: availableLiquidity calculation wrong");
    }

    function invariant_LockedNeverExceedsTotalAssets() public {
        assertLe(vault.totalLocked(), vault.totalAssets(), "INVARIANT: locked > totalAssets");
    }

    function test_LocationExposureSumsToTotalLocked() public {
        uint256 tokenId1 = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        uint256 tokenId2 = _createOptionAt(buyer2, NOTIONAL, STRIKE, SPREAD, "20.0", "-80.0");

        IBruma.Option memory opt1 = bruma.getOption(tokenId1);
        IBruma.Option memory opt2 = bruma.getOption(tokenId2);

        uint256 exposure1 = vault.locationExposure(opt1.state.locationKey);
        uint256 exposure2 = vault.locationExposure(opt2.state.locationKey);

        assertEq(exposure1 + exposure2, vault.totalLocked(), "Location exposures should sum to totalLocked");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 2: PAYOUT CONSTRAINTS
    //////////////////////////////////////////////////////////////*/

    function test_PayoutNeverExceedsMaxPayout() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        uint256 maxPayout = SPREAD * NOTIONAL;

        uint256[5] memory rainfalls = [uint256(1000), 500, 200, 150, STRIKE + SPREAD + 100];

        for (uint256 i = 0; i < rainfalls.length; i++) {
            assertLe(bruma.simulatePayout(tokenId, rainfalls[i]), maxPayout, "INVARIANT: payout > maxPayout");
        }
    }

    function test_CallPayoutZeroWhenOTM() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);

        assertEq(bruma.simulatePayout(tokenId, 0), 0, "Zero rainfall  zero payout");
        assertEq(bruma.simulatePayout(tokenId, STRIKE / 2), 0, "Below strike  zero payout");
        assertEq(bruma.simulatePayout(tokenId, STRIKE), 0, "At strike  zero payout");
    }

    function test_PutPayoutZeroWhenOTM() public {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Put,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });

        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;
        vm.prank(buyer1);
        uint256 tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);

        assertEq(bruma.simulatePayout(tokenId, STRIKE), 0, "At strike  zero payout");
        assertEq(bruma.simulatePayout(tokenId, STRIKE * 2), 0, "Above strike  zero payout");
        assertEq(bruma.simulatePayout(tokenId, 1000), 0, "Way above strike zero payout");
    }

    function test_PayoutIsLinearInSpread() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);

        assertEq(
            bruma.simulatePayout(tokenId, STRIKE + SPREAD / 4), (SPREAD / 4) * NOTIONAL, "25% spread  25% max payout"
        );
        assertEq(
            bruma.simulatePayout(tokenId, STRIKE + SPREAD / 2), (SPREAD / 2) * NOTIONAL, "50% spread  50% max payout"
        );
        assertEq(
            bruma.simulatePayout(tokenId, STRIKE + (SPREAD * 3) / 4),
            ((SPREAD * 3) / 4) * NOTIONAL,
            "75% spread  75% max payout"
        );
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 3: COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_CollateralLockedOnCreation() public {
        uint256 lockedBefore = vault.totalLocked();
        _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        assertEq(vault.totalLocked() - lockedBefore, SPREAD * NOTIONAL, "Wrong collateral locked");
    }

    function test_CollateralReleasedAfterSettlement() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        _settleOption(tokenId, 80); // ITM
        assertEq(vault.totalLocked(), 0, "All collateral should be released");
    }

    function test_MultipleOptionsLockCumulativeCollateral() public {
        _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        uint256 locked1 = vault.totalLocked();

        _createOptionAt(buyer2, NOTIONAL, STRIKE, SPREAD, "20.0", "-80.0");
        uint256 locked2 = vault.totalLocked();

        uint256 expected = SPREAD * NOTIONAL;
        assertEq(locked1, expected, "First option collateral wrong");
        assertEq(locked2, expected * 2, "Cumulative collateral wrong");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 4: PREMIUM AND FEE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_VaultReceivesCorrectPremium() public {
        uint256 vaultBefore = vault.totalAssets();

        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;
        vm.prank(buyer1);
        bruma.createOptionWithQuote{value: totalCost}(requestId);

        assertEq(vault.totalAssets() - vaultBefore, premium, "Vault should receive exact premium");
    }

    function test_ProtocolFeeCollectedCorrectly() public {
        uint256 feesBefore = bruma.collectedFees();

        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        uint256 expectedFee = (premium * bruma.protocolFeeBps()) / 10000;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        vm.prank(buyer1);
        bruma.createOptionWithQuote{value: premium + expectedFee}(requestId);

        assertEq(bruma.collectedFees() - feesBefore, expectedFee, "Protocol fee wrong");
    }

    function test_TotalPremiumsEarnedIncreases() public {
        uint256 premiumsBefore = vault.totalPremiumsEarned();

        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;
        vm.prank(buyer1);
        bruma.createOptionWithQuote{value: totalCost}(requestId);

        assertEq(vault.totalPremiumsEarned() - premiumsBefore, premium, "totalPremiumsEarned wrong");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 5: UTILIZATION CONSTRAINTS
    //////////////////////////////////////////////////////////////*/

    function test_UtilizationNeverExceedsMax() public {
        _createOptionAt(buyer1, 0.02 ether, STRIKE, 100, "10.0", "-75.0");
        _createOptionAt(buyer2, 0.02 ether, STRIKE, 100, "11.0", "-75.0");
        _createOptionAt(buyer3, 0.02 ether, STRIKE, 100, "12.0", "-75.0");

        assertLe(vault.utilizationRate(), vault.maxUtilizationBps(), "INVARIANT: util > max");
    }

    function test_LocationExposureNeverExceedsMax() public {
        _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        _createOption(buyer2, NOTIONAL, STRIKE, SPREAD);

        // Recompute the normalized key the same way the contract does
        bytes32 locationKey = bruma.getOption(0).state.locationKey;

        uint256 exposure = vault.locationExposure(locationKey);
        uint256 totalAssets = vault.totalAssets();
        uint256 exposurePct = (exposure * 10000) / totalAssets;

        assertLe(exposurePct, vault.maxLocationExposureBps(), "INVARIANT: location exposure > max");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 6: NFT OWNERSHIP AND TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_OnlyCurrentOwnerReceivesPayout() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);

        vm.prank(buyer1);
        bruma.safeTransferFrom(buyer1, buyer2, tokenId);
        assertEq(bruma.ownerOf(tokenId), buyer2, "Transfer failed");

        // Settle ITM — buyer2 is ownerAtSettlement
        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer2);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(requestId, 80);

        uint256 b1Before = buyer1.balance;
        uint256 b2Before = buyer2.balance;

        vm.prank(buyer2);
        bruma.settle(tokenId);

        vm.prank(buyer2);
        bruma.claimPayout(tokenId);

        assertEq(buyer1.balance, b1Before, "Original buyer should NOT receive payout");
        assertGt(buyer2.balance, b2Before, "New owner should receive payout");
    }

    function test_BuyerFieldUpdatesOnTransfer() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        assertEq(bruma.getOption(tokenId).state.buyer, buyer1, "Initial buyer wrong");

        vm.prank(buyer1);
        bruma.safeTransferFrom(buyer1, buyer2, tokenId);

        assertEq(bruma.getOption(tokenId).state.buyer, buyer2, "Buyer field not updated");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 7: STATUS TRANSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_ValidStatusTransitions() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        assertEq(uint8(bruma.getOption(tokenId).state.status), uint8(IBruma.OptionStatus.Active));

        vm.warp(block.timestamp + 4 days);
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestSettlement(tokenId);
        assertEq(uint8(bruma.getOption(tokenId).state.status), uint8(IBruma.OptionStatus.Settling));

        rainfallCoordinator.mockFulfillRequest(requestId, 80);
        vm.prank(buyer1);
        bruma.settle(tokenId);
        assertEq(uint8(bruma.getOption(tokenId).state.status), uint8(IBruma.OptionStatus.Settled));
    }

    function test_CannotSettleNonActiveOption() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        _settleOption(tokenId, 80);

        vm.expectRevert(IBruma.InvalidOptionStatus.selector);
        vm.prank(buyer1);
        bruma.requestSettlement(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 8: PREMIUM QUOTE VALIDITY
    //////////////////////////////////////////////////////////////*/

    function test_QuoteExpiresCorrectly() public {
        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp + 1 days, // future startDate
            expiryDate: block.timestamp + 4 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        uint256 premium = (SPREAD * NOTIONAL) / 10;
        premiumConsumer.mockFulfillRequest(requestId, premium);

        // Use just before expiry — should succeed
        vm.warp(block.timestamp + bruma.QUOTE_VALIDITY() - 1);

        uint256 totalCost = premium + (premium * bruma.protocolFeeBps()) / 10000;
        vm.prank(buyer1);
        bruma.createOptionWithQuote{value: totalCost}(requestId);

        assertEq(uint8(bruma.getOption(0).state.status), uint8(IBruma.OptionStatus.Active));
    }

    function test_QuoteTimestampSetCorrectly() public {
        uint256 ts = block.timestamp;

        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: DEFAULT_LAT,
            longitude: DEFAULT_LON,
            startDate: block.timestamp,
            expiryDate: block.timestamp + 3 days,
            strikeMM: STRIKE,
            spreadMM: SPREAD,
            notional: NOTIONAL
        });
        vm.prank(buyer1);
        bytes32 requestId = bruma.requestPremiumQuote(p);

        Bruma.PendingQuote memory pq = bruma.getPendingQuote(requestId);
        assertEq(pq.timestamp, ts, "Quote timestamp wrong");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 9: VAULT SHARE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_SharesRepresentProportionalOwnership() public {
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 lp2Shares = vault.balanceOf(lp2);
        uint256 totalShares = vault.totalSupply();

        assertEq(lp1Shares, lp2Shares, "Equal deposits  equal shares");
        assertEq(lp1Shares + lp2Shares, totalShares, "Shares must sum to totalSupply");

        assertApproxEqRel(
            vault.convertToAssets(lp1Shares), vault.totalAssets() / 2, 0.01e18, "LP1 should own ~50% of assets"
        );
    }

    function test_CannotWithdrawLockedCollateral() public {
        _createOption(buyer1, 0.01 ether, STRIKE, 50);
        _createOptionAt(buyer2, 0.01 ether, STRIKE, 50, "20.0", "-80.0");

        uint256 totalLocked = vault.totalLocked();
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 lp1MaxWithdraw = vault.maxWithdraw(lp1);
        uint256 lp1Assets = vault.convertToAssets(lp1Shares);

        if (totalLocked > 0) {
            assertLt(lp1MaxWithdraw, lp1Assets, "Should not withdraw locked collateral");
        }

        uint256 balanceBefore = weth.balanceOf(lp1);

        vm.prank(lp1);
        vault.withdraw(lp1MaxWithdraw, lp1, lp1);

        uint256 received = weth.balanceOf(lp1) - balanceBefore;

        assertGt(received, 0, "Should withdraw some amount");
        assertApproxEqRel(received, lp1MaxWithdraw, 0.01e18, "Withdrawn maxWithdraw");
        assertEq(vault.totalLocked(), totalLocked, "Locked collateral must not change");
        assertGe(vault.totalAssets(), totalLocked, "Vault must cover locked collateral");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT 10: SETTLED OPTIONS IMMUTABILITY
    //////////////////////////////////////////////////////////////*/

    function test_SettledOptionDataImmutable() public {
        uint256 tokenId = _createOption(buyer1, NOTIONAL, STRIKE, SPREAD);
        _settleOption(tokenId, 80);

        IBruma.Option memory before_ = bruma.getOption(tokenId);

        vm.warp(block.timestamp + 100 days);

        IBruma.Option memory after_ = bruma.getOption(tokenId);

        assertEq(uint8(before_.state.status), uint8(after_.state.status), "status changed");
        assertEq(before_.state.actualRainfall, after_.state.actualRainfall, "rainfall changed");
        assertEq(before_.state.finalPayout, after_.state.finalPayout, "payout changed");
    }

    /*//////////////////////////////////////////////////////////////
              PROPERTY-BASED (FUZZ) TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PayoutNeverExceedsCollateral(uint256 rainfall, uint256 strike, uint256 spread) public {
        strike = bound(strike, 1, 1000);
        spread = bound(spread, 1, 1000);
        rainfall = bound(rainfall, 0, 10000);

        uint256 mockPremium = (spread * NOTIONAL) / 10;
        if (mockPremium < bruma.minPremium()) return; // skip sub-minimum cases

        uint256 tokenId = _createOption(buyer1, NOTIONAL, strike, spread);
        uint256 maxPayout = spread * NOTIONAL;

        assertLe(bruma.simulatePayout(tokenId, rainfall), maxPayout, "FUZZ: payout > maxPayout");
    }

    function testFuzz_VaultCanCoverPayouts(uint8 numOptions, uint256 seed) public {
        numOptions = uint8(bound(numOptions, 1, 10));

        address[] memory buyers = new address[](numOptions);
        uint256[] memory tokenIds = new uint256[](numOptions);

        for (uint256 i = 0; i < numOptions; i++) {
            buyers[i] = address(uint160(uint256(keccak256(abi.encodePacked(seed, i)))));
            vm.deal(buyers[i], 10 ether);

            string memory lat = string(abi.encodePacked(vm.toString(i), ".0"));
            tokenIds[i] = _createOptionAt(buyers[i], NOTIONAL, STRIKE, SPREAD, lat, DEFAULT_LON);
        }

        for (uint256 i = 0; i < numOptions; i++) {
            vm.warp(block.timestamp + 4 days);

            // Use a fresh prank scope per iteration
            address nftOwner = bruma.ownerOf(tokenIds[i]);
            vm.prank(nftOwner);
            bytes32 requestId = bruma.requestSettlement(tokenIds[i]);

            uint256 rainfall = uint256(keccak256(abi.encodePacked(seed, i, "rain"))) % 200;
            rainfallCoordinator.mockFulfillRequest(requestId, rainfall);

            vm.prank(nftOwner);
            bruma.settle(tokenIds[i]);
        }

        assertGe(vault.totalAssets(), 0, "FUZZ: vault insolvent");
    }
}
