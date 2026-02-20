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
interface IBrumaVault {
    function lockCollateral(uint256 amount, uint256 optionId, bytes32 locationKey) external returns (bool);
    function releaseCollateral(uint256 amount, uint256 payout, uint256 optionId, bytes32 locationKey) external;
    function receivePremium(uint256 amount, uint256 optionId) external;
    function canUnderwrite(uint256 amount, bytes32 locationKey) external view returns (bool);
    function getPremiumMultiplier() external view returns (uint256);
}

/**
 * @title IBruma
 * @notice Interface for the Bruma weather options contract.
 *         Used by BrumaCCIPEscrow to claim payouts on behalf of cross-chain buyers.
 */
interface IBruma {

    // ── Enums ──────────────────────────────────────────────────────────────────

    enum OptionType { Call, Put }

    enum OptionStatus { Active, Expired, Settling, Settled }

    // ── Structs ────────────────────────────────────────────────────────────────

    struct OptionTerms {
        OptionType optionType;
        string latitude;
        string longitude;
        uint256 startDate;
        uint256 expiryDate;
        uint256 strikeMM;
        uint256 spreadMM;
        uint256 notional;
        uint256 premium;
    }

    struct OptionState {
        OptionStatus status;
        address buyer;
        uint256 createdAt;
        bytes32 requestId;
        bytes32 locationKey;
        uint256 actualRainfall;
        uint256 finalPayout;
        address ownerAtSettlement;
    }

    struct Option {
        uint256 tokenId;
        OptionTerms terms;
        OptionState state;
    }

    // ── Settlement ─────────────────────────────────────────────────────────────

    /**
     * @notice Claim ETH payout for a settled option.
     * @dev msg.sender must equal ownerAtSettlement.
     *      When called by BrumaCCIPEscrow, the escrow IS ownerAtSettlement
     *      because it held the NFT when requestSettlement() was called.
     */
    function claimPayout(uint256 tokenId) external;

    // ── Views ──────────────────────────────────────────────────────────────────

    /**
     * @notice Get the pending claimable payout for an option.
     * @dev Returns 0 if option is out-of-the-money or already claimed.
     */
    function pendingPayouts(uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get full option data including terms and state.
     */
    function getOption(uint256 tokenId) external view returns (Option memory);

    /**
     * @notice Get all active option token IDs.
     * @dev Used by CRE workflow to enumerate options for risk monitoring.
     */
    function getActiveOptions() external view returns (uint256[] memory);

    /**
     * @notice Check whether an option has passed its expiry date.
     */
    function isExpired(uint256 tokenId) external view returns (bool);

    /**
     * @notice Simulate payout for a hypothetical rainfall amount.
     * @dev Used by CRE risk workflow to compute expected loss under forecast scenarios.
     */
    function simulatePayout(uint256 tokenId, uint256 rainfallMM) external view returns (uint256);
}

/**
 * @title IBrumaCCIPEscrow
 * @notice Interface for individual cross-chain escrow instances.
 *         Used by the CRE workflow to trigger claimAndBridge() after settlement.
 */
interface IBrumaCCIPEscrow {

    struct BridgeReceipt {
        bytes32 messageId;
        uint256 amount;
        uint256 timestamp;
        uint64 destinationChain;
        address destinationReceiver;
    }

    /**
     * @notice Claim payout from Bruma and bridge to buyer's native chain.
     * @dev Callable by: escrow owner, CRE workflow (authorizedCaller),
     *      or anyone after PERMISSIONLESS_DELAY.
     */
    function claimAndBridge(uint256 tokenId) external;

    /**
     * @notice Permissionless fallback after 7-day delay.
     */
    function claimAndBridgePermissionless(uint256 tokenId, uint256 settledAt) external;

    /**
     * @notice Estimate CCIP fee for a given payout amount.
     */
    function estimateCCIPFee(uint256 payoutAmount) external view returns (uint256 linkFee);

    /**
     * @notice Whether a tokenId has been claimed.
     */
    function claimed(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get bridge receipt for a completed cross-chain payout.
     */
    function getBridgeReceipt(uint256 tokenId) external view returns (BridgeReceipt memory);

    /**
     * @notice The CRE-authorized caller address.
     */
    function authorizedCaller() external view returns (address);

    /**
     * @notice The escrow owner (buyer's Ethereum address).
     */
    function owner() external view returns (address);

    /**
     * @notice CCIP chain selector for destination.
     */
    function destinationChainSelector() external view returns (uint64);

    /**
     * @notice Buyer's address on destination chain.
     */
    function destinationReceiver() external view returns (address);
}

/**
 * @title IBrumaCCIPEscrowFactory
 * @notice Interface for the escrow factory.
 *         CRE workflow queries EscrowDeployed events to build its token→escrow registry.
 */
interface IBrumaCCIPEscrowFactory {
    event EscrowDeployed(
        address indexed escrow,
        address indexed owner,
        uint64 destinationChainSelector,
        address destinationReceiver
    );

    function deployEscrow(
        uint64 destinationChainSelector,
        address destinationReceiver
    ) external returns (address escrow);

    function bruma() external view returns (address);
    function authorizedCaller() external view returns (address);
}