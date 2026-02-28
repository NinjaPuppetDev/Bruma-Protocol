// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockBrumaForEscrow
 * @notice Minimal Bruma stand-in for BrumaCCIPEscrow unit tests.
 *
 * Implements the two IBruma surfaces the escrow touches:
 *   • pendingPayouts(tokenId)  — read by escrow before claiming
 *   • claimPayout(tokenId)     — called by escrow; sends ETH back to caller
 *
 * Extends ERC721 so ownerOf() works (escrow checks it before claiming).
 *
 * Test knobs:
 *   • setPendingPayout()   — configure what the escrow will find
 *   • setSendZeroETH()     — make claimPayout clear payout WITHOUT sending ETH
 *                            → exercises the NoPayoutAvailable guard in escrow
 *   • mint() / burn()      — give/take NFT ownership
 */
contract MockBrumaForEscrow is ERC721 {
    mapping(uint256 => uint256) public pendingPayouts;

    /// When true, claimPayout zeroes the payout but sends no ETH.
    bool public sendZeroETH;

    constructor() ERC721("MockBruma", "MBRUMA") {}

    /*//////////////////////////////////////////////////////////////
                        TEST CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }

    function setPendingPayout(uint256 tokenId, uint256 amount) external {
        pendingPayouts[tokenId] = amount;
    }

    /// @notice When set, claimPayout clears the payout without transferring ETH.
    ///         This simulates the (defensive, shouldn't-happen) case where
    ///         received == 0 even though pendingPayout was non-zero.
    function setSendZeroETH(bool flag) external {
        sendZeroETH = flag;
    }

    /*//////////////////////////////////////////////////////////////
                        IBruma SURFACE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mirrors Bruma.claimPayout: caller must be ownerAtSettlement.
     *         We skip that check here — escrow correctness is tested via
     *         the real Bruma in BrumaIntegrationTest. Here we only need
     *         the fund-transfer behaviour.
     */
    function claimPayout(uint256 tokenId) external {
        uint256 payout = pendingPayouts[tokenId];
        require(payout > 0, "NoPendingPayout");
        pendingPayouts[tokenId] = 0;

        if (!sendZeroETH) {
            (bool ok,) = payable(msg.sender).call{value: payout}("");
            require(ok, "ETH transfer failed");
        }
    }

    /// @dev Allows the test to fund this contract so it can pay out ETH.
    receive() external payable {}
}
