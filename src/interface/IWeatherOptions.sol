// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @notice Wrapped ETH interface
 */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title IRainfallCoordinator
 * @notice Chainlink Functions coordinator for rainfall data requests
 */
interface IRainfallCoordinator {
    function requestRainfall(
        string calldata lat,
        string calldata lon,
        string calldata startDate,
        string calldata endDate
    ) external returns (bytes32 requestId);
}

/**
 * @title IRainfallConsumer
 * @notice Consumer interface for rainfall data
 */
interface IRainfallConsumer {
    function rainfallByRequest(bytes32 requestId) external view returns (uint256);
    function requestStatus(bytes32 requestId) external view returns (uint8);
}

/**
 * @title IPremiumCalculatorCoordinator
 * @notice Chainlink Functions coordinator for premium calculation
 */
interface IPremiumCalculatorCoordinator {
    function requestPremium(
        string calldata latitude,
        string calldata longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    ) external returns (bytes32 requestId);
}

/**
 * @title IPremiumCalculatorConsumer
 * @notice Consumer interface for premium calculation results
 */
interface IPremiumCalculatorConsumer {
    function premiumByRequest(bytes32 requestId) external view returns (uint256);
    function requestStatus(bytes32 requestId) external view returns (uint8);
    function isRequestFulfilled(bytes32 requestId) external view returns (bool);
}

/**
 * @title IWeatherOptionsVault
 * @notice Vault interface for managing collateral and liquidity
 */
interface IWeatherOptionsVault {
    function lockCollateral(uint256 amount, uint256 optionId, bytes32 locationKey) external returns (bool);
    function releaseCollateral(uint256 amount, uint256 payout, uint256 optionId, bytes32 locationKey) external;
    function receivePremium(uint256 amount, uint256 optionId) external;
    function canUnderwrite(uint256 amount, bytes32 locationKey) external view returns (bool);
    function getPremiumMultiplier() external view returns (uint256);
}
