import {
  EVMClient,
  encodeCallMsg,
  bytesToHex,
  LAST_FINALIZED_BLOCK_NUMBER,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  parseAbiParameters,
  hexToBytes,
  zeroAddress,
} from "viem";
import type { Config } from "./config";

export function ethCall(
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

export function ethWrite(
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