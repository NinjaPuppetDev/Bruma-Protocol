export type Config = {
  settlementSchedule:         string;
  riskSchedule:               string;
  chainName:                  string;
  rpcUrl:                     string;
  brumaAddress:               string;
  brumaFactoryAddress:        string;
  brumaVaultAddress:          string;
  utilizationAlertBps:        number;
  maxUtilizationBps:          number;
  forecastDays:               number;
  gasLimit:                   string;
  criticalUtilizationBps:     number;
  emergencyMaxUtilizationBps: number;
  ccipEscrowFactoryAddress:   string;
  reinsurancePoolAddress:     string;
};

export const config: Config = {
  // ── Schedules ──────────────────────────────────────────────────────────────
  settlementSchedule:         "*/5 * * * *",   // every 5 min — check for expired options
  riskSchedule:               "0 * * * *",     // every hour — vault risk guardian

  // ── Chain ──────────────────────────────────────────────────────────────────
  chainName:                  "ethereum-testnet-sepolia",
  rpcUrl:                     "https://eth-sepolia.g.alchemy.com/v2/your-api-here",

  // ── Contracts (Sepolia v2) ─────────────────────────────────────────────────
  brumaAddress:               "0xB8171af0ecb428a74626C63dA843dc7840D409da", // WEATHER_OPTION
  brumaFactoryAddress:        "0x1DA7E84035FA37232F4955838feB9d851A900e3F", // CCIP_ESCROW_FACTORY
  brumaVaultAddress:          "0x91E707c9c78Cd099716A91BC63190BB813BE16d4", // VAULT
  ccipEscrowFactoryAddress:   "0x1DA7E84035FA37232F4955838feB9d851A900e3F", // CCIP_ESCROW_FACTORY
  reinsurancePoolAddress:     "0x1f24B221d3aEd386A239E1AD21B61bCE44dfcAbB", // REINSURANCE_POOL

  // ── Risk parameters ────────────────────────────────────────────────────────
  utilizationAlertBps:        7000,  // 70% — tighten vault limits
  criticalUtilizationBps:     8000,  // 80% — tighten + draw reinsurance
  maxUtilizationBps:          9000,  // 90% — ceiling written to vault on alert
  emergencyMaxUtilizationBps: 5000,  // 50% — hard cap written to vault on critical

  // ── Misc ───────────────────────────────────────────────────────────────────
  forecastDays:               7,     // rolling 7-day rainfall forecast window
  gasLimit:                   "500000",
};