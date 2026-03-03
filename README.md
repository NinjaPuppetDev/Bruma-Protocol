# Bruma On-Chain Parametric Rainfall Derivatives

Live Version: https://bruma-protocol.vercel.app/

**Bilateral rainfall index contracts, settled by Chainlink oracles.**
Bruma Protocol lets any operator take a structured financial position on rainfall —
priced deterministically against 10 years of historical data, settled automatically,
owned as an NFT.

> Built in Medellín, Colombia · Chainlink Convergence 2026

---

## Legal Notice

**Bruma Protocol provides on-chain financial instruments for transferring rainfall index risk.
It is not insurance and does not indemnify against actual losses.**

Payouts are determined solely by Chainlink oracle-reported rainfall data for the specified
coordinates and observation window. Settlement does not require, assess, or consider proof
of actual loss suffered by the position holder. A buyer may have underlying exposure they
are hedging, or may be taking a speculative financial position — the protocol does not
distinguish between the two.

Participation in this protocol may constitute trading in financial derivatives and may be
restricted or prohibited in your jurisdiction. This is not financial or legal advice.
Smart contracts are unaudited. Use at your own risk.

---

## Overview

Bruma is a parametric rainfall derivatives protocol. It allows any participant to enter
a bilateral index contract where:

- The **buyer** pays a premium to acquire a position that pays out if a rainfall index
  condition is met over a defined observation window
- The **liquidity pool** acts as the counterparty, collecting premiums and paying out
  when the index condition is triggered
- **Settlement** is determined entirely by Chainlink oracle data — no human assessment,
  no claims adjuster, no discretion

The protocol has two participant roles: **position buyers**, who pay premiums to transfer
rainfall index risk, and **liquidity providers**, who deposit WETH into an ERC-4626 vault
and earn premiums in exchange for bearing that risk.

A third layer — the **ReinsurancePool** — allows a separate class of capital providers
to back the primary vault. If vault utilization or expected losses breach critical
thresholds, the CRE Risk Guardian automatically draws from the reinsurance pool to
ensure the primary vault can meet its obligations.

---

## Architecture

```
Bruma (ERC-721)
├── PremiumCoordinator        ← Chainlink Functions: pricing from 10yr historical data
│   └── PremiumConsumer
├── RainfallCoordinator       ← Chainlink Functions: settlement data from Open-Meteo
│   └── RainfallConsumer
├── BrumaVault (ERC-4626)     ← Liquidity & collateral management
├── ReinsurancePool (ERC-4626)← Secondary capital layer backing the primary vault
├── CRE Workflow              ← Primary orchestration layer (settlement + risk + cross-chain)
│   ├── Settlement Automation     → drives options through full lifecycle
│   ├── Vault Risk Guardian       → proactive risk management via forecasts + AI + reinsurance draws
│   └── BrumaCCIPEscrow System    → cross-chain payout routing via CCIP
└── Chainlink Automation      ← Permissionless fallback settlement layer
```

### Position lifecycle

```
requestPremiumQuote()   →   [Chainlink Functions: 10yr historical data]
      ↓
createOptionWithQuote() →   NFT minted, collateral locked in vault
      ↓
[observation window]
      ↓
requestSettlement()     →   [CRE Workflow detects expiry automatically]
      ↓
settle()                →   [Chainlink Functions: oracle rainfall reading]
      ↓
claimPayout()           →   WETH to holder (same-chain) or CCIP bridge (cross-chain)
```

### Key design decisions

**Two-step creation.** A quote must be requested before a position is created. Quotes are
valid for 1 hour, preventing stale pricing and ensuring premiums reflect real conditions
at the time of entry.

**ERC-721 positions.** Each position is a transferable NFT. Transfers are locked during
the settlement window to prevent front-running.

**ERC-4626 vault.** Standard vault with virtual share offset (inflation attack protection).
Maximum utilization is capped at 80% of TVL. Per-location exposure is capped at 20%,
limiting correlated risk for liquidity providers.

**Pull payment pattern.** Payouts follow CEI. Auto-transfer is attempted at settlement;
if it fails, position holders can always claim manually.

**Index-only settlement.** The protocol calls `simulatePayout()` with the oracle-reported
rainfall figure. It does not interact with, verify, or consider the buyer's actual crop
yield, revenue, or any real-world outcome other than the oracle index reading.

**Two-layer capital stack.** The primary vault absorbs routine losses. If expected losses
approach critical levels, a separate ReinsurancePool is drawn upon automatically by the
CRE Risk Guardian. Reinsurance LPs earn yield from premium sharing while their capital
is idle, and accept drawdown risk in extreme scenarios.

**Option types.**
- `Call` — pays when oracle rainfall exceeds the strike level.
  `Payout = min(actual − strike, spread) × notional`
- `Put` — pays when oracle rainfall falls below the strike level.
  `Payout = min(strike − actual, spread) × notional`

---

## Option Parameters

### Strike (`strikeMM`)

The rainfall threshold in millimeters that triggers the option. It is the boundary at
which payout begins. A call with `strikeMM = 50` starts paying when oracle rainfall
exceeds 50 mm. A put with the same strike starts paying when rainfall falls below it.
No payout is owed on the wrong side of the strike regardless of how far rainfall moves.

Strike is bounded at creation time by a duration-adjusted floor and ceiling:

```
minDailyStrikeMM × durationDays  ≤  strikeMM  ≤  maxDailyStrikeMM × durationDays
```

This ensures Calls cannot be structured as near-certain payouts (floor) and Puts cannot
be structured as near-certain payouts via an astronomically high strike (ceiling). See
[Strike Bounds](#strike-bounds) for full details.

### Spread (`spreadMM`)

The range in millimeters over which the payout scales linearly from zero to its maximum.
Spread defines both the slope of the payout curve and, combined with notional, the
absolute cap on any payout:

```
maxPayout = spreadMM × notional
```

A spread of `10` means the position reaches full payout once rainfall moves 10 mm past
the strike. A spread of `50` means the payout ramps more gradually and caps higher.
The vault locks `maxPayout` as collateral at position creation.

### Notional (`notional`)

The payout **per millimeter** of rainfall movement within the spread, denominated in
wei. It is the multiplier that converts a rainfall index reading into a monetary amount.
A larger notional increases the payout at every point along the ramp and raises the
collateral requirement accordingly.

---

## Payout Equations

### Call — pays on excess rainfall

Triggered when `actualRainfall > strikeMM`.

```
diff   = actualRainfall − strikeMM
payout = min(diff, spreadMM) × notional
```

| Rainfall                  | Payout                        |
|---------------------------|-------------------------------|
| ≤ strike                  | 0                             |
| strike + X (X < spread)   | X × notional                  |
| ≥ strike + spread         | spreadMM × notional (capped)  |

### Put — pays on rainfall deficit

Triggered when `actualRainfall < strikeMM`.

```
diff   = strikeMM − actualRainfall
payout = min(diff, spreadMM) × notional
```

| Rainfall                  | Payout                        |
|---------------------------|-------------------------------|
| ≥ strike                  | 0                             |
| strike − X (X < spread)   | X × notional                  |
| ≤ strike − spread         | spreadMM × notional (capped)  |

### Payout profile

Both option types produce a **capped linear ramp**: zero on one side of the strike,
scaling linearly through the spread zone, and flat at maximum beyond it.

```
CALL payout                        PUT payout
    |                                  |
max ─────────╔══════             max ══════╗───────── 
    |        ╱                        |        ╲
    |       ╱                         |         ╲
  1 ───────╱──────────            ────────────────╲──
         strike  strike+spread    strike-spread  strike
```

This structure gives position holders a bounded, deterministic payout that is known
at entry — no slippage, no counterparty discretion, no basis risk beyond the
oracle index itself.

---

## Strike Bounds

Both option types — Call and Put — can be exploited if `strikeMM` is set to an
actuarially absurd value. The protocol enforces a duration-adjusted valid range:

```
minDailyStrikeMM × durationDays  ≤  strikeMM  ≤  maxDailyStrikeMM × durationDays
```

| Parameter | Default | Meaning |
|---|---|---|
| `minDailyStrikeMM` | 1 mm/day | Floor: 30-day option requires strike ≥ 30 mm |
| `maxDailyStrikeMM` | 50 mm/day | Ceiling: 30-day option requires strike ≤ 1500 mm |

**Why a floor (protects against Call exploit):**
A `Call` with `strikeMM = 0` pays out on any measurable rainfall at all. In any
non-arid location over a multi-day window, this is near-certain. The floor ensures
the strike is always above the baseline rainfall of even the world's driest inhabited
regions (~2–4 mm/month).

**Why a ceiling (protects against Put exploit):**
A `Put` with `strikeMM = 10000` (10 meters) pays out unless it rains 10 meters —
which never happens anywhere on Earth. This is the mirror image of the Call exploit:
a near-guaranteed payout extracted from the vault at a bounded premium cost. The
ceiling of 50 mm/day is above the wettest sustained averages on Earth (~25–30 mm/day
in places like Cherrapunji, India or Chocó, Colombia), giving legitimate hedgers
ample range while making a guaranteed-payout Put impossible to construct.

Both bounds are owner-configurable via `setMinDailyStrikeMM()` and
`setMaxDailyStrikeMM()` to allow tuning as the protocol expands to new geographies.

---

## Chainlink CRE Integration

Bruma uses the **Chainlink Runtime Environment (CRE)** as a parallel automation layer
that runs alongside the protocol. The core contracts are never modified — CRE operates
as an external orchestrator that reads from and writes to the already-deployed protocol.

For CRE integration to work, a protocol must emit events CRE can subscribe to at each
state transition. Bruma emits `OptionCreated`, `SettlementRequested`, `OptionSettled`,
and `EscrowDeployed` at each lifecycle stage. A protocol built without observable state
transitions cannot be wired to CRE without modification.

### What CRE adds that the contracts alone cannot do

| Capability | Without CRE | With CRE |
|---|---|---|
| Settlement triggering | Manual or separate Automation job | Automatic, driven by workflow |
| Payout delivery | Same-chain only, pull pattern | Cross-chain via CCIP, auto-pushed |
| Risk management | Static vault limits | Dynamic limits adjusted by weather forecasts |
| Reinsurance draws | Manual guardian intervention | Automatic drawdown at critical thresholds |
| External data | Oracle calls only at settlement | Continuous forecast monitoring |
| AI risk analysis | Not possible | Groq LLM summary via Confidential HTTP |

### The two workflows

**Workflow 1 — Settlement Automation** runs every 5 minutes. It fetches all active
positions, drives expired ones through `requestSettlement()` → `settle()`, and routes
payouts. For cross-chain buyers whose NFT is held in a `BrumaCCIPEscrow`, it calls
`claimAndBridge()` which transfers WETH via CCIP.

**Workflow 2 — Vault Risk Guardian** runs every hour. It:

1. Reads vault metrics (TVL, utilization, net PnL) and **ReinsurancePool capacity**
   (`availableCapacity`, `maxDrawableNow`)
2. Fetches 7-day weather forecasts from Open-Meteo for every active position location
3. Calls `simulatePayout()` with forecasted rainfall to compute aggregate expected loss
4. Evaluates expected loss and current utilization against two configurable thresholds:
   - **Alert threshold** — tightens vault utilization limits proactively
   - **Critical threshold** — tightens limits **and** draws from the ReinsurancePool
     to pre-fund potential payouts before settlements arrive
5. Sweeps settled CCIP escrow positions and triggers cross-chain bridges
6. Generates a natural-language risk summary via Groq using Confidential HTTP

This is the core runtime innovation: **a liquidity vault that reads the weather forecast,
consults an AI, and autonomously draws from a reinsurance layer to manage its own risk.**

### Risk Guardian threshold logic

```
expectedLossBps / currentUtilBps vs thresholds:

< alertThreshold     → No action. Log status.
≥ alertThreshold     → Tighten vault limits to maxUtilizationBps (standard alert).
≥ criticalThreshold  → Tighten vault limits to emergencyMaxUtilizationBps
                        AND draw min(expectedLoss, maxDrawableNow) from ReinsurancePool.
```

The reinsurance draw is executed by calling `receiveYield(amount)` on the
`ReinsurancePool`, which pushes capital back to the primary vault. This is a
guardian-initiated yield push rather than a pull — no change to core vault contracts
is required.

---

## Confidential Compute: The Problem No One Talks About

### The problem with authenticated APIs in decentralized workflows

Integrating an LLM or any authenticated external API into a decentralized workflow has
a fundamental problem: every node needs the credential to execute the call. The options
are all bad:

- **Hardcode the key** — visible in bytecode, extracted within hours
- **Store on-chain** — readable by anyone
- **Distribute to node operators** — social trust, not cryptographic guarantee
- **Don't use authenticated APIs** — sacrifice the capability entirely

The same problem applies to any credential: weather data providers, financial feeds,
compliance checks, AI inference endpoints.

### How Bruma solves it with CRE Confidential HTTP

The request is routed into a **Trusted Execution Environment (TEE)**. The enclave:

1. Pulls the API key from the **Vault DON** — Chainlink's decentralized secret store
2. Injects the key via Go template syntax (`{{.groqApiKey}}`) inside the sealed environment
3. Executes the HTTP request from within the enclave
4. Optionally encrypts the response before it leaves

The Groq API key exists nowhere in the workflow codebase, nowhere in node memory, and
nowhere on-chain. It is fetched by the enclave, used once, and discarded.

```typescript
// The key is never in code — only a template placeholder
const response = sendRequester.sendRequest({
  request: {
    url: "https://api.groq.com/openai/v1/chat/completions",
    method: "POST",
    multiHeaders: {
      Authorization: { values: ["Bearer {{.groqApiKey}}"] }, // injected in enclave
    },
    bodyString: JSON.stringify({ model: "groq/compound", messages: [...] }),
  },
  vaultDonSecrets: [{ key: "groqApiKey" }], // fetched from Vault DON
}).result();
```

This pattern unlocks authenticated external APIs for any decentralized protocol:
AI inference, KYC/AML providers, commercial data feeds, partner API integrations —
all without exposing credentials to node operators.

---

## Simulation Results

Running `cre workflow simulate BrumaEscrow --target staging-settings --broadcast`
against live Sepolia deployments:

**Settlement workflow:**
```
2026-02-24T10:38:42Z [USER LOG] === Bruma Settlement Workflow triggered ===
2026-02-24T10:38:42Z [USER LOG] Active options: 6
2026-02-24T10:38:43Z [USER LOG] TokenId 1: expired — requesting settlement...
2026-02-24T10:38:48Z [USER LOG] TokenId 2: expired — requesting settlement...
2026-02-24T10:39:01Z [USER LOG] Settlement requested: [1, 2]
                                Settled:              []
                                Bridged (CCIP):       []
                                Skipped:              [3, 4, 5, 6]
                                Errors:               0
```

**Risk Guardian with ReinsurancePool + Confidential HTTP + Groq:**
```
2026-02-28T18:18:32Z [SIMULATION] Simulator Initialized
2026-02-28T18:18:32Z [SIMULATION] Running trigger trigger=cron-trigger@1.0.0
2026-02-28T18:18:32Z [USER LOG] === Bruma Vault Risk Guardian triggered ===
2026-02-28T18:18:32Z [USER LOG] Vault: TVL=1753151250000000000 | Utilization=14.26% | NetPnL=253151250000000000
2026-02-28T18:18:32Z [USER LOG] ReinsurancePool: capacity=90659000000000000 | maxDrawableNow=56661875000000000
2026-02-28T18:18:33Z [USER LOG] TokenId 0 [6.25,-75.56]: forecast = 75.0mm over 7 days
2026-02-28T18:18:33Z [USER LOG] Expected loss across 1 options: 250000000000000000 wei | Auto-settled: 0
2026-02-28T18:18:34Z [USER LOG] Expected loss: 14.26% of TVL | Alert threshold: 70%
2026-02-28T18:18:34Z [USER LOG] Vault healthy. No vault action needed.
2026-02-28T18:18:38Z [USER LOG] Groq risk summary: The vault holds 1.7532 ETH with current utilization
                                at 14.26%, well below the 70% alert threshold. The forecasted loss equals
                                14.26% of TVL (~0.25 ETH), which exceeds the reinsurance pool capacity of
                                0.0907 ETH, but the vault net PnL is positive (+0.2532 ETH), providing a
                                buffer. Overall risk is moderate: no reinsurance drawdown triggered.

✓ Workflow Simulation Result: Vault healthy. Utilization: 14.26%. CCIP bridges: 0. Options settled: 0.
2026-02-28T18:18:38Z [SIMULATION] Execution finished
```

---

## Cross-chain payout system (BrumaCCIPEscrow)

For buyers on other chains, the protocol provides a companion contract system that
requires **zero modifications to the core contracts**.

```
Buyer on Avalanche
  │
  └─► Deploys BrumaCCIPEscrow on Ethereum (via BrumaCCIPEscrowFactory)
        │  Personal smart wallet holding their Bruma NFT
        ├─► Bruma settles normally → escrow is ownerAtSettlement
        ├─► CRE workflow detects OptionSettled event
        ├─► CRE calls escrow.claimAndBridge(tokenId)
        └─► CCIP-BnM bridged via CCIP → BrumaCCIPReceiver on Avalanche
              └─► Buyer receives on their native chain
```

A 7-day permissionless fallback ensures funds can never be permanently locked if the
CRE workflow is offline.

> **Testnet note:** The Sepolia → Avalanche Fuji CCIP lane does not support WETH.
> The current escrow implementation bridges CCIP-BnM (the canonical testnet token)
> as a representative payout. In a production deployment, this would be replaced
> with a DEX swap from ETH to a CCIP-supported token (e.g. USDC).

---

## Chainlink Automation Fallback

The CRE workflow is the primary driver of the settlement lifecycle. However, because CRE
is an off-chain orchestration layer, any disruption — workflow misconfiguration, node
unavailability, or network conditions — could leave expired positions unsettled.

Chainlink Automation provides a permissionless on-chain fallback that ensures this never
happens. The contract implements `checkUpkeep` and `performUpkeep` directly:

- `checkUpkeep` scans all active positions (capped at 100 per run to prevent DOS) and
  returns any that are expired or oracle-fulfilled
- `performUpkeep` drives those positions through `requestSettlement()` → `settle()`,
  and attempts `claimPayout()` if auto-claim is enabled

The fallback has no knowledge of reinsurance draws, CCIP routing, or AI risk summaries —
those capabilities belong to CRE. Its only job is liveness: guaranteeing that every
expired position reaches settlement regardless of off-chain conditions.

| Layer | Role | Capabilities |
|---|---|---|
| CRE Workflow | Primary orchestrator | Settlement, CCIP bridging, risk guardian, reinsurance draws, AI summaries |
| Chainlink Automation | Permissionless fallback | Settlement and payout only — no credentials, no off-chain compute |

Together they form a defense-in-depth settlement architecture. CRE handles intelligent
orchestration; Automation handles guaranteed liveness.

---

## Protocol Governance

Admin functions are currently controlled by a deployer EOA. Before any mainnet deployment:

- All `onlyOwner` state-changing functions (except `withdrawFees`) will be placed behind
  a 48–72 hour timelock
- The owner wallet will move to a multisig (Gnosis Safe, minimum 2-of-3)
- `withdrawFees` remains owner-controlled as collecting a protocol fee is legitimate
  and does not affect position holder outcomes

The CRE workflow is an authorized caller for settlement automation and reinsurance
draws, but has no custody of funds. All value flows through the audited core contracts.

---

## Competitive Advantage and Generalizability

The `BrumaCCIPEscrow` pattern solves a problem that affects every ERC-4626 vault that
issues ERC-721 positions — not just Bruma.

Any protocol where:
1. A vault locks collateral against an NFT position
2. Payout is restricted to `msg.sender == ownerAtSettlement`
3. Buyers may live on different chains

...faces the same cross-chain payout routing problem. Today these protocols either force
users to bridge first, or modify core contracts to add cross-chain logic.

The Bruma solution is non-invasive: any protocol can adopt the escrow pattern by emitting
a discoverable deployment event, deploying the factory with their protocol address, and
writing a CRE workflow that watches their settlement event.

The critical prerequisite is observable state transitions. The `EscrowDeployed` event
lets the CRE workflow build an in-memory registry from event history — no on-chain
mapping required, no additional contract surface.

Similarly, the **two-layer capital stack + autonomous reinsurance draw** pattern is
generalisable to any protocol that needs a backstop layer without hardcoding reinsurance
logic into core contracts. The guardian pattern — read forecast → compute expected loss →
draw reinsurance — can be adapted to any parametric risk protocol with a secondary
capital pool.

This pattern applies to: DeFi structured products with NFT vault shares, prediction
markets with ERC-721 positions, real-world asset protocols, and any parametric risk
transfer protocol built on ERC-4626.

---

## Known Issues

### Near-guaranteed payout exploit via strike manipulation (deployed contract)

The Sepolia deployment does not enforce bounds on `strikeMM`. This creates two
symmetric exploits, one per option type:

**Call exploit (zero or very low strike):**
A `Call` with `strikeMM = 0` pays out on any measurable rainfall at all. The payout
condition `actualRainfall > 0` is satisfied by virtually every non-arid location on
any multi-day window. A buyer with geographic knowledge can construct a near-guaranteed
payout — effectively using the vault as a bounded, certain-yield trade rather than a
risk transfer instrument.

**Put exploit (astronomically high strike):**
The mirror image. A `Put` with `strikeMM = 10000` pays out unless it rains 10 meters,
which never happens anywhere on Earth. A buyer simply picks any location, sets an
absurd strike, and collects a near-guaranteed payout bounded by `spreadMM × notional`.

**Why the premium calculator does not fully mitigate either:**
`PremiumCalculatorConsumer` prices both positions correctly against 10 years of
historical data — the premium for a zero-strike Call or a 10000mm Put will be high.
However, a sophisticated buyer can accept that premium knowing the payout probability
is near 1.0, making the trade a guaranteed yield extraction rather than a risk transfer.

**Fix implemented in this repository (not redeployed):**
`_validateParams` now enforces a duration-adjusted valid range for `strikeMM`:

```solidity
uint256 durationDays = (expiryDate - startDate) / 1 days;
if (strikeMM < durationDays * minDailyStrikeMM) revert InvalidStrike();
if (strikeMM > durationDays * maxDailyStrikeMM) revert StrikeTooHigh();
```

| Parameter | Default | Rationale |
|---|---|---|
| `minDailyStrikeMM` | 1 mm/day | Above baseline rainfall of Earth's driest inhabited regions (~2–4 mm/month) |
| `maxDailyStrikeMM` | 50 mm/day | Above the wettest sustained averages on Earth (~25–30 mm/day) |

For a 30-day option, the valid strike range is **[30 mm, 1500 mm]** — wide enough for
any legitimate weather hedging use case, impossible to exploit for near-certain payouts
in either direction. Both values are owner-configurable via `setMinDailyStrikeMM()` and
`setMaxDailyStrikeMM()` to allow tuning as the protocol expands to new geographies.

A more robust long-term solution would enforce strike bounds relative to
location-specific historical averages sourced from the oracle at creation time — but
this requires an additional Chainlink Functions call at quote time and is out of scope
for this submission.

### Premium calculator overflow on large notionals (deployed contract)

The Sepolia deployment encodes the final premium as `Functions.encodeUint256(Number(premiumWei))`.
JavaScript's `Number` type can only safely represent integers up to `2^53 − 1`. For notionals
above roughly `0.01 ETH`, the multiplied `premiumWei` BigInt can exceed this limit, silently
losing precision and returning a corrupted or zero premium quote.

**Fix implemented in this repository (not redeployed):**
The `Number()` cast is removed. The return is now:
```solidity
"return Functions.encodeUint256(premiumWei);"
```

`Functions.encodeUint256` accepts BigInt directly. The fix is one token — staying in
BigInt throughout eliminates the precision loss entirely. Testnet demos with small
notionals (~0.01 ETH) are unaffected, which is why this did not surface during testing.

---

## Chainlink Integration Summary

| File | Chainlink Service | Usage |
|---|---|---|
| `src/Bruma.sol` | Chainlink Functions | Premium pricing + rainfall settlement |
| `src/chainlinkfunctions/PremiumCalculatorConsumer.sol` | Chainlink Functions | 10yr historical rainfall → fair premium |
| `src/chainlinkfunctions/RainfallConsumer.sol` | Chainlink Functions | Actual rainfall at settlement |
| `src/BrumaCCIPEscrow.sol` | Chainlink CCIP | Cross-chain payout routing |
| `src/BrumaCCIPReceiver.sol` | Chainlink CCIP | Destination-chain payout delivery |
| `BrumaEscrow/main.ts` | Chainlink CRE | Settlement automation + risk guardian |
| `BrumaEscrow/workflows/risk.ts` | Chainlink CRE Confidential HTTP | Groq risk summary via secure enclave |

---

## Deployed Contracts

### Ethereum Sepolia (source chain)

| Contract | Address |
|---|---|
| `Bruma` | `0xB8171af0ecb428a74626C63dA843dc7840D409da` |
| `BrumaVault` | `0x91E707c9c78Cd099716A91BC63190BB813BE16d4` |
| `ReinsurancePool` | `0x1f24B221d3aEd386A239E1AD21B61bCE44dfcAbB` |
| `PremiumConsumer` | `0xEB36260fc0647D9ca4b67F40E1310697074897d4` |
| `PremiumCoordinator` | `0xf322B700c27a8C527F058f48481877855bD84F6e` |
| `RainfallCoordinator` | `0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6` |
| `RainfallConsumer` | `0x96722110DE16F18d3FF21E070F2251cbf8376f92` |
| `BrumaCCIPEscrowFactory` | `0x1DA7E84035FA37232F4955838feB9d851A900e3F` |
| `WETH` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

### Avalanche Fuji (destination chain)

| Contract | Address |
|---|---|
| `BrumaCCIPReceiver` | `0x3934A6a5952b2159B87C652b1919F718fb300eD6` |

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Bun](https://bun.sh) v1.2.21+
- [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation/macos-linux)
- A funded Sepolia wallet

### Install

```bash
git clone https://github.com/yourname/bruma-protocol
cd bruma-protocol
forge install
```

### Environment

```bash
cp .env.example .env
```

```bash
RPC_URL=
ACCOUNT=          # cast account name (keystore)
ETHERSCAN_API_KEY=
```

### Build & Test

```bash
forge build
forge test
forge test -vvv
```

---

## Deployment

### Core protocol (already deployed on Sepolia)

```bash
forge script script/DeployBruma.s.sol:DeployBruma \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify -vvvv
```

### Cross-chain escrow system

```bash
# 1. Deploy factory on Sepolia
export BRUMA_ADDRESS=0xB8171af0ecb428a74626C63dA843dc7840D409da
export CRE_WORKFLOW_ADDRESS=<cre-workflow-eoa>

forge script script/DeployBrumaFactory.s.sol \
  --rpc-url $SEPOLIA_RPC --account $ACCOUNT --broadcast --verify -vvvv

# 2. Deploy receiver on Avalanche Fuji
forge script script/DeployBrumaReceiver.s.sol \
  --rpc-url $FUJI_RPC --account $ACCOUNT --broadcast --verify -vvvv
```

### CRE Workflow

```bash
cd Bruma/BrumaEscrow
bun install

# Simulate against live Sepolia deployments
cre workflow simulate BrumaEscrow --target staging-settings --broadcast

# Deploy to CRE network
cre workflow deploy BrumaEscrow --target staging-settings
```

---

## Vault Operations

```bash
make balance          # Check WETH balance
make wrap             # Wrap ETH → WETH
make approve          # Approve vault
make deposit          # Deposit into vault
make metrics          # Full vault metrics
make max-withdraw     # Check max withdrawable
make withdraw         # Withdraw from vault
```

## Reinsurance Pool Operations

```bash
make reinsurance-capacity    # Check available capacity and maxDrawableNow
make reinsurance-deposit     # Deposit WETH into the reinsurance pool
make reinsurance-withdraw    # Withdraw shares from the reinsurance pool
make reinsurance-metrics     # totalAssets, totalDrawn, accruedYield
```

---

## Position Operations

```bash
# Request a premium quote
make quote-call LAT="6.25" LON="-75.56" STRIKE=100 SPREAD=50 NOTIONAL=10000000000000000

# Check if quote is ready
make check-quote REQUEST=0xYOUR_REQUEST_ID

# Create position from quote
make create-option REQUEST=0xYOUR_REQUEST_ID

# Check active positions
make active-options
```

---

## Security Notes

- Vault utilization is capped at **80% by default**. Liquidity providers always have an exit.
- Per-location exposure is capped at **20%**, limiting correlated payout risk.
- Position transfers are locked during the settlement window to prevent front-running.
- Payouts use the pull-payment pattern with auto-transfer attempted at settlement.
- Cross-chain escrows have a **7-day permissionless fallback** — funds can never be
  permanently locked.
- The CRE workflow is an authorized caller for settlement automation and reinsurance
  draws, but **never has custody of funds**. All value flows through the core contracts.
- **Reinsurance draws are bounded** by `maxDrawableNow`, which the ReinsurancePool
  enforces on-chain. The guardian cannot draw more than the pool allows regardless of
  the expected loss figure it computes.
- **Groq API key is never stored in workflow code or node memory.** It is fetched by
  the Vault DON and injected inside a secure enclave via Confidential HTTP. Node
  operators are cryptographically prevented from accessing it.
- **Strike bounds enforced at creation time.** `strikeMM` must satisfy
  `durationDays × minDailyStrikeMM ≤ strikeMM ≤ durationDays × maxDailyStrikeMM`
  (defaults: 1–50 mm/day). This prevents near-guaranteed payouts for both Calls
  (via zero/low strike) and Puts (via astronomically high strike). See
  [Known Issues](#known-issues) for deployed contract status.
- **Smart contracts are unaudited.** A formal audit is required before any mainnet
  deployment with real capital.

---

## License

MIT
