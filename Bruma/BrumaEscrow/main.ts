import {
  CronCapability,
  EVMClient,
  HTTPClient,
  handler,
  Runner,
  getNetwork,
  encodeCallMsg,
  bytesToHex,
  LAST_FINALIZED_BLOCK_NUMBER,
  consensusMedianAggregation,
  type Runtime,
  type NodeRuntime,
} from "@chainlink/cre-sdk";
import {
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  parseAbiParameters,
  hexToBytes,
  zeroAddress,
} from "viem";

// ─────────────────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────────────────

type Config = {
  settlementSchedule: string; // e.g. "*/5 * * * *"
  riskSchedule: string;       // e.g. "0 * * * *"
  chainName: string;          // e.g. "ethereum-testnet-sepolia"
  rpcUrl: string;             // for logging only
  brumaAddress: string;
  brumaFactoryAddress: string;
  brumaVaultAddress: string;
  utilizationAlertBps: number; // e.g. 7000 = 70%
  maxUtilizationBps: number;   // e.g. 9000 = 90%
  forecastDays: number;
  gasLimit: string;
};

// ─────────────────────────────────────────────────────────────────────────────
// ABIs
// ─────────────────────────────────────────────────────────────────────────────

const BRUMA_ABI = [
  {
    name: "getActiveOptions",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256[]" }],
  },
  {
    name: "getOption",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "tokenId", type: "uint256" },
          {
            name: "terms",
            type: "tuple",
            components: [
              { name: "optionType",  type: "uint8"   },
              { name: "latitude",    type: "string"  },
              { name: "longitude",   type: "string"  },
              { name: "startDate",   type: "uint256" },
              { name: "expiryDate",  type: "uint256" },
              { name: "strikeMM",    type: "uint256" },
              { name: "spreadMM",    type: "uint256" },
              { name: "notional",    type: "uint256" },
              { name: "premium",     type: "uint256" },
            ],
          },
          {
            name: "state",
            type: "tuple",
            components: [
              { name: "status",            type: "uint8"   },
              { name: "buyer",             type: "address" },
              { name: "createdAt",         type: "uint256" },
              { name: "requestId",         type: "bytes32" },
              { name: "locationKey",       type: "bytes32" },
              { name: "actualRainfall",    type: "uint256" },
              { name: "finalPayout",       type: "uint256" },
              { name: "ownerAtSettlement", type: "address" },
            ],
          },
        ],
      },
    ],
  },
  {
    name: "simulatePayout",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "tokenId",    type: "uint256" },
      { name: "rainfallMM", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "requestSettlement",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ type: "bytes32" }],
  },
  {
    name: "settle",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [],
  },
] as const;

const FACTORY_ABI = [
  {
    name: "isRegisteredEscrow",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "escrow", type: "address" }],
    outputs: [{ type: "bool" }],
  },
] as const;

const ESCROW_ABI = [
  {
    name: "claimAndBridge",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [],
  },
  {
    name: "claimed",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ type: "bool" }],
  },
] as const;

// getMetrics() returns 7 separate named values (not a struct/tuple).
// Viem decodes multi-output functions as an array indexed 0–6:
//   [0] tvl  [1] locked  [2] available  [3] utilization
//   [4] premiums  [5] payouts  [6] netPnL
const VAULT_ABI = [
  {
    name: "getMetrics",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "tvl",         type: "uint256" },
      { name: "locked",      type: "uint256" },
      { name: "available",   type: "uint256" },
      { name: "utilization", type: "uint256" },
      { name: "premiums",    type: "uint256" },
      { name: "payouts",     type: "uint256" },
      { name: "netPnL",      type: "int256"  },
    ],
  },
  {
    name: "setUtilizationLimits",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "maxBps",    type: "uint256" },
      { name: "targetBps", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

// ─────────────────────────────────────────────────────────────────────────────
// OPTION STATUS ENUM  (mirrors Bruma.sol)
// ─────────────────────────────────────────────────────────────────────────────

const OptionStatus = {
  Active:   0,
  Settling: 2,
  Settled:  3,
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

function ethCall(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  address: string,
  abi: readonly object[],
  functionName: string,
  args: readonly unknown[] = [],
): unknown {
  const callData = encodeFunctionData({ abi, functionName, args } as any);

  const reply = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to:   address as `0x${string}`,
        data: callData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result();

  return decodeFunctionResult({
    abi,
    functionName,
    data: bytesToHex(reply.data),
  } as any);
}

function ethWrite(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  address: string,
  abi: readonly object[],
  functionName: string,
  args: readonly unknown[],
  gasLimit: string,
): void {
  const callData = encodeFunctionData({ abi, functionName, args } as any);

  const reportData = encodeAbiParameters(
    parseAbiParameters("address target, bytes data"),
    [address as `0x${string}`, callData as `0x${string}`],
  );

  const report = runtime
    .report({
      encodedPayload: Buffer.from(hexToBytes(reportData)).toString("base64"),
      encoderName:    "evm",
      signingAlgo:    "ecdsa",
      hashingAlgo:    "keccak256",
    })
    .result();

  evmClient
    .writeReport(runtime, {
      receiver:  address,
      report,
      gasConfig: { gasLimit },
    })
    .result();
}

// ─────────────────────────────────────────────────────────────────────────────
// WORKFLOW 1: SETTLEMENT AUTOMATION
// ─────────────────────────────────────────────────────────────────────────────

const onSettlementCron = (runtime: Runtime<Config>): string => {
  const { config } = runtime;
  runtime.log("=== Bruma Settlement Workflow triggered ===");

  const network = getNetwork({
    chainFamily:       "evm",
    chainSelectorName: config.chainName,
    isTestnet:         true,
  });
  if (!network) throw new Error(`Unknown chain: ${config.chainName}`);

  const evmClient = new EVMClient(network.chainSelector.selector);

  // ── 1. Fetch active option IDs ───────────────────────────────────────────
  const activeOptions = ethCall(
    runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getActiveOptions",
  ) as bigint[];

  runtime.log(`Active options: ${activeOptions.length}`);
  if (activeOptions.length === 0) return "No active options to process.";

  const results = {
    settlementRequested: [] as bigint[],
    settled:             [] as bigint[],
    bridged:             [] as bigint[],
    skipped:             [] as bigint[],
    errors:              [] as { tokenId: bigint; reason: string }[],
  };

  // ── 2. Process each option ────────────────────────────────────────────────
  for (const tokenId of activeOptions) {
    try {
      const option = ethCall(
        runtime, evmClient, config.brumaAddress, BRUMA_ABI, "getOption", [tokenId],
      ) as any;

      const status = Number(option.state.status);
      const now    = Math.floor(Date.now() / 1000);

      // ── Step A: Request settlement for expired active options ─────────────
      if (status === OptionStatus.Active) {
        const expired = Number(option.terms.expiryDate) <= now;
        if (!expired) {
          runtime.log(`TokenId ${tokenId}: not yet expired, skipping.`);
          results.skipped.push(tokenId);
          continue;
        }

        runtime.log(`TokenId ${tokenId}: expired — requesting settlement...`);
        ethWrite(
          runtime, evmClient, config.brumaAddress, BRUMA_ABI,
          "requestSettlement", [tokenId], config.gasLimit,
        );
        results.settlementRequested.push(tokenId);
        continue;
      }

      // ── Step B: Finalize settlement once oracle is fulfilled ──────────────
      if (status === OptionStatus.Settling) {
        runtime.log(`TokenId ${tokenId}: settling...`);
        try {
          ethWrite(
            runtime, evmClient, config.brumaAddress, BRUMA_ABI,
            "settle", [tokenId], config.gasLimit,
          );
          results.settled.push(tokenId);
        } catch (e: any) {
          if (e.message?.includes("OracleNotFulfilled")) {
            runtime.log(`TokenId ${tokenId}: oracle pending, will retry next run.`);
            results.skipped.push(tokenId);
          } else {
            throw e;
          }
        }
        continue;
      }

      // ── Step C: Bridge payout for settled cross-chain options ─────────────
      if (status === OptionStatus.Settled) {
        const ownerAtSettlement = option.state.ownerAtSettlement as string;
        const finalPayout       = BigInt(option.state.finalPayout);

        if (finalPayout === 0n) {
          runtime.log(`TokenId ${tokenId}: zero payout (OTM), skipping.`);
          results.skipped.push(tokenId);
          continue;
        }

        const isEscrow = ethCall(
          runtime, evmClient, config.brumaFactoryAddress, FACTORY_ABI,
          "isRegisteredEscrow", [ownerAtSettlement],
        ) as boolean;

        if (!isEscrow) {
          runtime.log(`TokenId ${tokenId}: same-chain owner — skipping bridge.`);
          results.skipped.push(tokenId);
          continue;
        }

        const alreadyClaimed = ethCall(
          runtime, evmClient, ownerAtSettlement, ESCROW_ABI,
          "claimed", [tokenId],
        ) as boolean;

        if (alreadyClaimed) {
          runtime.log(`TokenId ${tokenId}: already claimed, skipping.`);
          results.skipped.push(tokenId);
          continue;
        }

        runtime.log(
          `TokenId ${tokenId}: escrow ${ownerAtSettlement} — ` +
          `bridging ${finalPayout.toString()} wei via CCIP...`,
        );

        ethWrite(
          runtime, evmClient, ownerAtSettlement, ESCROW_ABI,
          "claimAndBridge", [tokenId], config.gasLimit,
        );
        results.bridged.push(tokenId);
      }

    } catch (err: any) {
      runtime.log(`TokenId ${tokenId}: ERROR — ${err.message}`);
      results.errors.push({ tokenId, reason: err.message });
    }
  }

  const summary = [
    `Settlement requested: [${results.settlementRequested.join(", ")}]`,
    `Settled:              [${results.settled.join(", ")}]`,
    `Bridged (CCIP):       [${results.bridged.join(", ")}]`,
    `Skipped:              [${results.skipped.join(", ")}]`,
    `Errors:               ${results.errors.length}`,
  ].join("\n");

  runtime.log(summary);
  return summary;
};

// ─────────────────────────────────────────────────────────────────────────────
// WORKFLOW 2: VAULT RISK GUARDIAN
// ─────────────────────────────────────────────────────────────────────────────

// HTTP calls require NodeRuntime — must run inside runInNodeMode.
const fetchForecastRainfall = (
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

const onRiskCron = (runtime: Runtime<Config>): string => {
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
  // getMetrics() returns 7 separate values — Viem decodes as an array:
  // [0] tvl  [1] locked  [2] available  [3] utilization
  // [4] premiums  [5] payouts  [6] netPnL
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

  // ── 5. Tighten vault if threshold breached ────────────────────────────────
  if (
    currentUtilBps >= config.utilizationAlertBps ||
    expectedLossBps >= config.utilizationAlertBps
  ) {
    const newMaxBps    = config.maxUtilizationBps;
    const newTargetBps = Math.round(newMaxBps * 0.75);

    runtime.log(
      `⚠️  Risk threshold breached! ` +
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
      `${locationsSeen.size} unique locations.`
    );
  }

  return (
    `Vault healthy. Utilization: ${currentUtilBps / 100}%. ` +
    `Expected loss: ${expectedLossBps / 100}% of TVL. No action needed.`
  );
};

// ─────────────────────────────────────────────────────────────────────────────
// WORKFLOW INIT
// ─────────────────────────────────────────────────────────────────────────────

const initWorkflow = (config: Config) => {
  const settlementCron = new CronCapability();
  const riskCron       = new CronCapability();

  return [
    handler(
      settlementCron.trigger({ schedule: config.settlementSchedule }),
      onSettlementCron,
    ),
    handler(
      riskCron.trigger({ schedule: config.riskSchedule }),
      onRiskCron,
    ),
  ];
};

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}