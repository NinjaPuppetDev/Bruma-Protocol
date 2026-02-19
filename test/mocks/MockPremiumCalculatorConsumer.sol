// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

/**
 * @title MockPremiumCalculatorConsumer
 * @notice Mock consumer for testing - bypasses Chainlink Functions
 * @dev Simulates premium calculation without external dependencies
 */
contract MockPremiumCalculatorConsumer is ConfirmedOwner {
    enum RequestStatus {
        None,
        Pending,
        Fulfilled,
        Failed
    }

    struct PremiumRequest {
        string latitude;
        string longitude;
        uint256 strikeMM;
        uint256 spreadMM;
        uint256 durationDays;
        uint256 notionalWei;
    }

    mapping(bytes32 => RequestStatus) public requestStatus;
    mapping(bytes32 => uint256) public premiumByRequest;
    mapping(bytes32 => PremiumRequest) public requestMeta;

    bytes32 public lastRequestId;
    uint256 public lastPremium;
    uint256 private _nonce;

    event PremiumRequested(
        bytes32 indexed requestId,
        string latitude,
        string longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    );

    event PremiumFulfilled(bytes32 indexed requestId, uint256 premiumWei);

    constructor() ConfirmedOwner(msg.sender) {}

    /**
     * @notice Mock premium request - immediately returns a request ID
     * @dev In tests, you'll manually fulfill this with mockFulfillRequest()
     */
    function requestPremium(
        string calldata latitude,
        string calldata longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    ) external onlyOwner returns (bytes32 requestId) {
        // Generate deterministic request ID
        requestId = keccak256(
            abi.encodePacked(
                block.timestamp,
                msg.sender,
                _nonce++,
                latitude,
                longitude,
                strikeMM,
                spreadMM,
                durationDays,
                notionalWei
            )
        );

        // Mark as pending
        requestStatus[requestId] = RequestStatus.Pending;
        lastRequestId = requestId;

        // Store metadata
        requestMeta[requestId] = PremiumRequest({
            latitude: latitude,
            longitude: longitude,
            strikeMM: strikeMM,
            spreadMM: spreadMM,
            durationDays: durationDays,
            notionalWei: notionalWei
        });

        emit PremiumRequested(requestId, latitude, longitude, strikeMM, spreadMM, durationDays, notionalWei);

        return requestId;
    }

    /**
     * @notice Mock fulfillment function for tests
     * @dev Call this in your tests to simulate Chainlink Functions response
     */
    function mockFulfillRequest(bytes32 requestId, uint256 premium) external {
        require(requestStatus[requestId] == RequestStatus.Pending, "Not pending");

        premiumByRequest[requestId] = premium;
        lastPremium = premium;
        requestStatus[requestId] = RequestStatus.Fulfilled;

        emit PremiumFulfilled(requestId, premium);
    }

    /**
     * @notice Get premium by request ID
     */
    function getPremiumByRequest(bytes32 requestId) external view returns (uint256) {
        return premiumByRequest[requestId];
    }

    /**
     * @notice Get request status
     */
    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus) {
        return requestStatus[requestId];
    }

    /**
     * @notice Check if request is fulfilled
     */
    function isRequestFulfilled(bytes32 requestId) external view returns (bool) {
        return requestStatus[requestId] == RequestStatus.Fulfilled;
    }

    /**
     * @notice Get request metadata
     */
    function getRequestMeta(bytes32 requestId) external view returns (PremiumRequest memory) {
        return requestMeta[requestId];
    }
}
