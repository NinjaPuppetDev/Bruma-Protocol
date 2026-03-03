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

/// @notice Minimal interface for CCIP-BnM testnet token (has drip() for free minting)
interface ICCIPBnM is IERC20 {
    /// @notice Mints 1 CCIP-BnM to `to`. Free on testnet. No-op on mainnet.
    function drip(address to) external;
}

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
 *   The escrow claims ETH payout, then bridges CCIP-BnM (a CCIP-supported
 *   token) to represent the payout value on the destination chain.
 *   Bruma.sol is never modified.
 *
 * WHY CCIP-BnM INSTEAD OF WETH
 *   WETH is not whitelisted on the Sepolia → Avalanche Fuji CCIP lane.
 *   CCIP-BnM (0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 on Sepolia) is the
 *   canonical testnet token supported across all Chainlink CCIP testnet lanes.
 *   On testnet, drip() mints 1 CCIP-BnM for free. The ETH payout is held in
 *   this escrow and can be withdrawn by the owner separately (or swapped via
 *   a DEX in a production deployment).
 *
 * USAGE FLOW
 *   1. Cross-chain buyer calls BrumaCCIPEscrowFactory.deployEscrow()
 *   2. Buyer funds escrow with LINK (for CCIP fees)
 *   3. Buyer purchases Bruma option → transfers NFT to this escrow address
 *   4. Settlement lifecycle runs normally (CRE workflow or anyone calls
 *      requestSettlement() then settle() on Bruma)
 *   5. CRE workflow detects OptionSettled log event
 *   6. CRE workflow calls escrow.claimAndBridge(tokenId)
 *   7. Escrow claims ETH from Bruma, drips CCIP-BnM, sends via CCIP
 *   8. Buyer receives CCIP-BnM on their native chain via BrumaCCIPReceiver
 *   9. Owner can also withdrawETH() to recover the raw ETH payout locally
 *
 * AUTHORIZED CALLERS FOR claimAndBridge()
 *   - escrow owner       the buyer's Ethereum address — always has direct control
 *   - authorizedCaller   the CRE workflow address — enables full automation
 *   - anyone             after PERMISSIONLESS_DELAY (7 days) — funds never get stuck
 *
 * PRODUCTION NOTE
 *   Replace the drip() + fixed 1e18 amount with a DEX swap (e.g. Uniswap V3)
 *   from ETH → a CCIP-supported production token (e.g. USDC, native LINK).
 *   The ETH received from Bruma stays in this contract until swapped or withdrawn.
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

    /// @notice WETH on this chain (kept for interface compatibility, not used for bridging)
    IWETH public immutable weth;

    /// @notice CCIP-BnM token — the CCIP-supported token used for cross-chain transfer
    /// @dev    Sepolia:  0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05
    ///         Fuji:     0xD21341536c5cF5EB1bcb58f6723cE26e8D8E90e4
    ICCIPBnM public immutable ccipBnM;

    /// @notice LINK token for CCIP fee payment
    IERC20 public immutable link;

    /// @notice Chainlink CCIP router on this chain
    IRouterClient public immutable ccipRouter;

    /// @notice After this delay post-settlement, anyone can trigger the bridge
    uint256 public constant PERMISSIONLESS_DELAY = 7 days;

    /// @notice Gas limit forwarded to BrumaCCIPReceiver on destination chain
    uint256 public constant CCIP_RECEIVER_GAS_LIMIT = 200_000;

    /// @notice Fixed CCIP-BnM amount bridged per settlement (1 token = 1e18)
    /// @dev    On testnet drip() always mints exactly 1 CCIP-BnM.
    ///         The actual ETH payout stays in the escrow for local withdrawal.
    ///         In production, replace with a real swap amount.
    uint256 public constant CCIP_BNM_BRIDGE_AMOUNT = 1e18;

    /// @inheritdoc IBrumaCCIPEscrow
    mapping(uint256 => bool) public override claimed;

    /// @notice ETH payout held per tokenId, claimable by owner via withdrawETH()
    mapping(uint256 => uint256) public ethPayouts;

    /// @notice Internal storage for bridge receipts
    mapping(uint256 => BridgeReceipt) private _bridgeReceipts;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event PayoutClaimed(uint256 indexed tokenId, uint256 ethAmount);
    event ETHWithdrawn(uint256 indexed tokenId, address indexed to, uint256 amount);

    event BridgeDispatched(
        uint256 indexed tokenId,
        bytes32 indexed ccipMessageId,
        uint64 destinationChain,
        address destinationReceiver,
        uint256 ccipBnMAmount,
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
    error NothingToWithdraw();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _bruma                Bruma options contract address
     * @param _weth                 WETH address on this chain (kept for interface compat)
     * @param _ccipBnM              CCIP-BnM token address on this chain
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
        address _ccipBnM,
        address _link,
        address _ccipRouter,
        address _owner,
        address _authorizedCaller,
        uint64 _destChainSelector,
        address _destReceiver
    ) {
        require(_bruma != address(0), "Invalid bruma");
        require(_weth != address(0), "Invalid weth");
        require(_ccipBnM != address(0), "Invalid ccipBnM");
        require(_link != address(0), "Invalid link");
        require(_ccipRouter != address(0), "Invalid router");
        require(_owner != address(0), "Invalid owner");
        require(_destReceiver != address(0), "Invalid dest receiver");

        bruma = IBruma(_bruma);
        brumaERC721 = IERC721(_bruma);
        weth = IWETH(_weth);
        ccipBnM = ICCIPBnM(_ccipBnM);
        link = IERC20(_link);
        ccipRouter = IRouterClient(_ccipRouter);
        owner = _owner;
        authorizedCaller = _authorizedCaller;
        destinationChainSelector = _destChainSelector;
        destinationReceiver = _destReceiver;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE: CLAIM & BRIDGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim ETH payout from Bruma and bridge CCIP-BnM to buyer on destination chain.
     * @dev Called by CRE workflow after detecting OptionSettled event, or directly by owner.
     *      ETH payout is held in escrow; owner can withdraw via withdrawETH().
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
    function claimAndBridgePermissionless(uint256 tokenId, uint256 settledAt) external override nonReentrant {
        uint256 availableAt = settledAt + PERMISSIONLESS_DELAY;
        if (block.timestamp < availableAt) revert PermissionlessDelayNotPassed(availableAt);
        _claimAndBridge(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                          ETH WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw ETH payout held in escrow after claimAndBridge completes.
     * @dev The ETH from Bruma.claimPayout() stays here since we bridge CCIP-BnM
     *      instead. Owner calls this to recover the ETH locally on Sepolia.
     *      In a production deployment with a real DEX swap, this would not be needed.
     * @param tokenId The option token ID whose ETH payout to withdraw
     */
    function withdrawETH(uint256 tokenId) external nonReentrant {
        require(msg.sender == owner, "Only owner");
        uint256 amount = ethPayouts[tokenId];
        if (amount == 0) revert NothingToWithdraw();
        ethPayouts[tokenId] = 0;
        (bool ok,) = payable(owner).call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHWithdrawn(tokenId, owner, amount);
    }

    /**
     * @notice Withdraw any ETH held in the contract not tracked per-tokenId.
     * @dev Safety escape hatch for ETH sent directly to the contract.
     */
    function withdrawAllETH() external nonReentrant {
        require(msg.sender == owner, "Only owner");
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        (bool ok,) = payable(owner).call{value: amount}("");
        require(ok, "ETH transfer failed");
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
        require(!claimed[tokenId], "Already settled");
        brumaERC721.safeTransferFrom(address(this), owner, tokenId);
        emit NFTWithdrawn(tokenId, owner);
    }

    /**
     * @notice ERC721 receiver hook. Accepts only Bruma NFTs.
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(brumaERC721)) revert OnlyBrumaNFTs();
        emit NFTReceived(tokenId, from);
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                          LINK MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit LINK to cover future CCIP bridging fees.
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
    function estimateCCIPFee(uint256 /* payoutAmount */ ) external view override returns (uint256 linkFee) {
        // Fee is based on CCIP-BnM amount, not ETH payout amount
        return ccipRouter.getFee(destinationChainSelector, _buildCCIPMessage(CCIP_BNM_BRIDGE_AMOUNT, 0));
    }

    /// @inheritdoc IBrumaCCIPEscrow
    function getBridgeReceipt(uint256 tokenId) external view override returns (BridgeReceipt memory) {
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
     *
     *      Flow:
     *        1. Claim ETH from Bruma → store in ethPayouts[tokenId]
     *        2. Drip 1 CCIP-BnM to this contract (testnet free mint)
     *        3. Bridge CCIP-BnM via CCIP to destination chain
     *        4. Owner can withdrawETH(tokenId) separately to recover ETH
     */
    function _claimAndBridge(uint256 tokenId) internal {
        // ── Guards ────────────────────────────────────────────────────────────
        if (claimed[tokenId]) revert AlreadyClaimed();
        if (brumaERC721.ownerOf(tokenId) != address(this)) revert NotOwnedByEscrow();

        // ── CEI: mark claimed BEFORE any external call ────────────────────────
        claimed[tokenId] = true;

        // ── Short-circuit: out-of-the-money options have no payout ─────────────
        uint256 pendingPayout = bruma.pendingPayouts(tokenId);
        if (pendingPayout == 0) {
            emit NullPayoutSkipped(tokenId);
            return;
        }

        // ── Step 1: Claim ETH from Bruma ──────────────────────────────────────
        // Bruma enforces: msg.sender == ownerAtSettlement == address(this) ✓
        uint256 ethBefore = address(this).balance;
        bruma.claimPayout(tokenId);
        uint256 received = address(this).balance - ethBefore;
        if (received == 0) revert NoPayoutAvailable();

        // Store ETH so owner can withdraw it locally via withdrawETH()
        ethPayouts[tokenId] = received;
        emit PayoutClaimed(tokenId, received);

        // ── Step 2: Drip CCIP-BnM to this contract ────────────────────────────
        // drip() is a free testnet mint — gives exactly 1 CCIP-BnM (1e18)
        // In production: replace with a DEX swap of ETH → supported CCIP token
        ccipBnM.drip(address(this));

        // ── Step 3: Build CCIP message and check fee ──────────────────────────
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(CCIP_BNM_BRIDGE_AMOUNT, tokenId);
        uint256 ccipFee = ccipRouter.getFee(destinationChainSelector, message);
        uint256 currentLink = link.balanceOf(address(this));
        if (currentLink < ccipFee) revert InsufficientLinkForFees(ccipFee, currentLink);

        // ── Step 4: Approve router and dispatch ──────────────────────────────
        IERC20(address(ccipBnM)).forceApprove(address(ccipRouter), CCIP_BNM_BRIDGE_AMOUNT);
        link.forceApprove(address(ccipRouter), ccipFee);

        bytes32 messageId = ccipRouter.ccipSend(destinationChainSelector, message);

        // ── Step 5: Store receipt ─────────────────────────────────────────────
        _bridgeReceipts[tokenId] = BridgeReceipt({
            messageId: messageId,
            amount: CCIP_BNM_BRIDGE_AMOUNT,
            timestamp: block.timestamp,
            destinationChain: destinationChainSelector,
            destinationReceiver: destinationReceiver
        });

        emit BridgeDispatched(
            tokenId, messageId, destinationChainSelector, destinationReceiver, CCIP_BNM_BRIDGE_AMOUNT, ccipFee
        );
    }

    /**
     * @dev Constructs the CCIP EVM2AnyMessage using CCIP-BnM as the bridged token.
     *      tokenId is packed into data so BrumaCCIPReceiver can emit indexed events.
     */
    function _buildCCIPMessage(uint256 bnmAmount, uint256 tokenId)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(ccipBnM), // ← CCIP-BnM, not WETH
            amount: bnmAmount
        });

        return Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: abi.encode(tokenId),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: CCIP_RECEIVER_GAS_LIMIT})),
            feeToken: address(link)
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

    /// @notice CCIP-BnM token address on Sepolia
    /// @dev    0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05
    address public immutable ccipBnM;

    address public immutable link;
    address public immutable ccipRouter;

    /// @inheritdoc IBrumaCCIPEscrowFactory
    address public immutable override authorizedCaller;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => address[]) public escrowsByOwner;
    mapping(address => bool) public isRegisteredEscrow;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

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
        address _ccipBnM,
        address _link,
        address _ccipRouter,
        address _authorizedCaller
    ) {
        require(_bruma != address(0), "Invalid bruma");
        require(_weth != address(0), "Invalid weth");
        require(_ccipBnM != address(0), "Invalid ccipBnM");
        require(_link != address(0), "Invalid link");
        require(_ccipRouter != address(0), "Invalid router");
        require(_authorizedCaller != address(0), "Invalid caller");

        bruma = _bruma;
        weth = _weth;
        ccipBnM = _ccipBnM;
        link = _link;
        ccipRouter = _ccipRouter;
        authorizedCaller = _authorizedCaller;
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a personal escrow for a cross-chain buyer.
     *
     * @param _destChainSelector  CCIP chain selector for buyer's home chain
     *                            Avalanche Fuji testnet : 14767482510784806043
     *                            Polygon Amoy testnet   : 16281711391670634445
     *                            Arbitrum Sepolia       : 3478487238524512106
     * @param _destReceiver       BrumaCCIPReceiver contract on the destination chain
     * @return escrow             Newly deployed escrow address
     */
    function deployEscrow(uint64 _destChainSelector, address _destReceiver) public override returns (address escrow) {
        if (_destReceiver == address(0)) revert InvalidDestinationReceiver();
        if (_destChainSelector == 0) revert InvalidDestinationChain();

        escrow = address(
            new BrumaCCIPEscrow(
                bruma,
                weth,
                ccipBnM, // ← new param
                link,
                ccipRouter,
                msg.sender,
                authorizedCaller,
                _destChainSelector,
                _destReceiver
            )
        );

        escrowsByOwner[msg.sender].push(escrow);
        isRegisteredEscrow[escrow] = true;

        emit EscrowDeployed(escrow, msg.sender, _destChainSelector, _destReceiver);
    }

    /**
     * @notice Deploy escrow and fund with LINK in one transaction.
     */
    function deployAndFundEscrow(uint64 _destChainSelector, address _destReceiver, uint256 linkAmount)
        external
        returns (address escrow)
    {
        escrow = deployEscrow(_destChainSelector, _destReceiver);
        if (linkAmount > 0) {
            IERC20(link).safeTransferFrom(msg.sender, escrow, linkAmount);
            emit EscrowFunded(escrow, linkAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    function getEscrowsByOwner(address _owner) external view returns (address[] memory) {
        return escrowsByOwner[_owner];
    }
}
