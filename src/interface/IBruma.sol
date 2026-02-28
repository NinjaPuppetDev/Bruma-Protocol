// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBrumaVault} from "./IBrumaVault.sol";

// Re-export IBrumaVault so existing consumers that imported it from here
// don't break — they can still do `import { IBrumaVault } from "./IBruma.sol"`
// but the canonical definition lives in IBrumaVault.sol.
// (Solidity allows re-exporting via import; no duplicate definition needed.)

/**
 * @title IWETH
 * @notice Wrapped ETH interface
 */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
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
 * @notice Consumer interface for rainfall oracle data
 */
interface IRainfallConsumer {
    function rainfallByRequest(bytes32 requestId) external view returns (uint256 rainfallMM);
    function requestStatus(bytes32 requestId) external view returns (uint8 status);
    // 0 = pending, 1 = failed, 2 = fulfilled
}

/**
 * @title IPremiumCalculatorCoordinator
 * @notice Chainlink Functions coordinator for option premium calculation
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
    function premiumByRequest(bytes32 requestId) external view returns (uint256 premiumWei);
    function requestStatus(bytes32 requestId) external view returns (uint8 status);
    function isRequestFulfilled(bytes32 requestId) external view returns (bool);
}

/**
 * @title IBruma
 * @notice Interface for the Bruma weather options contract.
 *
 * Consumers:
 *   - BrumaCCIPEscrow  — claimPayout / pendingPayouts / getOption
 *   - CRE onRiskCron   — getActiveOptions / getOption / simulatePayout / isExpired
 */
interface IBruma {
    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    enum OptionType {
        Call, // Pays out when rainfall > strike
        Put // Pays out when rainfall < strike

    }

    enum OptionStatus {
        Active, // Live, can be settled at expiry
        Expired, // Deprecated — use Settling
        Settling, // Settlement requested, awaiting oracle
        Settled // Final payout recorded

    }

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct OptionTerms {
        OptionType optionType;
        string latitude;
        string longitude;
        uint256 startDate; // Unix timestamp
        uint256 expiryDate; // Unix timestamp
        uint256 strikeMM; // Strike in millimeters
        uint256 spreadMM; // Max payout range in millimeters
        uint256 notional; // Payout per mm (wei)
        uint256 premium; // Premium paid (wei)
    }

    struct OptionState {
        OptionStatus status;
        address buyer;
        uint256 createdAt;
        bytes32 requestId; // Rainfall oracle request ID
        bytes32 locationKey; // keccak256(normalizedLat, normalizedLon)
        uint256 actualRainfall; // Measured rainfall (mm)
        uint256 finalPayout; // Calculated payout (wei)
        address ownerAtSettlement; // Snapshot taken at requestSettlement()
    }

    struct Option {
        uint256 tokenId;
        OptionTerms terms;
        OptionState state;
    }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PremiumQuoteRequested(
        bytes32 indexed requestId,
        address indexed buyer,
        string latitude,
        string longitude,
        uint256 strikeMM,
        uint256 spreadMM
    );

    event PremiumQuoteFulfilled(bytes32 indexed requestId, uint256 premium);

    event OptionCreated(
        uint256 indexed tokenId,
        address indexed buyer,
        OptionType optionType,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 premium,
        uint256 collateral
    );

    event SettlementRequested(
        uint256 indexed tokenId,
        bytes32 indexed requestId,
        address ownerSnapshot,
        string latitude,
        string longitude,
        string startDate,
        string endDate
    );

    event OptionSettled(uint256 indexed tokenId, uint256 actualRainfall, uint256 payout, address beneficiary);

    event PayoutClaimed(uint256 indexed tokenId, address indexed claimer, uint256 amount);

    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event MinimumRequirementsUpdated(uint256 minPremium, uint256 minNotional);
    event AutoClaimToggled(bool enabled);
    event AutoClaimFailed(uint256 indexed tokenId, bytes reason);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidDates();
    error InsufficientPremium();
    error VaultCannotUnderwrite();
    error OptionNotExpired();
    error InvalidOptionStatus();
    error SettlementNotRequested();
    error OracleNotFulfilled();
    error InvalidSpread();
    error InvalidNotional();
    error VaultNotSet();
    error QuoteNotFulfilled();
    error NotYourQuote();
    error QuoteExpired();
    error InvalidPremium();
    error FeeTooHigh();
    error TransferLocked();
    error NoPendingPayout();
    error PremiumBelowMinimum();
    error NotionalBelowMinimum();
    error NotBeneficiary();

    /*//////////////////////////////////////////////////////////////
                         STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Parameters for requesting a premium quote.
     * @dev Preserved as a struct for frontend ABI compatibility.
     *      The function selector keccak256("requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))")
     *      must not change between deployments.
     */
    struct CreateOptionParams {
        OptionType optionType;
        string latitude;
        string longitude;
        uint256 startDate;
        uint256 expiryDate;
        uint256 strikeMM;
        uint256 spreadMM;
        uint256 notional;
    }

    /*//////////////////////////////////////////////////////////////
                         OPTION LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Step 1 — request a premium quote from Chainlink Functions.
     * @dev Stores params against the returned requestId.
     *      Buyer must call createOptionWithQuote() within QUOTE_VALIDITY (1hr).
     * @param p Option parameters struct — kept as struct to preserve ABI selector.
     */
    function requestPremiumQuote(CreateOptionParams calldata p) external returns (bytes32 requestId);

    /**
     * @notice Step 2 — create option after Chainlink fulfills the premium quote.
     * @dev msg.value must cover premium + protocol fee.
     *      Mints an ERC-721 to msg.sender.
     * @return tokenId The newly minted option NFT token ID
     */
    function createOptionWithQuote(bytes32 quoteRequestId) external payable returns (uint256 tokenId);

    /**
     * @notice Trigger settlement by requesting rainfall data from oracle.
     * @dev Callable by anyone once block.timestamp >= expiryDate.
     *      Snapshots ownerAtSettlement = ownerOf(tokenId) at call time.
     */
    function requestSettlement(uint256 tokenId) external returns (bytes32 requestId);

    /**
     * @notice Finalize settlement after oracle fulfills rainfall request.
     * @dev Callable by anyone once oracle status == 2 (fulfilled).
     *      Releases collateral from vault and records pendingPayout.
     */
    function settle(uint256 tokenId) external;

    /**
     * @notice Claim ETH payout for a settled option.
     * @dev msg.sender must equal ownerAtSettlement.
     *      When called by BrumaCCIPEscrow, the escrow IS ownerAtSettlement
     *      because it held the NFT when requestSettlement() was called.
     */
    function claimPayout(uint256 tokenId) external;

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get complete option data.
     */
    function getOption(uint256 tokenId) external view returns (Option memory);

    /**
     * @notice Get all currently active option token IDs.
     * @dev Used by CRE onRiskCron to enumerate for risk monitoring.
     */
    function getActiveOptions() external view returns (uint256[] memory);

    /**
     * @notice Simulate payout for a hypothetical rainfall amount.
     * @dev Used by CRE to compute expected loss under forecast scenarios.
     */
    function simulatePayout(uint256 tokenId, uint256 rainfallMM) external view returns (uint256 payout);

    /**
     * @notice Check whether an option has passed its expiry date.
     */
    function isExpired(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get the pending claimable payout for a settled option.
     * @dev Returns 0 if OTM or already claimed.
     */
    function pendingPayouts(uint256 tokenId) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                         STATE GETTERS
    //////////////////////////////////////////////////////////////*/

    function vault() external view returns (IBrumaVault);
    function protocolFeeBps() external view returns (uint256);
    function minPremium() external view returns (uint256);
    function minNotional() external view returns (uint256);
    function autoClaimEnabled() external view returns (bool);
    function collectedFees() external view returns (uint256);
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
     * @notice Claim payout from Bruma and bridge WETH to the buyer's native chain.
     * @dev Callable by: escrow owner, authorizedCaller (CRE guardian),
     *      or permissionlessly after PERMISSIONLESS_DELAY (7 days).
     */
    function claimAndBridge(uint256 tokenId) external;

    /**
     * @notice Permissionless fallback — callable by anyone after 7-day delay.
     * @param settledAt Timestamp when the option was settled (used to verify delay)
     */
    function claimAndBridgePermissionless(uint256 tokenId, uint256 settledAt) external;

    /**
     * @notice Estimate CCIP fee for bridging a given payout amount.
     */
    function estimateCCIPFee(uint256 payoutAmount) external view returns (uint256 linkFee);

    /**
     * @notice Whether a tokenId has been claimed and bridged.
     */
    function claimed(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get bridge receipt for a completed cross-chain payout.
     */
    function getBridgeReceipt(uint256 tokenId) external view returns (BridgeReceipt memory);

    function authorizedCaller() external view returns (address);
    function owner() external view returns (address);
    function destinationChainSelector() external view returns (uint64);
    function destinationReceiver() external view returns (address);
}

/**
 * @title IBrumaCCIPEscrowFactory
 * @notice Interface for the escrow factory.
 *         CRE workflow queries EscrowDeployed events to build its token→escrow registry.
 */
interface IBrumaCCIPEscrowFactory {
    event EscrowDeployed(
        address indexed escrow, address indexed owner, uint64 destinationChainSelector, address destinationReceiver
    );

    function deployEscrow(uint64 destinationChainSelector, address destinationReceiver)
        external
        returns (address escrow);

    function bruma() external view returns (address);
    function authorizedCaller() external view returns (address);
}

event ReinsuranceYieldRouted(
    uint256 indexed fromPremium, uint256 indexed fromFee, address indexed pool, uint256 tokenId
);
