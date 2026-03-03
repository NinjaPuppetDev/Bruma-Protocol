// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";

/**
 * @title MockFunctionsRouter
 * @notice Minimal mock of Chainlink Functions router for unit tests.
 *         Captures the last request and lets tests manually fulfill it.
 */
contract MockFunctionsRouter {
    uint256 public constant MOCK_FEE = 0.1 ether; // not used here but kept for parity

    bytes32 public lastRequestId;
    bytes public lastCBOR;
    uint64 public lastSubscriptionId;
    uint32 public lastCallbackGasLimit;
    bytes32 public lastDonId;

    uint256 private _nonce;

    event RequestSent(bytes32 indexed requestId);

    /// @notice Called by FunctionsClient._sendRequest internally.
    function sendRequest(
        uint64 subscriptionId,
        bytes calldata data,
        uint16, // dataVersion (unused)
        uint32 callbackGasLimit,
        bytes32 donId
    ) external returns (bytes32 requestId) {
        requestId = keccak256(abi.encodePacked(msg.sender, block.number, _nonce++));

        lastRequestId = requestId;
        lastCBOR = data;
        lastSubscriptionId = subscriptionId;
        lastCallbackGasLimit = callbackGasLimit;
        lastDonId = donId;

        emit RequestSent(requestId);
    }

    /// @notice Simulate a successful Chainlink Functions response.
    function fulfillRequest(address client, bytes32 requestId, bytes calldata response, bytes calldata err) external {
        FunctionsClient(client).handleOracleFulfillment(requestId, response, err);
    }
}

/**
 * @title MockFunctionsClient
 * @notice Thin wrapper so we can deploy FunctionsClient-derived contracts
 *         pointing at our MockFunctionsRouter.
 */
// (Not needed — each consumer already accepts a router address in its constructor.)
