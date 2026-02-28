// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {RainfallFunctionsConsumer} from "../src/chainlinkfunctions/RainfallConsumer.sol";
import {RainfallCoordinator} from "../src/chainlinkfunctions/RainfallCoordinator.sol";

import {MockFunctionsRouter} from "./mocks/MockFunctionsInfra.sol";

/**
 * @title RainfallConsumerTest
 * @notice Unit tests for RainfallFunctionsConsumer.
 *
 * COVERAGE TARGETS
 * ────────────────────────────────────────────────────────
 * sendRequest
 *   • InvalidArgsLength        — wrong number of args
 *   • onlyOwner revert         — non-owner caller
 *   • happy path               — status Pending, meta stored, event emitted
 *
 * fulfillRequest (via router mock)
 *   • happy path (success)     — rainfall stored, status Fulfilled, event
 *   • error path               — error bytes stored, status Failed, event
 *   • UnexpectedRequestID      — re-fulfillment attempt
 *
 * view helpers
 *   • getRainfallByRequest
 *   • getRequestStatus
 *   • getRequestMeta
 *   • isRequestFulfilled
 */
contract RainfallConsumerTest is Test {
    /*//////////////////////////////////////////////////////////////
                             CONTRACTS
    //////////////////////////////////////////////////////////////*/

    RainfallFunctionsConsumer public consumer;
    MockFunctionsRouter public router;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public owner = address(this); // deployer = owner
    address public nonOwner = address(0xBAD);

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint64 constant SUB_ID = 42;
    string constant LAT = "40.7128";
    string constant LON = "-74.0060";
    string constant START_DATE = "2023-01-01";
    string constant END_DATE = "2023-12-31";
    uint256 constant RAINFALL_MM = 1234;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        router = new MockFunctionsRouter();
        consumer = new RainfallFunctionsConsumer();
        // NOTE: RainfallFunctionsConsumer hard-codes the Sepolia router.
        // For unit tests we swap it out by re-deploying with our mock
        // via a workaround: etch the mock bytecode at the hardcoded address.
        _patchRouter();
    }

    /// @dev Replace the hardcoded Sepolia router address with our mock.
    function _patchRouter() internal {
        address hardcodedRouter = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
        vm.etch(hardcodedRouter, address(router).code);
        // Mirror storage so the mock nonce/state is at the patched address.
        router = MockFunctionsRouter(hardcodedRouter);
    }

    /*//////////////////////////////////////////////////////////////
                      HELPER: build valid args array
    //////////////////////////////////////////////////////////////*/

    function _validArgs() internal pure returns (string[] memory args) {
        args = new string[](4);
        args[0] = LAT;
        args[1] = LON;
        args[2] = START_DATE;
        args[3] = END_DATE;
    }

    /// @dev Sends a request and returns its requestId.
    function _sendRequest() internal returns (bytes32 requestId) {
        requestId = consumer.sendRequest(SUB_ID, _validArgs());
    }

    /*//////////////////////////////////////////////////////////////
                          sendRequest — GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_SendRequest_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(nonOwner);
        consumer.sendRequest(SUB_ID, _validArgs());
    }

    function test_SendRequest_InvalidArgsLength_TooFew() external {
        string[] memory args = new string[](3);
        vm.expectRevert(abi.encodeWithSelector(RainfallFunctionsConsumer.InvalidArgsLength.selector, 3));
        consumer.sendRequest(SUB_ID, args);
    }

    function test_SendRequest_InvalidArgsLength_TooMany() external {
        string[] memory args = new string[](5);
        vm.expectRevert(abi.encodeWithSelector(RainfallFunctionsConsumer.InvalidArgsLength.selector, 5));
        consumer.sendRequest(SUB_ID, args);
    }

    /*//////////////////////////////////////////////////////////////
                         sendRequest — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_SendRequest_HappyPath() external {
        vm.expectEmit(false, false, false, true, address(consumer));
        emit RainfallFunctionsConsumer.RainfallRequested(
            bytes32(0), // indexed — not checked in this signature
            LAT,
            LON,
            START_DATE,
            END_DATE
        );

        bytes32 requestId = _sendRequest();

        // Status is Pending
        assertEq(
            uint8(consumer.requestStatus(requestId)),
            uint8(RainfallFunctionsConsumer.RequestStatus.Pending),
            "Status should be Pending"
        );

        // lastRequestId updated
        assertEq(consumer.lastRequestId(), requestId);

        // Metadata stored correctly
        RainfallFunctionsConsumer.RainfallRequest memory meta = consumer.getRequestMeta(requestId);
        assertEq(meta.latitude, LAT);
        assertEq(meta.longitude, LON);
        assertEq(meta.startDate, START_DATE);
        assertEq(meta.endDate, END_DATE);
    }

    /*//////////////////////////////////////////////////////////////
                   fulfillRequest — SUCCESS PATH
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_Success() external {
        bytes32 requestId = _sendRequest();
        bytes memory response = abi.encode(RAINFALL_MM);

        vm.expectEmit(true, false, false, true, address(consumer));
        emit RainfallFunctionsConsumer.RainfallResponse(requestId, RAINFALL_MM, response, "");

        router.fulfillRequest(address(consumer), requestId, response, "");

        // Status Fulfilled
        assertEq(uint8(consumer.requestStatus(requestId)), uint8(RainfallFunctionsConsumer.RequestStatus.Fulfilled));

        // Rainfall stored per-request
        assertEq(consumer.rainfallByRequest(requestId), RAINFALL_MM);

        // Global last value updated
        assertEq(consumer.lastRainfallMM(), RAINFALL_MM);
    }

    /*//////////////////////////////////////////////////////////////
                   fulfillRequest — ERROR PATH
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_Error() external {
        bytes32 requestId = _sendRequest();
        bytes memory errBytes = bytes("open-meteo timeout");

        vm.expectEmit(true, false, false, true, address(consumer));
        emit RainfallFunctionsConsumer.RainfallResponse(requestId, 0, "", errBytes);

        router.fulfillRequest(address(consumer), requestId, "", errBytes);

        // Status Failed
        assertEq(uint8(consumer.requestStatus(requestId)), uint8(RainfallFunctionsConsumer.RequestStatus.Failed));

        // Error bytes stored
        assertEq(consumer.errorByRequest(requestId), errBytes);

        // Rainfall stays 0
        assertEq(consumer.rainfallByRequest(requestId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                   fulfillRequest — UNEXPECTED ID
    //////////////////////////////////////////////////////////////*/

    function test_FulfillRequest_UnexpectedRequestID_AfterFulfill() external {
        bytes32 requestId = _sendRequest();
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL_MM), "");

        // Second fulfillment should revert
        vm.expectRevert(abi.encodeWithSelector(RainfallFunctionsConsumer.UnexpectedRequestID.selector, requestId));
        router.fulfillRequest(address(consumer), requestId, abi.encode(999), "");
    }

    function test_FulfillRequest_UnexpectedRequestID_UnknownId() external {
        bytes32 bogus = keccak256("bogus");
        vm.expectRevert(abi.encodeWithSelector(RainfallFunctionsConsumer.UnexpectedRequestID.selector, bogus));
        router.fulfillRequest(address(consumer), bogus, abi.encode(1), "");
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetRainfallByRequest_BeforeFulfill() external {
        bytes32 requestId = _sendRequest();
        assertEq(consumer.getRainfallByRequest(requestId), 0);
    }

    function test_GetRainfallByRequest_AfterFulfill() external {
        bytes32 requestId = _sendRequest();
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL_MM), "");
        assertEq(consumer.getRainfallByRequest(requestId), RAINFALL_MM);
    }

    function test_GetRequestStatus_None() external {
        assertEq(
            uint8(consumer.getRequestStatus(keccak256("nonexistent"))),
            uint8(RainfallFunctionsConsumer.RequestStatus.None)
        );
    }

    function test_IsRequestFulfilled_FalseBeforeFulfill() external {
        bytes32 requestId = _sendRequest();
        assertFalse(consumer.isRequestFulfilled(requestId));
    }

    function test_IsRequestFulfilled_TrueAfterFulfill() external {
        bytes32 requestId = _sendRequest();
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL_MM), "");
        assertTrue(consumer.isRequestFulfilled(requestId));
    }

    function test_IsRequestFulfilled_FalseAfterError() external {
        bytes32 requestId = _sendRequest();
        router.fulfillRequest(address(consumer), requestId, "", bytes("error"));
        assertFalse(consumer.isRequestFulfilled(requestId));
    }

    /// @notice Multiple sequential requests each get distinct IDs and correct metadata.
    function test_MultipleRequests_IndependentState() external {
        bytes32 id1 = consumer.sendRequest(SUB_ID, _validArgs());

        string[] memory args2 = new string[](4);
        args2[0] = "-33.8688"; // Sydney
        args2[1] = "151.2093";
        args2[2] = "2022-01-01";
        args2[3] = "2022-12-31";
        bytes32 id2 = consumer.sendRequest(SUB_ID, args2);

        assertTrue(id1 != id2, "Request IDs must be distinct");

        // Fulfill only the first
        router.fulfillRequest(address(consumer), id1, abi.encode(500), "");

        assertEq(uint8(consumer.requestStatus(id1)), uint8(RainfallFunctionsConsumer.RequestStatus.Fulfilled));
        assertEq(uint8(consumer.requestStatus(id2)), uint8(RainfallFunctionsConsumer.RequestStatus.Pending));
        assertEq(consumer.rainfallByRequest(id1), 500);
        assertEq(consumer.rainfallByRequest(id2), 0);

        // Second request's meta should still be Sydney
        RainfallFunctionsConsumer.RainfallRequest memory meta2 = consumer.getRequestMeta(id2);
        assertEq(meta2.latitude, "-33.8688");
    }
}

/**
 * @title RainfallCoordinatorTest
 * @notice Unit tests for RainfallCoordinator.
 *
 * COVERAGE TARGETS
 * ────────────────────────────────────────────────────────
 * requestRainfall
 *   • emits RainfallRequested
 *   • returns requestId from consumer
 *
 * view proxies
 *   • lastRainfallMM
 *   • getRainfallByRequest
 *   • getRequestStatus (raw uint8 mapping)
 *   • isRequestFulfilled
 *
 * acceptConsumerOwnership
 *   • calls through to consumer.acceptOwnership()
 */
contract RainfallCoordinatorTest is Test {
    /*//////////////////////////////////////////////////////////////
                             CONTRACTS
    //////////////////////////////////////////////////////////////*/

    RainfallFunctionsConsumer public consumer;
    RainfallCoordinator public coordinator;
    MockFunctionsRouter public router;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint64 constant SUB_ID = 99;
    string constant LAT = "51.5074";
    string constant LON = "-0.1278";
    string constant START_DATE = "2024-01-01";
    string constant END_DATE = "2024-06-30";
    uint256 constant RAINFALL = 789;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        // Deploy & patch router
        router = new MockFunctionsRouter();
        address hardcodedRouter = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
        vm.etch(hardcodedRouter, address(router).code);
        router = MockFunctionsRouter(hardcodedRouter);

        consumer = new RainfallFunctionsConsumer();
        coordinator = new RainfallCoordinator(address(consumer), SUB_ID);

        // Transfer consumer ownership to coordinator so it can call sendRequest
        consumer.transferOwnership(address(coordinator));
        coordinator.acceptConsumerOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                        requestRainfall
    //////////////////////////////////////////////////////////////*/

    function test_RequestRainfall_EmitsEvent() external {
        vm.expectEmit(false, false, false, true, address(coordinator));
        emit RainfallCoordinator.RainfallRequested(bytes32(0), LAT, LON, START_DATE, END_DATE);

        coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
    }

    function test_RequestRainfall_ReturnsRequestId() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        assertNotEq(requestId, bytes32(0), "requestId must be non-zero");
        // Status should be Pending on the underlying consumer
        assertEq(coordinator.getRequestStatus(requestId), 1 /* Pending */ );
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW PROXY — lastRainfallMM
    //////////////////////////////////////////////////////////////*/

    function test_LastRainfallMM_BeforeFulfill() external {
        coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        assertEq(coordinator.lastRainfallMM(), 0);
    }

    function test_LastRainfallMM_AfterFulfill() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL), "");
        assertEq(coordinator.lastRainfallMM(), RAINFALL);
    }

    /*//////////////////////////////////////////////////////////////
                     VIEW PROXY — getRainfallByRequest
    //////////////////////////////////////////////////////////////*/

    function test_GetRainfallByRequest_AfterFulfill() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL), "");
        assertEq(coordinator.getRainfallByRequest(requestId), RAINFALL);
    }

    function test_GetRainfallByRequest_Zero_BeforeFulfill() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        assertEq(coordinator.getRainfallByRequest(requestId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       VIEW PROXY — getRequestStatus
    //////////////////////////////////////////////////////////////*/

    function test_GetRequestStatus_PendingToFulfilled() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);

        assertEq(coordinator.getRequestStatus(requestId), 1 /* Pending */ );

        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL), "");

        assertEq(coordinator.getRequestStatus(requestId), 2 /* Fulfilled */ );
    }

    function test_GetRequestStatus_Failed() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        router.fulfillRequest(address(consumer), requestId, "", bytes("timeout"));
        assertEq(coordinator.getRequestStatus(requestId), 3 /* Failed */ );
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW PROXY — isRequestFulfilled
    //////////////////////////////////////////////////////////////*/

    function test_IsRequestFulfilled_TrueAfterSuccess() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        router.fulfillRequest(address(consumer), requestId, abi.encode(RAINFALL), "");
        assertTrue(coordinator.isRequestFulfilled(requestId));
    }

    function test_IsRequestFulfilled_FalseAfterError() external {
        bytes32 requestId = coordinator.requestRainfall(LAT, LON, START_DATE, END_DATE);
        router.fulfillRequest(address(consumer), requestId, "", bytes("err"));
        assertFalse(coordinator.isRequestFulfilled(requestId));
    }

    /*//////////////////////////////////////////////////////////////
                    acceptConsumerOwnership
    //////////////////////////////////////////////////////////////*/

    function test_AcceptConsumerOwnership_CoordinatorIsOwner() external {
        // Ownership was transferred in setUp — confirm coordinator owns consumer.
        assertEq(consumer.owner(), address(coordinator));
    }
}
