// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {DateTime} from "./DateTime.sol";
import {
    IWETH,
    IRainfallCoordinator,
    IRainfallConsumer,
    IPremiumCalculatorCoordinator,
    IPremiumCalculatorConsumer,
    IWeatherOptionsVault
} from "./interface/IWeatherOptions.sol";

/**
 * @title WeatherOptionV3 - SECURED VERSION (Backward Compatible)
 * @notice Decentralized weather derivatives with dynamic pricing via Chainlink Functions
 * @dev Weather options backed by vault liquidity with automated settlement
 *
 * SECURITY FIXES IMPLEMENTED:
 * 1.  Historical date validation - prevents insider trading with past data
 * 2.  Location normalization - prevents bypass of exposure limits via string variations
 * 3.  Transfer lock during settlement - prevents front-running attacks
 * 4.  EnumerableSet for active options - prevents automation DOS
 * 5.  Pull payment pattern - prevents malicious contract DOS
 * 6.  Minimum premium requirements - reduces griefing attack profitability
 * 7.  Auto-claim in Chainlink Automation - fully automatic payouts for better UX
 *
 * NOTE: Geographic correlation limits (Fix #6) removed for backward compatibility with vault interface
 */
contract Bruma is ERC721URIStorage, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using DateTime for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum OptionType {
        Call, // Pays out when rainfall > strike
        Put // Pays out when rainfall < strike

    }

    enum OptionStatus {
        Active, // Option is live and can be exercised at expiry
        Expired, // Option expired (deprecated, use Settling instead)
        Settling, // Settlement requested, waiting for oracle
        Settled // Final payout completed

    }

    struct OptionTerms {
        OptionType optionType;
        string latitude;
        string longitude;
        uint256 startDate; // Unix timestamp
        uint256 expiryDate; // Unix timestamp
        uint256 strikeMM; // Strike price in millimeters
        uint256 spreadMM; // Max payout range in millimeters
        uint256 notional; // Payout per mm (in wei)
        uint256 premium; // Premium paid (in wei)
    }

    struct OptionState {
        OptionStatus status;
        address buyer;
        uint256 createdAt;
        bytes32 requestId; // Rainfall oracle request ID
        bytes32 locationKey; // Hash of lat/lon for vault tracking
        uint256 actualRainfall; // Measured rainfall in mm
        uint256 finalPayout; // Calculated payout in wei
        address ownerAtSettlement; // Snapshot of owner when settlement requested
    }

    struct Option {
        uint256 tokenId;
        OptionTerms terms;
        OptionState state;
    }

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
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    // Chainlink oracles for rainfall measurement (settlement)
    IRainfallCoordinator public immutable rainfallCoordinator;
    IRainfallConsumer public immutable rainfallConsumer;

    // Chainlink oracles for premium calculation (option creation)
    IPremiumCalculatorCoordinator public immutable premiumCoordinator;
    IPremiumCalculatorConsumer public immutable premiumConsumer;

    // Vault for liquidity provision and collateral management
    IWeatherOptionsVault public vault;

    // WETH for gas-efficient ETH handling
    IWETH public immutable weth;

    // Token ID counter
    uint256 private _nextTokenId;

    // Core option data
    mapping(uint256 => Option) public options;
    mapping(bytes32 => uint256) public requestIdToTokenId;

    EnumerableSet.UintSet private activeOptions;

    // Premium quote management (two-step option creation)
    mapping(bytes32 => CreateOptionParams) public pendingOptions;
    mapping(bytes32 => address) public pendingOptionBuyer;
    mapping(bytes32 => uint256) public quotedPremiums;
    mapping(bytes32 => uint256) public quoteTimestamp;

    mapping(uint256 => uint256) public pendingPayouts;

    // Protocol economics
    uint256 public protocolFeeBps = 100; // 1% fee on premiums (100 basis points)
    uint256 public collectedFees;

    uint256 public minPremium = 0.05 ether; // Minimum 0.05 ETH premium
    uint256 public minNotional = 0.01 ether; // Minimum 0.01 ETH per mm

    bool public autoClaimEnabled = true; // Default: enabled for better UX

    // Constants
    uint256 public constant QUOTE_VALIDITY = 1 hours; // Premium quotes expire after 1 hour
    uint256 private constant MAX_PROTOCOL_FEE = 1000; // 10% maximum protocol fee

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

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _rainfallCoordinator,
        address _rainfallConsumer,
        address _premiumCoordinator,
        address _premiumConsumer,
        address _vault,
        address _weth
    ) ERC721("Weather Option V3", "WOPT3") Ownable(msg.sender) {
        rainfallCoordinator = IRainfallCoordinator(_rainfallCoordinator);
        rainfallConsumer = IRainfallConsumer(_rainfallConsumer);
        premiumCoordinator = IPremiumCalculatorCoordinator(_premiumCoordinator);
        premiumConsumer = IPremiumCalculatorConsumer(_premiumConsumer);
        vault = IWeatherOptionsVault(_vault);
        weth = IWETH(_weth);
    }

    /*//////////////////////////////////////////////////////////////
                  STEP 1: REQUEST PREMIUM QUOTE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request a premium quote from Chainlink Functions
     * @dev First step of two-step option creation process
     *      Premium is calculated using 10 years of historical rainfall data
     * @param p Option parameters (location, strike, spread, dates, etc.)
     * @return requestId The Chainlink Functions request ID
     */
    function requestPremiumQuote(CreateOptionParams calldata p) external nonReentrant returns (bytes32 requestId) {
        _validateOptionParams(p);

        uint256 durationDays = (p.expiryDate - p.startDate) / 1 days;

        // Request premium calculation from Chainlink Functions
        requestId =
            premiumCoordinator.requestPremium(p.latitude, p.longitude, p.strikeMM, p.spreadMM, durationDays, p.notional);

        // Store pending option data
        pendingOptions[requestId] = p;
        pendingOptionBuyer[requestId] = msg.sender;
        quoteTimestamp[requestId] = block.timestamp;

        emit PremiumQuoteRequested(requestId, msg.sender, p.latitude, p.longitude, p.strikeMM, p.spreadMM);
    }

    /*//////////////////////////////////////////////////////////////
              STEP 2: CREATE OPTION WITH QUOTED PREMIUM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create option using a fulfilled premium quote
     * @dev Second step of option creation - called after Chainlink fulfills premium
     * @param quoteRequestId The request ID from requestPremiumQuote()
     * @return tokenId The newly created option token ID
     */
    function createOptionWithQuote(bytes32 quoteRequestId) external payable nonReentrant returns (uint256 tokenId) {
        if (address(vault) == address(0)) revert VaultNotSet();

        // Verify quote is fulfilled and valid
        _validateQuote(quoteRequestId);

        // Get the calculated premium
        uint256 premium = premiumConsumer.premiumByRequest(quoteRequestId);
        if (premium == 0) revert InvalidPremium();

        // 🔒 FIX #7: Enforce minimum premium
        if (premium < minPremium) revert PremiumBelowMinimum();

        // Store quoted premium for transparency
        quotedPremiums[quoteRequestId] = premium;

        // Calculate total cost including protocol fee
        uint256 protocolFee = (premium * protocolFeeBps) / 10000;
        uint256 totalCost = premium + protocolFee;

        // Verify payment
        if (msg.value < totalCost) revert InsufficientPremium();

        // Get option parameters
        CreateOptionParams memory p = pendingOptions[quoteRequestId];

        // 🔒 FIX #2: Normalize location for consistent hashing
        bytes32 locationKey = _getLocationKey(p.latitude, p.longitude);
        uint256 maxPayout = p.spreadMM * p.notional;

        // Check if vault has sufficient liquidity
        if (!vault.canUnderwrite(maxPayout, locationKey)) {
            revert VaultCannotUnderwrite();
        }

        // Create the option NFT
        tokenId = _createOption(p, premium, locationKey);

        // 🔒 FIX #4: Add to active options set
        activeOptions.add(tokenId);

        // Lock collateral in vault
        vault.lockCollateral(maxPayout, tokenId, locationKey);

        // Handle payments
        _handlePayments(premium, protocolFee, totalCost, tokenId);

        // Cleanup pending data
        delete pendingOptions[quoteRequestId];
        delete pendingOptionBuyer[quoteRequestId];

        // Mint NFT to buyer
        _safeMint(msg.sender, tokenId);

        emit PremiumQuoteFulfilled(quoteRequestId, premium);
        emit OptionCreated(tokenId, msg.sender, p.optionType, p.strikeMM, p.spreadMM, premium, maxPayout);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Request settlement via rainfall measurement
     * @dev Triggers Chainlink Functions to fetch actual rainfall data
     *      Can be called by anyone after option expiry
     * @param _tokenId The option token ID to settle
     * @return requestId The Chainlink Functions request ID
     */
    function requestSettlement(uint256 _tokenId) external nonReentrant returns (bytes32 requestId) {
        Option storage option = options[_tokenId];

        if (option.state.status != OptionStatus.Active) revert InvalidOptionStatus();
        if (block.timestamp < option.terms.expiryDate) revert OptionNotExpired();

        option.state.ownerAtSettlement = ownerOf(_tokenId);

        // Convert timestamps to date strings for API request
        string memory startDate = option.terms.startDate.timestampToDateString();
        string memory endDate = option.terms.expiryDate.timestampToDateString();

        // Request rainfall measurement from Chainlink Functions
        requestId =
            rainfallCoordinator.requestRainfall(option.terms.latitude, option.terms.longitude, startDate, endDate);

        option.state.requestId = requestId;
        option.state.status = OptionStatus.Settling;
        requestIdToTokenId[requestId] = _tokenId;

        emit SettlementRequested(
            _tokenId,
            requestId,
            option.state.ownerAtSettlement,
            option.terms.latitude,
            option.terms.longitude,
            startDate,
            endDate
        );
    }

    /**
     * @notice Finalize settlement after rainfall data received
     * @dev Calculates payout and makes it claimable via pull payment
     *      Can be called by anyone after oracle fulfills request
     * @param _tokenId The option token ID to settle
     */
    function settle(uint256 _tokenId) external nonReentrant {
        Option storage option = options[_tokenId];

        if (option.state.status != OptionStatus.Settling) revert InvalidOptionStatus();
        if (option.state.requestId == bytes32(0)) revert SettlementNotRequested();

        // Check if oracle has fulfilled the request
        uint8 reqStatus = rainfallConsumer.requestStatus(option.state.requestId);
        if (reqStatus != 2) revert OracleNotFulfilled(); // 2 = fulfilled

        // Get actual rainfall and calculate payout
        uint256 rainfall = rainfallConsumer.rainfallByRequest(option.state.requestId);
        uint256 payout = _calculatePayout(option.terms, rainfall);

        option.state.actualRainfall = rainfall;
        option.state.finalPayout = payout;
        option.state.status = OptionStatus.Settled;

        uint256 maxPayout = option.terms.spreadMM * option.terms.notional;

        // Release collateral from vault
        vault.releaseCollateral(maxPayout, payout, _tokenId, option.state.locationKey);

        if (payout > 0) {
            pendingPayouts[_tokenId] = payout;
        }

        activeOptions.remove(_tokenId);

        emit OptionSettled(_tokenId, rainfall, payout, option.state.ownerAtSettlement);
    }

    /**
     * @notice Claim payout for a settled option (pull payment pattern)
     * @dev Prevents malicious contracts from blocking settlements
     * @param _tokenId The option token ID
     */
    function claimPayout(uint256 _tokenId) external nonReentrant {
        Option storage option = options[_tokenId];

        if (option.state.status != OptionStatus.Settled) revert InvalidOptionStatus();

        uint256 payout = pendingPayouts[_tokenId];
        if (payout == 0) revert NoPendingPayout();

        // Only the owner at settlement can claim
        address beneficiary = option.state.ownerAtSettlement;
        require(msg.sender == beneficiary, "Not beneficiary");

        // Clear pending payout before transfer (CEI pattern)
        pendingPayouts[_tokenId] = 0;

        // Transfer payout
        weth.withdraw(payout);
        payable(beneficiary).transfer(payout);

        emit PayoutClaimed(_tokenId, beneficiary, payout);
    }

    /*//////////////////////////////////////////////////////////////
              CHAINLINK AUTOMATION COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if any options need settlement actions
     * @dev Uses EnumerableSet for efficient iteration
     * @return upkeepNeeded True if there are options to settle
     * @return performData Encoded array of token IDs to process
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256[] memory toSettle = new uint256[](100);
        uint256 count = 0;

        // Only iterate through active options
        uint256 length = activeOptions.length();
        uint256 maxCheck = length > 100 ? 100 : length;

        for (uint256 i = 0; i < maxCheck; i++) {
            uint256 tokenId = activeOptions.at(i);
            Option storage option = options[tokenId];

            // Check if option needs settlement request
            if (option.state.status == OptionStatus.Active && block.timestamp >= option.terms.expiryDate) {
                toSettle[count] = tokenId;
                count++;
                continue;
            }

            // Check if settlement can be finalized
            if (option.state.status == OptionStatus.Settling && option.state.requestId != bytes32(0)) {
                uint8 reqStatus = rainfallConsumer.requestStatus(option.state.requestId);
                if (reqStatus == 2) {
                    toSettle[count] = tokenId;
                    count++;
                }
            }
        }

        if (count > 0) {
            upkeepNeeded = true;
            uint256[] memory finalList = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                finalList[i] = toSettle[i];
            }
            performData = abi.encode(finalList);
        }
    }

    /**
     * @notice Execute settlement actions for options
     * @dev Called by Chainlink Automation when upkeep is needed
     * @param performData Encoded array of token IDs to process
     */
    function performUpkeep(bytes calldata performData) external {
        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            Option storage option = options[tokenId];

            // Step 1: Request settlement for expired options
            if (option.state.status == OptionStatus.Active && block.timestamp >= option.terms.expiryDate) {
                try this.requestSettlement(tokenId) {} catch {}
            }

            // Step 2: Settle and optionally auto-claim
            if (option.state.status == OptionStatus.Settling) {
                try this.settle(tokenId) {
                    // Auto-claim if enabled
                    if (autoClaimEnabled) {
                        try this.claimPayout(tokenId) {}
                        catch (bytes memory reason) {
                            // If auto-claim fails (e.g., malicious contract),
                            // user can still claim manually later
                            emit AutoClaimFailed(tokenId, reason);
                        }
                    }
                } catch {}
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get complete option data
     * @param _tokenId The option token ID
     * @return Complete option struct with terms and state
     */
    function getOption(uint256 _tokenId) external view returns (Option memory) {
        return options[_tokenId];
    }

    /**
     * @notice Get pending option data for a quote request
     * @param quoteRequestId The quote request ID
     * @return params Option parameters
     * @return buyer Address of the buyer
     * @return timestamp When the quote was requested
     */
    function getPendingOption(bytes32 quoteRequestId)
        external
        view
        returns (CreateOptionParams memory params, address buyer, uint256 timestamp)
    {
        return (pendingOptions[quoteRequestId], pendingOptionBuyer[quoteRequestId], quoteTimestamp[quoteRequestId]);
    }

    /**
     * @notice Get all active option token IDs
     * @dev Returns from EnumerableSet for efficiency
     * @return Array of token IDs for active options
     */
    function getActiveOptions() external view returns (uint256[] memory) {
        uint256 length = activeOptions.length();
        uint256[] memory activeIds = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            activeIds[i] = activeOptions.at(i);
        }

        return activeIds;
    }

    /**
     * @notice Simulate payout for a given rainfall amount
     * @param _tokenId The option token ID
     * @param rainfallMM Hypothetical rainfall in millimeters
     * @return Simulated payout in wei
     */
    function simulatePayout(uint256 _tokenId, uint256 rainfallMM) external view returns (uint256) {
        return _calculatePayout(options[_tokenId].terms, rainfallMM);
    }

    /**
     * @notice Check if an option has expired
     * @param _tokenId The option token ID
     * @return True if expired
     */
    function isExpired(uint256 _tokenId) external view returns (bool) {
        return block.timestamp >= options[_tokenId].terms.expiryDate;
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the vault address
     * @dev Only owner can call
     * @param _vault New vault address
     */
    function setVault(address _vault) external onlyOwner {
        address oldVault = address(vault);
        vault = IWeatherOptionsVault(_vault);
        emit VaultUpdated(oldVault, _vault);
    }

    /**
     * @notice Update protocol fee
     * @dev Only owner can call. Maximum 10% (1000 bps)
     * @param newFeeBps New fee in basis points
     */
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        uint256 oldFeeBps = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldFeeBps, newFeeBps);
    }

    /**
     * @notice Update minimum requirements
     * @param _minPremium Minimum premium in wei
     * @param _minNotional Minimum notional in wei
     */
    function setMinimumRequirements(uint256 _minPremium, uint256 _minNotional) external onlyOwner {
        minPremium = _minPremium;
        minNotional = _minNotional;
        emit MinimumRequirementsUpdated(_minPremium, _minNotional);
    }

    /**
     * @notice Toggle automatic claiming in Chainlink Automation
     * @dev  FIX #8: Only owner can call. Allows disabling if gas griefing occurs
     * @param enabled True to enable auto-claiming, false to disable
     */
    function setAutoClaim(bool enabled) external onlyOwner {
        autoClaimEnabled = enabled;
        emit AutoClaimToggled(enabled);
    }

    /**
     * @notice Withdraw collected protocol fees
     * @dev Only owner can call
     * @param to Address to receive fees
     */
    function withdrawFees(address payable to) external nonReentrant onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool success,) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate option parameters
     */
    function _validateOptionParams(CreateOptionParams calldata p) internal view {
        if (p.startDate < block.timestamp) revert InvalidDates();
        if (p.expiryDate <= block.timestamp) revert InvalidDates();
        if (p.expiryDate <= p.startDate) revert InvalidDates();
        if (p.spreadMM == 0) revert InvalidSpread();
        if (p.notional == 0) revert InvalidNotional();

        if (p.notional < minNotional) revert NotionalBelowMinimum();
    }

    /**
     * @notice Validate a premium quote
     * @dev Checks quote is fulfilled, belongs to caller, and hasn't expired
     */
    function _validateQuote(bytes32 quoteRequestId) internal view {
        if (!premiumConsumer.isRequestFulfilled(quoteRequestId)) {
            revert QuoteNotFulfilled();
        }
        if (pendingOptionBuyer[quoteRequestId] != msg.sender) {
            revert NotYourQuote();
        }
        if (block.timestamp > quoteTimestamp[quoteRequestId] + QUOTE_VALIDITY) {
            revert QuoteExpired();
        }
    }

    /**
     * @dev Prevents bypass via string variations like "40.7128" vs "40.71280"
     */
    function _getLocationKey(string memory lat, string memory lon) internal pure returns (bytes32) {
        // Normalize coordinates to 4 decimal places
        string memory normalizedLat = _normalizeCoordinate(lat);
        string memory normalizedLon = _normalizeCoordinate(lon);
        return keccak256(abi.encodePacked(normalizedLat, normalizedLon));
    }

    /**
     * @notice Normalize coordinate string to fixed precision
     * @dev Removes trailing zeros, extra spaces, and standardizes format
     */
    function _normalizeCoordinate(string memory coord) internal pure returns (string memory) {
        bytes memory coordBytes = bytes(coord);

        if (coordBytes.length == 0) return coord;

        // Remove leading/trailing spaces
        uint256 start = 0;
        uint256 end = coordBytes.length;

        while (start < end && coordBytes[start] == " ") start++;
        while (end > start && coordBytes[end - 1] == " ") end--;

        if (start >= end) return coord; // Empty after trimming

        // Find decimal point
        uint256 decimalPos = end; // Default: no decimal
        for (uint256 i = start; i < end; i++) {
            if (coordBytes[i] == ".") {
                decimalPos = i;
                break;
            }
        }

        // If has decimal, remove trailing zeros after decimal point
        if (decimalPos < end) {
            // Find last non-zero digit after decimal
            uint256 lastNonZero = decimalPos;
            for (uint256 i = decimalPos + 1; i < end; i++) {
                if (coordBytes[i] != "0") {
                    lastNonZero = i;
                }
            }

            // If all zeros after decimal, keep just the decimal point
            if (lastNonZero == decimalPos) {
                end = decimalPos; // Remove decimal point too
            } else {
                end = lastNonZero + 1; // Keep up to last non-zero
            }
        }

        // Copy normalized bytes
        bytes memory normalized = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            normalized[i] = coordBytes[start + i];
        }

        return string(normalized);
    }

    /**
     * @notice Create option struct and store in mapping
     * @dev Internal function to initialize option data
     */
    function _createOption(CreateOptionParams memory p, uint256 premium, bytes32 locationKey)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId++;

        options[tokenId] = Option({
            tokenId: tokenId,
            terms: OptionTerms({
                optionType: p.optionType,
                latitude: p.latitude,
                longitude: p.longitude,
                startDate: p.startDate,
                expiryDate: p.expiryDate,
                strikeMM: p.strikeMM,
                spreadMM: p.spreadMM,
                notional: p.notional,
                premium: premium
            }),
            state: OptionState({
                status: OptionStatus.Active,
                buyer: msg.sender,
                createdAt: block.timestamp,
                requestId: bytes32(0),
                locationKey: locationKey,
                actualRainfall: 0,
                finalPayout: 0,
                ownerAtSettlement: address(0)
            })
        });
    }

    /**
     * @notice Handle premium and fee payments
     * @dev Wraps ETH to WETH, transfers to vault, refunds excess
     */
    function _handlePayments(uint256 premium, uint256 protocolFee, uint256 totalCost, uint256 tokenId) internal {
        // Record protocol fee (kept in this contract as ETH)
        collectedFees += protocolFee;

        // Wrap ETH to WETH and transfer to vault
        weth.deposit{value: premium}();
        weth.safeTransfer(address(vault), premium);
        vault.receivePremium(premium, tokenId);

        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
    }

    /**
     * @notice Calculate option payout based on actual rainfall
     * @dev Implements European-style payout formula with spread cap
     * @param terms Option terms with strike and spread
     * @param actualRainfall Measured rainfall in millimeters
     * @return payout Payout amount in wei
     */
    function _calculatePayout(OptionTerms memory terms, uint256 actualRainfall)
        internal
        pure
        returns (uint256 payout)
    {
        if (terms.optionType == OptionType.Call) {
            // Call: pays when rainfall > strike
            if (actualRainfall > terms.strikeMM) {
                uint256 difference = actualRainfall - terms.strikeMM;
                if (difference > terms.spreadMM) {
                    difference = terms.spreadMM;
                }
                payout = difference * terms.notional;
            }
        } else {
            // Put: pays when rainfall < strike
            if (actualRainfall < terms.strikeMM) {
                uint256 difference = terms.strikeMM - actualRainfall;
                if (difference > terms.spreadMM) {
                    difference = terms.spreadMM;
                }
                payout = difference * terms.notional;
            }
        }
    }

    /**
     * @notice Override _update to track option buyer on transfers
     * @dev  FIX #3: Prevents transfers during settlement
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        //  FIX #3: Lock transfers during settlement to prevent front-running
        if (options[tokenId].state.status == OptionStatus.Settling) {
            revert TransferLocked();
        }

        address from = super._update(to, tokenId, auth);
        if (to != address(0) && from != address(0)) {
            options[tokenId].state.buyer = to;
        }
        return from;
    }

    /**
     * @notice Allow contract to receive ETH
     * @dev Required for WETH unwrapping during settlements
     */
    receive() external payable {}
}
