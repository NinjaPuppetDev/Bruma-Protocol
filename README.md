# Bruma — Parametric Rainfall Insurance on Chainlink CRE

**Parametric rainfall options, on-chain.**
Bruma transforms weather uncertainty into a structured financial position — priced by Chainlink oracles, settled automatically, owned as an NFT.

> Built in Medellín, Colombia · Chainlink Convergence 2026

---

## Overview

Bruma Protocol lets any operator — a farmer, an event venue, a recreational farm — hedge rainfall risk directly on-chain. No counterparty negotiations. No insurance bureaucracy. A user selects their coordinates, strike level in millimeters, observation window, and option type (Call or Put), pays a Chainlink-priced premium, and receives an ERC-721 NFT representing their position. At expiry, Chainlink Automation fetches real rainfall data and settles the contract automatically.

The protocol has two user roles: **option buyers**, who pay premiums to hedge risk, and **liquidity providers**, who deposit WETH into an ERC-4626 vault and earn a share of those premiums in exchange for backing the positions.

---

## Architecture

```
BrumaProtocol (ERC-721)
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

### Option lifecycle

```
requestPremiumQuote()   →   [Chainlink Functions: 10yr historical data]
      ↓
createOptionWithQuote() →   NFT minted, collateral locked in vault
      ↓
[observation window]
      ↓
requestSettlement()     →   [CRE Workflow detects expiry automatically]
      ↓
settle()                →   [Chainlink Functions: actual rainfall data]
      ↓
claimPayout()           →   WETH to holder (same-chain) or CCIP bridge (cross-chain)
```

### Key design decisions

**Two-step creation.** A quote must be requested before an option is created. Quotes are valid for 1 hour, preventing stale pricing and ensuring premiums reflect real conditions at purchase time.

**ERC-721 options.** Each position is a transferable NFT. Transfers are locked during the settlement window to prevent front-running.

**ERC-4626 vault.** Standard vault with virtual share offset (inflation attack protection). Maximum utilization is capped at 80% of TVL. Per-location exposure is capped at 20%, limiting correlated risk for liquidity providers.

**Pull payment pattern.** Payouts follow the CEI pattern. Auto-claim is attempted at settlement; if it fails, holders can always claim manually.

**Option types.**
- `Call` — pays when actual rainfall exceeds the strike level. Payout = `min(actual − strike, spread) × notional`
- `Put` — pays when actual rainfall falls below the strike level. Payout = `min(strike − actual, spread) × notional`

---

## Chainlink CRE Integration

Bruma uses the **Chainlink Runtime Environment (CRE)** as a parallel automation layer that runs alongside the protocol. This is not a wrapper — the core contracts are never modified, but were deliberately designed with CRE integration in mind: every state transition emits an event that the workflow can subscribe to as a trigger. CRE operates as an external orchestrator that reads from and writes to the already-deployed protocol.

This is an important design constraint to understand: **CRE integration is not free**. For a protocol to be orchestrated by a CRE workflow, it must emit the right events at the right moments. Bruma's contracts emit `OptionCreated`, `SettlementRequested`, `OptionSettled`, and `EscrowDeployed` at each lifecycle stage — these are what the workflow subscribes to. A protocol built without this in mind cannot be wired to CRE without modification.

### What CRE adds that the contracts alone cannot do

Most on-chain derivatives protocols are **purely reactive** — they settle after the fact, triggered by external keepers or manual calls. The CRE layer makes Bruma **predictive and fully automatic**:

| Capability | Without CRE | With CRE |
|---|---|---|
| Settlement triggering | Manual or separate Automation job | Automatic, driven by workflow |
| Payout delivery | Same-chain only, pull pattern | Cross-chain via CCIP, auto-pushed |
| Risk management | Static vault limits | Dynamic limits adjusted by weather forecasts |
| External data | Oracle calls only at settlement | Continuous forecast monitoring |
| AI risk analysis | Not possible | Groq LLM summary via Confidential HTTP |

### The two workflows

**Workflow 1 — Settlement Automation** runs every 5 minutes. It fetches all active options, drives expired ones through `requestSettlement()` → `settle()`, and then routes payouts. For cross-chain buyers whose NFT is held in a `BrumaCCIPEscrow`, it calls `claimAndBridge()` which transfers WETH to the buyer's native chain via CCIP. Same-chain buyers are handled by Bruma's built-in auto-claim mechanism.

**Workflow 2 — Vault Risk Guardian** runs every hour. It fetches 7-day weather forecasts from the Open-Meteo API for every active option location, calls `simulatePayout()` with the forecasted rainfall to compute expected loss, and if aggregate expected loss as a percentage of TVL breaches the configured threshold, it calls `setUtilizationLimits()` to tighten the vault — **before** claims arrive. It then generates a natural-language risk summary via Groq using Confidential HTTP.

This is the key innovation: **a liquidity vault that reads the weather forecast and consults an AI to protect its own capital.**

---

## Confidential Compute: The Problem No One Talks About

### The problem with AI in decentralized workflows

Integrating an LLM into a decentralized workflow sounds straightforward — until you think about what it actually requires: an API key. And that's where the architecture falls apart.

In a standard decentralized network, your workflow runs across multiple independent nodes. Each node executes the same code. If you need to call the Groq API, every one of those nodes needs the API key to make the HTTP request. That means one of the following, and none of them are acceptable:

- **Hardcode the key in the workflow** — now your key is visible in the bytecode deployed to the network. It will be extracted and abused within hours.
- **Store the key on-chain** — visible to anyone who reads the contract. Worse than hardcoding.
- **Give each node operator the key separately** — now you're trusting every node operator not to share or misuse it. You've replaced a cryptographic guarantee with a social one.
- **Don't use AI at all** — you sacrifice the capability entirely.

This isn't a niche edge case. It applies to **any authenticated external API**: weather data providers, financial data feeds, off-chain databases, compliance checks, AI inference endpoints. The moment your workflow needs a credential, decentralization becomes a liability.

The deeper problem is that the API key isn't the only thing that's exposed. The **response** is too. When a node calls Groq and gets back a risk analysis, every other node can see that response in the clear. If your AI is analyzing sensitive vault metrics, competitive positioning, or user-specific data, that data is now readable by every node operator in the network.

**Existing workarounds don't solve it.** Some protocols try to route sensitive calls through a single trusted node — but that reintroduces centralization. Others use threshold encryption schemes that require complex key management and still expose data during computation. The fundamental tension between "decentralized execution" and "authenticated private calls" has no clean solution in the standard model.

### How Bruma solves it with CRE Confidential HTTP

Bruma uses the **Chainlink CRE Confidential HTTP** capability, which resolves this tension at the infrastructure level using **secure enclaves**.

Instead of each node making the API call independently, the request is routed into a **Trusted Execution Environment (TEE)** — a hardware-isolated compute environment where code runs in a verifiably sealed context. The enclave:

1. Pulls the API key from the **Vault DON** (Chainlink's decentralized secret store) — the key never appears in the workflow code or node memory
2. Injects the key into the request using Go template syntax (`{{.groqApiKey}}`) inside the sealed environment
3. Executes the HTTP request from within the enclave — the key is never exposed outside it
4. Optionally encrypts the response before it leaves the enclave, so even node operators cannot read it

The result: **the Groq API key exists nowhere in the workflow codebase, nowhere in any node's memory, and nowhere on-chain.** It is fetched by the enclave, used once, and discarded. Node operators run the workflow but are cryptographically prevented from accessing the credentials or intercepting the response.

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

This is not a workaround. It's a new primitive: **authenticated, private external calls from a decentralized network.**

### What this unlocks for Bruma

The Vault Risk Guardian uses Confidential HTTP to call the **Groq compound model** after computing expected loss from weather forecasts. The model receives live vault metrics — TVL, utilization, PnL, active option count, location distribution — and returns a natural-language risk summary that the workflow logs and includes in its output.

Live simulation result with Confidential HTTP active:

```
2026-02-24T10:57:06Z [USER LOG] Groq risk summary: The vault holds roughly 10.84 ETH
(TVL = 1.0843 × 10¹⁹ wei) and has generated a net profit of about 1.34 ETH
(Net PnL = 1.3433 × 10¹⁸ wei). While current utilization is 23.97%, comfortably
below the 70% alert threshold, the forecasted loss of 9.68% of TVL (≈ 1.05 ETH)
is a material risk that warrants close monitoring, especially given the six active
options spread across two locations.
```

The Groq API key that authenticated this request was never visible to any node, never appeared in any log, and was never stored anywhere in the workflow. The enclave fetched it, used it, and discarded it.

### Why this matters beyond Bruma

The Confidential HTTP pattern solves a problem that blocks **every serious DeFi protocol** from integrating authenticated external services:

- **AI-powered risk engines** that require inference API keys
- **KYC/AML compliance checks** against authenticated identity providers
- **Premium pricing feeds** from commercial weather or financial data providers
- **Cross-protocol risk monitoring** that requires authenticated reads from partner APIs
- **Any workflow** that needs a credential to do its job

Before Confidential HTTP, the choice was: centralize or don't use credentials. Now there's a third option: use credentials in a decentralized network, with cryptographic guarantees that no single party can extract them.

---

## Simulation Results

Running `cre workflow simulate BrumaEscrow --target staging-settings --broadcast` against live Sepolia deployments:

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
                                has generated a net profit of about 1.34 ETH. While current
                                utilization is 23.97%, comfortably below the 70% alert
                                threshold, the forecasted loss of 9.68% of TVL (≈ 1.05 ETH)
                                is a material risk that warrants close monitoring, especially
                                given the six active options spread across two locations.

✓ Workflow Simulation Result:
"Vault healthy. Utilization: 23.97%. Expected loss: 9.68% of TVL. No action needed."
```

---

## Cross-chain payout system (BrumaCCIPEscrow)

For buyers on other chains who want to purchase Bruma options on Ethereum without bridging first, the protocol provides a companion contract system that requires **zero modifications to the core contracts**.

```
Buyer on Avalanche
  │
  └─► Deploys BrumaCCIPEscrow on Ethereum (via BrumaCCIPEscrowFactory)
        │  Personal smart wallet holding their Bruma NFT
        ├─► Bruma settles normally → escrow is ownerAtSettlement
        ├─► CRE workflow detects OptionSettled event
        ├─► CRE calls escrow.claimAndBridge(tokenId)
        └─► WETH bridged via CCIP → BrumaCCIPReceiver on Avalanche
              └─► Buyer receives WETH on their native chain
```

A 7-day permissionless fallback ensures funds can never be permanently locked if the CRE workflow is offline.

---

## Competitive Advantage and Generalizability

The `BrumaCCIPEscrow` pattern solves a problem that affects **every ERC-4626 vault that issues ERC-721 positions** — not just Bruma.

### The general problem

Any protocol where:
1. A vault locks collateral against an NFT position
2. Payout is restricted to `msg.sender == ownerAtSettlement` (or equivalent snapshot)
3. Buyers may live on different chains

...faces the same cross-chain payout routing problem. Today these protocols either force users to bridge to the source chain, or they modify their core contracts to add cross-chain logic — introducing audit surface and upgrade risk.

### The Bruma solution

The `BrumaCCIPEscrow` is **vault-agnostic and non-invasive at the contract level**. Any protocol can adopt it by:

1. Emitting a discoverable deployment event (e.g. `EscrowDeployed`) that the CRE workflow can index
2. Deploying `BrumaCCIPEscrowFactory` with their protocol address
3. Writing a CRE workflow that watches their settlement event
4. Pointing cross-chain buyers to `deployEscrow()` before purchase

The critical insight is in step 1. The `BrumaCCIPEscrowFactory` emits `EscrowDeployed(address escrow, address owner, uint64 destinationChainSelector, address destinationReceiver)` every time a buyer creates a personal escrow. The CRE workflow subscribes to this event and **builds its own off-chain registry** — a mapping of `escrow address → destination chain + receiver` — without needing any on-chain registry contract. There is no `mapping(address => address)` stored anywhere on-chain. The workflow reconstructs the full picture from event history every time it runs.

This means when `OptionSettled` fires and `ownerAtSettlement` is some address, the workflow can instantly answer "is this a registered escrow?" by checking its in-memory registry built from `EscrowDeployed` logs — and if yes, call `claimAndBridge()` on it. No on-chain lookup, no registry storage costs, no additional contract surface to audit.

The prerequisite for any protocol adopting this pattern is that it must **emit events CRE can subscribe to**. A protocol that performs silent state transitions cannot be wired to CRE without modification. This is the honest boundary of what "non-invasive" means: non-invasive to protocols already built with observable state transitions, which is best practice anyway.

This pattern could be applied to:
- **DeFi structured products** where vault shares are NFTs
- **Prediction markets** with ERC-721 positions and pull-payment settlement
- **Real-world asset protocols** where payouts accrue to NFT holders on settlement
- **Any parametric insurance protocol** built on ERC-4626

---

## Chainlink Integration

Every file in this repository that uses a Chainlink service is listed below.

| File | Chainlink Service | How it's used |
|---|---|---|
| [`src/Bruma.sol`](./src/Bruma.sol) | Chainlink Functions | Calls `PremiumCoordinator` for option pricing and `RainfallCoordinator` for settlement data |
| [`src/chainlinkfunctions/PremiumCalculatorConsumer.sol`](./src/chainlinkfunctions/PremiumCalculatorConsumer.sol) | Chainlink Functions | Fetches 10 years of Open-Meteo historical rainfall to compute fair option premiums |
| [`src/chainlinkfunctions/PremiumCalculatorCoordinator.sol`](./src/chainlinkfunctions/PremiumCalculatorCoordinator.sol) | Chainlink Functions | Coordinator that owns the consumer and exposes `requestPremium()` to Bruma |
| [`src/chainlinkfunctions/RainfallConsumer.sol`](./src/chainlinkfunctions/RainfallConsumer.sol) | Chainlink Functions | Fetches actual rainfall from Open-Meteo at settlement time |
| [`src/chainlinkfunctions/RainfallCoordinator.sol`](./src/chainlinkfunctions/RainfallCoordinator.sol) | Chainlink Functions | Coordinator that owns the rainfall consumer and exposes `requestRainfall()` to Bruma |
| [`src/BrumaCCIPEscrow.sol`](./src/BrumaCCIPEscrow.sol) | Chainlink CCIP | `BrumaCCIPEscrow` wraps ETH → WETH and sends it cross-chain via `IRouterClient.ccipSend()`. `BrumaCCIPEscrowFactory` deploys personal escrows for cross-chain buyers |
| [`src/BrumaCCIPReceiver.sol`](./src/BrumaCCIPReceiver.sol) | Chainlink CCIP | Deployed on Avalanche Fuji. Receives CCIP messages from escrows on Sepolia and forwards WETH to buyers |
| [`BrumaEscrow/main.ts`](./BrumaEscrow/main.ts) | Chainlink CRE | Settlement automation + Vault Risk Guardian with weather forecasts |
| [`BrumaEscrow/workflows/risk.ts`](./BrumaEscrow/workflows/risk.ts) | Chainlink CRE Confidential HTTP | Groq compound model called via secure enclave — API key injected from Vault DON, never exposed to node operators |

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
| `RainfallConsumer`  |  `'0x96722110DE16F18d3FF21E070F2251cbf8376f92'` |
| `BrumaCCIPEscrowFactory` | `0x39a0430cFB4E1b850087ba6157bB0c5F35b20dF4` |
| `WETH` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

old 0x79ef70728f07ebfc2af439568cc1ebdb756e487c6bb8c3f75b9ca2b3358386c5

### Avalanche Fuji (destination chain)

| Contract | Address |
|---|---|
| `BrumaCCIPReceiver` | `0x3934A6a5952b2159B87C652b1919F718fb300eD6` |

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Bun](https://bun.sh) v1.2.21+ (required for CRE workflow compilation)
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
# .env
RPC_URL=
ACCOUNT=          # cast account name (keystore)
ETHERSCAN_API_KEY=
```

### Build

```bash
forge build
```

### Test

```bash
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
export BRUMA_FACTORY_ADDRESS=0xCE425d7Eee6de977c8B07324dE5BdC78354d02Ae

forge script script/DeployBrumaReceiver.s.sol \
  --rpc-url $FUJI_RPC --account $ACCOUNT --broadcast --verify -vvvv
```

### CRE Workflow

```bash
cd Bruma/BrumaEscrow
bun install

# Set up secrets
export GROQ_API_KEY_ALL="gsk_..."   # Groq API key for Confidential HTTP

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

## Option Operations

```bash
# Request a premium quote
make quote-call LAT="6.25" LON="-75.56" STRIKE=100 SPREAD=50 NOTIONAL=10000000000000000

# Check if quote is ready
make check-quote REQUEST=0xYOUR_REQUEST_ID

# Create option from quote
make create-option REQUEST=0xYOUR_REQUEST_ID

# Check active options
make active-options
```

---

## Security Notes

- Vault utilization is capped at **80% by default**. Liquidity providers always have an exit.
- Per-location exposure is capped at **20%**, limiting correlated payout risk.
- Option transfers are locked during the settlement window to prevent front-running.
- Payouts use the pull-payment pattern with auto-claim attempted at settlement.
- Cross-chain escrows have a **7-day permissionless fallback** — funds can never be permanently locked.
- The CRE workflow is an authorized caller but never has custody of funds. All value flows through the audited core contracts.
- **Groq API key is never stored in workflow code or node memory.** It is fetched by the Vault DON and injected inside a secure enclave via Confidential HTTP. Node operators running the workflow are cryptographically prevented from accessing it.

---

## License

MIT