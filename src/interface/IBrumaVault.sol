// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBrumaVault
 * @notice Interface for the BrumaVault ERC-4626 liquidity pool.
 *
 * Consumers:
 *   - Bruma.sol         — lockCollateral / releaseCollateral / receivePremium / canUnderwrite
 *   - ReinsurancePool   — receiveReinsuranceDraw (accounting notification)
 *   - CRE onRiskCron    — getMetrics / setUtilizationLimits / receiveReinsuranceDraw
 */
interface IBrumaVault {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultMetrics {
        uint256 tvl;
        uint256 locked;
        uint256 available;
        uint256 utilizationBps;
        uint256 premiumsEarned;
        uint256 totalPayouts;
        int256 netPnL;
        uint256 reinsuranceReceived;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PremiumReceived(uint256 indexed optionId, uint256 amount);
    event ReinsuranceYieldRouted(uint256 indexed optionId, uint256 yieldAmount);
    event PayoutMade(uint256 indexed optionId, uint256 amount);
    event CollateralLocked(uint256 indexed optionId, uint256 amount, bytes32 locationKey);
    event CollateralReleased(uint256 indexed optionId, uint256 amount, uint256 payout, bytes32 locationKey);
    event UtilizationLimitsUpdated(uint256 newMaxBps, uint256 newTargetBps);
    event LocationExposureUpdated(bytes32 indexed locationKey, uint256 newExposure);
    event ReinsurancePoolUpdated(address indexed oldPool, address indexed newPool);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event ReinsuranceDrawReceived(uint256 amount);
    event ReinsuranceYieldBpsUpdated(uint256 oldBps, uint256 newBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedCaller();
    error UnauthorizedGuardian();
    error UtilizationTooHigh();
    error InsufficientLiquidity();
    error LocationExposureTooHigh();
    error ZeroAmount();
    error InvalidAddress();
    error InvalidLimits();

    /*//////////////////////////////////////////////////////////////
                        WEATHER OPTIONS OPERATIONS
                        (callable only by weatherOptions)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lock collateral for an option being written.
     * @param amount      WETH amount to lock (= spreadMM * notional)
     * @param optionId    Token ID of the option NFT
     * @param locationKey Normalized keccak256(lat, lon) for exposure tracking
     * @return success    Always true — reverts on failure
     */
    function lockCollateral(uint256 amount, uint256 optionId, bytes32 locationKey) external returns (bool success);

    /**
     * @notice Release collateral after settlement.
     * @dev Transfers `payout` WETH to msg.sender (WeatherOptions contract).
     * @param amount      Originally locked amount
     * @param payout      Actual payout owed (0 if OTM)
     * @param optionId    Token ID of the option NFT
     * @param locationKey Normalized keccak256(lat, lon)
     */
    function releaseCollateral(uint256 amount, uint256 payout, uint256 optionId, bytes32 locationKey) external;

    /**
     * @notice Notify vault that premium WETH has arrived and route yield split.
     * @dev WETH is transferred to the vault before this is called.
     *      If reinsurancePool is set, routes reinsuranceYieldBps of amount
     *      to the reinsurance pool as reinsurer yield.
     * @param amount   Full premium amount in WETH (wei)
     * @param optionId Token ID of the option NFT
     */
    function receivePremium(uint256 amount, uint256 optionId) external;

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN OPERATIONS
                        (callable only by guardian)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tighten or relax vault utilization limits.
     * @dev Called by CRE guardian in response to risk tier changes.
     *      Guardian can only call — not owner — to keep CRE autonomous.
     * @param newMaxBps    New maximum utilization in basis points
     * @param newTargetBps New target utilization in basis points
     */
    function setUtilizationLimits(uint256 newMaxBps, uint256 newTargetBps) external;

    /**
     * @notice Accounting notification after ReinsurancePool draws capital here.
     * @dev WETH arrives via ReinsurancePool.fundPrimaryVault() before this call.
     *      This function only updates accounting state and emits an event.
     * @param amount WETH amount that was transferred
     */
    function receiveReinsuranceDraw(uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                        OWNER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setWeatherOptions(address weatherOptions) external;
    function setGuardian(address guardian) external;
    function setReinsurancePool(address pool) external;
    function setReinsuranceYieldBps(uint256 bps) external;
    function setMaxLocationExposure(uint256 maxBps) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function availableLiquidity() external view returns (uint256);
    function utilizationRate() external view returns (uint256);
    function getPremiumMultiplier() external view returns (uint256 multiplierBps);
    function getMetrics() external view returns (VaultMetrics memory);

    /**
     * @notice Check whether the vault can underwrite a new position.
     * @param amount      Max payout of the new option
     * @param locationKey Normalized location hash
     */
    function canUnderwrite(uint256 amount, bytes32 locationKey) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                            STATE GETTERS
    //////////////////////////////////////////////////////////////*/

    function weatherOptions() external view returns (address);
    function guardian() external view returns (address);
    function reinsurancePool() external view returns (address);
    function reinsuranceYieldBps() external view returns (uint256);
    function maxUtilizationBps() external view returns (uint256);
    function targetUtilizationBps() external view returns (uint256);
    function maxLocationExposureBps() external view returns (uint256);
    function totalLocked() external view returns (uint256);
    function totalPremiumsEarned() external view returns (uint256);
    function totalPayouts() external view returns (uint256);
    function totalReinsuranceReceived() external view returns (uint256);
    function locationExposure(bytes32 locationKey) external view returns (uint256);
}
