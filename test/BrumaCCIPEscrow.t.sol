// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {BrumaCCIPEscrow, BrumaCCIPEscrowFactory} from "../src/BrumaCCIPEscrow.sol";
import {IBrumaCCIPEscrow} from "../src/interface/IBruma.sol";

import {MockBrumaForEscrow} from "./mocks/MockBrumaForEscrow.sol";
import {MockCCIPBnM} from "./mocks/MockCCIPInfra.sol";
import {MockLINK} from "./mocks/MockCCIPInfra.sol";
import {MockCCIPRouter} from "./mocks/MockCCIPInfra.sol";
import {MockWETH} from "./mocks/MockCCIPInfra.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrumaCCIPEscrowTest
 * @notice Full branch-and-guard coverage for BrumaCCIPEscrow + BrumaCCIPEscrowFactory.
 *
 * COVERAGE TARGETS (BrumaCCIPEscrow)
 * ──────────────────────────────────────────────────────────────────────────────
 * claimAndBridge
 *   • NotAuthorized              — third-party caller
 *   • AlreadyClaimed             — duplicate call
 *   • NotOwnedByEscrow           — NFT not held by escrow
 *   • NullPayoutSkipped          — OTM option (pendingPayout == 0)
 *   • NoPayoutAvailable          — claimPayout sends no ETH (defensive path)
 *   • InsufficientLinkForFees    — LINK balance < router fee
 *   • happy path (owner)         — ITM, LINK pulled, messageId stored
 *   • happy path (authorizedCaller)
 *
 * claimAndBridgePermissionless
 *   • PermissionlessDelayNotPassed
 *   • happy path after delay
 *
 * withdrawETH
 *   • only owner revert
 *   • NothingToWithdraw
 *   • happy path
 *
 * withdrawAllETH
 *   • only owner revert
 *   • NothingToWithdraw
 *   • happy path (untracked ETH in contract)
 *
 * withdrawNFT
 *   • only owner revert
 *   • "Already settled" (claimed[tokenId] == true)
 *   • happy path
 *
 * fundLink / withdrawLink
 *   • fundLink transfers LINK in
 *   • withdrawLink only owner revert
 *   • withdrawLink happy path
 *
 * estimateCCIPFee / getBridgeReceipt  (view functions)
 *
 * onERC721Received
 *   • OnlyBrumaNFTs — sender is not bruma contract
 *   • happy path — returns selector, emits NFTReceived
 *
 * COVERAGE TARGETS (BrumaCCIPEscrowFactory)
 * ──────────────────────────────────────────────────────────────────────────────
 *   • InvalidDestinationReceiver  (address(0))
 *   • InvalidDestinationChain     (selector == 0)
 *   • deployEscrow happy path     — registered, event emitted
 *   • deployAndFundEscrow         — with and without LINK funding
 *   • getEscrowsByOwner           — view
 */
contract BrumaCCIPEscrowTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    BrumaCCIPEscrow public escrow;
    BrumaCCIPEscrowFactory public factory;

    MockBrumaForEscrow public mockBruma;
    MockCCIPBnM public ccipBnM;
    MockLINK public link;
    MockWETH public weth;
    MockCCIPRouter public ccipRouter;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public escrowOwner = address(0xA11CE);
    address public authorizedCaller = address(0xC0DE);
    address public thirdParty = address(0xDEAD);

    uint64 public constant DEST_CHAIN = 14_767_482_510_784_806_043; // Fuji
    address public constant DEST_RECV = address(0xBEEF);

    /*//////////////////////////////////////////////////////////////
                          OPTION PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint256 constant TOKEN_ID = 1;
    uint256 constant ETH_PAYOUT = 0.3 ether;
    uint256 constant LINK_FUNDING = 10e18; // 10 LINK

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        // Deploy mocks
        mockBruma = new MockBrumaForEscrow();
        ccipBnM = new MockCCIPBnM();
        link = new MockLINK();
        weth = new MockWETH();
        ccipRouter = new MockCCIPRouter();

        // Deploy escrow (owner = escrowOwner, caller = authorizedCaller)
        escrow = new BrumaCCIPEscrow(
            address(mockBruma),
            address(weth),
            address(ccipBnM),
            address(link),
            address(ccipRouter),
            escrowOwner,
            authorizedCaller,
            DEST_CHAIN,
            DEST_RECV
        );

        // Fund mock Bruma so it can pay out ETH on claimPayout
        vm.deal(address(mockBruma), 100 ether);

        // Fund escrowOwner + thirdParty with ETH
        vm.deal(escrowOwner, 10 ether);
        vm.deal(thirdParty, 1 ether);

        // Mint LINK to escrowOwner for funding escrow
        link.mint(escrowOwner, 100e18);

        // Deploy factory (for factory-specific tests)
        factory = new BrumaCCIPEscrowFactory(
            address(mockBruma), address(weth), address(ccipBnM), address(link), address(ccipRouter), authorizedCaller
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Seeds the escrow with a ready-to-claim ITM option:
    ///      NFT owned by escrow, pendingPayout set, LINK funded.
    function _seedITMOption(uint256 tokenId, uint256 payout) internal {
        mockBruma.mint(address(escrow), tokenId);
        mockBruma.setPendingPayout(tokenId, payout);
        link.mint(address(escrow), LINK_FUNDING);
    }

    /// @dev Executes a full successful claimAndBridge from the given caller.
    function _claimAndBridge(address caller, uint256 tokenId) internal {
        vm.prank(caller);
        escrow.claimAndBridge(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                    claimAndBridge — AUTH GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimAndBridge_NotAuthorized() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);

        vm.expectRevert(BrumaCCIPEscrow.NotAuthorized.selector);
        vm.prank(thirdParty);
        escrow.claimAndBridge(TOKEN_ID);
    }

    function test_ClaimAndBridge_AlreadyClaimed() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);
        _claimAndBridge(escrowOwner, TOKEN_ID);

        vm.expectRevert(BrumaCCIPEscrow.AlreadyClaimed.selector);
        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);
    }

    function test_ClaimAndBridge_NotOwnedByEscrow() external {
        // NFT minted to escrowOwner, not the escrow contract
        mockBruma.mint(escrowOwner, TOKEN_ID);
        mockBruma.setPendingPayout(TOKEN_ID, ETH_PAYOUT);
        link.mint(address(escrow), LINK_FUNDING);

        vm.expectRevert(BrumaCCIPEscrow.NotOwnedByEscrow.selector);
        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                  claimAndBridge — PAYOUT BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// OTM option: pendingPayout == 0 → skip bridge, emit NullPayoutSkipped
    function test_ClaimAndBridge_NullPayoutSkipped() external {
        mockBruma.mint(address(escrow), TOKEN_ID);
        // pendingPayout stays at 0

        vm.expectEmit(true, false, false, false, address(escrow));
        emit BrumaCCIPEscrow.NullPayoutSkipped(TOKEN_ID);

        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);

        assertTrue(escrow.claimed(TOKEN_ID), "Should be marked claimed even for OTM");
    }

    /// claimPayout runs but sends 0 ETH → NoPayoutAvailable
    function test_ClaimAndBridge_NoPayoutAvailable() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);
        mockBruma.setSendZeroETH(true);

        vm.expectRevert(BrumaCCIPEscrow.NoPayoutAvailable.selector);
        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);
    }

    /// Not enough LINK to cover CCIP fee → InsufficientLinkForFees
    function test_ClaimAndBridge_InsufficientLinkForFees() external {
        mockBruma.mint(address(escrow), TOKEN_ID);
        mockBruma.setPendingPayout(TOKEN_ID, ETH_PAYOUT);
        // No LINK funded to escrow

        vm.expectRevert(
            abi.encodeWithSelector(BrumaCCIPEscrow.InsufficientLinkForFees.selector, ccipRouter.mockFee(), 0)
        );
        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                  claimAndBridge — HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimAndBridge_HappyPath_Owner() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);

        uint256 linkBefore = link.balanceOf(address(escrow));
        uint256 ccipBnMBefore = ccipBnM.balanceOf(address(ccipRouter));

        vm.prank(escrowOwner);
        escrow.claimAndBridge(TOKEN_ID);

        // Claimed flag set
        assertTrue(escrow.claimed(TOKEN_ID));

        // ETH payout recorded in escrow
        assertEq(escrow.ethPayouts(TOKEN_ID), ETH_PAYOUT);

        // CCIP-BnM drip'd (1e18) and then sent to router
        assertEq(ccipBnM.balanceOf(address(ccipRouter)), ccipBnMBefore + 1e18);

        // LINK fee pulled from escrow
        assertEq(link.balanceOf(address(escrow)), linkBefore - ccipRouter.mockFee());

        // Bridge receipt stored
        IBrumaCCIPEscrow.BridgeReceipt memory receipt = escrow.getBridgeReceipt(TOKEN_ID);
        assertEq(receipt.messageId, ccipRouter.lastMessageId());
        assertEq(receipt.amount, escrow.CCIP_BNM_BRIDGE_AMOUNT());
        assertEq(receipt.destinationChain, DEST_CHAIN);
        assertEq(receipt.destinationReceiver, DEST_RECV);
        assertGt(receipt.timestamp, 0);
    }

    function test_ClaimAndBridge_HappyPath_AuthorizedCaller() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);

        vm.prank(authorizedCaller);
        escrow.claimAndBridge(TOKEN_ID);

        assertTrue(escrow.claimed(TOKEN_ID), "authorizedCaller should succeed");
    }

    /*//////////////////////////////////////////////////////////////
            claimAndBridgePermissionless
    //////////////////////////////////////////////////////////////*/

    function test_ClaimAndBridgePermissionless_DelayNotPassed() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);

        uint256 settledAt = block.timestamp;
        uint256 availableAt = settledAt + escrow.PERMISSIONLESS_DELAY();

        vm.expectRevert(abi.encodeWithSelector(BrumaCCIPEscrow.PermissionlessDelayNotPassed.selector, availableAt));
        vm.prank(thirdParty);
        escrow.claimAndBridgePermissionless(TOKEN_ID, settledAt);
    }

    function test_ClaimAndBridgePermissionless_HappyPath() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);

        uint256 settledAt = block.timestamp;
        vm.warp(settledAt + escrow.PERMISSIONLESS_DELAY() + 1);

        vm.prank(thirdParty); // anyone can call after delay
        escrow.claimAndBridgePermissionless(TOKEN_ID, settledAt);

        assertTrue(escrow.claimed(TOKEN_ID));
        assertEq(escrow.ethPayouts(TOKEN_ID), ETH_PAYOUT);
    }

    /*//////////////////////////////////////////////////////////////
                           withdrawETH
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawETH_OnlyOwner() external {
        vm.expectRevert("Only owner");
        vm.prank(thirdParty);
        escrow.withdrawETH(TOKEN_ID);
    }

    function test_WithdrawETH_NothingToWithdraw() external {
        vm.expectRevert(BrumaCCIPEscrow.NothingToWithdraw.selector);
        vm.prank(escrowOwner);
        escrow.withdrawETH(TOKEN_ID);
    }

    function test_WithdrawETH_HappyPath() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);
        _claimAndBridge(escrowOwner, TOKEN_ID);

        uint256 ownerBefore = escrowOwner.balance;

        vm.prank(escrowOwner);
        escrow.withdrawETH(TOKEN_ID);

        assertEq(escrowOwner.balance, ownerBefore + ETH_PAYOUT);
        assertEq(escrow.ethPayouts(TOKEN_ID), 0, "ethPayouts should be cleared");
    }

    /*//////////////////////////////////////////////////////////////
                          withdrawAllETH
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawAllETH_OnlyOwner() external {
        vm.expectRevert("Only owner");
        vm.prank(thirdParty);
        escrow.withdrawAllETH();
    }

    function test_WithdrawAllETH_NothingToWithdraw() external {
        vm.expectRevert(BrumaCCIPEscrow.NothingToWithdraw.selector);
        vm.prank(escrowOwner);
        escrow.withdrawAllETH();
    }

    function test_WithdrawAllETH_HappyPath() external {
        // Send ETH directly to the escrow (e.g. mis-routed funds)
        uint256 strayETH = 0.5 ether;
        vm.deal(address(escrow), strayETH);

        uint256 ownerBefore = escrowOwner.balance;

        vm.prank(escrowOwner);
        escrow.withdrawAllETH();

        assertEq(escrowOwner.balance, ownerBefore + strayETH);
        assertEq(address(escrow).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           withdrawNFT
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawNFT_OnlyOwner() external {
        mockBruma.mint(address(escrow), TOKEN_ID);

        vm.expectRevert("Only owner");
        vm.prank(thirdParty);
        escrow.withdrawNFT(TOKEN_ID);
    }

    function test_WithdrawNFT_AlreadySettled() external {
        _seedITMOption(TOKEN_ID, ETH_PAYOUT);
        _claimAndBridge(escrowOwner, TOKEN_ID); // sets claimed[TOKEN_ID] = true

        vm.expectRevert("Already settled");
        vm.prank(escrowOwner);
        escrow.withdrawNFT(TOKEN_ID);
    }

    function test_WithdrawNFT_HappyPath() external {
        mockBruma.mint(address(escrow), TOKEN_ID);

        vm.prank(escrowOwner);
        escrow.withdrawNFT(TOKEN_ID);

        assertEq(mockBruma.ownerOf(TOKEN_ID), escrowOwner, "NFT should be back with owner");
    }

    /*//////////////////////////////////////////////////////////////
                         fundLink / withdrawLink
    //////////////////////////////////////////////////////////////*/

    function test_FundLink_HappyPath() external {
        uint256 amount = 5e18;
        link.mint(address(this), amount);
        link.approve(address(escrow), amount);

        uint256 balBefore = link.balanceOf(address(escrow));
        escrow.fundLink(amount);

        assertEq(link.balanceOf(address(escrow)), balBefore + amount);
    }

    function test_WithdrawLink_OnlyOwner() external {
        vm.expectRevert("Only owner");
        vm.prank(thirdParty);
        escrow.withdrawLink();
    }

    function test_WithdrawLink_HappyPath() external {
        link.mint(address(escrow), 5e18);

        uint256 ownerLinkBefore = link.balanceOf(escrowOwner);

        vm.prank(escrowOwner);
        escrow.withdrawLink();

        assertEq(link.balanceOf(escrowOwner), ownerLinkBefore + 5e18);
        assertEq(link.balanceOf(address(escrow)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_EstimateCCIPFee() external {
        uint256 fee = escrow.estimateCCIPFee(ETH_PAYOUT);
        assertEq(fee, ccipRouter.mockFee(), "Fee should match mock router's quote");
    }

    function test_GetBridgeReceipt_BeforeClaim() external {
        IBrumaCCIPEscrow.BridgeReceipt memory receipt = escrow.getBridgeReceipt(TOKEN_ID);
        assertEq(receipt.messageId, bytes32(0), "Receipt should be empty before claim");
    }

    function test_LinkBalance() external {
        link.mint(address(escrow), 7e18);
        assertEq(escrow.linkBalance(), 7e18);
    }

    /*//////////////////////////////////////////////////////////////
                       onERC721Received
    //////////////////////////////////////////////////////////////*/

    function test_OnERC721Received_OnlyBrumaNFTs() external {
        // Deploy a rogue ERC721
        MockBrumaForEscrow rogueNFT = new MockBrumaForEscrow();
        rogueNFT.mint(address(this), 42);

        vm.expectRevert(BrumaCCIPEscrow.OnlyBrumaNFTs.selector);
        rogueNFT.safeTransferFrom(address(this), address(escrow), 42);
    }

    function test_OnERC721Received_HappyPath() external {
        mockBruma.mint(address(this), TOKEN_ID);

        // Should succeed without revert
        mockBruma.safeTransferFrom(address(this), address(escrow), TOKEN_ID);

        assertEq(mockBruma.ownerOf(TOKEN_ID), address(escrow));
    }
}

/*//////////////////////////////////////////////////////////////
                    FACTORY TESTS
//////////////////////////////////////////////////////////////*/

contract BrumaCCIPEscrowFactoryTest is Test {
    BrumaCCIPEscrowFactory public factory;

    MockBrumaForEscrow public mockBruma;
    MockCCIPBnM public ccipBnM;
    MockLINK public link;
    MockWETH public weth;
    MockCCIPRouter public ccipRouter;

    address public deployer = address(this);
    address public buyer = address(0xB0B);
    address public authorizedCaller = address(0xC0DE);

    uint64 constant DEST_CHAIN = 14_767_482_510_784_806_043;
    address constant DEST_RECV = address(0xBEEF);

    function setUp() external {
        mockBruma = new MockBrumaForEscrow();
        ccipBnM = new MockCCIPBnM();
        link = new MockLINK();
        weth = new MockWETH();
        ccipRouter = new MockCCIPRouter();

        factory = new BrumaCCIPEscrowFactory(
            address(mockBruma), address(weth), address(ccipBnM), address(link), address(ccipRouter), authorizedCaller
        );
    }

    /*//////////////////////////////////////////////////////////////
                       deployEscrow
    //////////////////////////////////////////////////////////////*/

    function test_DeployEscrow_InvalidDestReceiver() external {
        vm.expectRevert(BrumaCCIPEscrowFactory.InvalidDestinationReceiver.selector);
        vm.prank(buyer);
        factory.deployEscrow(DEST_CHAIN, address(0));
    }

    function test_DeployEscrow_InvalidDestChain() external {
        vm.expectRevert(BrumaCCIPEscrowFactory.InvalidDestinationChain.selector);
        vm.prank(buyer);
        factory.deployEscrow(0, DEST_RECV);
    }

    function test_DeployEscrow_HappyPath() external {
        vm.prank(buyer);
        address escrowAddr = factory.deployEscrow(DEST_CHAIN, DEST_RECV);

        // Registered in factory
        assertTrue(factory.isRegisteredEscrow(escrowAddr), "Should be registered");

        address[] memory escrows = factory.getEscrowsByOwner(buyer);
        assertEq(escrows.length, 1);
        assertEq(escrows[0], escrowAddr);

        // Escrow has correct immutables
        BrumaCCIPEscrow e = BrumaCCIPEscrow(payable(escrowAddr));
        assertEq(e.owner(), buyer);
        assertEq(e.authorizedCaller(), authorizedCaller);
        assertEq(e.destinationChainSelector(), DEST_CHAIN);
        assertEq(e.destinationReceiver(), DEST_RECV);
    }

    function test_DeployEscrow_MultipleEscrowsPerOwner() external {
        address dest2 = address(0xCAFE);

        vm.startPrank(buyer);
        factory.deployEscrow(DEST_CHAIN, DEST_RECV);
        factory.deployEscrow(DEST_CHAIN, dest2);
        vm.stopPrank();

        assertEq(factory.getEscrowsByOwner(buyer).length, 2);
    }

    /*//////////////////////////////////////////////////////////////
                    deployAndFundEscrow
    //////////////////////////////////////////////////////////////*/

    function test_DeployAndFundEscrow_WithLink() external {
        uint256 linkAmount = 5e18;
        link.mint(buyer, linkAmount);

        vm.startPrank(buyer);
        link.approve(address(factory), linkAmount);
        address escrowAddr = factory.deployAndFundEscrow(DEST_CHAIN, DEST_RECV, linkAmount);
        vm.stopPrank();

        assertEq(link.balanceOf(escrowAddr), linkAmount, "LINK should be in escrow");
    }

    function test_DeployAndFundEscrow_ZeroLink() external {
        vm.prank(buyer);
        address escrowAddr = factory.deployAndFundEscrow(DEST_CHAIN, DEST_RECV, 0);

        assertEq(link.balanceOf(escrowAddr), 0, "No LINK should be transferred for zero amount");
        assertTrue(factory.isRegisteredEscrow(escrowAddr));
    }
}
