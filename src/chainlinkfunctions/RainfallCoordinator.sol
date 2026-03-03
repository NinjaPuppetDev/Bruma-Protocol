// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RainfallFunctionsConsumer} from "./RainfallConsumer.sol";

/**
 * @title RainfallCoordinator
 * @notice Orchestrates rainfall data requests through Chainlink Functions
 * @dev Acts as the owner of RainfallFunctionsConsumer to manage requests
 */
contract RainfallCoordinator {
    RainfallFunctionsConsumer public immutable consumer;
    uint64 public immutable subscriptionId;

    event RainfallRequested(bytes32 indexed requestId, string lat, string lon, string startDate, string endDate);

    constructor(address _consumer, uint64 _subscriptionId) {
        consumer = RainfallFunctionsConsumer(_consumer);
        subscriptionId = _subscriptionId;
    }

    /**
     * @notice Accept ownership of the consumer contract
     * @dev Call this after transferring ownership to the coordinator
     */
    function acceptConsumerOwnership() external {
        consumer.acceptOwnership();
    }

    /**
     * @notice Triggers a Chainlink Functions rainfall request
     * @dev Coordinator MUST be owner of the consumer
     * @param lat Latitude as string (e.g., "40.7128")
     * @param lon Longitude as string (e.g., "-74.0060" or "74.0060")
     * @param startDate Date string in YYYY-MM-DD format
     * @param endDate Date string in YYYY-MM-DD format
     * @return requestId The Chainlink request ID for tracking
     */
    function requestRainfall(
        string calldata lat,
        string calldata lon,
        string calldata startDate,
        string calldata endDate
    ) external returns (bytes32 requestId) {
        string[] memory args = new string[](4);
        args[0] = lat;
        args[1] = lon;
        args[2] = startDate;
        args[3] = endDate;

        requestId = consumer.sendRequest(subscriptionId, args);

        emit RainfallRequested(requestId, lat, lon, startDate, endDate);
    }

    /**
     * @notice Reads the last fulfilled rainfall value (global)
     * @dev This is for backwards compatibility - prefer getRainfallByRequest
     * @return The most recent rainfall reading in mm
     */
    function lastRainfallMM() external view returns (uint256) {
        return consumer.lastRainfallMM();
    }

    /**
     * @notice Get rainfall data for a specific request
     * @param requestId The Chainlink request ID
     * @return rainfall The total rainfall in mm for that request
     */
    function getRainfallByRequest(bytes32 requestId) external view returns (uint256 rainfall) {
        return consumer.rainfallByRequest(requestId);
    }

    /**
     * @notice Get the status of a specific request
     * @param requestId The Chainlink request ID
     * @return status 0=None, 1=Pending, 2=Fulfilled, 3=Failed
     */
    function getRequestStatus(bytes32 requestId) external view returns (uint8 status) {
        return uint8(consumer.requestStatus(requestId));
    }

    /**
     * @notice Check if a request has been fulfilled
     * @param requestId The Chainlink request ID
     * @return fulfilled True if the request is complete
     */
    function isRequestFulfilled(bytes32 requestId) external view returns (bool fulfilled) {
        return consumer.isRequestFulfilled(requestId);
    }
}
