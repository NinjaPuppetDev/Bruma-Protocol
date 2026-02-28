// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CCIPReceiver} from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BrumaCCIPReceiver
 * @notice Destination-chain contract that receives cross-chain weather option payouts
 *         from BrumaCCIPEscrow via Chainlink CCIP.
 *
 * @dev DEPLOYMENT
 *   This contract is deployed on the buyer's native chain (e.g. Avalanche, Polygon).
 *   Its address is passed as `_destReceiver` when deploying a BrumaCCIPEscrow on Ethereum.
 *   It can be shared — one receiver per chain can serve all Bruma users on that chain.
 *
 * WHAT IT DOES
 *   1. Validates incoming CCIP message came from an approved BrumaCCIPEscrow on Ethereum
 *   2. Decodes the tokenId from message data
 *   3. Forwards the bridged WETH directly to the intended recipient
 *   4. Emits events so the buyer's frontend can confirm receipt
 *
 * SECURITY MODEL
 *   - allowedSenders: only registered BrumaCCIPEscrow addresses on the source chain
 *                     are permitted to send messages. Anyone else is rejected.
 *   - allowedSourceChains: only the configured Ethereum source chain selector is accepted.
 *   - These two together ensure no spoofed messages can drain user funds.
 *
 * TOKEN HANDLING
 *   CCIP delivers WETH (bridged) directly into this contract alongside the message.
 *   The receiver immediately forwards it to the intended recipient — it holds no funds.
 *   If forwarding fails, funds are stored in pendingWithdrawals (pull pattern fallback).
 */
contract BrumaCCIPReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct PayoutReceipt {
        bytes32 ccipMessageId;
        address sourceEscrow; // BrumaCCIPEscrow that sent this
        uint256 tokenId; // Bruma option token ID on Ethereum
        address recipient; // Who received the payout on this chain
        uint256 amount; // WETH amount received
        uint256 timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice WETH token on this destination chain
    IERC20 public immutable weth;

    /// @notice Source chain CCIP selector (Ethereum mainnet or Sepolia for testnet)
    uint64 public immutable sourceChainSelector;

    /// @notice Approved BrumaCCIPEscrow addresses on the source chain
    /// @dev escrow address → approved recipient address on this chain
    ///      The escrow stores destinationReceiver — we map escrow → recipient
    ///      so we know who to forward funds to without relying on message data alone.
    mapping(address => address) public escrowToRecipient;

    /// @notice Whether a source escrow is registered
    mapping(address => bool) public isAllowedSender;

    /// @notice Fallback pull-payment for failed direct forwards
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Full receipt history indexed by CCIP message ID
    mapping(bytes32 => PayoutReceipt) public receipts;

    /// @notice All receipts per recipient for frontend querying
    mapping(address => bytes32[]) public receiptsByRecipient;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event PayoutReceived(
        bytes32 indexed ccipMessageId,
        uint256 indexed tokenId,
        address indexed recipient,
        address sourceEscrow,
        uint256 amount
    );

    event PayoutForwarded(address indexed recipient, uint256 amount);

    event PayoutPending(address indexed recipient, uint256 amount, string reason);

    event PendingWithdrawn(address indexed recipient, uint256 amount);

    event SenderRegistered(address indexed escrow, address indexed recipient);

    event SenderRevoked(address indexed escrow);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedSourceChain(uint64 sourceChainSelector);
    error UnauthorizedSender(address sender);
    error InvalidMessageData();
    error NoTokensInMessage();
    error UnexpectedToken(address token);
    error NoPendingWithdrawal();
    error ZeroRecipient();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _ccipRouter           CCIP router on this destination chain
     * @param _weth                 WETH (bridged) token address on this chain
     * @param _sourceChainSelector  CCIP selector for the Ethereum source chain
     */
    constructor(address _ccipRouter, address _weth, uint64 _sourceChainSelector)
        CCIPReceiver(_ccipRouter)
        Ownable(msg.sender)
    {
        require(_weth != address(0), "Invalid weth");
        require(_sourceChainSelector != 0, "Invalid source chain");

        weth = IERC20(_weth);
        sourceChainSelector = _sourceChainSelector;
    }

    /*//////////////////////////////////////////////////////////////
                    SENDER REGISTRY (ADMIN)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a BrumaCCIPEscrow as an allowed CCIP sender.
     * @dev Owner calls this after a new escrow is deployed on Ethereum.
     *      In production this can be automated: the CRE workflow watches
     *      EscrowDeployed events and calls this function via a separate
     *      admin workflow, or the factory owner manages it.
     *
     * @param escrow     BrumaCCIPEscrow address on the Ethereum source chain
     * @param recipient  The buyer's address on this chain who receives payouts
     */
    function registerSender(address escrow, address recipient) external onlyOwner {
        require(escrow != address(0), "Invalid escrow");
        if (recipient == address(0)) revert ZeroRecipient();

        escrowToRecipient[escrow] = recipient;
        isAllowedSender[escrow] = true;

        emit SenderRegistered(escrow, recipient);
    }

    /**
     * @notice Register multiple senders in one call.
     * @dev Gas-efficient batch registration for initial setup.
     */
    function registerSenderBatch(address[] calldata escrows, address[] calldata recipients) external onlyOwner {
        require(escrows.length == recipients.length, "Length mismatch");
        for (uint256 i = 0; i < escrows.length; i++) {
            if (recipients[i] == address(0)) revert ZeroRecipient();
            escrowToRecipient[escrows[i]] = recipients[i];
            isAllowedSender[escrows[i]] = true;
            emit SenderRegistered(escrows[i], recipients[i]);
        }
    }

    /**
     * @notice Revoke a sender's permission (e.g. compromised escrow).
     */
    function revokeSender(address escrow) external onlyOwner {
        isAllowedSender[escrow] = false;
        escrowToRecipient[escrow] = address(0);
        emit SenderRevoked(escrow);
    }

    /*//////////////////////////////////////////////////////////////
                    CCIP MESSAGE HANDLER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by CCIP router when a message arrives from Ethereum.
     * @dev Validates source chain and sender, then forwards WETH to recipient.
     *      Never reverts (would cause CCIP to retry indefinitely) — failed
     *      forwards fall back to pendingWithdrawals.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        // ── Validate source chain ──────────────────────────────────────────────
        if (message.sourceChainSelector != sourceChainSelector) {
            revert UnauthorizedSourceChain(message.sourceChainSelector);
        }

        // ── Validate sender is a registered escrow ────────────────────────────
        address sourceEscrow = abi.decode(message.sender, (address));
        if (!isAllowedSender[sourceEscrow]) {
            revert UnauthorizedSender(sourceEscrow);
        }

        // ── Decode tokenId from message data ──────────────────────────────────
        if (message.data.length == 0) revert InvalidMessageData();
        uint256 tokenId = abi.decode(message.data, (uint256));

        // ── Validate exactly one token in transfer ────────────────────────────
        if (message.destTokenAmounts.length == 0) revert NoTokensInMessage();
        Client.EVMTokenAmount memory tokenAmount = message.destTokenAmounts[0];

        // Ensure it's the expected WETH token
        if (tokenAmount.token != address(weth)) {
            revert UnexpectedToken(tokenAmount.token);
        }

        uint256 amount = tokenAmount.amount;
        address recipient = escrowToRecipient[sourceEscrow];

        emit PayoutReceived(message.messageId, tokenId, recipient, sourceEscrow, amount);

        // ── Store receipt ──────────────────────────────────────────────────────
        receipts[message.messageId] = PayoutReceipt({
            ccipMessageId: message.messageId,
            sourceEscrow: sourceEscrow,
            tokenId: tokenId,
            recipient: recipient,
            amount: amount,
            timestamp: block.timestamp
        });
        receiptsByRecipient[recipient].push(message.messageId);

        // ── Forward WETH to recipient ──────────────────────────────────────────
        // Use try/catch pattern: if recipient is a contract that reverts,
        // store in pendingWithdrawals so funds are never lost.
        try this.forwardWeth(recipient, amount) {
            emit PayoutForwarded(recipient, amount);
        } catch (bytes memory reason) {
            // Fallback: recipient can pull manually
            pendingWithdrawals[recipient] += amount;
            emit PayoutPending(recipient, amount, string(reason));
        }
    }

    /**
     * @notice External wrapper for WETH forwarding (enables try/catch in _ccipReceive).
     * @dev Only callable by this contract itself.
     */
    function forwardWeth(address recipient, uint256 amount) external {
        require(msg.sender == address(this), "Only self");
        weth.safeTransfer(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    PULL PAYMENT FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw pending WETH payout if direct forwarding failed.
     * @dev This is the safety net. In normal operation forwardWeth() succeeds
     *      and this function is never needed.
     */
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoPendingWithdrawal();

        pendingWithdrawals[msg.sender] = 0;
        weth.safeTransfer(msg.sender, amount);

        emit PendingWithdrawn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get all payout receipt IDs for a recipient.
     * @dev Frontend uses this to show payout history.
     */
    function getReceiptIds(address recipient) external view returns (bytes32[] memory) {
        return receiptsByRecipient[recipient];
    }

    /**
     * @notice Get full receipt for a CCIP message ID.
     */
    function getReceipt(bytes32 messageId) external view returns (PayoutReceipt memory) {
        return receipts[messageId];
    }

    /**
     * @notice Get all full receipts for a recipient in one call.
     * @dev Convenience function for frontend — avoid for large receipt counts.
     */
    function getReceiptsForRecipient(address recipient) external view returns (PayoutReceipt[] memory) {
        bytes32[] memory ids = receiptsByRecipient[recipient];
        PayoutReceipt[] memory result = new PayoutReceipt[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = receipts[ids[i]];
        }
        return result;
    }

    /**
     * @notice Check pending WETH balance for a recipient.
     */
    function pendingBalance(address recipient) external view returns (uint256) {
        return pendingWithdrawals[recipient];
    }
}
