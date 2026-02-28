# ============================================================
#  Bruma — Deployment & Operations Makefile
#  Usage: make <target>
#  Requires: forge, cast, jq
# ============================================================

# ── Load .env if present ─────────────────────────────────────
-include .env
export

# ── Required env vars ────────────────────────────────────────
RPC          ?= https://eth-sepolia.g.alchemy.com/v2/your-api-here
ACCOUNT      ?= rainfall-deployer
ETHERSCAN_KEY ?= SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB
DEPLOYER     ?= 0xc022d2263835D14D5AcA7E3f45ADA019D1E23D9e

# ── Unchanged contract addresses ─────────────────────────────
WETH                 ?= 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
RAINFALL_COORDINATOR ?= 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6
RAINFALL_CONSUMER    ?= 0x96722110DE16F18d3FF21E070F2251cbf8376f92
PREMIUM_COORDINATOR  ?= 0xf322B700c27a8C527F058f48481877855bD84F6e
PREMIUM_CONSUMER     ?= 0xEB36260fc0647D9ca4b67F40E1310697074897d4
CCIP_FACTORY         ?= 0x39a0430cFB4E1b850087ba6157bB0c5F35b20dF4

# ── New addresses (set after deploy) ─────────────────────────
BRUMA            ?= 0xB8171af0ecb428a74626C63dA843dc7840D409da
VAULT            ?= 0x91E707c9c78Cd099716A91BC63190BB813BE16d4
REINSURANCE_POOL ?= 0x1f24B221d3aEd386A239E1AD21B61bCE44dfcAbB

# ── Hackathon risk limits ─────────────────────────────────────
MAX_UTIL         ?= 9500
TARGET_UTIL      ?= 7000
MAX_LOCATION_EXP ?= 8000
REINSURANCE_BPS  ?= 500

# ── Formatting helpers ────────────────────────────────────────
BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[32m
CYAN  := \033[36m
YELLOW := \033[33m

.PHONY: help \
        build test test-fork coverage \
        deploy-all deploy-chainlink deploy-core deploy-factory \
        fund-vault set-limits set-guardian activate-reinsurance \
        quote-flood quote-drought check-quote create-option \
        check-vault check-bruma check-pool \
        wrap-eth approve-weth \
        clean

# ============================================================
#  HELP
# ============================================================

help:
	@echo ""
	@echo "$(BOLD)$(CYAN)Bruma — Operations Makefile$(RESET)"
	@echo ""
	@echo "$(BOLD)Build & Test$(RESET)"
	@echo "  make build              Compile all contracts"
	@echo "  make test               Run unit tests (no fork)"
	@echo "  make test-fork          Run fork tests against Sepolia"
	@echo "  make coverage           Coverage report (no fork)"
	@echo "  make coverage-fork      Coverage report (with fork)"
	@echo ""
	@echo "$(BOLD)Deployment$(RESET)"
	@echo "  make deploy-chainlink   Deploy RainfallConsumer + RainfallCoordinator"
	@echo "                          + PremiumConsumer + PremiumCoordinator (first time only)"
	@echo "  make deploy-core        Redeploy Bruma + BrumaVault + ReinsurancePool"
	@echo "  make deploy-factory     Redeploy BrumaCCIPEscrowFactory (if BRUMA changed)"
	@echo "  make deploy-all         Full fresh deploy (chainlink + core + factory)"
	@echo ""
	@echo "$(BOLD)Post-Deploy Config$(RESET)"
	@echo "  make fund-vault         Wrap 1 ETH and deposit into vault"
	@echo "  make set-limits         Set hackathon utilization + location limits"
	@echo "  make set-guardian       Set deployer as guardian (dev shortcut)"
	@echo "  make activate-reinsurance  Wire vault to reinsurance pool"
	@echo ""
	@echo "$(BOLD)Options Operations$(RESET)"
	@echo "  make quote-flood        Request flood protection premium quote"
	@echo "  make quote-drought      Request drought protection premium quote"
	@echo "  make check-quote        Check if REQUEST_ID quote is fulfilled"
	@echo "  make create-option      Create option from fulfilled REQUEST_ID"
	@echo ""
	@echo "$(BOLD)Monitoring$(RESET)"
	@echo "  make check-vault        Print all vault metrics"
	@echo "  make check-bruma        Print Bruma state"
	@echo "  make check-pool         Print ReinsurancePool state"
	@echo ""
	@echo "$(BOLD)Required env vars$(RESET)"
	@echo "  RPC, ACCOUNT, ETHERSCAN_KEY, DEPLOYER"
	@echo "  BRUMA, VAULT, REINSURANCE_POOL  (after deploy)"
	@echo "  REQUEST_ID                       (for check-quote / create-option)"
	@echo ""

# ============================================================
#  BUILD & TEST
# ============================================================

build:
	@echo "$(BOLD)Building...$(RESET)"
	forge build

test:
	@echo "$(BOLD)Running unit tests...$(RESET)"
	forge test --no-match-contract "DeploymentTest" -v

test-fork:
	@echo "$(BOLD)Running fork tests against Sepolia...$(RESET)"
	forge test --match-contract "DeploymentTest" --fork-url $(RPC) -vvv

coverage:
	@echo "$(BOLD)Coverage (unit tests)...$(RESET)"
	forge coverage --no-match-contract "DeploymentTest"

coverage-fork:
	@echo "$(BOLD)Coverage (with fork)...$(RESET)"
	forge coverage --fork-url $(RPC)

clean:
	forge clean

# ============================================================
#  CHAINLINK INFRASTRUCTURE (first time only)
# ============================================================

deploy-chainlink: _deploy-rainfall-consumer _transfer-rainfall-ownership \
                  _accept-rainfall-ownership \
                  _deploy-premium-consumer _deploy-premium-coordinator \
                  _transfer-premium-ownership _accept-premium-ownership
	@echo "$(GREEN)$(BOLD)Chainlink infra deployed and wired.$(RESET)"

_deploy-rainfall-consumer:
	@echo "$(BOLD)[1/7] Deploying RainfallConsumer...$(RESET)"
	forge script script/DeployRainfall.s.sol \
	  --rpc-url $(RPC) --account $(ACCOUNT) \
	  --broadcast --verify $(ETHERSCAN_KEY)

_deploy-rainfall-coordinator:
	@echo "$(BOLD)[2/7] Deploying RainfallCoordinator...$(RESET)"
	forge script script/DeployCoordinator.s.sol \
	  --rpc-url $(RPC) --account $(ACCOUNT) \
	  --broadcast --verify $(ETHERSCAN_KEY)

_transfer-rainfall-ownership:
	@echo "$(BOLD)[3/7] Transferring RainfallConsumer ownership to Coordinator...$(RESET)"
	cast send $(RAINFALL_CONSUMER) \
	  "transferOwnership(address)" $(RAINFALL_COORDINATOR) \
	  --rpc-url $(RPC) --account $(ACCOUNT)

_accept-rainfall-ownership:
	@echo "$(BOLD)[4/7] Coordinator accepting consumer ownership...$(RESET)"
	cast send $(RAINFALL_COORDINATOR) \
	  "acceptConsumerOwnership()" \
	  --rpc-url $(RPC) --account $(ACCOUNT)

_deploy-premium-consumer:
	@echo "$(BOLD)[5/7] Deploying PremiumConsumer...$(RESET)"
	forge script script/DeployPremiumConsumer.s.sol:DeployPremiumConsumer \
	  --rpc-url $(RPC) --account $(ACCOUNT) \
	  --broadcast --verify $(ETHERSCAN_KEY)

_deploy-premium-coordinator:
	@echo "$(BOLD)[6/7] Deploying PremiumCoordinator...$(RESET)"
	forge script script/DeployPremiumCoordinator.s.sol:DeployPremiumCoordinator \
	  --rpc-url $(RPC) --account $(ACCOUNT) \
	  --broadcast --verify $(ETHERSCAN_KEY)

_transfer-premium-ownership:
	@echo "$(BOLD)[6b] Transferring PremiumConsumer ownership to Coordinator...$(RESET)"
	cast send $(PREMIUM_CONSUMER) \
	  "transferOwnership(address)" $(PREMIUM_COORDINATOR) \
	  --rpc-url $(RPC) --account $(ACCOUNT)

_accept-premium-ownership:
	@echo "$(BOLD)[7/7] PremiumCoordinator accepting consumer ownership...$(RESET)"
	cast send $(PREMIUM_COORDINATOR) \
	  "acceptConsumerOwnership()" \
	  --rpc-url $(RPC) --account $(ACCOUNT)

# ============================================================
#  CORE DEPLOYMENT (Bruma + BrumaVault + ReinsurancePool)
# ============================================================

deploy-core:
	@echo "$(BOLD)Redeploying core contracts...$(RESET)"
	forge script script/DeployBruma.s.sol:DeployBruma \
	  --rpc-url $(RPC) \
	  --account $(ACCOUNT) \
	  --broadcast \
	  --verify $(ETHERSCAN_KEY) \
	  -vvv
	@echo ""
	@echo "$(YELLOW)$(BOLD)Copy the new addresses above into your .env file:$(RESET)"
	@echo "  BRUMA=<new>"
	@echo "  VAULT=<new>"
	@echo "  REINSURANCE_POOL=<new>"

deploy-factory:
	@echo "$(BOLD)Redeploying BrumaCCIPEscrowFactory (new Bruma: $(BRUMA))...$(RESET)"
	forge script script/DeployBrumaFactory.s.sol \
	  --rpc-url $(RPC) \
	  --account $(ACCOUNT) \
	  --broadcast \
	  --verify $(ETHERSCAN_KEY)

deploy-all: deploy-chainlink deploy-core deploy-factory
	@echo "$(GREEN)$(BOLD)Full deployment complete.$(RESET)"

# ============================================================
#  POST-DEPLOY CONFIGURATION
# ============================================================

wrap-eth:
	@echo "$(BOLD)Wrapping 1 ETH → WETH...$(RESET)"
	cast send $(WETH) \
	  "deposit()" \
	  --value 1ether \
	  --rpc-url $(RPC) --account $(ACCOUNT)

approve-weth:
	@echo "$(BOLD)Approving VAULT to spend 1 WETH...$(RESET)"
	cast send $(WETH) \
	  "approve(address,uint256)" \
	  $(VAULT) 1000000000000000000 \
	  --rpc-url $(RPC) --account $(ACCOUNT)

fund-vault: wrap-eth approve-weth
	@echo "$(BOLD)Depositing 1 WETH into vault...$(RESET)"
	cast send $(VAULT) \
	  "deposit(uint256,address)" \
	  1000000000000000000 $(DEPLOYER) \
	  --rpc-url $(RPC) --account $(ACCOUNT)
	@echo "$(GREEN)Vault funded.$(RESET)"
	@make check-vault

set-guardian:
	@echo "$(BOLD)Setting deployer as guardian (dev shortcut)...$(RESET)"
	@echo "$(YELLOW)NOTE: In production, set to CRE_GUARDIAN wallet instead.$(RESET)"
	cast send $(VAULT) \
	  "setGuardian(address)" $(DEPLOYER) \
	  --rpc-url $(RPC) --account $(ACCOUNT)

set-limits:
	@echo "$(BOLD)Setting hackathon risk limits...$(RESET)"
	@echo "  maxUtilization=$(MAX_UTIL) targetUtilization=$(TARGET_UTIL)"
	@echo "  maxLocationExposure=$(MAX_LOCATION_EXP)"
	@echo "$(YELLOW)NOTE: setUtilizationLimits requires guardian wallet.$(RESET)"
	cast send $(VAULT) \
	  "setUtilizationLimits(uint256,uint256)" \
	  $(MAX_UTIL) $(TARGET_UTIL) \
	  --rpc-url $(RPC) --account $(ACCOUNT)
	cast send $(VAULT) \
	  "setMaxLocationExposure(uint256)" \
	  $(MAX_LOCATION_EXP) \
	  --rpc-url $(RPC) --account $(ACCOUNT)
	@echo "$(GREEN)Limits set.$(RESET)"

activate-reinsurance:
	@echo "$(BOLD)Wiring vault to reinsurance pool...$(RESET)"
	cast send $(VAULT) \
	  "setReinsurancePool(address)" $(REINSURANCE_POOL) \
	  --rpc-url $(RPC) --account $(ACCOUNT)
	cast send $(VAULT) \
	  "setReinsuranceYieldBps(uint256)" $(REINSURANCE_BPS) \
	  --rpc-url $(RPC) --account $(ACCOUNT)
	@echo "$(GREEN)Reinsurance active at $(REINSURANCE_BPS) bps yield routing.$(RESET)"

# ============================================================
#  OPTIONS OPERATIONS
# ============================================================

quote-flood:
	$(eval NOW := $(shell cast block latest --field timestamp --rpc-url $(RPC)))
	$(eval START := $(shell echo $$(($(NOW) + 300))))
	$(eval EXPIRY := $(shell echo $$(($(START) + 259200))))
	@echo "$(BOLD)Requesting flood protection quote...$(RESET)"
	@echo "  Start:  $(START)  Expiry: $(EXPIRY)"
	cast send $(BRUMA) \
	  "requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))" \
	  "(0,\"10.0\",\"-75.0\",$(START),$(EXPIRY),100,50,10000000000000000)" \
	  --rpc-url $(RPC) --account $(ACCOUNT)

quote-drought:
	$(eval NOW := $(shell cast block latest --field timestamp --rpc-url $(RPC)))
	$(eval START := $(shell echo $$(($(NOW) + 300))))
	$(eval EXPIRY := $(shell echo $$(($(START) + 259200))))
	@echo "$(BOLD)Requesting drought protection quote...$(RESET)"
	@echo "  Start:  $(START)  Expiry: $(EXPIRY)"
	cast send $(BRUMA) \
	  "requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))" \
	  "(1,\"10.0\",\"-75.0\",$(START),$(EXPIRY),80,50,10000000000000000)" \
	  --rpc-url $(RPC) --account $(ACCOUNT)

check-quote:
ifndef REQUEST_ID
	@echo "$(YELLOW)Usage: make check-quote REQUEST_ID=0x...$(RESET)"
	@exit 1
endif
	@echo "$(BOLD)Checking quote $(REQUEST_ID)...$(RESET)"
	@echo -n "  Fulfilled: "
	@cast call $(PREMIUM_CONSUMER) \
	  "isRequestFulfilled(bytes32)(bool)" $(REQUEST_ID) \
	  --rpc-url $(RPC)
	@echo -n "  Premium:   "
	@cast call $(PREMIUM_CONSUMER) \
	  "premiumByRequest(bytes32)(uint256)" $(REQUEST_ID) \
	  --rpc-url $(RPC)

create-option:
ifndef REQUEST_ID
	@echo "$(YELLOW)Usage: make create-option REQUEST_ID=0x...$(RESET)"
	@exit 1
endif
	$(eval PREMIUM := $(shell cast call $(PREMIUM_CONSUMER) \
	  "premiumByRequest(bytes32)(uint256)" $(REQUEST_ID) --rpc-url $(RPC)))
	$(eval FEE := $(shell echo $$(($(PREMIUM) / 100))))
	$(eval TOTAL := $(shell echo $$(($(PREMIUM) + $(FEE)))))
	@echo "$(BOLD)Creating option from quote $(REQUEST_ID)...$(RESET)"
	@echo "  Premium:      $(PREMIUM) wei"
	@echo "  Protocol fee: $(FEE) wei"
	@echo "  Total cost:   $(TOTAL) wei"
	cast send $(BRUMA) \
	  "createOptionWithQuote(bytes32)" $(REQUEST_ID) \
	  --value $(TOTAL) \
	  --rpc-url $(RPC) --account $(ACCOUNT)

# ============================================================
#  MONITORING
# ============================================================

check-vault:
	@echo "$(BOLD)$(CYAN)BrumaVault ($(VAULT))$(RESET)"
	@echo -n "  totalAssets:        "
	@cast call $(VAULT) "totalAssets()(uint256)"        --rpc-url $(RPC)
	@echo -n "  totalLocked:        "
	@cast call $(VAULT) "totalLocked()(uint256)"        --rpc-url $(RPC)
	@echo -n "  availableLiquidity: "
	@cast call $(VAULT) "availableLiquidity()(uint256)" --rpc-url $(RPC)
	@echo -n "  utilizationRate:    "
	@cast call $(VAULT) "utilizationRate()(uint256)"    --rpc-url $(RPC)
	@echo -n "  totalPremiums:      "
	@cast call $(VAULT) "totalPremiumsEarned()(uint256)" --rpc-url $(RPC)
	@echo -n "  totalPayouts:       "
	@cast call $(VAULT) "totalPayouts()(uint256)"       --rpc-url $(RPC)
	@echo -n "  reinsurancePool:    "
	@cast call $(VAULT) "reinsurancePool()(address)"    --rpc-url $(RPC)
	@echo -n "  reinsuranceBps:     "
	@cast call $(VAULT) "reinsuranceYieldBps()(uint256)" --rpc-url $(RPC)
	@echo -n "  guardian:           "
	@cast call $(VAULT) "guardian()(address)"           --rpc-url $(RPC)
	@echo -n "  weatherOptions:     "
	@cast call $(VAULT) "weatherOptions()(address)"     --rpc-url $(RPC)

check-bruma:
	@echo "$(BOLD)$(CYAN)Bruma ($(BRUMA))$(RESET)"
	@echo -n "  owner:              "
	@cast call $(BRUMA) "owner()(address)"              --rpc-url $(RPC)
	@echo -n "  vault:              "
	@cast call $(BRUMA) "vault()(address)"              --rpc-url $(RPC)
	@echo -n "  protocolFeeBps:     "
	@cast call $(BRUMA) "protocolFeeBps()(uint256)"     --rpc-url $(RPC)
	@echo -n "  minPremium:         "
	@cast call $(BRUMA) "minPremium()(uint256)"         --rpc-url $(RPC)
	@echo -n "  collectedFees:      "
	@cast call $(BRUMA) "collectedFees()(uint256)"      --rpc-url $(RPC)
	@echo -n "  autoClaimEnabled:   "
	@cast call $(BRUMA) "autoClaimEnabled()(bool)"      --rpc-url $(RPC)
	@echo -n "  activeOptions:      "
	@cast call $(BRUMA) "getActiveOptions()(uint256[])" --rpc-url $(RPC)

check-pool:
	@echo "$(BOLD)$(CYAN)ReinsurancePool ($(REINSURANCE_POOL))$(RESET)"
	@echo -n "  totalAssets:        "
	@cast call $(REINSURANCE_POOL) "totalAssets()(uint256)"      --rpc-url $(RPC)
	@echo -n "  totalDrawn:         "
	@cast call $(REINSURANCE_POOL) "totalDrawn()(uint256)"       --rpc-url $(RPC)
	@echo -n "  accruedYield:       "
	@cast call $(REINSURANCE_POOL) "accruedYield()(uint256)"     --rpc-url $(RPC)
	@echo -n "  availableCapacity:  "
	@cast call $(REINSURANCE_POOL) "availableCapacity()(uint256)" --rpc-url $(RPC)
	@echo -n "  maxDrawableNow:     "
	@cast call $(REINSURANCE_POOL) "maxDrawableNow()(uint256)"   --rpc-url $(RPC)
	@echo -n "  primaryVault:       "
	@cast call $(REINSURANCE_POOL) "primaryVault()(address)"     --rpc-url $(RPC)
	@echo -n "  guardian:           "
	@cast call $(REINSURANCE_POOL) "guardian()(address)"         --rpc-url $(RPC)
	@echo -n "  lockupPeriod:       "
	@cast call $(REINSURANCE_POOL) "lockupPeriod()(uint256)"     --rpc-url $(RPC)