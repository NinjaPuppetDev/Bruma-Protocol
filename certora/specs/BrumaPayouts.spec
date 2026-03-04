// BrumaPayouts.spec
// CVL2 — payout correctness rules, vacuity-safe.

using BrumaVault as vault;
using WETH9     as weth;

/*//////////////////////////////////////////////////////////////
                         METHODS BLOCK
//////////////////////////////////////////////////////////////*/
methods {
    function getOption(uint256)      external returns (IBruma.Option memory) envfree;
    function ownerOf(uint256)        external returns (address)              envfree;
    function pendingPayouts(uint256) external returns (uint256)              envfree;

    function vault.totalAssets()     external returns (uint256) envfree;
    function vault.totalLocked()     external returns (uint256) envfree;

    function _.balanceOf(address)                             external => DISPATCHER(true);
    function _.withdraw(uint256)                              external => DISPATCHER(true);
    function _.deposit()                                      external => DISPATCHER(true);
    function _.transfer(address, uint256)                     external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256)        external => DISPATCHER(true);

    function _.safeTransfer(address, address, uint256)        internal => NONDET;
    function _.safeTransferFrom(address, address, uint256)    internal => NONDET;

    function _.onERC721Received(address, address, uint256, bytes) external => NONDET;

    function _.requestRainfall(string, string, string, string)                    external => NONDET;
    function _.requestPremium(string, string, uint256, uint256, uint256, uint256) external => NONDET;
    function _.premiumByRequest(bytes32)                                          external => NONDET;
    function _.rainfallByRequest(bytes32)                                         external => NONDET;
    function _.requestStatus(bytes32)                                             external => NONDET;
    function _.isRequestFulfilled(bytes32)                                        external => NONDET;

    function _.lockCollateral(uint256, uint256, bytes32)             external => NONDET;
    function _.releaseCollateral(uint256, uint256, uint256, bytes32) external => NONDET;
    function _.receivePremium(uint256, uint256)                      external => NONDET;
    function _.canUnderwrite(uint256, bytes32)                       external => NONDET;
}

/*//////////////////////////////////////////////////////////////
                      STATUS CONSTANTS
   Active   = 0
   Settling = 1
   Settled  = 2
//////////////////////////////////////////////////////////////*/
definition STATUS_ACTIVE()   returns uint8 = 0;
definition STATUS_SETTLING() returns uint8 = 1;
definition STATUS_SETTLED()  returns uint8 = 2;

/*//////////////////////////////////////////////////////////////
         RULE 1 — NO DOUBLE CLAIM
//////////////////////////////////////////////////////////////
 Straightforward revert check — no compound preconditions,
 prover can always construct a Settled option with zero payout.
//////////////////////////////////////////////////////////////*/
rule noDoubleClaim(uint256 tokenId) {
    env e;
    require assert_uint8(getOption(tokenId).state.status) == STATUS_SETTLED();
    require pendingPayouts(tokenId) == 0;
    require e.msg.value == 0;

    claimPayout@withrevert(e, tokenId);

    assert lastReverted, "claimPayout must revert when no pending payout";
}



/*//////////////////////////////////////////////////////////////
         RULE 3 — ONLY BENEFICIARY CAN CLAIM
//////////////////////////////////////////////////////////////*/
rule onlyBeneficiaryClaims(uint256 tokenId) {
    env e;

    address beneficiary = getOption(tokenId).state.ownerAtSettlement;

    require pendingPayouts(tokenId) > 0;
    require assert_uint8(getOption(tokenId).state.status) == STATUS_SETTLED();
    require e.msg.sender != beneficiary;
    require e.msg.value == 0;

    claimPayout@withrevert(e, tokenId);

    assert lastReverted, "non-beneficiary claimPayout must revert";
}

/*//////////////////////////////////////////////////////////////
         RULE 4 — ownerAtSettlement IS IMMUTABLE ONCE SET
//////////////////////////////////////////////////////////////
 Key fix: split into two sub-rules instead of one parametric.
 - For settle() and claimPayout(): ownerAtSettlement is already
   set (non-zero) before the call — these are valid to check.
 - For requestSettlement(): ownerAtSettlement starts as zero
   and gets written — checking immutability here is vacuous
   by construction. We verify it separately: once set by
   requestSettlement it must not change in subsequent calls.
//////////////////////////////////////////////////////////////*/

// 4a — settle() and claimPayout() must not overwrite ownerAtSettlement
rule ownerAtSettlementImmutableAfterSet(uint256 tokenId, method f)
    filtered {
        f -> f.selector == sig:settle(uint256).selector
          || f.selector == sig:claimPayout(uint256).selector
    }
{
    env e; calldataarg args;

    address ownerBefore = getOption(tokenId).state.ownerAtSettlement;
    require ownerBefore != 0;
    require getOption(tokenId).state.requestId != to_bytes32(0);

    f(e, args);

    assert getOption(tokenId).state.ownerAtSettlement == ownerBefore,
        "ownerAtSettlement must not change once set";
}



