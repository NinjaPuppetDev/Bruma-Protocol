// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockWeatherOptionsVault
 * @notice Mock vault for testing WeatherOptionV3
 * @dev Simulates vault behavior without ERC4626 complexity
 */
contract MockWeatherOptionsVault {
    // Track locked collateral
    mapping(uint256 => uint256) public lockedByOption;
    mapping(bytes32 => uint256) public locationExposure;

    uint256 public totalLocked;
    uint256 public totalPremiumsEarned;
    uint256 public totalAssets;

    // Risk parameters
    uint256 public maxUtilizationBps = 8000; // 80%
    uint256 public maxLocationExposureBps = 2000; // 20%

    // For testing: control whether vault can underwrite
    bool public canUnderwriteResponse = true;
    uint256 public premiumMultiplier = 10000; // 1.0x default

    event CollateralLocked(uint256 amount, uint256 optionId, bytes32 locationKey);
    event CollateralReleased(uint256 amount, uint256 payout, uint256 optionId);
    event PremiumReceived(uint256 amount, uint256 optionId);

    /**
     * @notice Initialize vault with some assets
     */
    constructor() {
        totalAssets = 100 ether; // Start with 100 ETH
    }

    /**
     * @notice Add funds to vault (for testing)
     */
    function addAssets(uint256 amount) external {
        totalAssets += amount;
    }

    /**
     * @notice Lock collateral for an option
     */
    function lockCollateral(uint256 amount, uint256 optionId, bytes32 locationKey) external returns (bool) {
        require(canUnderwriteResponse, "Vault cannot underwrite");

        lockedByOption[optionId] = amount;
        totalLocked += amount;
        locationExposure[locationKey] += amount;

        emit CollateralLocked(amount, optionId, locationKey);
        return true;
    }

    /**
     * @notice Release collateral after settlement
     */
    function releaseCollateral(uint256 amount, uint256 payout, uint256 optionId, bytes32 locationKey) external {
        require(lockedByOption[optionId] == amount, "Amount mismatch");

        lockedByOption[optionId] = 0;
        totalLocked -= amount;
        locationExposure[locationKey] -= amount;

        if (payout > 0) {
            payable(msg.sender).transfer(payout);
        }

        emit CollateralReleased(amount, payout, optionId);
    }

    /**
     * @notice Record premium received
     */
    function receivePremium(uint256 amount, uint256 optionId) external payable {
        totalPremiumsEarned += amount;
        emit PremiumReceived(amount, optionId);
    }

    /**
     * @notice Check if vault can underwrite
     */
    function canUnderwrite(uint256 amount, bytes32 locationKey) external view returns (bool) {
        if (!canUnderwriteResponse) return false;

        // Check utilization
        uint256 newUtil = ((totalLocked + amount) * 10000) / totalAssets;
        if (newUtil > maxUtilizationBps) return false;

        // Check location exposure
        uint256 newLocationExp = (locationExposure[locationKey] + amount) * 10000 / totalAssets;
        if (newLocationExp > maxLocationExposureBps) return false;

        return true;
    }

    /**
     * @notice Get premium multiplier based on utilization
     */
    function getPremiumMultiplier() external view returns (uint256) {
        return premiumMultiplier;
    }

    /**
     * @notice Get available liquidity
     */
    function availableLiquidity() external view returns (uint256) {
        if (totalLocked >= totalAssets) return 0;
        return totalAssets - totalLocked;
    }

    /**
     * @notice Get current utilization
     */
    function utilizationRate() external view returns (uint256) {
        if (totalAssets == 0) return 0;
        return (totalLocked * 10000) / totalAssets;
    }

    // ===== Test Helpers =====

    /**
     * @notice Set whether vault can underwrite (for testing failure cases)
     */
    function setCanUnderwrite(bool _canUnderwrite) external {
        canUnderwriteResponse = _canUnderwrite;
    }

    /**
     * @notice Set premium multiplier (for testing pricing)
     */
    function setPremiumMultiplier(uint256 _multiplier) external {
        premiumMultiplier = _multiplier;
    }

    /**
     * @notice Set utilization limits
     */
    function setUtilizationLimits(uint256 _maxBps, uint256 _maxLocationBps) external {
        maxUtilizationBps = _maxBps;
        maxLocationExposureBps = _maxLocationBps;
    }

    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}
