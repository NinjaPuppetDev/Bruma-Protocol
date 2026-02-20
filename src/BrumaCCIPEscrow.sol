// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

import {IWETH, IBruma, IBrumaCCIPEscrow, IBrumaCCIPEscrowFactory} from "./interface/IBruma.sol";

/**
 * @title BrumaCCIPEscrow
 * @notice Personal smart wallet that holds Bruma option NFTs on behalf of a cross-chain buyer.
 *         When an option settles in-the-money, this contract claims the ETH payout from Bruma
 *         and routes it to the buyer's address on their native chain via Chainlink CCIP.
 *
 * @dev WHY THIS CONTRACT EXISTS
 *   Bruma.claimPayout() enforces: msg.sender == ownerAtSettlement.
 *   ownerAtSettlement is snapshotted when requestSettlement() is called.
 *   So whoever holds the NFT at that moment must be the one to claim.
 *
 *   For cross-chain buyers, that holder is this escrow contract.
 *   The escrow claims ETH, wraps it to WETH, and sends it via CCIP.
 *   Bruma.sol is never modified.
 *
 * USAGE FLOW
 *   1. Cross-chain buyer calls BrumaCCIPEscrowFactory.deployEscrow()
 *   2. Buyer funds escrow with LINK (for CCIP fees)
 *   3. Buyer purchases Bruma option → transfers NFT to this escrow address
 *   4. Settlement lifecycle runs normally (CRE workflow or anyone calls
 *      requestSettlement() then settle() on Bruma)
 *   5. CRE workflow detects OptionSettled log event
 *   6. CRE workflow calls escrow.claimAndBridge(tokenId)
 *   7. Escrow claims ETH from Bruma, wraps to WETH, sends via CCIP
 *   8. Buyer receives WETH on their native chain via BrumaCCIPReceiver
 *
 * AUTHORIZED CALLERS FOR claimAndBridge()
 *   - escrow owner       the buyer's Ethereum address — always has direct control
 *   - authorizedCaller   the CRE workflow address — enables full automation
 *   - anyone             after PERMISSIONLESS_DELAY (7 days) — funds never get stuck
 */
contract BrumaCCIPEscrow is IBrumaCCIPEscrow, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBrumaCCIPEscrow
    address public immutable override owner;

    /// @inheritdoc IBrumaCCIPEscrow
    address public immutable override authorizedCaller;

    /// @inheritdoc IBrumaCCIPEscrow
    uint64 public immutable override destinationChainSelector;

    /// @inheritdoc IBrumaCCIPEscrow
    address public immutable override destinationReceiver;

    /// @notice Bruma options contract (claimPayout + pendingPayouts)
    IBruma public immutable bruma;

    /// @notice Bruma as ERC721 (NFT transfers)
    IERC721 public immutable brumaERC721;

    /// @notice WETH on this (source) chain
    IWETH public immutable weth;

    /// @notice LINK token for CCIP fee payment
    IERC20 public immutable link;

    /// @notice Chainlink CCIP router on this chain
    IRouterClient public immutable ccipRouter;

    /// @notice After this delay post-settlement, anyone can trigger the bridge
    uint256 public constant PERMISSIONLESS_DELAY = 7 days;

    /// @notice Gas limit forwarded to BrumaCCIPReceiver on destination chain
    uint256 public constant CCIP_RECEIVER_GAS_LIMIT = 200_000;

    /// @inheritdoc IBrumaCCIPEscrow
    mapping(uint256 => bool) public override claimed;

    /// @notice Internal storage for bridge receipts
    mapping(uint256 => BridgeReceipt) private _bridgeReceipts;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event PayoutClaimed(uint256 indexed tokenId, uint256 amount);

    event BridgeDispatched(
        uint256 indexed tokenId,
        bytes32 indexed ccipMessageId,
        uint64  destinationChain,
        address destinationReceiver,
        uint256 amount,
        uint256 ccipFee
    );

    event NullPayoutSkipped(uint256 indexed tokenId);
    event NFTReceived(uint256 indexed tokenId, address from);
    event NFTWithdrawn(uint256 indexed tokenId, address to);
    event LinkFunded(address indexed funder, uint256 amount);
    event LinkWithdrawn(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error AlreadyClaimed();
    error NoPayoutAvailable();
    error PermissionlessDelayNotPassed(uint256 availableAt);
    error InsufficientLinkForFees(uint256 required, uint256 available);
    error NotOwnedByEscrow();
    error OnlyBrumaNFTs();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _bruma                Bruma options contract address
     * @param _weth                 WETH address on this chain
     * @param _link                 LINK token address on this chain
     * @param _ccipRouter           Chainlink CCIP router on this chain
     * @param _owner                Buyer's address on this (source) chain
     * @param _authorizedCaller     CRE workflow address for automation
     * @param _destChainSelector    CCIP chain selector for buyer's native chain
     * @param _destReceiver         BrumaCCIPReceiver contract on destination chain
     */
    constructor(
        address _bruma,
        address _weth,
        address _link,
        address _ccipRouter,
        address _owner,
        address _authorizedCaller,
        uint64  _destChainSelector,
        address _destReceiver
    ) {
        require(_bruma != address(0),        "Invalid bruma");
        require(_weth != address(0),         "Invalid weth");
        require(_link != address(0),         "Invalid link");
        require(_ccipRouter != address(0),   "Invalid router");
        require(_owner != address(0),        "Invalid owner");
        require(_destReceiver != address(0), "Invalid dest receiver");

        bruma                    = IBruma(_bruma);
        brumaERC721              = IERC721(_bruma);
        weth                     = IWETH(_weth);
        link                     = IERC20(_link);
        ccipRouter               = IRouterClient(_ccipRouter);
        owner                    = _owner;
        authorizedCaller         = _authorizedCaller;
        destinationChainSelector = _destChainSelector;
        destinationReceiver      = _destReceiver;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE: CLAIM & BRIDGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim ETH payout from Bruma and bridge WETH to buyer on destination chain.
     * @dev Called by CRE workflow after detecting OptionSettled event, or directly by owner.
     * @param tokenId The Bruma option NFT token ID
     */
    function claimAndBridge(uint256 tokenId) external override nonReentrant {
        if (msg.sender != owner && msg.sender != authorizedCaller) revert NotAuthorized();
        _claimAndBridge(tokenId);
    }

    /**
     * @notice Permissionless fallback — anyone can trigger after PERMISSIONLESS_DELAY.
     * @dev Caller supplies settledAt from the OptionSettled event log.
     *      Ensures funds can never be permanently stuck.
     * @param tokenId   The option token ID
     * @param settledAt Unix timestamp from the OptionSettled event
     */
    function claimAndBridgePermissionless(
        uint256 tokenId,
        uint256 settledAt
    ) external override nonReentrant {
        uint256 availableAt = settledAt + PERMISSIONLESS_DELAY;
        if (block.timestamp < availableAt) revert PermissionlessDelayNotPassed(availableAt);
        _claimAndBridge(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                          NFT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw an option NFT back to the owner before settlement is requested.
     * @dev Must be called before Bruma.requestSettlement() — once ownerAtSettlement
     *      is snapshotted as this escrow, payout will always route cross-chain.
     * @param tokenId The option NFT to withdraw
     */
    function withdrawNFT(uint256 tokenId) external {
        require(msg.sender == owner, "Only owner");
        require(!claimed[tokenId],   "Already settled");
        brumaERC721.safeTransferFrom(address(this), owner, tokenId);
        emit NFTWithdrawn(tokenId, owner);
    }

    /**
     * @notice ERC721 receiver hook. Accepts only Bruma NFTs.
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        if (msg.sender != address(brumaERC721)) revert OnlyBrumaNFTs();
        emit NFTReceived(tokenId, from);
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                          LINK MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit LINK to cover future CCIP bridging fees.
     * @dev Anyone can fund. Typical cost is 0.5–2 LINK per bridge depending on chain pair.
     * @param amount LINK amount to deposit
     */
    function fundLink(uint256 amount) external {
        link.safeTransferFrom(msg.sender, address(this), amount);
        emit LinkFunded(msg.sender, amount);
    }

    /**
     * @notice Withdraw remaining LINK balance to owner.
     */
    function withdrawLink() external {
        require(msg.sender == owner, "Only owner");
        uint256 balance = link.balanceOf(address(this));
        link.safeTransfer(owner, balance);
        emit LinkWithdrawn(owner, balance);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBrumaCCIPEscrow
    function estimateCCIPFee(uint256 payoutAmount)
        external
        view
        override
        returns (uint256 linkFee)
    {
        return ccipRouter.getFee(
            destinationChainSelector,
            _buildCCIPMessage(payoutAmount, 0)
        );
    }

    /// @inheritdoc IBrumaCCIPEscrow
    function getBridgeReceipt(uint256 tokenId)
        external
        view
        override
        returns (BridgeReceipt memory)
    {
        return _bridgeReceipts[tokenId];
    }

    /**
     * @notice LINK balance available for fees.
     */
    function linkBalance() external view returns (uint256) {
        return link.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Core logic. CEI pattern: state written before all external calls.
     */
    function _claimAndBridge(uint256 tokenId) internal {
        // ── Guards ─────────────────────────────────────────────────────────────
        if (claimed[tokenId]) revert AlreadyClaimed();
        if (brumaERC721.ownerOf(tokenId) != address(this)) revert NotOwnedByEscrow();

        // ── CEI: mark claimed BEFORE any external call ─────────────────────────
        claimed[tokenId] = true;

        // ── Short-circuit: out-of-the-money options have no payout ─────────────
        uint256 pendingPayout = bruma.pendingPayouts(tokenId);
        if (pendingPayout == 0) {
            emit NullPayoutSkipped(tokenId);
            return;
        }

        // ── Claim ETH from Bruma ───────────────────────────────────────────────
        // Bruma checks: msg.sender == ownerAtSettlement
        // ownerAtSettlement was snapshotted as address(this) at requestSettlement() ✓
        uint256 ethBefore = address(this).balance;
        bruma.claimPayout(tokenId);
        uint256 received = address(this).balance - ethBefore;
        if (received == 0) revert NoPayoutAvailable();

        emit PayoutClaimed(tokenId, received);

        // ── Wrap ETH → WETH for CCIP transfer ─────────────────────────────────
        weth.deposit{value: received}();

        // ── Build CCIP message and calculate fee ───────────────────────────────
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(received, tokenId);
        uint256 ccipFee = ccipRouter.getFee(destinationChainSelector, message);
        uint256 currentLink = link.balanceOf(address(this));

        if (currentLink < ccipFee) revert InsufficientLinkForFees(ccipFee, currentLink);

        // ── Approve router and dispatch ────────────────────────────────────────
        IERC20(address(weth)).forceApprove(address(ccipRouter), received);
        link.forceApprove(address(ccipRouter), ccipFee);

        bytes32 messageId = ccipRouter.ccipSend(destinationChainSelector, message);

        // ── Store receipt ──────────────────────────────────────────────────────
        _bridgeReceipts[tokenId] = BridgeReceipt({
            messageId:           messageId,
            amount:              received,
            timestamp:           block.timestamp,
            destinationChain:    destinationChainSelector,
            destinationReceiver: destinationReceiver
        });

        emit BridgeDispatched(
            tokenId,
            messageId,
            destinationChainSelector,
            destinationReceiver,
            received,
            ccipFee
        );
    }

    /**
     * @dev Constructs the CCIP EVM2AnyMessage.
     *      tokenId is packed into data so BrumaCCIPReceiver can emit indexed events.
     */
    function _buildCCIPMessage(
        uint256 wethAmount,
        uint256 tokenId
    ) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token:  address(weth),
            amount: wethAmount
        });

        return Client.EVM2AnyMessage({
            receiver:     abi.encode(destinationReceiver),
            data:         abi.encode(tokenId),
            tokenAmounts: tokenAmounts,
            extraArgs:    Client._argsToBytes(
                              Client.EVMExtraArgsV1({gasLimit: CCIP_RECEIVER_GAS_LIMIT})
                          ),
            feeToken:     address(link)
        });
    }

    /// @notice Required to receive ETH from Bruma.claimPayout() (uses address.transfer)
    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                          FACTORY
//////////////////////////////////////////////////////////////*/

/**
 * @title BrumaCCIPEscrowFactory
 * @notice Deploys BrumaCCIPEscrow instances for cross-chain option buyers.
 *
 * @dev CRE WORKFLOW INTEGRATION
 *   The CRE workflow subscribes to EscrowDeployed events and maintains an
 *   off-chain registry:
 *       escrow address  →  { owner, destinationChain, destinationReceiver }
 *
 *   When Bruma emits OptionSettled(tokenId, rainfall, payout, ownerAtSettlement):
 *       1. CRE checks: is ownerAtSettlement a registered escrow?
 *       2. If yes  → call escrow.claimAndBridge(tokenId)
 *       3. If no   → standard same-chain flow, nothing to do
 */
contract BrumaCCIPEscrowFactory is IBrumaCCIPEscrowFactory {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBrumaCCIPEscrowFactory
    address public immutable override bruma;
    address public immutable weth;
    address public immutable link;
    address public immutable ccipRouter;

    /// @inheritdoc IBrumaCCIPEscrowFactory
    /// @dev This is the CRE workflow EOA or contract — injected into every escrow
    address public immutable override authorizedCaller;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice All escrows per owner (frontend convenience, not used by CRE)
    mapping(address => address[]) public escrowsByOwner;

    /// @notice Reverse-lookup used by CRE workflow to validate ownerAtSettlement
    mapping(address => bool) public isRegisteredEscrow;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    // EscrowDeployed inherited from IBrumaCCIPEscrowFactory
    event EscrowFunded(address indexed escrow, uint256 linkAmount);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidDestinationReceiver();
    error InvalidDestinationChain();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _bruma,
        address _weth,
        address _link,
        address _ccipRouter,
        address _authorizedCaller
    ) {
        require(_bruma != address(0),            "Invalid bruma");
        require(_weth != address(0),             "Invalid weth");
        require(_link != address(0),             "Invalid link");
        require(_ccipRouter != address(0),       "Invalid router");
        require(_authorizedCaller != address(0), "Invalid caller");

        bruma            = _bruma;
        weth             = _weth;
        link             = _link;
        ccipRouter       = _ccipRouter;
        authorizedCaller = _authorizedCaller;
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a personal escrow for a cross-chain buyer.
     * @dev Call this BEFORE purchasing any Bruma options.
     *      After deployment:
     *        1. Fund escrow with LINK via fundLink() or deployAndFundEscrow()
     *        2. Transfer each purchased Bruma NFT to the escrow address
     *
     * @param _destChainSelector  CCIP chain selector for buyer's home chain
     *                            Avalanche Fuji testnet : 14767482510784806043
     *                            Polygon Amoy testnet   : 16281711391670634445
     *                            Arbitrum Sepolia       : 3478487238524512106
     * @param _destReceiver       BrumaCCIPReceiver contract on the destination chain
     * @return escrow             Newly deployed escrow address
     */
    function deployEscrow(
        uint64  _destChainSelector,
        address _destReceiver
    ) public override returns (address escrow) {
        if (_destReceiver == address(0)) revert InvalidDestinationReceiver();
        if (_destChainSelector == 0)     revert InvalidDestinationChain();

        escrow = address(new BrumaCCIPEscrow(
            bruma,
            weth,
            link,
            ccipRouter,
            msg.sender,
            authorizedCaller,
            _destChainSelector,
            _destReceiver
        ));

        escrowsByOwner[msg.sender].push(escrow);
        isRegisteredEscrow[escrow] = true;

        emit EscrowDeployed(escrow, msg.sender, _destChainSelector, _destReceiver);
    }

    /**
     * @notice Deploy escrow and fund with LINK in one transaction.
     * @dev Saves buyers from a separate fundLink() call.
     *      Caller must have approved this factory to spend `linkAmount` LINK.
     *
     * @param _destChainSelector  CCIP chain selector for destination
     * @param _destReceiver       BrumaCCIPReceiver on destination chain
     * @param linkAmount          LINK to pre-deposit for CCIP fees
     * @return escrow             Deployed and funded escrow address
     */
    function deployAndFundEscrow(
        uint64  _destChainSelector,
        address _destReceiver,
        uint256 linkAmount
    ) external returns (address escrow) {
        escrow = deployEscrow(_destChainSelector, _destReceiver);

        if (linkAmount > 0) {
            IERC20(link).safeTransferFrom(msg.sender, escrow, linkAmount);
            emit EscrowFunded(escrow, linkAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get all escrow addresses deployed by an owner.
     */
    function getEscrowsByOwner(address _owner) external view returns (address[] memory) {
        return escrowsByOwner[_owner];
    }
}