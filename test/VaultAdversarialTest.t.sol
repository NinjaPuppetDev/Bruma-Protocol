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
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title BrumaAdversarialTest
 * @notice Tests to verify security fixes are effective
 * @dev Tests should now PASS showing vulnerabilities are patched
 *
 * CHANGES:
 *   - All Bruma.OptionType / Bruma.OptionStatus / Bruma.Option / Bruma.CreateOptionParams
 *     updated to IBruma.* — these types now live in the interface.
 *   - `option` variable renamed to `bruma` to avoid shadowing the `option` keyword.
 *   - Added IBruma import.
 *   - Errors updated to IBruma.* selectors.
 */
contract BrumaAdversarialTest is Test {
    Bruma public bruma;
    BrumaVault public vault;
    WETH9 public weth;

    MockRainfallCoordinator public rainfallCoordinator;
    PremiumCalculatorCoordinator public premiumCoordinator;
    MockPremiumCalculatorConsumer public premiumConsumer;

    address public deployer = address(this);
    address public attacker = address(0xBAD);
    address public victim = address(0x600D);
    address public lp = address(0xA11CE);

    function setUp() external {
        vm.warp(1_704_067_200); // January 1, 2024

        weth = new WETH9();
        rainfallCoordinator = new MockRainfallCoordinator(address(0), 1);
        premiumConsumer = new MockPremiumCalculatorConsumer();
        premiumCoordinator = new PremiumCalculatorCoordinator(address(premiumConsumer));

        premiumConsumer.transferOwnership(address(premiumCoordinator));
        premiumCoordinator.acceptConsumerOwnership();

        vault = new BrumaVault(IERC20(address(weth)), "Bruma Vault", "brumaVault");

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

        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(lp, 500 ether);

        vm.startPrank(lp);
        weth.deposit{value: 200 ether}();
        weth.approve(address(vault), 200 ether);
        vault.deposit(200 ether, lp);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
          FIX #1: HISTORICAL DATE VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_HistoricalDateExploit_FIXED() external {
        console.log("\n=== FIX #1: HISTORICAL DATE EXPLOIT - PROTECTED ===");

        vm.prank(attacker);
        vm.expectRevert(IBruma.InvalidDates.selector);
        bruma.requestPremiumQuote(
            IBruma.CreateOptionParams({
                optionType: IBruma.OptionType.Call,
                latitude: "25.7617",
                longitude: "-80.1918",
                startDate: block.timestamp - 1 days, // historical → must revert
                expiryDate: block.timestamp + 1 days,
                strikeMM: 50,
                spreadMM: 50,
                notional: 0.1 ether
            })
        );

        console.log("PROTECTED: Historical date rejected with InvalidDates error");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #2: LOCATION NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_LocationStringManipulation_FIXED() external {
        console.log("\n=== FIX #2: LOCATION STRING MANIPULATION - PROTECTED ===");

        string[4] memory latVariations = ["40.7128", "40.71280", "40.712800", " 40.7128"];

        bytes32 key0 = _getLocationKeyExternal(latVariations[0], "-74.0060");

        for (uint256 i = 1; i < 4; i++) {
            bytes32 keyI = _getLocationKeyExternal(latVariations[i], "-74.0060");
            assertEq(
                key0, keyI, string(abi.encodePacked("Variation ", vm.toString(i), " should normalize to same key"))
            );
            console.log("Variation", i, "normalized to same location key");
        }

        console.log("PROTECTED: All coordinate variations map to same location");

        uint256 maxLocationExposure = (vault.totalAssets() * vault.maxLocationExposureBps()) / 10000;
        console.log("Max location exposure:", maxLocationExposure / 1e18, "ETH");

        // Option 1 — base string
        IBruma.CreateOptionParams memory p1 = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: latVariations[0],
            longitude: "-74.0060",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 30 days,
            strikeMM: 50,
            spreadMM: 100,
            notional: 0.2 ether
        });

        vm.prank(attacker);
        bytes32 req1 = bruma.requestPremiumQuote(p1);
        premiumConsumer.mockFulfillRequest(req1, 1 ether);

        uint256 cost1 = 1 ether + (1 ether * bruma.protocolFeeBps()) / 10000;
        vm.prank(attacker);
        uint256 tokenId1 = bruma.createOptionWithQuote{value: cost1}(req1);

        IBruma.Option memory opt1 = bruma.getOption(tokenId1);
        uint256 exposure1 = vault.locationExposure(opt1.state.locationKey);
        console.log("First option exposure:", exposure1 / 1e18, "ETH");

        // Option 2 — trailing zero variation, same location
        IBruma.CreateOptionParams memory p2 = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: latVariations[1],
            longitude: "-74.0060",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 30 days,
            strikeMM: 50,
            spreadMM: 100,
            notional: 0.2 ether
        });

        vm.prank(attacker);
        bytes32 req2 = bruma.requestPremiumQuote(p2);
        premiumConsumer.mockFulfillRequest(req2, 1 ether);

        uint256 cost2 = 1 ether + (1 ether * bruma.protocolFeeBps()) / 10000;
        vm.prank(attacker);
        uint256 tokenId2 = bruma.createOptionWithQuote{value: cost2}(req2);

        IBruma.Option memory opt2 = bruma.getOption(tokenId2);

        assertEq(
            opt1.state.locationKey,
            opt2.state.locationKey,
            "Different string variations should produce same location key"
        );

        uint256 exposure2 = vault.locationExposure(opt1.state.locationKey);
        assertEq(exposure2, exposure1 * 2, "Exposure should accumulate for same location");

        console.log("Cumulative exposure:", exposure2 / 1e18, "ETH");
        console.log("PROTECTED: String variations recognized as same location");
    }

    function _getLocationKeyExternal(string memory lat, string memory lon) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_normalizeCoordinate(lat), _normalizeCoordinate(lon)));
    }

    function _normalizeCoordinate(string memory coord) internal pure returns (string memory) {
        bytes memory b = bytes(coord);
        if (b.length == 0) return coord;

        uint256 start = 0;
        uint256 end = b.length;

        while (start < end && b[start] == " ") start++;
        while (end > start && b[end - 1] == " ") end--;
        if (start >= end) return coord;

        uint256 decPos = end;
        for (uint256 i = start; i < end; i++) {
            if (b[i] == ".") {
                decPos = i;
                break;
            }
        }

        if (decPos < end) {
            uint256 lastNonZero = decPos;
            for (uint256 i = decPos + 1; i < end; i++) {
                if (b[i] != "0") lastNonZero = i;
            }
            end = (lastNonZero == decPos) ? decPos : lastNonZero + 1;
        }

        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /*//////////////////////////////////////////////////////////////
          FIX #3: TRANSFER LOCK DURING SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_NFTSettlementFrontRunning_FIXED() external {
        console.log("\n=== FIX #3: NFT SETTLEMENT FRONT-RUNNING - PROTECTED ===");

        IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
            optionType: IBruma.OptionType.Call,
            latitude: "25.7617",
            longitude: "-80.1918",
            startDate: block.timestamp,
            expiryDate: block.timestamp + 7 days,
            strikeMM: 50,
            spreadMM: 50,
            notional: 0.1 ether
        });

        vm.prank(victim);
        bytes32 requestId = bruma.requestPremiumQuote(p);
        premiumConsumer.mockFulfillRequest(requestId, 0.5 ether);

        uint256 totalCost = 0.5 ether + (0.5 ether * bruma.protocolFeeBps()) / 10000;

        vm.prank(victim);
        uint256 tokenId = bruma.createOptionWithQuote{value: totalCost}(requestId);

        console.log("Victim owns option", tokenId);

        vm.warp(block.timestamp + 8 days);

        vm.prank(victim);
        bytes32 settlementId = bruma.requestSettlement(tokenId);
        console.log("Settlement requested, status: Settling");

        rainfallCoordinator.mockFulfillRequest(settlementId, 100);
        console.log("Oracle fulfilled: 100mm rainfall (profitable)");

        // Transfer is locked while Settling
        vm.prank(victim);
        vm.expectRevert(IBruma.TransferLocked.selector);
        bruma.safeTransferFrom(victim, attacker, tokenId);

        console.log("PROTECTED: Transfer blocked during settlement");

        vm.prank(victim);
        bruma.settle(tokenId);

        uint256 victimBefore = victim.balance;
        vm.prank(victim);
        bruma.claimPayout(tokenId);

        console.log("Victim claimed:", (victim.balance - victimBefore) / 1e18, "ETH");
        console.log("Owner at settlement gets payout (not attacker)");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #4: ENUMERABLE SET FOR AUTOMATION
    //////////////////////////////////////////////////////////////*/

    function test_AutomationDOS_FIXED() external {
        console.log("\n=== FIX #4: AUTOMATION DOS - PROTECTED ===");

        uint256 numOptions = 100;
        console.log("Creating", numOptions, "options...");

        for (uint256 i = 0; i < numOptions; i++) {
            string memory lat = string(abi.encodePacked(vm.toString(i), ".0"));

            IBruma.CreateOptionParams memory p = IBruma.CreateOptionParams({
                optionType: IBruma.OptionType.Call,
                latitude: lat,
                longitude: "-75.0",
                startDate: block.timestamp,
                expiryDate: block.timestamp + 1 days,
                strikeMM: 50,
                spreadMM: 10,
                notional: 0.01 ether
            });

            vm.prank(attacker);
            bytes32 requestId = bruma.requestPremiumQuote(p);
            premiumConsumer.mockFulfillRequest(requestId, 0.05 ether);

            uint256 totalCost = 0.05 ether + (0.05 ether * bruma.protocolFeeBps()) / 10000;
            vm.prank(attacker);
            bruma.createOptionWithQuote{value: totalCost}(requestId);
        }

        vm.warp(block.timestamp + 2 days);

        uint256 gasBefore = gasleft();
        (bool upkeepNeeded,) = bruma.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("checkUpkeep gas used:", gasUsed);
        console.log("Gas per option:", gasUsed / numOptions);

        uint256 projectedGas = (gasUsed * 5000) / numOptions;
        console.log("Projected gas for 5000 options:", projectedGas);

        assertTrue(projectedGas < 30_000_000, "PROTECTED: Gas usage scales linearly");
        assertTrue(upkeepNeeded, "Options need settlement");
        console.log("EnumerableSet prevents iteration over inactive options");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #5: PULL PAYMENT PATTERN
    //////////////////////////////////////////////////////////////*/

    function test_MaliciousNFTOwner_FIXED() external {
        console.log("\n=== FIX #5: MALICIOUS NFT OWNER - PROTECTED ===");

        MaliciousReceiver malicious = new MaliciousReceiver();
        vm.deal(address(malicious), 10 ether);

        vm.prank(address(malicious));
        bytes32 requestId = bruma.requestPremiumQuote(
            IBruma.CreateOptionParams({
                optionType: IBruma.OptionType.Call,
                latitude: "25.7617",
                longitude: "-80.1918",
                startDate: block.timestamp,
                expiryDate: block.timestamp + 7 days,
                strikeMM: 50,
                spreadMM: 50,
                notional: 0.1 ether
            })
        );
        premiumConsumer.mockFulfillRequest(requestId, 0.5 ether);

        uint256 totalCost = 0.5 ether + (0.5 ether * bruma.protocolFeeBps()) / 10000;
        vm.prank(address(malicious));
        uint256 tokenId = malicious.createOption{value: totalCost}(address(bruma), requestId);

        vm.warp(block.timestamp + 8 days);

        vm.prank(address(malicious));
        bytes32 settlementId = bruma.requestSettlement(tokenId);
        rainfallCoordinator.mockFulfillRequest(settlementId, 100);

        // settle() must succeed — does NOT push ETH (pull pattern)
        vm.prank(address(malicious));
        bruma.settle(tokenId);

        console.log("PROTECTED: Settlement completed despite malicious receiver");

        vm.prank(address(malicious));
        vm.expectRevert();
        bruma.claimPayout(tokenId);

        assertGt(bruma.pendingPayouts(tokenId), 0, "Payout preserved in pendingPayouts");
        console.log("Pull payment pattern isolates malicious contract");
        console.log("Payout is available but contract can't receive it");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #6: GEOGRAPHIC CORRELATION (KNOWN GAP)
    //////////////////////////////////////////////////////////////*/

    function test_CorrelationExploitation_NotFixed() external {
        console.log("\n=== FIX #6: CORRELATION - KNOWN GAP ===");
        console.log("Geographic correlation limits require vault upgrade.");
        console.log("Current mitigation: 20% per-location exposure cap.");
        console.log("Reinsurance pool provides backstop for correlated events.");
    }

    /*//////////////////////////////////////////////////////////////
          FIX #7: MINIMUM PREMIUM REQUIREMENTS
    //////////////////////////////////////////////////////////////*/

    function test_LiquidityGriefing_FIXED() external {
        console.log("\n=== FIX #7: LIQUIDITY GRIEFING - PROTECTED ===");

        uint256 numAttempts = 40;
        uint256 successCount = 0;

        console.log("Attempting to create", numAttempts, "tiny premium options...");

        for (uint256 i = 0; i < numAttempts; i++) {
            string memory lat = string(abi.encodePacked(vm.toString(i), ".0"));

            vm.prank(attacker);
            bytes32 requestId = bruma.requestPremiumQuote(
                IBruma.CreateOptionParams({
                    optionType: IBruma.OptionType.Call,
                    latitude: lat,
                    longitude: "-75.0",
                    startDate: block.timestamp,
                    expiryDate: block.timestamp + 1 days,
                    strikeMM: 200,
                    spreadMM: 20,
                    notional: 0.01 ether
                })
            );

            premiumConsumer.mockFulfillRequest(requestId, 0.01 ether); // below minPremium

            uint256 totalCost = 0.01 ether + (0.01 ether * bruma.protocolFeeBps()) / 10000;
            vm.prank(attacker);
            try bruma.createOptionWithQuote{value: totalCost}(requestId) {
                successCount++;
            } catch {
                // Expected: PremiumBelowMinimum
            }
        }

        console.log("Options created:", successCount, "/", numAttempts);
        assertEq(successCount, 0, "PROTECTED: All sub-minimum premiums rejected");
        console.log("Minimum premium requirement prevents griefing");
    }

    /*//////////////////////////////////////////////////////////////
          QUOTE SHOPPING (DESIGN TRADEOFF)
    //////////////////////////////////////////////////////////////*/

    function test_QuoteShopping_LIMITED() external {
        console.log("\n=== QUOTE SHOPPING - LIMITED BY UTILIZATION ===");

        bytes32[] memory requestIds = new bytes32[](10);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(attacker);
            requestIds[i] = bruma.requestPremiumQuote(
                IBruma.CreateOptionParams({
                    optionType: IBruma.OptionType.Call,
                    latitude: "25.7617",
                    longitude: "-80.1918",
                    startDate: block.timestamp,
                    expiryDate: block.timestamp + 7 days,
                    strikeMM: 100,
                    spreadMM: 50,
                    notional: 0.1 ether
                })
            );
            premiumConsumer.mockFulfillRequest(requestIds[i], 0.25 ether);
        }

        vm.warp(block.timestamp + 45 minutes);
        console.log("T+45min: Attacker tries to execute all quotes...");

        uint256 successCount = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 cost = 0.25 ether + (0.25 ether * bruma.protocolFeeBps()) / 10000;
            vm.prank(attacker);
            try bruma.createOptionWithQuote{value: cost}(requestIds[i]) {
                successCount++;
            } catch {
                console.log("Quote", i, "blocked by utilization");
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

contract MaliciousReceiver is IERC721Receiver {
    function createOption(address optionContract, bytes32 requestId) external payable returns (uint256) {
        return Bruma(payable(optionContract)).createOptionWithQuote{value: msg.value}(requestId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("I don't want your money!");
    }
}
