import {
  EVMClient,
  getNetwork,
  type Runtime,
} from "@chainlink/cre-sdk";
import type { Config } from "../config";
import { BRUMA_ABI, ESCROW_ABI, FACTORY_ABI, OptionStatus } from "../abis";
import { ethCall, ethWrite } from "../evm";

export const onSettlementCron = (runtime: Runtime<Config>): string => {
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