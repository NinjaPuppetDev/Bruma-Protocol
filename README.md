# Bruma Protocol

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
    ├── Vault Risk Guardian       → proactive risk management via forecasts
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

### The two workflows

**Workflow 1 — Settlement Automation** runs every 5 minutes. It fetches all active options, drives expired ones through `requestSettlement()` → `settle()`, and then routes payouts. For cross-chain buyers whose NFT is held in a `BrumaCCIPEscrow`, it calls `claimAndBridge()` which transfers WETH to the buyer's native chain via CCIP. Same-chain buyers are handled by Bruma's built-in auto-claim mechanism.

**Workflow 2 — Vault Risk Guardian** runs every hour. It fetches 7-day weather forecasts from the Open-Meteo API for every active option location, calls `simulatePayout()` with the forecasted rainfall to compute expected loss, and if aggregate expected loss as a percentage of TVL breaches the configured threshold, it calls `setUtilizationLimits()` to tighten the vault — **before** claims arrive.

This is the key innovation: **a liquidity vault that reads the weather forecast to protect its own capital.**

### Simulation results

Running `cre workflow simulate BrumaEscrow --target staging-settings --broadcast` against live Sepolia deployments:

**Settlement workflow** (2 active options, neither expired yet):
```
2026-02-20T08:58:17Z [USER LOG] === Bruma Settlement Workflow triggered ===
2026-02-20T08:58:17Z [USER LOG] Active options: 2
2026-02-20T08:58:17Z [USER LOG] TokenId 0: not yet expired, skipping.
2026-02-20T08:58:18Z [USER LOG] TokenId 1: not yet expired, skipping.

✓ Workflow Simulation Result:
"Settlement requested: []\nSettled: []\nBridged (CCIP): []\nSkipped: [0, 1]\nErrors: 0"
```

**Risk Guardian workflow** (live vault data + Open-Meteo forecast for Medellín):
```
2026-02-20T08:58:37Z [USER LOG] === Bruma Vault Risk Guardian triggered ===
2026-02-20T08:58:37Z [USER LOG] Vault: TVL=5401700000000000000 | Utilization=9.25% | NetPnL=401700000000000000
2026-02-20T08:58:39Z [USER LOG] TokenId 0 [6.25,-75.56]: forecast = 59.5mm over 7 days
2026-02-20T08:58:39Z [USER LOG] TokenId 1 [6.25,-75.56]: forecast = 59.5mm over 7 days
2026-02-20T08:58:39Z [USER LOG] Expected loss across 2 options: 250000000000000000 wei
2026-02-20T08:58:39Z [USER LOG] Expected loss as % of TVL: 4.62% | Alert threshold: 70%

✓ Workflow Simulation Result:
"Vault healthy. Utilization: 9.25%. Expected loss: 4.62% of TVL. No action needed."
```

The Risk Guardian fetched a live 7-day forecast (59.5mm for Medellín), simulated the payout against each active option, computed 4.62% expected loss against the vault's TVL, and correctly decided no action was needed. If a storm were forming, the vault would tighten automatically.

### Cross-chain payout system (BrumaCCIPEscrow)

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

The prerequisite for any protocol adopting this pattern is that it must **emit events CRE can subscribe to**. A protocol that performs silent state transitions — updating storage without events — cannot be wired to CRE without modification. This is the honest boundary of what "non-invasive" means: non-invasive to protocols already built with observable state transitions, which is best practice anyway.

This means the pattern could be applied to:
- **DeFi structured products** where vault shares are NFTs
- **Prediction markets** with ERC-721 positions and pull-payment settlement
- **Real-world asset protocols** where payouts accrue to NFT holders on settlement
- **Any parametric insurance protocol** built on ERC-4626

The CRE layer is what makes this composable — without a workflow orchestrator, someone would still need to manually call `claimAndBridge()`. With CRE, the entire lifecycle from expiry detection to cross-chain delivery is fully automatic.

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
| `BrumaCCIPEscrowFactory` | `0xCE425d7Eee6de977c8B07324dE5BdC78354d02Ae` |
| `WETH` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

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

---

## License

MIT