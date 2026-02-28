// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {BrumaCCIPReceiver} from "../src/BrumaCCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

import {MockCCIPRouter} from "./mocks/MockCCIPInfra.sol";
import {MockWETH} from "./mocks/MockCCIPInfra.sol";

/**
 * @title BrumaCCIPReceiverTest
 * @notice Full branch-and-guard coverage for BrumaCCIPReceiver.
 *
 * ARCHITECTURE NOTE — driving _ccipReceive()
 *   _ccipReceive is internal and gated by the `onlyRouter` modifier on the
 *   public ccipReceive() entry point, which checks msg.sender == i_ccipRouter.
 *   All tests that exercise _ccipReceive therefore vm.prank(address(mockRouter))
 *   before calling receiver.ccipReceive(message).
 *
 *   Before each ccipReceive call we also mint WETH into the receiver — in
 *   production the CCIP router deposits the bridged tokens before invoking the
 *   callback. Our mock router doesn't do that automatically, so we replicate it.
 *
 * COVERAGE TARGETS
 * ──────────────────────────────────────────────────────────────────────────────
 * registerSender
 *   • ZeroRecipient
 *   • happy path
 *
 * registerSenderBatch
 *   • length mismatch
 *   • ZeroRecipient in batch
 *   • happy path
 *
 * revokeSender
 *   • happy path — isAllowedSender cleared, escrowToRecipient zeroed
 *
 * _ccipReceive (via ccipReceive, pranked as router)
 *   • UnauthorizedSourceChain
 *   • UnauthorizedSender (not registered)
 *   • InvalidMessageData (empty data bytes)
 *   • NoTokensInMessage (empty destTokenAmounts)
 *   • UnexpectedToken (token != weth)
 *   • happy path — forward succeeds, receipt stored
 *   • forward fails → PayoutPending, pendingWithdrawals updated
 *
 * forwardWeth
 *   • only self revert
 *
 * withdrawPending
 *   • NoPendingWithdrawal
 *   • happy path — clears balance, transfers WETH
 *
 * View functions
 *   • getReceiptIds, getReceipt, getReceiptsForRecipient, pendingBalance
 */
contract BrumaCCIPReceiverTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    BrumaCCIPReceiver public receiver;
    MockCCIPRouter public mockRouter;
    MockWETH public weth;

    /*//////////////////////////////////////////////////////////////
                              ACTORS
    //////////////////////////////////////////////////////////////*/

    address public admin = address(this); // test contract is owner
    address public recipient = address(0xA11CE);
    address public escrow = address(0xBEEF);
    address public stranger = address(0xDEAD);

    uint64 public constant SOURCE_CHAIN = 16_015_286_601_757_825_753; // Sepolia selector

    /*//////////////////////////////////////////////////////////////
                          OPTION PARAMS
    //////////////////////////////////////////////////////////////*/

    uint256 constant TOKEN_ID = 7;
    uint256 constant PAYOUT_AMOUNT = 0.3 ether;

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        mockRouter = new MockCCIPRouter();
        weth = new MockWETH();

        receiver = new BrumaCCIPReceiver(address(mockRouter), address(weth), SOURCE_CHAIN);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Build a well-formed CCIP message from a registered escrow.
    function _buildMessage(address _escrow, uint64 sourceChain, uint256 tokenId, address tokenAddr, uint256 amount)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: tokenAddr, amount: amount});

        return Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(tokenId, block.timestamp)),
            sourceChainSelector: sourceChain,
            sender: abi.encode(_escrow),
            data: abi.encode(tokenId),
            destTokenAmounts: tokenAmounts
        });
    }

    /// Build a valid message using test defaults.
    function _validMessage() internal view returns (Client.Any2EVMMessage memory) {
        return _buildMessage(escrow, SOURCE_CHAIN, TOKEN_ID, address(weth), PAYOUT_AMOUNT);
    }

    /// Register the default escrow and fund the receiver with WETH.
    function _registerAndFund() internal {
        receiver.registerSender(escrow, recipient);
        weth.mint(address(receiver), PAYOUT_AMOUNT);
    }

    /// Deliver a message to the receiver, pranking as the router.
    function _deliver(Client.Any2EVMMessage memory message) internal {
        vm.prank(address(mockRouter));
        receiver.ccipReceive(message);
    }

    /*//////////////////////////////////////////////////////////////
                       registerSender
    //////////////////////////////////////////////////////////////*/

    function test_RegisterSender_ZeroRecipient() external {
        vm.expectRevert(BrumaCCIPReceiver.ZeroRecipient.selector);
        receiver.registerSender(escrow, address(0));
    }

    function test_RegisterSender_HappyPath() external {
        vm.expectEmit(true, true, false, false, address(receiver));
        emit BrumaCCIPReceiver.SenderRegistered(escrow, recipient);
        receiver.registerSender(escrow, recipient);

        assertTrue(receiver.isAllowedSender(escrow));
        assertEq(receiver.escrowToRecipient(escrow), recipient);
    }

    /*//////////////////////////////////////////////////////////////
                     registerSenderBatch
    //////////////////////////////////////////////////////////////*/

    function test_RegisterSenderBatch_LengthMismatch() external {
        address[] memory escrows = new address[](2);
        address[] memory recipients = new address[](1);
        escrows[0] = escrow;
        escrows[1] = address(0x1);
        recipients[0] = recipient;

        vm.expectRevert("Length mismatch");
        receiver.registerSenderBatch(escrows, recipients);
    }

    function test_RegisterSenderBatch_ZeroRecipientInBatch() external {
        address[] memory escrows = new address[](2);
        address[] memory recipients = new address[](2);
        escrows[0] = escrow;
        recipients[0] = recipient;
        escrows[1] = address(0x1);
        recipients[1] = address(0); // ← bad

        vm.expectRevert(BrumaCCIPReceiver.ZeroRecipient.selector);
        receiver.registerSenderBatch(escrows, recipients);
    }

    function test_RegisterSenderBatch_HappyPath() external {
        address escrow2 = address(0xCAFE);
        address recipient2 = address(0xFACE);

        address[] memory escrows = new address[](2);
        address[] memory recipients = new address[](2);
        escrows[0] = escrow;
        recipients[0] = recipient;
        escrows[1] = escrow2;
        recipients[1] = recipient2;

        receiver.registerSenderBatch(escrows, recipients);

        assertTrue(receiver.isAllowedSender(escrow));
        assertTrue(receiver.isAllowedSender(escrow2));
        assertEq(receiver.escrowToRecipient(escrow2), recipient2);
    }

    /*//////////////////////////////////////////////////////////////
                         revokeSender
    //////////////////////////////////////////////////////////////*/

    function test_RevokeSender_HappyPath() external {
        receiver.registerSender(escrow, recipient);

        vm.expectEmit(true, false, false, false, address(receiver));
        emit BrumaCCIPReceiver.SenderRevoked(escrow);
        receiver.revokeSender(escrow);

        assertFalse(receiver.isAllowedSender(escrow));
        assertEq(receiver.escrowToRecipient(escrow), address(0));
    }

    /*//////////////////////////////////////////////////////////////
              _ccipReceive — CHAIN + SENDER GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_CcipReceive_UnauthorizedSourceChain() external {
        _registerAndFund();

        uint64 wrongChain = SOURCE_CHAIN + 1;
        Client.Any2EVMMessage memory message = _buildMessage(escrow, wrongChain, TOKEN_ID, address(weth), PAYOUT_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(BrumaCCIPReceiver.UnauthorizedSourceChain.selector, wrongChain));
        _deliver(message);
    }

    function test_CcipReceive_UnauthorizedSender() external {
        // escrow is NOT registered
        weth.mint(address(receiver), PAYOUT_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(BrumaCCIPReceiver.UnauthorizedSender.selector, escrow));
        _deliver(_validMessage());
    }

    /*//////////////////////////////////////////////////////////////
              _ccipReceive — DATA + TOKEN GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_CcipReceive_InvalidMessageData_EmptyBytes() external {
        _registerAndFund();

        Client.Any2EVMMessage memory message = _validMessage();
        message.data = ""; // empty — decoder will revert

        vm.expectRevert(BrumaCCIPReceiver.InvalidMessageData.selector);
        _deliver(message);
    }

    function test_CcipReceive_NoTokensInMessage() external {
        _registerAndFund();

        Client.Any2EVMMessage memory message = _validMessage();
        message.destTokenAmounts = new Client.EVMTokenAmount[](0); // empty

        vm.expectRevert(BrumaCCIPReceiver.NoTokensInMessage.selector);
        _deliver(message);
    }

    function test_CcipReceive_UnexpectedToken() external {
        _registerAndFund();

        address wrongToken = address(0x999);
        Client.Any2EVMMessage memory message = _buildMessage(escrow, SOURCE_CHAIN, TOKEN_ID, wrongToken, PAYOUT_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(BrumaCCIPReceiver.UnexpectedToken.selector, wrongToken));
        _deliver(message);
    }

    /*//////////////////////////////////////////////////////////////
          _ccipReceive — HAPPY PATH (forward succeeds)
    //////////////////////////////////////////////////////////////*/

    function test_CcipReceive_HappyPath_ForwardSucceeds() external {
        _registerAndFund();
        Client.Any2EVMMessage memory message = _validMessage();

        uint256 recipientBefore = weth.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(receiver));
        emit BrumaCCIPReceiver.PayoutReceived(message.messageId, TOKEN_ID, recipient, escrow, PAYOUT_AMOUNT);
        vm.expectEmit(true, false, false, true, address(receiver));
        emit BrumaCCIPReceiver.PayoutForwarded(recipient, PAYOUT_AMOUNT);

        _deliver(message);

        // WETH forwarded to recipient
        assertEq(weth.balanceOf(recipient), recipientBefore + PAYOUT_AMOUNT);

        // Receipt stored correctly
        BrumaCCIPReceiver.PayoutReceipt memory r = receiver.getReceipt(message.messageId);
        assertEq(r.ccipMessageId, message.messageId);
        assertEq(r.sourceEscrow, escrow);
        assertEq(r.tokenId, TOKEN_ID);
        assertEq(r.recipient, recipient);
        assertEq(r.amount, PAYOUT_AMOUNT);
        assertGt(r.timestamp, 0);

        // receiptsByRecipient updated
        bytes32[] memory ids = receiver.getReceiptIds(recipient);
        assertEq(ids.length, 1);
        assertEq(ids[0], message.messageId);

        // pendingWithdrawals unchanged (direct forward succeeded)
        assertEq(receiver.pendingBalance(recipient), 0);
    }

    /*//////////////////////////////////////////////////////////////
        _ccipReceive — FORWARD FAILS → pendingWithdrawals
    //////////////////////////////////////////////////////////////*/

    function test_CcipReceive_ForwardFails_PayoutPending() external {
        _registerAndFund();

        // Make WETH transfer to `recipient` revert
        weth.setRevertOnTransferTo(recipient, true);

        Client.Any2EVMMessage memory message = _validMessage();

        vm.expectEmit(true, false, false, false, address(receiver));
        emit BrumaCCIPReceiver.PayoutPending(recipient, PAYOUT_AMOUNT, "");

        _deliver(message);

        // WETH NOT forwarded; stored in pendingWithdrawals
        assertEq(weth.balanceOf(recipient), 0);
        assertEq(receiver.pendingBalance(recipient), PAYOUT_AMOUNT);
    }

    /// Second message for same recipient accumulates in pendingWithdrawals
    function test_CcipReceive_PendingWithdrawals_Accumulate() external {
        receiver.registerSender(escrow, recipient);
        weth.setRevertOnTransferTo(recipient, true);

        // First message
        weth.mint(address(receiver), PAYOUT_AMOUNT);
        Client.Any2EVMMessage memory msg1 = _buildMessage(escrow, SOURCE_CHAIN, TOKEN_ID, address(weth), PAYOUT_AMOUNT);
        _deliver(msg1);

        // Second message (different messageId via different tokenId)
        uint256 payout2 = 0.1 ether;
        weth.mint(address(receiver), payout2);
        Client.Any2EVMMessage memory msg2 = _buildMessage(escrow, SOURCE_CHAIN, TOKEN_ID + 1, address(weth), payout2);
        _deliver(msg2);

        assertEq(receiver.pendingBalance(recipient), PAYOUT_AMOUNT + payout2);
    }

    /*//////////////////////////////////////////////////////////////
                          forwardWeth
    //////////////////////////////////////////////////////////////*/

    function test_ForwardWeth_OnlySelf() external {
        vm.expectRevert("Only self");
        vm.prank(stranger);
        receiver.forwardWeth(recipient, PAYOUT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        withdrawPending
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawPending_NoPendingWithdrawal() external {
        vm.expectRevert(BrumaCCIPReceiver.NoPendingWithdrawal.selector);
        vm.prank(recipient);
        receiver.withdrawPending();
    }

    function test_WithdrawPending_HappyPath() external {
        // Set up a failed forward so pendingWithdrawals[recipient] > 0
        _registerAndFund();
        weth.setRevertOnTransferTo(recipient, true);
        _deliver(_validMessage());

        assertEq(receiver.pendingBalance(recipient), PAYOUT_AMOUNT);

        // Unblock WETH transfers, then pull
        weth.setRevertOnTransferTo(recipient, false);

        uint256 balBefore = weth.balanceOf(recipient);

        vm.expectEmit(true, false, false, true, address(receiver));
        emit BrumaCCIPReceiver.PendingWithdrawn(recipient, PAYOUT_AMOUNT);

        vm.prank(recipient);
        receiver.withdrawPending();

        assertEq(weth.balanceOf(recipient), balBefore + PAYOUT_AMOUNT);
        assertEq(receiver.pendingBalance(recipient), 0, "Should be cleared after withdrawal");
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetReceiptsForRecipient_Empty() external {
        BrumaCCIPReceiver.PayoutReceipt[] memory receipts = receiver.getReceiptsForRecipient(recipient);
        assertEq(receipts.length, 0);
    }

    function test_GetReceiptsForRecipient_MultipleMessages() external {
        _registerAndFund();
        _deliver(_validMessage());

        // Second message
        weth.mint(address(receiver), PAYOUT_AMOUNT);
        Client.Any2EVMMessage memory msg2 =
            _buildMessage(escrow, SOURCE_CHAIN, TOKEN_ID + 1, address(weth), PAYOUT_AMOUNT);
        _deliver(msg2);

        BrumaCCIPReceiver.PayoutReceipt[] memory receipts = receiver.getReceiptsForRecipient(recipient);
        assertEq(receipts.length, 2);
    }

    function test_PendingBalance_ZeroForUnknownAddress() external {
        assertEq(receiver.pendingBalance(stranger), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  onlyOwner — admin functions
    //////////////////////////////////////////////////////////////*/

    function test_RegisterSender_OnlyOwner() external {
        vm.expectRevert();
        vm.prank(stranger);
        receiver.registerSender(escrow, recipient);
    }

    function test_RegisterSenderBatch_OnlyOwner() external {
        address[] memory escrows = new address[](1);
        address[] memory recipients = new address[](1);
        escrows[0] = escrow;
        recipients[0] = recipient;

        vm.expectRevert();
        vm.prank(stranger);
        receiver.registerSenderBatch(escrows, recipients);
    }

    function test_RevokeSender_OnlyOwner() external {
        receiver.registerSender(escrow, recipient);

        vm.expectRevert();
        vm.prank(stranger);
        receiver.revokeSender(escrow);
    }
}
