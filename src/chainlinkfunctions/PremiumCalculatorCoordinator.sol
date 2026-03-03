// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

interface IPremiumCalculatorConsumer {
    function acceptOwnership() external;
    function requestPremium(
        string calldata latitude,
        string calldata longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    ) external returns (bytes32);
    function premiumByRequest(bytes32 requestId) external view returns (uint256);
    function requestStatus(bytes32 requestId) external view returns (uint8);
    function isRequestFulfilled(bytes32 requestId) external view returns (bool);
}

/**
 * @title PremiumCalculatorCoordinator
 * @notice Coordinates premium calculation requests through Chainlink Functions
 * @dev Acts as the owner of PremiumCalculatorConsumer to manage requests
 */
contract PremiumCalculatorCoordinator is ConfirmedOwner {
    IPremiumCalculatorConsumer public immutable consumer;
    address public weatherOptions;

    event PremiumRequested(
        bytes32 indexed requestId,
        string latitude,
        string longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    );

    error OnlyWeatherOptions();

    modifier onlyWeatherOptions() {
        if (msg.sender != weatherOptions) revert OnlyWeatherOptions();
        _;
    }

    constructor(address _consumer) ConfirmedOwner(msg.sender) {
        consumer = IPremiumCalculatorConsumer(_consumer);
    }

    /**
     * @notice Accept ownership of the consumer contract
     * @dev Call this after transferring ownership to the coordinator
     */
    function acceptConsumerOwnership() external onlyOwner {
        consumer.acceptOwnership();
    }

    /**
     * @notice Set the authorized WeatherOptions contract
     */
    function setWeatherOptions(address _weatherOptions) external onlyOwner {
        weatherOptions = _weatherOptions;
    }

    /**
     * @notice Request premium calculation via Chainlink Functions
     * @dev Called by WeatherOptionV3 contract
     */
    function requestPremium(
        string calldata latitude,
        string calldata longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    ) external onlyWeatherOptions returns (bytes32 requestId) {
        // Forward request to consumer
        requestId = consumer.requestPremium(latitude, longitude, strikeMM, spreadMM, durationDays, notionalWei);

        emit PremiumRequested(requestId, latitude, longitude, strikeMM, spreadMM, durationDays, notionalWei);

        return requestId;
    }
}
