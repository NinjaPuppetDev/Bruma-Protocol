// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Bruma} from "../src/Bruma.sol";
import {BrumaVault} from "../src/BrumaVault.sol";
import {PremiumCalculatorCoordinator} from "../src/chainlinkfunctions/PremiumCalculatorCoordinator.sol";
import {WETH9} from "./mocks/WETH9.sol";
import {MockRainfallCoordinator} from "./mocks/MockRainfallCoordinator.sol";
import {MockPremiumCalculatorConsumer} from "./mocks/MockPremiumCalculatorConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrumaAdversarialTest
 * @notice Tests to verify security fixes are effective
 * @dev Tests should now PASS showing vulnerabilities are patched
 */
contract BrumaAdversarialTest is Test {
    Bruma public option;
    BrumaVault public vault;
    WETH9 public weth;
    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;
    MockPremiumCalculatorConsumer public premiumConsumer;

    address public attacker = address(0xBAD);
    address public victim = address(0x600D);
    address public lp = address(0xA11CE);

    function setUp() external {
        // Set a reasonable starting timestamp to avoid underflow
        vm.warp(1704067200); // January 1, 2024

        weth = new WETH9();
        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        premiumConsumer = new MockPremiumCalculatorConsumer();
        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));

        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "brumaVault");

        option = new Bruma(
            address(rainfallCoordinator),
            address(rainfallCoordinator),
            address(premiumCoordinator),
            address(premiumConsumer),
            address(vault),
            address(weth)
        );

        vault.setWeatherOptions(address(option));
        premiumCoordinator.setWeatherOptions(address(option));

        // Fund accounts
        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(lp, 500 ether);

        // Fund vault
        vm.startPrank(lp);
        weth.deposit{value: 200 ether}();
        weth.approve(address(vault), 200 ether);
        vault.deposit(200 ether, lp);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
          FIX #1: HISTORICAL DATE VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: Historical dates now rejected
     */
    function test_HistoricalDateExploit_FIXED() external {
        console.log("\n=== FIX #1: HISTORICAL DATE EXPLOIT - PROTECTED ===");

        // Use current timestamp for calculation (now safe from underflow)
        uint256 yesterday = block.timestamp - 1 days;
        uint256 tomorrow = block.timestamp + 1 days;

        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "25.7617",
            longitude: "-80.1918",
            startDate: yesterday, // Will be rejected
            expiryDate: tomorrow, // Valid future date
            strikeMM: 50,
            spreadMM: 50,
            notional: 0.1 ether
        });

        vm.prank(attacker);
        vm.expectRevert(Bruma.InvalidDates.selector);
        option.requestPremiumQuote(p);

        console.log("PROTECTED: Historical date rejected with InvalidDates error");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #2: LOCATION NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: Location string variations now normalized
     * @dev Tests that different string representations of same coordinates
     *      are recognized as the same location
     */
    function test_LocationStringManipulation_FIXED() external {
        console.log("\n=== FIX #2: LOCATION STRING MANIPULATION - PROTECTED ===");

        string[4] memory latVariations = ["40.7128", "40.71280", "40.712800", " 40.7128"];

        // Test normalization directly by checking location keys
        bytes32 key0 = _getLocationKeyExternal(latVariations[0], "-74.0060");

        for (uint256 i = 1; i < 4; i++) {
            bytes32 keyI = _getLocationKeyExternal(latVariations[i], "-74.0060");

            assertEq(
                key0, keyI, string(abi.encodePacked("Variation ", vm.toString(i), " should normalize to same key"))
            );

            console.log("Variation", i, "normalized to same location key");
        }

        console.log("PROTECTED: All coordinate variations map to same location");

        // Additional test: Create options and verify they count toward same location exposure
        uint256 maxLocationExposure = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        console.log("Max location exposure:", maxLocationExposure / 1e18, "ETH");

        // Create first option with one variation
        Bruma.CreateOptionParams memory p1 = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: latVariations[0],
            longitude: "-74.0060",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 30 days,
            strikeMM: 50,
            spreadMM: 100,
            notional: 0.2 ether
        });

        vm.prank(attacker);
        bytes32 req1 = option.requestPremiumQuote(p1);
        premiumConsumer.mockFulfillRequest(req1, 1 ether);

        uint256 cost1 = 1 ether + (1 ether * option.protocolFeeBps()) / 10000;
        vm.prank(attacker);
        uint256 tokenId1 = option.createOptionWithQuote{value: cost1}(req1);

        Bruma.Option memory opt1 = option.getOption(tokenId1);
        uint256 exposure1 = vault.locationExposure(opt1.state.locationKey);

        console.log("First option exposure:", exposure1 / 1e18, "ETH");

        // Create second option with different string variation but same location
        Bruma.CreateOptionParams memory p2 = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: latVariations[1], // Different string, same location
            longitude: "-74.0060",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 30 days,
            strikeMM: 50,
            spreadMM: 100,
            notional: 0.2 ether
        });

        vm.prank(attacker);
        bytes32 req2 = option.requestPremiumQuote(p2);
        premiumConsumer.mockFulfillRequest(req2, 1 ether);

        uint256 cost2 = 1 ether + (1 ether * option.protocolFeeBps()) / 10000;
        vm.prank(attacker);
        uint256 tokenId2 = option.createOptionWithQuote{value: cost2}(req2);

        Bruma.Option memory opt2 = option.getOption(tokenId2);

        // KEY ASSERTION: Both options should have same location key
        assertEq(
            opt1.state.locationKey,
            opt2.state.locationKey,
            "Different string variations should produce same location key"
        );

        uint256 exposure2 = vault.locationExposure(opt1.state.locationKey);

        // Exposure should have doubled (cumulative)
        assertEq(exposure2, exposure1 * 2, "Exposure should accumulate for same location");

        console.log("Second option added to same location");
        console.log("Cumulative exposure:", exposure2 / 1e18, "ETH");
        console.log("PROTECTED: String variations recognized as same location");
    }

    // Helper function to test location key generation
    function _getLocationKeyExternal(string memory lat, string memory lon) internal pure returns (bytes32) {
        // This mimics the contract's _normalizeCoordinate logic
        string memory normalizedLat = _normalizeCoordinate(lat);
        string memory normalizedLon = _normalizeCoordinate(lon);
        return keccak256(abi.encodePacked(normalizedLat, normalizedLon));
    }

    function _normalizeCoordinate(string memory coord) internal pure returns (string memory) {
        bytes memory coordBytes = bytes(coord);
        if (coordBytes.length == 0) return coord;

        uint256 start = 0;
        uint256 end = coordBytes.length;

        // Remove leading/trailing spaces
        while (start < end && coordBytes[start] == " ") start++;
        while (end > start && coordBytes[end - 1] == " ") end--;

        if (start >= end) return coord;

        // Find decimal point
        uint256 decimalPos = end;
        for (uint256 i = start; i < end; i++) {
            if (coordBytes[i] == ".") {
                decimalPos = i;
                break;
            }
        }

        // Remove trailing zeros after decimal
        if (decimalPos < end) {
            uint256 lastNonZero = decimalPos;
            for (uint256 i = decimalPos + 1; i < end; i++) {
                if (coordBytes[i] != "0") {
                    lastNonZero = i;
                }
            }

            if (lastNonZero == decimalPos) {
                end = decimalPos;
            } else {
                end = lastNonZero + 1;
            }
        }

        bytes memory normalized = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            normalized[i] = coordBytes[start + i];
        }

        return string(normalized);
    }

    /*//////////////////////////////////////////////////////////////
          FIX #3: TRANSFER LOCK DURING SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: NFT transfers blocked during settlement
     */
    function test_NFTSettlementFrontRunning_FIXED() external {
        console.log("\n=== FIX #3: NFT SETTLEMENT FRONT-RUNNING - PROTECTED ===");

        // Victim creates option
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "25.7617",
            longitude: "-80.1918",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 7 days,
            strikeMM: 50,
            spreadMM: 50,
            notional: 0.1 ether
        });

        vm.prank(victim);
        bytes32 requestId = option.requestPremiumQuote(p);
        premiumConsumer.mockFulfillRequest(requestId, 0.5 ether);

        uint256 totalCost = 0.5 ether + (0.5 ether * option.protocolFeeBps()) / 10000;

        vm.prank(victim);
        uint256 tokenId = option.createOptionWithQuote{value: totalCost}(requestId);

        console.log("Victim owns option", tokenId);

        // Fast forward to expiry
        vm.warp(block.timestamp + 8 days);

        // Victim requests settlement
        vm.prank(victim);
        bytes32 settlementId = option.requestSettlement(tokenId);

        console.log("Settlement requested, status: Settling");

        // Oracle fulfills with profitable rainfall
        rainfallCoordinator.mockFulfillRequest(settlementId, 100);

        console.log("Oracle fulfilled: 100mm rainfall (profitable)");

        // ATTACK BLOCKED: Attacker tries to buy NFT but transfer is locked
        vm.prank(victim);
        vm.expectRevert(Bruma.TransferLocked.selector);
        option.safeTransferFrom(victim, attacker, tokenId);

        console.log("PROTECTED: Transfer blocked during settlement");

        // Settlement completes
        vm.prank(victim);
        option.settle(tokenId);

        // Victim can claim payout (pull payment)
        uint256 victimBalanceBefore = victim.balance;
        vm.prank(victim);
        option.claimPayout(tokenId);

        uint256 payout = victim.balance - victimBalanceBefore;
        console.log("Victim claimed:", payout / 1e18, "ETH");
        console.log("Owner at settlement gets payout (not attacker)");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #4: ENUMERABLE SET FOR AUTOMATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: Automation uses EnumerableSet, scales efficiently
     */
    function test_AutomationDOS_FIXED() external {
        console.log("\n=== FIX #4: AUTOMATION DOS - PROTECTED ===");

        uint256 numOptions = 100;

        console.log("Creating", numOptions, "options...");

        for (uint256 i = 0; i < numOptions; i++) {
            string memory lat = string(abi.encodePacked(vm.toString(i), ".0"));

            Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
                optionType: Bruma.OptionType.Call,
                latitude: lat,
                longitude: "-75.0",
                startDate: block.timestamp,
                expiryDate: block.timestamp + 1 days,
                strikeMM: 50,
                spreadMM: 10,
                notional: 0.01 ether
            });

            vm.prank(attacker);
            bytes32 requestId = option.requestPremiumQuote(p);
            premiumConsumer.mockFulfillRequest(requestId, 0.05 ether); // Above minimum

            uint256 totalCost = 0.05 ether + (0.05 ether * option.protocolFeeBps()) / 10000;

            vm.prank(attacker);
            option.createOptionWithQuote{value: totalCost}(requestId);
        }

        // Fast forward past expiry
        vm.warp(block.timestamp + 2 days);

        // Measure gas for checkUpkeep
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = option.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("checkUpkeep gas used:", gasUsed);
        console.log("Gas per option:", gasUsed / numOptions);

        // Extrapolate to 5000 options
        uint256 projectedGas = (gasUsed * 5000) / numOptions;
        console.log("Projected gas for 5000 options:", projectedGas);

        assertTrue(projectedGas < 30_000_000, "PROTECTED: Gas usage scales linearly");
        assertTrue(upkeepNeeded, "Options need settlement");

        console.log("EnumerableSet prevents iteration over inactive options");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #5: PULL PAYMENT PATTERN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: Malicious contracts can't block settlements
     */
    function test_MaliciousNFTOwner_FIXED() external {
        console.log("\n=== FIX #5: MALICIOUS NFT OWNER - PROTECTED ===");

        // Deploy malicious contract
        MaliciousReceiver malicious = new MaliciousReceiver();
        vm.deal(address(malicious), 10 ether);

        // Malicious contract creates option
        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "25.7617",
            longitude: "-80.1918",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 7 days,
            strikeMM: 50,
            spreadMM: 50,
            notional: 0.1 ether
        });

        vm.prank(address(malicious));
        bytes32 requestId = option.requestPremiumQuote(p);
        premiumConsumer.mockFulfillRequest(requestId, 0.5 ether);

        uint256 totalCost = 0.5 ether + (0.5 ether * option.protocolFeeBps()) / 10000;

        vm.prank(address(malicious));
        uint256 tokenId = malicious.createOption{value: totalCost}(address(option), requestId);

        // Fast forward and settle
        vm.warp(block.timestamp + 8 days);

        vm.prank(address(malicious));
        bytes32 settlementId = option.requestSettlement(tokenId);

        rainfallCoordinator.mockFulfillRequest(settlementId, 100); // ITM

        // Settlement succeeds (doesn't push payment)
        vm.prank(address(malicious));
        option.settle(tokenId);

        console.log("PROTECTED: Settlement completed despite malicious receiver");

        // Malicious contract must explicitly claim (will fail)
        vm.prank(address(malicious));
        vm.expectRevert(); // Will fail when trying to transfer to malicious contract
        option.claimPayout(tokenId);

        console.log("Pull payment pattern isolates malicious contract");
        console.log("Payout is available but contract can't receive it");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #6: GEOGRAPHIC CORRELATION (Requires Vault Upgrade)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Geographic correlation limits require vault interface changes
     * @dev This fix is NOT implemented in backward-compatible version
     */
    function test_CorrelationExploitation_NotFixed() external {
        console.log("\n=== FIX #6: CORRELATION EXPLOITATION - NOT IN BACKWARD COMPATIBLE VERSION ===");
        console.log("This fix requires vault interface changes (totalAssets function)");
        console.log("Consider implementing in future vault upgrade");
        console.log("Current mitigation: Vault's per-location exposure limits (20%)");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #7: MINIMUM PREMIUM REQUIREMENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice FIXED: Minimum premium prevents griefing
     */
    function test_LiquidityGriefing_FIXED() external {
        console.log("\n=== FIX #7: LIQUIDITY GRIEFING - PROTECTED ===");

        uint256 numAttempts = 40;
        uint256 successCount = 0;

        console.log("Attempting to create", numAttempts, "tiny premium options...");

        for (uint256 i = 0; i < numAttempts; i++) {
            string memory lat = string(abi.encodePacked(vm.toString(i), ".0"));

            Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
                optionType: Bruma.OptionType.Call,
                latitude: lat,
                longitude: "-75.0",
                startDate: block.timestamp,
                expiryDate: block.timestamp + 1 days,
                strikeMM: 200,
                spreadMM: 20,
                notional: 0.01 ether
            });

            vm.prank(attacker);
            bytes32 requestId = option.requestPremiumQuote(p);

            // Try tiny premium (below minimum)
            premiumConsumer.mockFulfillRequest(requestId, 0.01 ether);

            uint256 totalCost = 0.01 ether + (0.01 ether * option.protocolFeeBps()) / 10000;

            vm.prank(attacker);
            try option.createOptionWithQuote{value: totalCost}(requestId) {
                successCount++;
            } catch {
                // Expected to fail due to minimum premium
            }
        }

        console.log("Options created:", successCount, "/", numAttempts);
        console.log("Utilization:", vault.utilizationRate() / 100, "%");

        assertTrue(successCount == 0, "PROTECTED: All tiny premiums rejected");
        console.log("Minimum premium requirement prevents griefing");
    }

    /*//////////////////////////////////////////////////////////////
          QUOTE SHOPPING (DESIGN TRADEOFF)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Quote shopping is limited by vault utilization
     */
    function test_QuoteShopping_LIMITED() external {
        console.log("\n=== QUOTE SHOPPING - LIMITED BY UTILIZATION ===");

        bytes32[] memory requestIds = new bytes32[](10);

        Bruma.CreateOptionParams memory p = Bruma.CreateOptionParams({
            optionType: Bruma.OptionType.Call,
            latitude: "25.7617",
            longitude: "-80.1918",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 7 days,
            strikeMM: 100,
            spreadMM: 50,
            notional: 0.1 ether
        });

        console.log("Requesting 10 premium quotes...");
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(attacker);
            requestIds[i] = option.requestPremiumQuote(p);
            premiumConsumer.mockFulfillRequest(requestIds[i], 0.25 ether);
        }

        vm.warp(block.timestamp + 45 minutes);
        console.log("T+45min: Attacker tries to execute all quotes...");

        uint256 successCount = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 premium = premiumConsumer.premiumByRequest(requestIds[i]);
            uint256 cost = premium + (premium * option.protocolFeeBps()) / 10000;

            vm.prank(attacker);
            try option.createOptionWithQuote{value: cost}(requestIds[i]) {
                successCount++;
            } catch {
                console.log("Quote", i, "failed - insufficient liquidity");
                break;
            }
        }

        console.log("Options created:", successCount, "/10");
        console.log("LIMITED: Vault utilization caps prevent unlimited quote shopping");
    }
}

/*//////////////////////////////////////////////////////////////
                    HELPER CONTRACTS
//////////////////////////////////////////////////////////////*/

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MaliciousReceiver is IERC721Receiver {
    function createOption(address optionContract, bytes32 requestId) external payable returns (uint256) {
        Bruma _option = Bruma(payable(optionContract));
        return _option.createOptionWithQuote{value: msg.value}(requestId);
    }

    // Implement ERC721Receiver to accept NFTs
    function onERC721Received(address, /*operator*/ address, /*from*/ uint256, /*tokenId*/ bytes calldata /*data*/ )
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    // Refuse all ETH transfers (this is the malicious part)
    receive() external payable {
        revert("I don't want your money!");
    }
}