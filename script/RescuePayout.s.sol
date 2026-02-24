// script/RescuePayout.s.sol
pragma solidity ^0.8.20;
import "forge-std/Script.sol";

interface IEscrow {
    function owner() external view returns (address);
}
interface IBruma {
    function claimPayout(uint256 tokenId) external;
    function pendingPayouts(uint256) external view returns (uint256);
}

contract RescuePayout is Script {
    function run() external {
        // The escrow IS the ownerAtSettlement, so we need it to call claimPayout.
        // We can't do that directly — instead use Foundry's prank to simulate,
        // then for real: add a rescueClaim() function to the escrow via upgrade,
        // OR accept the 0.25 ETH is stuck and demo with the new factory.
        
        address escrow = 0xc8AbE232af9689FFfaF40582f646a800Af96b310;
        address bruma  = 0x762a995182433fDE85dC850Fa8FF6107582110d2;
        
        // This only works in simulation (--no-broadcast)
        vm.startPrank(escrow);
        IBruma(bruma).claimPayout(0);
        vm.stopPrank();
        
        console.log("ETH in escrow:", escrow.balance);
    }
}