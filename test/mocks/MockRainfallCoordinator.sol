// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockRainfallCoordinator
 * @notice Mock coordinator for testing - bypasses Chainlink Functions
 * @dev Simulates request/response cycle without external dependencies
 */
contract MockRainfallCoordinator {
    // Mock consumer interface (simplified)
    struct MockConsumer {
        mapping(bytes32 => uint256) rainfallByRequest;
        mapping(bytes32 => uint8) requestStatus;
    }

    MockConsumer private _mockConsumer;
    uint64 public immutable subscriptionId;
    uint256 private _nonce;

    event RainfallRequested(bytes32 indexed requestId, string lat, string lon, string startDate, string endDate);

    constructor(address, /* _consumer */ uint64 _subscriptionId) {
        subscriptionId = _subscriptionId;
    }

    /**
     * @notice Mock ownership acceptance (no-op)
     */
    function acceptConsumerOwnership() external {
        // No-op for mock
    }

    /**
     * @notice Mock rainfall request - immediately returns a request ID
     * @dev In tests, you'll manually fulfill this with mockFulfillRequest()
     */
    function requestRainfall(
        string calldata lat,
        string calldata lon,
        string calldata startDate,
        string calldata endDate
    ) external returns (bytes32 requestId) {
        // Generate deterministic request ID
        requestId = keccak256(abi.encodePacked(block.timestamp, msg.sender, _nonce++, lat, lon, startDate, endDate));

        // Mark as pending
        _mockConsumer.requestStatus[requestId] = 1; // Pending

        emit RainfallRequested(requestId, lat, lon, startDate, endDate);
        return requestId;
    }

    /**
     * @notice Mock fulfillment function for tests
     * @dev Call this in your tests to simulate oracle response
     */
    function mockFulfillRequest(bytes32 requestId, uint256 rainfall) external {
        require(_mockConsumer.requestStatus[requestId] == 1, "Not pending");

        _mockConsumer.rainfallByRequest[requestId] = rainfall;
        _mockConsumer.requestStatus[requestId] = 2; // Fulfilled
    }

    /**
     * @notice Get rainfall by request ID
     */
    function rainfallByRequest(bytes32 requestId) external view returns (uint256) {
        return _mockConsumer.rainfallByRequest[requestId];
    }

    /**
     * @notice Get request status
     */
    function requestStatus(bytes32 requestId) external view returns (uint8) {
        return _mockConsumer.requestStatus[requestId];
    }

    /**
     * @notice Mock last rainfall (not used in current flow)
     */
    function lastRainfallMM() external pure returns (uint256) {
        return 0;
    }

    /**
     * @notice Check if request is fulfilled
     */
    function isRequestFulfilled(bytes32 requestId) external view returns (bool) {
        return _mockConsumer.requestStatus[requestId] == 2;
    }
}
