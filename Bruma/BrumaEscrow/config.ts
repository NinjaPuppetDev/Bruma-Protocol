export type Config = {
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