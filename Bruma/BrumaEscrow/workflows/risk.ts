import {
  EVMClient,
  HTTPClient,
  ConfidentialHTTPClient,
  getNetwork,
  consensusMedianAggregation,
  ok,
  json,
  type Runtime,
  type NodeRuntime,
} from "@chainlink/cre-sdk";

import type { Config } from "../config";
import {
  BRUMA_ABI,
  VAULT_ABI,
  FACTORY_ABI,
  ESCROW_ABI,
} from "../abis";
import { ethCall, ethWrite } from "../evm";

// ─────────────────────────────────────────────────────────────────────────────
// REINSURANCE_POOL_ABI  (inline — only the functions the agent needs)
// ─────────────────────────────────────────────────────────────────────────────

const REINSURANCE_POOL_ABI = [
  {
    name: "availableCapacity",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "maxDrawableNow",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "totalAssets",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

// ─────────────────────────────────────────────────────────────────────────────
// Option status enum — mirrors Bruma.sol
// ─────────────────────────────────────────────────────────────────────────────

const OptionStatus = {
  Active:   0,
  Expired:  1,
  Settling: 2,
  Settled:  3,
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// WEATHER FORECAST  (plain HTTP — Open-Meteo is public)
// ─────────────────────────────────────────────────────────────────────────────

export const fetchForecastRainfall = (
  nodeRuntime: NodeRuntime<Config>,
  lat: string,
  lon: string,
  forecastDays: number,
): number => {
  const httpClient = new HTTPClient();
  const url =
    `https://api.open-meteo.com/v1/forecast` +
    `?latitude=${lat}&longitude=${lon}` +
    `&daily=precipitation_sum` +
    `&forecast_days=${forecastDays}` +
    `&timezone=UTC`;

  const resp = httpClient
    .sendRequest(nodeRuntime, { url, method: "GET" })
    .result();

  const body = new TextDecoder().decode(resp.body);
  const data = JSON.parse(body) as any;

  if (!data?.daily?.precipitation_sum) return 0;

  return (data.daily.precipitation_sum as (number | null)[])
    .filter((v): v is number => typeof v === "number" && isFinite(v))
    .reduce((sum, v) => sum + v, 0);
};

// ─────────────────────────────────────────────────────────────────────────────
// GROQ RISK SUMMARY  (confidential HTTP — API key from Vault DON)
// ─────────────────────────────────────────────────────────────────────────────

type GroqSummaryParams = {
  tvl: string;
  currentUtilBps: number;
  expectedLossBps: number;
  activeOptionsCount: number;
  uniqueLocations: number;
  netPnL: string;
  alertThresholdBps: number;
  reinsuranceCapacity: string;
  reinsuranceTriggered: boolean;
  settledCount: number;
  escrowBridgesTriggered: number;
};

type GroqResponse = {
  choices: { message: { content: string } }[];
};

const fetchGroqRiskSummary = (
  sendRequester: any,
  params: GroqSummaryParams,
): string => {
  const tvlEth  = (Number(params.tvl)    / 1e18).toFixed(4);
  const pnlEth  = (Number(params.netPnL) / 1e18).toFixed(4);
  const pnlSign = Number(params.netPnL) >= 0 ? "+" : "";
  const reinEth = (Number(params.reinsuranceCapacity) / 1e18).toFixed(4);

  const prompt =
    `You are a risk analyst for a parametric rainfall insurance protocol. ` +
    `Summarize the vault risk in 2-3 sentences for the operations team. ` +
    `All monetary values are in ETH. Do not convert to USD or any other currency.\n\n` +
    `Vault metrics:\n` +
    `- TVL: ${tvlEth} ETH\n` +
    `- Current utilization: ${params.currentUtilBps / 100}%\n` +
    `- Expected loss (forecast): ${params.expectedLossBps / 100}% of TVL\n` +
    `- Active options: ${params.activeOptionsCount} across ${params.uniqueLocations} locations\n` +
    `- Net PnL: ${pnlSign}${pnlEth} ETH\n` +
    `- Alert threshold: ${params.alertThresholdBps / 100}%\n` +
    `- Reinsurance pool capacity: ${reinEth} ETH\n` +
    `- Reinsurance drawdown triggered: ${params.reinsuranceTriggered}\n` +
    `- Options auto-settled this run: ${params.settledCount}\n` +
    `- CCIP escrow bridges triggered: ${params.escrowBridgesTriggered}`;

  const response = sendRequester
    .sendRequest({
      request: {
        url: "https://api.groq.com/openai/v1/chat/completions",
        method: "POST",
        multiHeaders: {
          Authorization: { values: ["Bearer {{.groqApiKey}}"] },
          "Content-Type": { values: ["application/json"] },
        },
        bodyString: JSON.stringify({
          model: "groq/compound",
          messages: [{ role: "user", content: prompt }],
          max_completion_tokens: 1024,
          temperature: 1,
          top_p: 1,
          stream: false,
          stop: null,
          compound_custom: {
            tools: {
              enabled_tools: ["web_search", "code_interpreter", "visit_website"],
            },
          },
        }),
      },
      vaultDonSecrets: [{ key: "groqApiKey" }],
    })
    .result();

  if (!ok(response)) {
    throw new Error(`Groq API failed with status: ${response.statusCode}`);
  }

  const result = json(response) as GroqResponse;
  return result.choices[0].message.content;
};

// ─────────────────────────────────────────────────────────────────────────────
// MAIN RISK HANDLER
// ─────────────────────────────────────────────────────────────────────────────

export const onRiskCron = (runtime: Runtime<Config>): string => {
  const { config } = runtime;
  runtime.log("=== Bruma Vault Risk Guardian triggered ===");

  const network = getNetwork({
    chainFamily:       "evm",
    chainSelectorName: config.chainName,
    isTestnet:         true,
  });
  if (!network) throw new Error(`Unknown chain: ${config.chainName}`);

  const evmClient = new EVMClient(network.chainSelector.selector);

  // ── 1. Read vault metrics ─────────────────────────────────────────────────
  // getMetrics() returns 7 flat values (not a struct); viem decodes as array[0..6]:
  //   [0] tvl  [1] locked  [2] available  [3] utilizationBps
  //   [4] premiumsEarned  [5] totalPayouts  [6] netPnL (int256)
  const metricsArr = ethCall(
    runtime, evmClient, config.brumaVaultAddress, VAULT_ABI, "getMetrics",
  ) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint];

  const tvl            = metricsArr[0];
  const currentUtilBps = Number(metricsArr[3]);
  const netPnL         = metricsArr[6];

  runtime.log(
    `Vault: TVL=${tvl.toString()} | ` +
    `Utilization=${currentUtilBps / 100}% | ` +
    `NetPnL=${netPnL.toString()}`,
  );

  // ── 2. Read reinsurance pool capacity ─────────────────────────────────────
  const reinsuranceCapacity = ethCall(
    runtime, evmClient, config.reinsurancePoolAddress,
    REINSURANCE_POOL_ABI, "availableCapacity",
  ) as bigint;

  const maxDrawableNow = ethCall(
    runtime, evmClient, config.reinsurancePoolAddress,
    REINSURANCE_POOL_ABI, "maxDrawableNow",
  ) as bigint;

  runtime.log(
    `ReinsurancePool: capacity=${reinsuranceCapacity.toString()} | ` +
    `maxDrawableNow=${maxDrawableNow.toString()}`,
  );

  // ── 3. Get active options ─────────────────────────────────────────────────
  const activeOptions = ethCall(
    runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getActiveOptions",
  ) as bigint[];

  if (activeOptions.length === 0) {
    runtime.log("No active options — vault risk is zero.");
    return "No active options.";
  }

  // ── 4. Fetch forecasts, compute expected loss, auto-settle expired ─────────
  let totalExpectedLoss = 0n;
  const locationsSeen   = new Set<string>();
  let settledCount      = 0;

  for (const tokenId of activeOptions) {
    const option = ethCall(
      runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getOption", [tokenId],
    ) as any;

    const status: number = Number(option.state.status);

    // Auto-request settlement for expired options not yet settling/settled
    if (status === OptionStatus.Expired) {
      try {
        runtime.log(`TokenId ${tokenId}: expired — requesting settlement...`);
        ethWrite(
          runtime, evmClient, config.brumaAddress, BRUMA_ABI,
          "requestSettlement", [tokenId], config.gasLimit,
        );
        settledCount++;
      } catch (e: any) {
        runtime.log(`TokenId ${tokenId}: requestSettlement failed — ${e.message}`);
      }
      continue; // No forecast needed for expired options
    }

    // Skip options already in settlement pipeline
    if (status === OptionStatus.Settling || status === OptionStatus.Settled) {
      runtime.log(`TokenId ${tokenId}: status=${status} — skipping forecast.`);
      continue;
    }

    // Active option — compute expected loss via forecast
    const lat         = option.terms.latitude  as string;
    const lon         = option.terms.longitude as string;
    const locationKey = `${lat},${lon}`;
    locationsSeen.add(locationKey);

    let forecastRainfall: number;

    try {
      forecastRainfall = runtime
        .runInNodeMode(fetchForecastRainfall, consensusMedianAggregation())
        (lat, lon, config.forecastDays)
        .result();

      runtime.log(
        `TokenId ${tokenId} [${locationKey}]: ` +
        `forecast = ${forecastRainfall.toFixed(1)}mm over ${config.forecastDays} days`,
      );
    } catch (e: any) {
      // Conservative fallback: assume max possible rainfall triggers full payout
      forecastRainfall =
        Number(option.terms.strikeMM) + Number(option.terms.spreadMM);
      runtime.log(
        `TokenId ${tokenId}: forecast fetch failed (${e.message}) — ` +
        `using conservative ${forecastRainfall}mm`,
      );
    }

    const simulatedPayout = ethCall(
      runtime, evmClient, config.brumaAddress, BRUMA_ABI,
      "simulatePayout", [tokenId, BigInt(Math.round(forecastRainfall))],
    ) as bigint;

    totalExpectedLoss += simulatedPayout;
  }

  runtime.log(
    `Expected loss across ${activeOptions.length} options: ` +
    `${totalExpectedLoss.toString()} wei | ` +
    `Auto-settled: ${settledCount}`,
  );

  // ── 5. Compute expected loss as % of TVL ─────────────────────────────────
  const expectedLossBps = tvl > 0n
    ? Number((totalExpectedLoss * 10000n) / tvl)
    : 0;

  runtime.log(
    `Expected loss: ${expectedLossBps / 100}% of TVL | ` +
    `Alert threshold: ${config.utilizationAlertBps / 100}%`,
  );

  // ── 6. CCIP escrow bridge sweep ───────────────────────────────────────────
  // For each settled option, check if its buyer is a registered CCIP escrow.
  // If so, trigger claimAndBridge so cross-chain buyers receive their payout.
  let escrowBridgesTriggered = 0;

  for (const tokenId of activeOptions) {
    let option: any;
    try {
      option = ethCall(
        runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getOption", [tokenId],
      );
    } catch {
      continue;
    }

    if (Number(option.state.status) !== OptionStatus.Settled) continue;

    const buyer: string = option.state.buyer;

    // Check if buyer is a registered CCIP escrow
    let isEscrow = false;
    try {
      isEscrow = ethCall(
        runtime, evmClient, config.ccipEscrowFactoryAddress,
        FACTORY_ABI, "isRegisteredEscrow", [buyer],
      ) as boolean;
    } catch (e: any) {
      runtime.log(`Factory check failed for ${buyer}: ${e.message}`);
      continue;
    }

    if (!isEscrow) continue;

    // Check if already claimed
    let alreadyClaimed = false;
    try {
      alreadyClaimed = ethCall(
        runtime, evmClient, buyer as `0x${string}`,
        ESCROW_ABI, "claimed", [tokenId],
      ) as boolean;
    } catch (e: any) {
      runtime.log(`Escrow claimed() check failed for tokenId ${tokenId}: ${e.message}`);
      continue;
    }

    if (alreadyClaimed) {
      runtime.log(`TokenId ${tokenId}: escrow already claimed — skipping.`);
      continue;
    }

    // Trigger claimAndBridge
    try {
      runtime.log(`TokenId ${tokenId}: triggering claimAndBridge on escrow ${buyer}...`);
      ethWrite(
        runtime, evmClient, buyer as `0x${string}`,
        ESCROW_ABI, "claimAndBridge", [tokenId], config.gasLimit,
      );
      escrowBridgesTriggered++;
      runtime.log(`TokenId ${tokenId}: claimAndBridge submitted.`);
    } catch (e: any) {
      runtime.log(`TokenId ${tokenId}: claimAndBridge failed — ${e.message}`);
    }
  }

  // ── 7. Risk threshold evaluation and vault/reinsurance actions ────────────
  const criticalThresholdBreached =
    currentUtilBps >= config.utilizationAlertBps ||
    expectedLossBps >= config.utilizationAlertBps;

  // CRITICAL: vault at dangerous volume — tighten limits AND draw reinsurance
  const criticalVolumeBreached =
    currentUtilBps >= config.criticalUtilizationBps ||
    expectedLossBps >= config.criticalUtilizationBps;

  let reinsuranceTriggered = false;
  let actionLog            = "";

  if (criticalVolumeBreached) {
    // Hard cap: tighten vault utilization limits immediately
    const newMaxBps    = config.emergencyMaxUtilizationBps;
    const newTargetBps = Math.round(newMaxBps * 0.6); // 60% of emergency cap as target

    runtime.log(
      `CRITICAL VOLUME BREACHED! ` +
      `Util=${currentUtilBps / 100}% / ExpectedLoss=${expectedLossBps / 100}%. ` +
      `Tightening vault to ${newMaxBps / 100}% max, ${newTargetBps / 100}% target...`,
    );

    ethWrite(
      runtime, evmClient, config.brumaVaultAddress, VAULT_ABI,
      "setUtilizationLimits",
      [BigInt(newMaxBps), BigInt(newTargetBps)],
      config.gasLimit,
    );

    // Draw from reinsurance pool to cover expected losses if capacity exists.
    // The Vault's drawFromReinsurance() pulls from the pool autonomously —
    // here we signal the pool is needed by calling the Vault's rebalance hook.
    // If the Vault does not expose a direct draw fn, the guardian (this agent)
    // can call receiveYield on the pool to push yield back to the vault instead.
    if (maxDrawableNow > 0n && totalExpectedLoss > 0n) {
      const drawAmount = totalExpectedLoss < maxDrawableNow
        ? totalExpectedLoss
        : maxDrawableNow;

      runtime.log(
        `Drawing ${drawAmount.toString()} wei from ReinsurancePool ` +
        `(maxDrawableNow=${maxDrawableNow.toString()})...`,
      );

      try {
        // The Vault's reinsurance draw is initiated by calling receiveYield
        // on the pool (guardian-initiated yield push back to Vault).
        // Replace with Vault.drawFromReinsurance(amount) if/when exposed.
        ethWrite(
          runtime, evmClient, config.reinsurancePoolAddress,
          REINSURANCE_POOL_ABI as any, "receiveYield",
          [drawAmount], config.gasLimit,
        );
        reinsuranceTriggered = true;
        runtime.log(`ReinsurancePool draw submitted: ${drawAmount.toString()} wei`);
      } catch (e: any) {
        runtime.log(`ReinsurancePool draw failed: ${e.message}`);
      }
    } else {
      runtime.log(
        `ReinsurancePool draw skipped: ` +
        `maxDrawableNow=${maxDrawableNow.toString()} | ` +
        `totalExpectedLoss=${totalExpectedLoss.toString()}`,
      );
    }

    actionLog =
      `CRITICAL ACTION TAKEN: vault tightened to ${newMaxBps / 100}% max. ` +
      `Reinsurance draw: ${reinsuranceTriggered ? "YES" : "SKIPPED (no capacity)"}. ` +
      `Expected loss: ${expectedLossBps / 100}% of TVL across ` +
      `${locationsSeen.size} unique locations. ` +
      `CCIP bridges triggered: ${escrowBridgesTriggered}. ` +
      `Options auto-settled: ${settledCount}.`;

  } else if (criticalThresholdBreached) {
    // Standard alert — tighten vault limits but do not draw reinsurance yet
    const newMaxBps    = config.maxUtilizationBps;
    const newTargetBps = Math.round(newMaxBps * 0.75);

    runtime.log(
      `Risk threshold breached. ` +
      `Tightening vault to ${newMaxBps / 100}% max, ${newTargetBps / 100}% target...`,
    );

    ethWrite(
      runtime, evmClient, config.brumaVaultAddress, VAULT_ABI,
      "setUtilizationLimits",
      [BigInt(newMaxBps), BigInt(newTargetBps)],
      config.gasLimit,
    );

    actionLog =
      `RISK ACTION TAKEN: vault tightened to ${newMaxBps / 100}% max. ` +
      `Expected loss: ${expectedLossBps / 100}% of TVL. ` +
      `CCIP bridges triggered: ${escrowBridgesTriggered}. ` +
      `Options auto-settled: ${settledCount}.`;

  } else {
    actionLog =
      `Vault healthy. Utilization: ${currentUtilBps / 100}%. ` +
      `Expected loss: ${expectedLossBps / 100}% of TVL. ` +
      `CCIP bridges triggered: ${escrowBridgesTriggered}. ` +
      `Options auto-settled: ${settledCount}. No vault action needed.`;
  }

  runtime.log(actionLog);

  // ── 8. Generate Groq risk summary ────────────────────────────────────────
  let riskSummary = "";
  try {
    const groqParams: GroqSummaryParams = {
      tvl:                  tvl.toString(),
      currentUtilBps,
      expectedLossBps,
      activeOptionsCount:   activeOptions.length,
      uniqueLocations:      locationsSeen.size,
      netPnL:               netPnL.toString(),
      alertThresholdBps:    config.utilizationAlertBps,
      reinsuranceCapacity:  reinsuranceCapacity.toString(),
      reinsuranceTriggered,
      settledCount,
      escrowBridgesTriggered,
    };

    const confHTTPClient = new ConfidentialHTTPClient();
    riskSummary = fetchGroqRiskSummary(
      { sendRequest: (req: any) => confHTTPClient.sendRequest(runtime as any, req) },
      groqParams,
    );

    runtime.log(`Groq risk summary: ${riskSummary}`);
  } catch (e: any) {
    runtime.log(`Groq summary skipped: ${e.message}`);
  }

  return actionLog + (riskSummary ? `\n\nSummary: ${riskSummary}` : "");
};