// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PremiumCalculatorConsumer} from "../src/chainlinkfunctions/PremiumCalculatorConsumer.sol";

import {MockFunctionsRouter} from "./mocks/MockFunctionsInfra.sol";

/**
 * @title PremiumCalculatorConsumerTest
 * @notice Unit tests for PremiumCalculatorConsumer.
 *
 * COVERAGE TARGETS
 * ────────────────────────────────────────────────────────
 * Constructor
 *   • donId / subscriptionId / callbackGasLimit stored correctly
 *
 * requestPremium
 *   • onlyOwner guard
 *   • happy path: status Pending, meta stored, lastRequestId updated, event emitted
 *
 * fulfillRequest (via MockFunctionsRouter)
 *   • success path — premium stored, lastPremium updated, status Fulfilled, event
 *   • error path   — error stored, status Failed, event
 *   • UnexpectedRequestID — re-fulfillment or unknown ID
 *
 * view helpers
 *   • getPremiumByRequest
 *   • getRequestStatus
 *   • isRequestFulfilled
 *   • getRequestMeta
 *
 * admin setters (onlyOwner)
 *   • updateSubscriptionId
 *   • updateCallbackGasLimit
 *   • updateDonId
 *   • non-owner reverts for all three
 */
contract PremiumCalculatorConsumerTest is Test {
    /*//////////////////////////////////////////////////////////////
                             CONTRACTS
    //////////////////////////////////////////////////////////////*/

    PremiumCalculatorConsumer public consumer;
    MockFunctionsRouter public router;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public owner = address(this);
    address public nonOwner = address(0xBAD);

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 constant DON_ID = bytes32(uint256(1));
    uint64 constant SUB_ID = 7;
    uint32 constant CB_GAS = 300_000;

    string constant LAT = "-23.5505";
    string constant LON = "-46.6333";
    uint256 constant STRIKE_MM = 100;
    uint256 constant SPREAD_MM = 50;
    uint256 constant DURATION_DAYS = 30;
    uint256 constant NOTIONAL_WEI = 1 ether;

    uint256 constant PREMIUM_WEI = 0.05 ether;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        router = new MockFunctionsRouter();
        // Patch router at the address we supply to the constructor
        // (no hardcoded address here — consumer accepts router in ctor).
        consumer = new PremiumCalculatorConsumer(address(router), DON_ID, SUB_ID, CB_GAS);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_StoredCorrectly() external {
        assertEq(consumer.donId(), DON_ID);
        assertEq(consumer.subscriptionId(), SUB_ID);
        assertEq(consumer.callbackGasLimit(), CB_GAS);
    }

    /*//////////////////////////////////////////////////////////////
                     requestPremium — GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RequestPremium_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(nonOwner);
        consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
    }

    /*//////////////////////////////////////////////////////////////
                   requestPremium — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_RequestPremium_HappyPath() external {
        vm.expectEmit(false, false, false, true, address(consumer));
        emit PremiumCalculatorConsumer.PremiumRequested(
            bytes32(0), LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI
        );

        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);

        // lastRequestId updated
        assertEq(consumer.lastRequestId(), requestId);

        // Status Pending
        assertEq(uint8(consumer.requestStatus(requestId)), uint8(PremiumCalculatorConsumer.RequestStatus.Pending));

        // Meta stored
        PremiumCalculatorConsumer.PremiumRequest memory meta = consumer.getRequestMeta(requestId);
        assertEq(meta.latitude, LAT);
        assertEq(meta.longitude, LON);
        assertEq(meta.strikeMM, STRIKE_MM);
        assertEq(meta.spreadMM, SPREAD_MM);
        assertEq(meta.durationDays, DURATION_DAYS);
        assertEq(meta.notionalWei, NOTIONAL_WEI);
    }

    /*//////////////////////////////////////////////////////////////
                  fulfillRequest — SUCCESS PATH
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_Success() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        bytes memory response = abi.encode(PREMIUM_WEI);

        vm.expectEmit(true, false, false, true, address(consumer));
        emit PremiumCalculatorConsumer.PremiumFulfilled(requestId, PREMIUM_WEI);

        router.fulfillRequest(address(consumer), requestId, response, "");

        // Status Fulfilled
        assertEq(uint8(consumer.requestStatus(requestId)), uint8(PremiumCalculatorConsumer.RequestStatus.Fulfilled));

        // Premium stored per-request
        assertEq(consumer.premiumByRequest(requestId), PREMIUM_WEI);

        // Global lastPremium updated
        assertEq(consumer.lastPremium(), PREMIUM_WEI);
    }

    /*//////////////////////////////////////////////////////////////
                  fulfillRequest — ERROR PATH
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_Error() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        bytes memory errBytes = bytes("open-meteo unavailable");

        vm.expectEmit(true, false, false, true, address(consumer));
        emit PremiumCalculatorConsumer.RequestFailed(requestId, errBytes);

        router.fulfillRequest(address(consumer), requestId, "", errBytes);

        // Status Failed
        assertEq(uint8(consumer.requestStatus(requestId)), uint8(PremiumCalculatorConsumer.RequestStatus.Failed));

        // Error bytes stored
        assertEq(consumer.errorByRequest(requestId), errBytes);

        // Premium should NOT be set
        assertEq(consumer.premiumByRequest(requestId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                 fulfillRequest — UNEXPECTED REQUEST ID
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_UnexpectedID_AfterFulfill() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        router.fulfillRequest(address(consumer), requestId, abi.encode(PREMIUM_WEI), "");

        vm.expectRevert(abi.encodeWithSelector(PremiumCalculatorConsumer.UnexpectedRequestID.selector, requestId));
        router.fulfillRequest(address(consumer), requestId, abi.encode(999), "");
    }

    function test_FulfillRequest_UnexpectedID_UnknownId() external {
        bytes32 bogus = keccak256("does-not-exist");
        vm.expectRevert(abi.encodeWithSelector(PremiumCalculatorConsumer.UnexpectedRequestID.selector, bogus));
        router.fulfillRequest(address(consumer), bogus, abi.encode(1), "");
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetPremiumByRequest_BeforeFulfill() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        assertEq(consumer.getPremiumByRequest(requestId), 0);
    }

    function test_GetPremiumByRequest_AfterFulfill() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        router.fulfillRequest(address(consumer), requestId, abi.encode(PREMIUM_WEI), "");
        assertEq(consumer.getPremiumByRequest(requestId), PREMIUM_WEI);
    }

    function test_GetRequestStatus_None() external {
        assertEq(
            uint8(consumer.getRequestStatus(keccak256("unknown"))), uint8(PremiumCalculatorConsumer.RequestStatus.None)
        );
    }

    function test_IsRequestFulfilled_False_BeforeFulfill() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        assertFalse(consumer.isRequestFulfilled(requestId));
    }

    function test_IsRequestFulfilled_True_AfterFulfill() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        router.fulfillRequest(address(consumer), requestId, abi.encode(PREMIUM_WEI), "");
        assertTrue(consumer.isRequestFulfilled(requestId));
    }

    function test_IsRequestFulfilled_False_AfterError() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        router.fulfillRequest(address(consumer), requestId, "", bytes("error"));
        assertFalse(consumer.isRequestFulfilled(requestId));
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateSubscriptionId_HappyPath() external {
        consumer.updateSubscriptionId(999);
        assertEq(consumer.subscriptionId(), 999);
    }

    function test_UpdateSubscriptionId_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(nonOwner);
        consumer.updateSubscriptionId(999);
    }

    function test_UpdateCallbackGasLimit_HappyPath() external {
        consumer.updateCallbackGasLimit(500_000);
        assertEq(consumer.callbackGasLimit(), 500_000);
    }

    function test_UpdateCallbackGasLimit_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(nonOwner);
        consumer.updateCallbackGasLimit(500_000);
    }

    function test_UpdateDonId_HappyPath() external {
        bytes32 newDonId = keccak256("new-don");
        consumer.updateDonId(newDonId);
        assertEq(consumer.donId(), newDonId);
    }

    function test_UpdateDonId_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(nonOwner);
        consumer.updateDonId(keccak256("new-don"));
    }

    /*//////////////////////////////////////////////////////////////
               MULTIPLE REQUESTS — INDEPENDENT STATE
    //////////////////////////////////////////////////////////////*/

    function test_MultipleRequests_IndependentState() external {
        bytes32 id1 = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        bytes32 id2 = consumer.requestPremium("-33.8688", "151.2093", 200, 100, 60, 2 ether);

        assertTrue(id1 != id2, "Request IDs must be distinct");

        // Fulfill only id1
        router.fulfillRequest(address(consumer), id1, abi.encode(PREMIUM_WEI), "");

        assertEq(uint8(consumer.requestStatus(id1)), uint8(PremiumCalculatorConsumer.RequestStatus.Fulfilled));
        assertEq(uint8(consumer.requestStatus(id2)), uint8(PremiumCalculatorConsumer.RequestStatus.Pending));

        assertEq(consumer.premiumByRequest(id1), PREMIUM_WEI);
        assertEq(consumer.premiumByRequest(id2), 0);

        // lastPremium reflects the last fulfilled
        assertEq(consumer.lastPremium(), PREMIUM_WEI);

        // Fulfill id2 with a different premium
        uint256 premium2 = 0.1 ether;
        router.fulfillRequest(address(consumer), id2, abi.encode(premium2), "");

        assertEq(consumer.premiumByRequest(id2), premium2);
        assertEq(consumer.lastPremium(), premium2, "lastPremium should update to most recent");
    }

    /*//////////////////////////////////////////////////////////////
          EDGE CASE: zero-value premium is a valid fulfillment
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_ZeroPremium_IsValid() external {
        bytes32 requestId = consumer.requestPremium(LAT, LON, STRIKE_MM, SPREAD_MM, DURATION_DAYS, NOTIONAL_WEI);
        router.fulfillRequest(address(consumer), requestId, abi.encode(0), "");

        assertEq(
            uint8(consumer.requestStatus(requestId)),
            uint8(PremiumCalculatorConsumer.RequestStatus.Fulfilled),
            "Zero premium should still be Fulfilled"
        );
        assertEq(consumer.premiumByRequest(requestId), 0);
    }
}
