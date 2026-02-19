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
├── PremiumCoordinator        ← Chainlink Functions: pricing
│   └── PremiumConsumer
├── RainfallCoordinator       ← Chainlink Functions: settlement data
│   └── RainfallConsumer
├── BrumaVault (ERC-4626)     ← Liquidity & collateral management
└── Chainlink Automation      ← Triggers settlement at expiry
```

### Option lifecycle

```
requestPremiumQuote()   →   [Chainlink Functions: 10yr historical data]
      ↓
createOptionWithQuote() →   NFT minted, collateral locked in vault
      ↓
[observation window]
      ↓
settleOption()          →   [Chainlink Automation + Rainfall Oracle]
      ↓
claimPayout()           →   WETH transferred to holder
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

## Deployed Contracts (Sepolia)

| Contract | Address |
|---|---|
| `BrumaProtocol` | `0x762a995182433fDE85dC850Fa8FF6107582110d2` |
| `BrumaVault` | `0x681915B4226014045665e4D5d6Bb348eB90cB32f` |
| `PremiumConsumer` | `0xEB36260fc0647D9ca4b67F40E1310697074897d4` |
| `PremiumCoordinator` | `0xf322B700c27a8C527F058f48481877855bD84F6e` |
| `RainfallCoordinator` | `0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6` |
| `WETH (Sepolia)` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Node.js](https://nodejs.org/) (for the frontend)
- A funded Sepolia wallet

### Install

```bash
git clone https://github.com/yourname/bruma-protocol
cd bruma-protocol
forge install
```

### Environment

Copy the example env file and fill in your values:

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
forge test -vvv          # verbose output
```

### Coverage

```bash
forge coverage
forge coverage --report lcov   # outputs lcov.info for IDE integration
```

---

## Deployment

All deployment steps are available as `make` commands. See [Makefile](#makefile) below.

### Manual sequence

```bash
# 1. Deploy Rainfall Consumer
forge script script/DeployRainfall.s.sol \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify $ETHERSCAN_API_KEY

# 2. Deploy Rainfall Coordinator
forge script script/DeployCoordinator.s.sol \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify $ETHERSCAN_API_KEY

# 3. Transfer ownership of Rainfall Consumer → Coordinator, then accept
cast send $RAINFALL_CONSUMER "transferOwnership(address)" $RAINFALL_COORDINATOR ...
cast send $RAINFALL_COORDINATOR "acceptConsumerOwnership()" ...

# 4. Deploy Premium Consumer
forge script script/DeployPremiumConsumer.s.sol:DeployPremiumConsumer \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify $ETHERSCAN_API_KEY

# 5. Deploy Premium Coordinator
forge script script/DeployPremiumCoordinator.s.sol:DeployPremiumCoordinator \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify $ETHERSCAN_API_KEY

# 6. Transfer ownership of Premium Consumer → Coordinator, then accept
cast send $PREMIUM_CONSUMER "transferOwnership(address)" $PREMIUM_COORDINATOR ...
cast send $PREMIUM_COORDINATOR "acceptConsumerOwnership()" ...

# 7. Deploy Bruma + Vault
forge script script/DeployBruma.s.sol:DeployBruma \
  --rpc-url $RPC_URL --account $ACCOUNT --broadcast --verify $ETHERSCAN_API_KEY
```

---

## Vault Operations

```bash
# Check WETH balance
make balance

# Wrap ETH → WETH
make wrap AMOUNT=1ether

# Approve vault to spend WETH
make approve AMOUNT=1000000000000000000

# Deposit into vault
make deposit AMOUNT=1000000000000000000

# Check max withdrawable
make max-withdraw

# Withdraw from vault
make withdraw AMOUNT=500000000000000000

# Full vault metrics
make metrics
```

---

## Option Operations

### Request a premium quote

```bash
# Call option (excess rain protection)
make quote-call LAT="10.0" LON="-75.0" STRIKE=100 SPREAD=50 NOTIONAL=10000000000000000

# Put option (drought protection)
make quote-put LAT="10.0" LON="-75.0" STRIKE=80 SPREAD=50 NOTIONAL=10000000000000000
```

The contract computes `START` as 5 minutes from now and `EXPIRY` as 3 days after that automatically when using the Makefile.

### Check if quote is ready

```bash
make check-quote REQUEST=0xYOUR_REQUEST_ID
```

### Create option from quote

```bash
make create-option REQUEST=0xYOUR_REQUEST_ID
```

The Makefile reads the premium from the consumer contract, adds the 1% protocol fee, and sends the exact amount.

### Check active options

```bash
make active-options
```

---

## Security Notes

- Vault utilization is capped at **80% by default**. This ensures liquidity providers always have an exit even when many options are active.
- Per-location exposure is capped at **20%**, limiting correlated payout risk.
- Option transfers are locked during the settlement window (last 24h before expiry).
- Payouts use the pull-payment pattern. Auto-claim is attempted at settlement; holders can always claim manually if it fails.

---

## License

MIT