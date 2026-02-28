# Bruma — On-Chain Parametric Rainfall Derivatives

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

---

## Architecture

```
Bruma (ERC-721)
├── PremiumCoordinator        ← Chainlink Functions: pricing from 10yr historical data
│   └── PremiumConsumer
├── RainfallCoordinator       ← Chainlink Functions: settlement data from Open-Meteo
│   └── RainfallConsumer
├── BrumaVault (ERC-4626)     ← Liquidity & collateral management
└── CRE Workflow              ← Orchestration layer (settlement + risk + cross-chain)
    ├── Settlement Automation     → drives options through full lifecycle
    ├── Vault Risk Guardian       → proactive risk management via forecasts + AI
    └── BrumaCCIPEscrow System    → cross-chain payout routing via CCIP
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

**Option types.**
- `Call` — pays when oracle rainfall exceeds the strike level.
  `Payout = min(actual − strike, spread) × notional`
- `Put` — pays when oracle rainfall falls below the strike level.
  `Payout = min(strike − actual, spread) × notional`

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
| External data | Oracle calls only at settlement | Continuous forecast monitoring |
| AI risk analysis | Not possible | Groq LLM summary via Confidential HTTP |

### The two workflows

**Workflow 1 — Settlement Automation** runs every 5 minutes. It fetches all active
positions, drives expired ones through `requestSettlement()` → `settle()`, and routes
payouts. For cross-chain buyers whose NFT is held in a `BrumaCCIPEscrow`, it calls
`claimAndBridge()` which transfers WETH via CCIP.

**Workflow 2 — Vault Risk Guardian** runs every hour. It fetches 7-day weather forecasts
from Open-Meteo for every active position location, calls `simulatePayout()` with the
forecasted rainfall to compute expected loss, and if aggregate expected loss as a
percentage of TVL breaches the configured threshold, it tightens vault utilization limits
**before** settlements arrive. It then generates a natural-language risk summary via Groq
using Confidential HTTP.

This is the core runtime innovation: **a liquidity vault that reads the weather forecast
and consults an AI to manage its own risk exposure.**

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

**Risk Guardian with Confidential HTTP + Groq:**
```
2026-02-24T10:56:54Z [USER LOG] === Bruma Vault Risk Guardian triggered ===
2026-02-24T10:56:54Z [USER LOG] Vault: TVL=10843315000000000000 | Utilization=23.97% | NetPnL=1343315000000000000
2026-02-24T10:56:55Z [USER LOG] TokenId 3 [6.25,-75.56]: forecast = 16.4mm over 7 days
2026-02-24T10:56:56Z [USER LOG] TokenId 2 [25.76,-80.19]: forecast = 5.1mm over 7 days
2026-02-24T10:56:57Z [USER LOG] Expected loss across 6 options: 1050000000000000000 wei
2026-02-24T10:56:57Z [USER LOG] Expected loss as % of TVL: 9.68% | Alert threshold: 70%
2026-02-24T10:57:06Z [USER LOG] Groq risk summary: The vault holds roughly 10.84 ETH and
                                has generated a net profit of about 1.34 ETH. Current
                                utilization is 23.97%, comfortably below the 70% alert
                                threshold. The forecasted loss of 9.68% of TVL (≈ 1.05 ETH)
                                warrants monitoring given six active positions across two
                                locations.

✓ Workflow Simulation Result:
"Vault healthy. Utilization: 23.97%. Expected loss: 9.68% of TVL. No action needed."
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

## Protocol Governance

Admin functions are currently controlled by a deployer EOA. Before any mainnet deployment:

- All `onlyOwner` state-changing functions (except `withdrawFees`) will be placed behind
  a 48–72 hour timelock
- The owner wallet will move to a multisig (Gnosis Safe, minimum 2-of-3)
- `withdrawFees` remains owner-controlled as collecting a protocol fee is legitimate
  and does not affect position holder outcomes

The CRE workflow is an authorized caller for settlement automation but has no custody
of funds. All value flows through the audited core contracts.

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

This pattern applies to: DeFi structured products with NFT vault shares, prediction
markets with ERC-721 positions, real-world asset protocols, and any parametric risk
transfer protocol built on ERC-4626.

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
| `Bruma` | `0x762a995182433fDE85dC850Fa8FF6107582110d2` |
| `BrumaVault` | `0x681915B4226014045665e4D5d6Bb348eB90cB32f` |
| `PremiumConsumer` | `0xEB36260fc0647D9ca4b67F40E1310697074897d4` |
| `PremiumCoordinator` | `0xf322B700c27a8C527F058f48481877855bD84F6e` |
| `RainfallCoordinator` | `0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6` |
| `RainfallConsumer` | `0x96722110DE16F18d3FF21E070F2251cbf8376f92` |
| `BrumaCCIPEscrowFactory` | `0x39a0430cFB4E1b850087ba6157bB0c5F35b20dF4` |
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
export BRUMA_ADDRESS=0x762a995182433fDE85dC850Fa8FF6107582110d2
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
- The CRE workflow is an authorized caller but never has custody of funds.
- **Groq API key is never stored in workflow code or node memory.** It is fetched by
  the Vault DON and injected inside a secure enclave via Confidential HTTP. Node
  operators are cryptographically prevented from accessing it.
- **Smart contracts are unaudited.** A formal audit is required before any mainnet
  deployment with real capital.

---

## License

MIT