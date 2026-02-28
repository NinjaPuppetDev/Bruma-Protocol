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

import {IBrumaVault} from "./interface/IBrumaVault.sol";
import {
    IBruma,
    IWETH,
    IRainfallCoordinator,
    IRainfallConsumer,
    IPremiumCalculatorCoordinator,
    IPremiumCalculatorConsumer
} from "./interface/IBruma.sol";

/**
 * @title Bruma
 * @notice Decentralized parametric rainfall options backed by BrumaVault liquidity.
 *
 * OPTION LIFECYCLE:
 *   1. requestPremiumQuote()    — buyer submits params; Chainlink Functions calculates premium
 *   2. createOptionWithQuote()  — buyer pays premium+fee; NFT minted; collateral locked
 *   3. requestSettlement()      — anyone calls after expiry; Chainlink Functions fetches rainfall
 *   4. settle()                 — anyone calls after oracle fulfills; payout recorded
 *   5. claimPayout()            — ownerAtSettlement collects ETH payout
 *
 * PAYMENT FLOW (_handlePayments):
 *   Bruma's responsibility is simple — wrap ETH → WETH, push to vault, notify vault.
 *   All reinsurance yield routing is handled inside BrumaVault.receivePremium().
 *   Bruma has no knowledge of the ReinsurancePool.
 *
 * SECURITY:
 *   - Historical date validation       prevents insider trading with past data
 *   - Location normalization           prevents exposure limit bypass via string variations
 *   - Transfer lock during Settling    prevents front-running settlement
 *   - EnumerableSet for activeOptions  prevents Chainlink Automation DOS
 *   - Pull payment (pendingPayouts)    prevents malicious-contract DOS on settlement
 *   - Minimum premium + notional       reduces griefing profitability
 *
 * ROLES:
 *   owner   — protocol config (fee, vault, min requirements, auto-claim toggle)
 *   anyone  — requestSettlement / settle (permissionless after expiry/oracle fulfillment)
 *   buyer   — requestPremiumQuote / createOptionWithQuote / claimPayout
 */
contract Bruma is IBruma, ERC721URIStorage, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using DateTime for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    // ── Chainlink oracles ─────────────────────────────────────────────────────
    IRainfallCoordinator public immutable rainfallCoordinator;
    IRainfallConsumer public immutable rainfallConsumer;
    IPremiumCalculatorCoordinator public immutable premiumCoordinator;
    IPremiumCalculatorConsumer public immutable premiumConsumer;

    // ── Vault + payment token ─────────────────────────────────────────────────
    IBrumaVault public override vault;
    IWETH public immutable weth;

    // ── Option state ──────────────────────────────────────────────────────────
    uint256 private _nextTokenId;

    mapping(uint256 => Option) public options;
    mapping(bytes32 => uint256) public requestIdToTokenId;
    mapping(uint256 => uint256) public override pendingPayouts;

    EnumerableSet.UintSet private _activeOptions;

    // ── Two-step creation: pending quotes ─────────────────────────────────────
    struct PendingQuote {
        OptionType optionType;
        string latitude;
        string longitude;
        uint256 startDate;
        uint256 expiryDate;
        uint256 strikeMM;
        uint256 spreadMM;
        uint256 notional;
        address buyer;
        uint256 timestamp;
    }

    mapping(bytes32 => PendingQuote) private _pendingQuotes;

    mapping(bytes32 => uint256) public quotedPremiums;

    // ── Protocol economics ────────────────────────────────────────────────────
    uint256 public override protocolFeeBps = 100; // 1%
    uint256 public override collectedFees;
    uint256 public override minPremium = 0.05 ether;
    uint256 public override minNotional = 0.01 ether;
    bool public override autoClaimEnabled = true;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant QUOTE_VALIDITY = 1 hours;
    uint256 private constant MAX_PROTOCOL_FEE = 1000; // 10%

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
    ) ERC721("Bruma Weather Option", "BRUMA") Ownable(msg.sender) {
        if (_weth == address(0)) revert VaultNotSet();
        if (_vault == address(0)) revert VaultNotSet();

        rainfallCoordinator = IRainfallCoordinator(_rainfallCoordinator);
        rainfallConsumer = IRainfallConsumer(_rainfallConsumer);
        premiumCoordinator = IPremiumCalculatorCoordinator(_premiumCoordinator);
        premiumConsumer = IPremiumCalculatorConsumer(_premiumConsumer);
        vault = IBrumaVault(_vault);
        weth = IWETH(_weth);
    }

    /*//////////////////////////////////////////////////////////////
              STEP 1 — REQUEST PREMIUM QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBruma
    function requestPremiumQuote(CreateOptionParams calldata p)
        external
        override
        nonReentrant
        returns (bytes32 requestId)
    {
        _validateParams(p.startDate, p.expiryDate, p.spreadMM, p.notional);

        uint256 durationDays = (p.expiryDate - p.startDate) / 1 days;

        requestId =
            premiumCoordinator.requestPremium(p.latitude, p.longitude, p.strikeMM, p.spreadMM, durationDays, p.notional);

        _pendingQuotes[requestId] = PendingQuote({
            optionType: p.optionType,
            latitude: p.latitude,
            longitude: p.longitude,
            startDate: p.startDate,
            expiryDate: p.expiryDate,
            strikeMM: p.strikeMM,
            spreadMM: p.spreadMM,
            notional: p.notional,
            buyer: msg.sender,
            timestamp: block.timestamp
        });

        emit PremiumQuoteRequested(requestId, msg.sender, p.latitude, p.longitude, p.strikeMM, p.spreadMM);
    }

    /*//////////////////////////////////////////////////////////////
              STEP 2 — CREATE OPTION WITH QUOTED PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBruma
    function createOptionWithQuote(bytes32 quoteRequestId)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        if (address(vault) == address(0)) revert VaultNotSet();

        PendingQuote memory q = _pendingQuotes[quoteRequestId];
        _validateQuote(quoteRequestId, q);

        uint256 premium = premiumConsumer.premiumByRequest(quoteRequestId);
        if (premium == 0) revert InvalidPremium();
        if (premium < minPremium) revert PremiumBelowMinimum();

        quotedPremiums[quoteRequestId] = premium;

        uint256 protocolFee = (premium * protocolFeeBps) / 10000;
        uint256 totalCost = premium + protocolFee;
        if (msg.value < totalCost) revert InsufficientPremium();

        bytes32 locationKey = _getLocationKey(q.latitude, q.longitude);
        uint256 maxPayout = q.spreadMM * q.notional;

        if (!vault.canUnderwrite(maxPayout, locationKey)) revert VaultCannotUnderwrite();

        tokenId = _nextTokenId++;

        options[tokenId] = Option({
            tokenId: tokenId,
            terms: OptionTerms({
                optionType: q.optionType,
                latitude: q.latitude,
                longitude: q.longitude,
                startDate: q.startDate,
                expiryDate: q.expiryDate,
                strikeMM: q.strikeMM,
                spreadMM: q.spreadMM,
                notional: q.notional,
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

        _activeOptions.add(tokenId);

        vault.lockCollateral(maxPayout, tokenId, locationKey);

        _handlePayments(premium, protocolFee, totalCost, tokenId);

        delete _pendingQuotes[quoteRequestId];

        _safeMint(msg.sender, tokenId);

        emit PremiumQuoteFulfilled(quoteRequestId, premium);
        emit OptionCreated(tokenId, msg.sender, q.optionType, q.strikeMM, q.spreadMM, premium, maxPayout);
    }

    /*//////////////////////////////////////////////////////////////
                           SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBruma
    function requestSettlement(uint256 tokenId) external override nonReentrant returns (bytes32 requestId) {
        Option storage option = options[tokenId];

        if (option.state.status != OptionStatus.Active) revert InvalidOptionStatus();
        if (block.timestamp < option.terms.expiryDate) revert OptionNotExpired();

        option.state.ownerAtSettlement = ownerOf(tokenId);

        string memory startDate = option.terms.startDate.timestampToDateString();
        string memory endDate = option.terms.expiryDate.timestampToDateString();

        requestId =
            rainfallCoordinator.requestRainfall(option.terms.latitude, option.terms.longitude, startDate, endDate);

        option.state.requestId = requestId;
        option.state.status = OptionStatus.Settling;
        requestIdToTokenId[requestId] = tokenId;

        emit SettlementRequested(
            tokenId,
            requestId,
            option.state.ownerAtSettlement,
            option.terms.latitude,
            option.terms.longitude,
            startDate,
            endDate
        );
    }

    /// @inheritdoc IBruma
    function settle(uint256 tokenId) external override nonReentrant {
        Option storage option = options[tokenId];

        if (option.state.status != OptionStatus.Settling) revert InvalidOptionStatus();
        if (option.state.requestId == bytes32(0)) revert SettlementNotRequested();

        uint8 reqStatus = rainfallConsumer.requestStatus(option.state.requestId);
        if (reqStatus != 2) revert OracleNotFulfilled();

        uint256 rainfall = rainfallConsumer.rainfallByRequest(option.state.requestId);
        uint256 payout = _calculatePayout(option.terms, rainfall);

        option.state.actualRainfall = rainfall;
        option.state.finalPayout = payout;
        option.state.status = OptionStatus.Settled;

        uint256 maxPayout = option.terms.spreadMM * option.terms.notional;

        vault.releaseCollateral(maxPayout, payout, tokenId, option.state.locationKey);

        if (payout > 0) {
            pendingPayouts[tokenId] = payout;
        }

        _activeOptions.remove(tokenId);

        emit OptionSettled(tokenId, rainfall, payout, option.state.ownerAtSettlement);
    }

    /// @inheritdoc IBruma
    function claimPayout(uint256 tokenId) external override nonReentrant {
        Option storage option = options[tokenId];

        if (option.state.status != OptionStatus.Settled) revert InvalidOptionStatus();

        uint256 payout = pendingPayouts[tokenId];
        if (payout == 0) revert NoPendingPayout();

        address beneficiary = option.state.ownerAtSettlement;
        if (msg.sender != beneficiary) revert NotBeneficiary();

        pendingPayouts[tokenId] = 0;

        weth.withdraw(payout);
        (bool ok,) = payable(beneficiary).call{value: payout}("");
        require(ok, "ETH transfer failed");

        emit PayoutClaimed(tokenId, beneficiary, payout);
    }

    /*//////////////////////////////////////////////////////////////
             CHAINLINK AUTOMATION COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 length = _activeOptions.length();
        uint256 maxCheck = length > 100 ? 100 : length;
        uint256[] memory toProcess = new uint256[](maxCheck);
        uint256 count;

        for (uint256 i = 0; i < maxCheck; i++) {
            uint256 tid = _activeOptions.at(i);
            Option storage opt = options[tid];

            if (opt.state.status == OptionStatus.Active && block.timestamp >= opt.terms.expiryDate) {
                toProcess[count++] = tid;
                continue;
            }

            if (
                opt.state.status == OptionStatus.Settling && opt.state.requestId != bytes32(0)
                    && rainfallConsumer.requestStatus(opt.state.requestId) == 2
            ) {
                toProcess[count++] = tid;
            }
        }

        if (count > 0) {
            upkeepNeeded = true;
            uint256[] memory finalList = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                finalList[i] = toProcess[i];
            }
            performData = abi.encode(finalList);
        }
    }

    function performUpkeep(bytes calldata performData) external {
        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tid = tokenIds[i];
            Option storage opt = options[tid];

            if (opt.state.status == OptionStatus.Active && block.timestamp >= opt.terms.expiryDate) {
                try this.requestSettlement(tid) {} catch {}
            }

            if (opt.state.status == OptionStatus.Settling) {
                try this.settle(tid) {
                    if (autoClaimEnabled) {
                        try this.claimPayout(tid) {}
                        catch (bytes memory reason) {
                            emit AutoClaimFailed(tid, reason);
                        }
                    }
                } catch {}
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBruma
    function getOption(uint256 tokenId) external view override returns (Option memory) {
        return options[tokenId];
    }

    /// @inheritdoc IBruma
    function getActiveOptions() external view override returns (uint256[] memory) {
        uint256 length = _activeOptions.length();
        uint256[] memory ids = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            ids[i] = _activeOptions.at(i);
        }
        return ids;
    }

    /// @inheritdoc IBruma
    function simulatePayout(uint256 tokenId, uint256 rainfallMM) external view override returns (uint256) {
        return _calculatePayout(options[tokenId].terms, rainfallMM);
    }

    /// @inheritdoc IBruma
    function isExpired(uint256 tokenId) external view override returns (bool) {
        return block.timestamp >= options[tokenId].terms.expiryDate;
    }

    function getPendingQuote(bytes32 quoteRequestId) external view returns (PendingQuote memory) {
        return _pendingQuotes[quoteRequestId];
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert VaultNotSet();
        address old = address(vault);
        vault = IBrumaVault(_vault);
        emit VaultUpdated(old, _vault);
    }

    function setProtocolFee(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        uint256 old = protocolFeeBps;
        protocolFeeBps = _newFeeBps;
        emit ProtocolFeeUpdated(old, _newFeeBps);
    }

    function setMinimumRequirements(uint256 _minPremium, uint256 _minNotional) external onlyOwner {
        minPremium = _minPremium;
        minNotional = _minNotional;
        emit MinimumRequirementsUpdated(_minPremium, _minNotional);
    }

    function setAutoClaim(bool _enabled) external onlyOwner {
        autoClaimEnabled = _enabled;
        emit AutoClaimToggled(_enabled);
    }

    function withdrawFees(address payable _to) external nonReentrant onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool ok,) = _to.call{value: amount}("");
        require(ok, "Fee withdrawal failed");
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateParams(uint256 startDate, uint256 expiryDate, uint256 spreadMM, uint256 notional) internal view {
        if (startDate < block.timestamp) revert InvalidDates();
        if (expiryDate <= block.timestamp) revert InvalidDates();
        if (expiryDate <= startDate) revert InvalidDates();
        if (spreadMM == 0) revert InvalidSpread();
        if (notional == 0) revert InvalidNotional();
        if (notional < minNotional) revert NotionalBelowMinimum();
    }

    function _validateQuote(bytes32 quoteRequestId, PendingQuote memory q) internal view {
        if (!premiumConsumer.isRequestFulfilled(quoteRequestId)) revert QuoteNotFulfilled();
        if (q.buyer != msg.sender) revert NotYourQuote();
        if (block.timestamp > q.timestamp + QUOTE_VALIDITY) revert QuoteExpired();
    }

    function _getLocationKey(string memory lat, string memory lon) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_normalizeCoordinate(lat), _normalizeCoordinate(lon)));
    }

    function _normalizeCoordinate(string memory coord) internal pure returns (string memory) {
        bytes memory b = bytes(coord);
        if (b.length == 0) return coord;

        uint256 start = 0;
        uint256 end = b.length;
        while (start < end && b[start] == " ") start++;
        while (end > start && b[end - 1] == " ") end--;
        if (start >= end) return coord;

        uint256 decPos = end;
        for (uint256 i = start; i < end; i++) {
            if (b[i] == ".") {
                decPos = i;
                break;
            }
        }

        if (decPos < end) {
            uint256 lastNonZero = decPos;
            for (uint256 i = decPos + 1; i < end; i++) {
                if (b[i] != "0") lastNonZero = i;
            }
            end = (lastNonZero == decPos) ? decPos : lastNonZero + 1;
        }

        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /**
     * @notice Wrap ETH → WETH, push to vault, notify vault.
     * @dev Deliberately simple — reinsurance yield routing is entirely the
     *      vault's responsibility inside receivePremium(). Bruma has no
     *      knowledge of the ReinsurancePool.
     *
     *   protocolFee  — stays in this contract as ETH (withdrawn via withdrawFees)
     *   premium      — wrapped to WETH, transferred to vault, vault notified
     *   overpayment  — refunded to buyer
     */
    function _handlePayments(uint256 premium, uint256 protocolFee, uint256 totalCost, uint256 tokenId) internal {
        // Protocol fee stays as ETH in this contract
        collectedFees += protocolFee;

        // Wrap premium ETH → WETH and push to vault
        weth.deposit{value: premium}();
        weth.safeTransfer(address(vault), premium);

        // Vault books premium and routes reinsurance yield slice internally
        vault.receivePremium(premium, tokenId);

        // Refund any overpayment
        if (msg.value > totalCost) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - totalCost}("");
            require(ok, "Refund failed");
        }
    }

    function _calculatePayout(OptionTerms memory terms, uint256 actualRainfall)
        internal
        pure
        returns (uint256 payout)
    {
        if (terms.optionType == OptionType.Call) {
            if (actualRainfall > terms.strikeMM) {
                uint256 diff = actualRainfall - terms.strikeMM;
                payout = (diff > terms.spreadMM ? terms.spreadMM : diff) * terms.notional;
            }
        } else {
            if (actualRainfall < terms.strikeMM) {
                uint256 diff = terms.strikeMM - actualRainfall;
                payout = (diff > terms.spreadMM ? terms.spreadMM : diff) * terms.notional;
            }
        }
    }

    /**
     * @dev Block NFT transfers while settlement is in-flight to prevent
     *      front-running of the ownerAtSettlement snapshot.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        if (options[tokenId].state.status == OptionStatus.Settling) revert TransferLocked();

        address from = super._update(to, tokenId, auth);

        if (to != address(0) && from != address(0)) {
            options[tokenId].state.buyer = to;
        }

        return from;
    }

    /// @dev Required so WETH.withdraw() can send ETH back to this contract.
    receive() external payable {}
}
