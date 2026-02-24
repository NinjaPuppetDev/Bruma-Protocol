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

// ConfidentialHTTPSendRequester is not a named export despite being in the docs.
// We type sendRequester as `any` in the fetch fn — the SDK injects the real
// object at runtime, and the high-level overload cast at the call site ensures
// correct end-to-end typing without needing the intermediate type.
import type { Config } from "../config";
import { BRUMA_ABI, VAULT_ABI } from "../abis";
import { ethCall, ethWrite } from "../evm";

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
// GROQ RISK SUMMARY  (confidential HTTP — requires API key from Vault DON)
//
// High-level sendRequest signature (from SDK reference):
//   sendRequest(runtime, fn, consensusAggregation): (...args) => { result() }
//
// The fetch fn receives (sendRequester: any, ...args).
// The curried return accepts ...args (everything after sendRequester).
// bodyString (not body) is the correct field for string request bodies.
// ─────────────────────────────────────────────────────────────────────────────

type GroqSummaryParams = {
  tvl: string;
  currentUtilBps: number;
  expectedLossBps: number;
  activeOptionsCount: number;
  uniqueLocations: number;
  netPnL: string;
  alertThresholdBps: number;
};

type GroqResponse = {
  choices: { message: { content: string } }[];
};

const fetchGroqRiskSummary = (
  sendRequester: any, // ConfidentialHTTPSendRequester — not exported by the SDK
  params: GroqSummaryParams,
): string => {
  // Convert wei to ETH before sending — Groq has no context for wei and will
  // hallucinate USD conversions if given raw 18-decimal integers.
  const tvlEth  = (Number(params.tvl)    / 1e18).toFixed(4);
  const pnlEth  = (Number(params.netPnL) / 1e18).toFixed(4);
  const pnlSign = Number(params.netPnL) >= 0 ? "+" : "";

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
    `- Alert threshold: ${params.alertThresholdBps / 100}%`;

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

  // ── 2. Get active options ─────────────────────────────────────────────────
  const activeOptions = ethCall(
    runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getActiveOptions",
  ) as bigint[];

  if (activeOptions.length === 0) {
    runtime.log("No active options — vault risk is zero.");
    return "No active options.";
  }

  // ── 3. Fetch forecasts and compute expected loss ──────────────────────────
  let totalExpectedLoss = 0n;
  const locationsSeen  = new Set<string>();

  for (const tokenId of activeOptions) {
    const option = ethCall(
      runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getOption", [tokenId],
    ) as any;

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
      // Conservative fallback: assume max possible rainfall
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
    `${totalExpectedLoss.toString()} wei`,
  );

  // ── 4. Compute expected loss as % of TVL ─────────────────────────────────
  const expectedLossBps = tvl > 0n
    ? Number((totalExpectedLoss * 10000n) / tvl)
    : 0;

  runtime.log(
    `Expected loss as % of TVL: ${expectedLossBps / 100}% | ` +
    `Alert threshold: ${config.utilizationAlertBps / 100}%`,
  );

  // ── 5. Generate Groq risk summary ─────────────────────────────────────────
  // sendRequest(runtime, fn, consensus) returns a curried fn: (...args) => { result() }
  // The curried call receives the args that follow `sendRequester` in fetchGroqRiskSummary,
  // which is just (params: GroqSummaryParams).
  let riskSummary = "";
  try {
    // The high-level sendRequest overload does not work at runtime despite being
    // in the docs — the SDK serializes the fn arg as JSON and fails.
    // Use the low-level pattern instead: build the request object directly and
    // call sendRequest inside runInNodeMode, then pass through consensusIdenticalAggregation.
    const groqParams: GroqSummaryParams = {
      tvl:               tvl.toString(),
      currentUtilBps,
      expectedLossBps,
      activeOptionsCount: activeOptions.length,
      uniqueLocations:   locationsSeen.size,
      netPnL:            netPnL.toString(),
      alertThresholdBps: config.utilizationAlertBps,
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

  // ── 6. Tighten vault if threshold breached ────────────────────────────────
  if (
    currentUtilBps >= config.utilizationAlertBps ||
    expectedLossBps >= config.utilizationAlertBps
  ) {
    const newMaxBps    = config.maxUtilizationBps;
    const newTargetBps = Math.round(newMaxBps * 0.75);

    runtime.log(
      `Risk threshold breached! ` +
      `Tightening vault to ${newMaxBps / 100}% max, ${newTargetBps / 100}% target...`,
    );

    ethWrite(
      runtime, evmClient, config.brumaVaultAddress, VAULT_ABI,
      "setUtilizationLimits",
      [BigInt(newMaxBps), BigInt(newTargetBps)],
      config.gasLimit,
    );

    return (
      `RISK ACTION TAKEN: vault tightened to ${newMaxBps / 100}% max. ` +
      `Expected loss: ${expectedLossBps / 100}% of TVL across ` +
      `${locationsSeen.size} unique locations.\n` +
      (riskSummary ? `Summary: ${riskSummary}` : "")
    );
  }

  return (
    `Vault healthy. Utilization: ${currentUtilBps / 100}%. ` +
    `Expected loss: ${expectedLossBps / 100}% of TVL. No action needed.\n` +
    (riskSummary ? `Summary: ${riskSummary}` : "")
  );
};