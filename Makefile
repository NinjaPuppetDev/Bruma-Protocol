# SETUP

export WEATHER_OPTION=0xac46BC205d962FD0d1aBa3FEf291f90bCf52db82
export DEPLOYER=0xc022d2263835D14D5AcA7E3f45ADA019D1E23D9e
export COORDINATOR=0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6
export RPC_URL="your-rpc"
account: your-deployer


## Deployment sequence

### DeployRainfall Chainlink Consumer

forge script script/DeployRainfall.s.sol --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer --broadcast --verify SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB

## Deploy Rainfall Coordinator

forge script script/DeployCoordinator.s.sol --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer --broadcast --verify SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB


## Transfer ownership For Rainfall

cast send 0x96722110DE16F18d3FF21E070F2251cbf8376f92 "transferOwnership(address)" 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6 --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer 

## Accept Consumer Ownership

cast send 0x58079Fd1c9BCdbe91eD4c83E1bE196B5FFBa62e6 \
  "acceptConsumerOwnership()" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK \
  --account rainfall-deployer


## DeployPremiumConsumer

forge script script/DeployPremiumConsumer.s.sol:DeployPremiumConsumer --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer --broadcast --verify SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB

PREMIUM_CONSUMER=0xEB36260fc0647D9ca4b67F40E1310697074897d4

## Deploy Premium Coordinator

forge script script/DeployPremiumCoordinator.s.sol:DeployPremiumCoordinator --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer --broadcast --verify SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB

PREMIUM_COORDINATOR=0xf322B700c27a8C527F058f48481877855bD84F6e

## Transfer ownership For PremiumCalculator

cast send 0xEB36260fc0647D9ca4b67F40E1310697074897d4 "transferOwnership(address)" 0xf322B700c27a8C527F058f48481877855bD84F6e --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK --account rainfall-deployer 

## Accept Consumer Ownership

cast send 0xf322B700c27a8C527F058f48481877855bD84F6e \
  "acceptConsumerOwnership()" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK \
  --account rainfall-deployer


  ## Deploy Bruma

  forge script script/DeployBruma.s.sol:DeployBruma --rpc-url $RPC --account rainfall-deployer --broadcast --verify SH6TUFNGYM3S2PE9I6C8NJH6WHF7A9P2ZB


## Contract Addresses (Sepolia)
```
# Core Contracts
export BRUMA=0x762a995182433fDE85dC850Fa8FF6107582110d2
export VAULT=0x681915B4226014045665e4D5d6Bb348eB90cB32f
export WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
export PREMIUM_CONSUMER=0xEB36260fc0647D9ca4b67F40E1310697074897d4
export DEPLOYER=0xc022d2263835D14D5AcA7E3f45ADA019D1E23D9e
export RPC=https://eth-sepolia.g.alchemy.com/v2/lmeow
```
## VAULT OPERATIONS

```Javascript
# Check ETH balance
cast balance $DEPLOYER --rpc-url $RPC

# Check WETH balance
cast call $WETH \
  "balanceOf(address)(uint256)" \
  $YOUR_ADDRESS \
  --rpc-url $RPC

# Check vault shares
cast call $VAULT \
  "balanceOf(address)(uint256)" \
  $DEPLOYER \
  --rpc-url $RPC
```
## Deposit Liquidity

```Javascript
# Wrap 1 ETH to WETH
cast send $WETH \
  "deposit()" \
  --value 1ether \
  --rpc-url $RPC \
  --account rainfall-deployer
```
```Javascript
# Approve 1 WETH (1000000000000000000 wei)
cast send $WETH \
  "approve(address,uint256)" \
  $VAULT \
  1000000000000000000 \
  --rpc-url $RPC \
  --account rainfall-deployer

  cast send $VAULT \
  "deposit(uint256,address)(uint256)" \
  1000000000000000000 \
  $DEPLOYER \
  --rpc-url $RPC \
  --account rainfall-deployer
```
## Withdraw from Vault

```Javascript
# Check maximum withdrawable amount
cast call $VAULT \
  "maxWithdraw(address)(uint256)" \
  $YOUR_ADDRESS \
  --rpc-url $RPC

# Withdraw available WETH
cast send $VAULT \
  "withdraw(uint256,address,address)(uint256)" \
  500000000000000000 \
  $YOUR_ADDRESS \
  $YOUR_ADDRESS \
  --rpc-url $RPC \
  --account rainfall-deployer
```

## Check Vault Metrics

```Javascript
# Get comprehensive vault metrics
cast call $VAULT \
  "getMetrics()(uint256,uint256,uint256,uint256,uint256,uint256,int256)" \
  --rpc-url $RPC

# Individual metrics
cast call $VAULT "totalAssets()(uint256)" --rpc-url $RPC
cast call $VAULT "totalLocked()(uint256)" --rpc-url $RPC
cast call $VAULT "availableLiquidity()(uint256)" --rpc-url $RPC
cast call $VAULT "utilizationRate()(uint256)" --rpc-url $RPC
```

## OPTIONS OPERATIONS

```Javascript
NOW=$(cast block latest --field timestamp --rpc-url $RPC)
START=$((NOW + 300))     
EXPIRY=$((START + 259200)) 

echo "Current block time: $NOW ($(date -d @$NOW))"
echo "Option start time: $START ($(date -d @$START))"
echo "Option expiry time: $EXPIRY ($(date -d @$EXPIRY))"
echo ""

cast send $BRUMA \
  "requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))(bytes32)" \
  "(0,\"10.0\",\"-75.0\",$START,$EXPIRY,100,50,10000000000000000)" \
  --rpc-url $RPC --account rainfall-deployer
```

## Drought Protection 

```Javascript

NOW=$(cast block latest --field timestamp --rpc-url $RPC)
START=$((NOW + 300))     
EXPIRY=$((START + 259200)) 

echo "Current block time: $NOW ($(date -d @$NOW))"
echo "Option start time: $START ($(date -d @$START))"
echo "Option expiry time: $EXPIRY ($(date -d @$EXPIRY))"
echo ""

cast send $BRUMA \
  "requestPremiumQuote((uint8,string,string,uint256,uint256,uint256,uint256,uint256))(bytes32)" \
  "(1,\"10.0\",\"-75.0\",$START,$EXPIRY,80,50,10000000000000000)" \
  --rpc-url $RPC \
  --account rainfall-deployer
```


## PREMIUM CONSUMER
```Javascript
cast call $PREMIUM_CONSUMER   "isRequestFulfilled(bytes32)(bool)"   0x2ca0d40941db25001d48736d2b6c3671b74c19782172164a4307bce67bc0a44c   --rpc-url $RPC
cast call $PREMIUM_CONSUMER   "premiumByRequest(bytes32)(uint256)"   0x2ca0d40941db25001d48736d2b6c3671b74c19782172164a4307bce67bc0a44c   --rpc-url $RPC
````

cast call $BRUMA \
  "getActiveOptions()(uint256[])" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/8rnTBOrmLgFWnn-IAsFxK

  # Check Quote 1
export REQUEST_1=0x9b32f2971c102479d92358b185c477a867e0f1ae1ebac63c94ac9bb741bf1cce
export PREMIUM_CONSUMER=0xEB36260fc0647D9ca4b67F40E1310697074897d4
export TOTAL_COST=500000000000000000

cast call $PREMIUM_CONSUMER \
  "premiumByRequest(bytes32)(uint256)" \
  $REQUEST_1 \
  --rpc-url $RPC

# If premium > 0, create option:
PREMIUM=$(cast call $PREMIUM_CONSUMER "premiumByRequest(bytes32)(uint256)" $REQUEST_1 --rpc-url $RPC)
PROTOCOL_FEE=$((PREMIUM / 100))
TOTAL_COST=$((PREMIUM + PROTOCOL_FEE))

echo "Total cost: $(cast --to-unit $TOTAL_COST ether) ETH"

cast send $BRUMA \
  "createOptionWithQuote(bytes32)(uint256)" \
  $REQUEST_1 \
  --value $TOTAL_COST \
  --rpc-url $RPC \
  --account rainfall-deployer



  ///////////////////////////////// SET UTILIZATION ////////////////////////////////////////////


  # Raise utilization to 95% (max) for hackathon
cast send $VAULT \
  'setUtilizationLimits(uint256,uint256)' \
  9500 7000 \
  --rpc-url $RPC --account rainfall-deployer

# Raise per-location exposure limit to 80% (allows most of the vault per location)
cast send $VAULT \
  'setMaxLocationExposure(uint256)' \
  8000 \
  --rpc-url $RPC --account rainfall-deployer