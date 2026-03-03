// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

/*//////////////////////////////////////////////////////////////
                       BASE MOCK ERC20
//////////////////////////////////////////////////////////////*/

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                       MOCK LINK TOKEN
//////////////////////////////////////////////////////////////*/

contract MockLINK is MockERC20 {
    constructor() MockERC20("Chainlink Token", "LINK") {}
}

/*//////////////////////////////////////////////////////////////
               MOCK CCIP-BnM TOKEN  (testnet drip)
//////////////////////////////////////////////////////////////*/

contract MockCCIPBnM is MockERC20 {
    constructor() MockERC20("CCIP-BnM", "CCIP-BnM") {}

    /// @notice Replicates the testnet drip — always mints exactly 1e18 to `to`.
    function drip(address to) external {
        _mint(to, 1e18);
    }
}

/*//////////////////////////////////////////////////////////////
        MOCK WETH — configurable per-address transfer revert
        Used to exercise the BrumaCCIPReceiver PayoutPending path.
//////////////////////////////////////////////////////////////*/

contract MockWETH is MockERC20 {
    mapping(address => bool) public revertOnTransferTo;

    constructor() MockERC20("Wrapped Ether", "WETH") {}

    /// @notice Make transfers to `recipient` revert (simulates non-ERC20-compliant contract).
    function setRevertOnTransferTo(address recipient, bool shouldRevert) external {
        revertOnTransferTo[recipient] = shouldRevert;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!revertOnTransferTo[to], "MockWETH: transfer blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!revertOnTransferTo[to], "MockWETH: transfer blocked");
        return super.transferFrom(from, to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
             MOCK CCIP ROUTER
             Pulls tokens + fee on ccipSend (mirrors real router).
             Exposes simulateDelivery() so tests can drive
             BrumaCCIPReceiver._ccipReceive() end-to-end.
//////////////////////////////////////////////////////////////*/

contract MockCCIPRouter is IRouterClient {
    uint256 public mockFee = 0.1e18; // default: 0.1 LINK
    uint256 private _nonce;

    // Last send metadata — readable in tests
    bytes32 public lastMessageId;
    uint64 public lastDestChain;
    address public lastFeeToken;
    uint256 public lastFeePaid;

    // error UnsupportedDestinationChain(uint64 destChainSelector);
    // error InsufficientFeeTokenAmount();
    // error InvalidMsgValue();

    // ── IRouterClient ─────────────────────────────────────────────────────────

    function isChainSupported(uint64) external pure override returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory) {
        return new address[](0);
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view override returns (uint256) {
        return mockFee;
    }

    /**
     * @dev Pulls LINK fee and each bridged token from msg.sender.
     *      This means the escrow's `forceApprove` must have been called first,
     *      which is exactly what BrumaCCIPEscrow._claimAndBridge does.
     */
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        override
        returns (bytes32 messageId)
    {
        // Pull fee token (LINK)
        if (message.feeToken != address(0) && mockFee > 0) {
            IERC20(message.feeToken).transferFrom(msg.sender, address(this), mockFee);
        }

        // Pull bridged tokens
        for (uint256 i = 0; i < message.tokenAmounts.length; i++) {
            address token = message.tokenAmounts[i].token;
            uint256 amount = message.tokenAmounts[i].amount;
            if (token != address(0) && amount > 0) {
                IERC20(token).transferFrom(msg.sender, address(this), amount);
            }
        }

        messageId = keccak256(abi.encode(_nonce++, destinationChainSelector, block.timestamp, msg.sender));
        lastMessageId = messageId;
        lastDestChain = destinationChainSelector;
        lastFeeToken = message.feeToken;
        lastFeePaid = mockFee;
    }

    // ── Test helpers ──────────────────────────────────────────────────────────

    function setFee(uint256 fee) external {
        mockFee = fee;
    }

    /**
     * @notice Simulate CCIP delivering a message to a receiver contract.
     * @dev    Because CCIPReceiver.ccipReceive has `onlyRouter`, this call
     *         must originate FROM this mock router address. In tests, call
     *         via vm.prank(address(mockRouter)) or use this helper directly.
     */
    function simulateDelivery(address receiverContract, Client.Any2EVMMessage calldata message) external {
        // Cast to the public entry-point exposed by CCIPReceiver base
        (bool ok, bytes memory reason) = receiverContract.call(
            abi.encodeWithSignature("ccipReceive((bytes32,uint64,bytes,bytes,(address,uint256)[]))", message)
        );
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
