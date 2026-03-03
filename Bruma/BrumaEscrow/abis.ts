// ─── Bruma (WeatherOption) ───────────────────────────────────────────────────

export const BRUMA_ABI = [
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

// ─── Vault ───────────────────────────────────────────────────────────────────
// getMetrics() returns 7 flat named values (NOT a struct/tuple).
// Viem decodes multi-output functions as an array indexed 0–6:
//   [0] tvl  [1] locked  [2] available  [3] utilizationBps
//   [4] premiumsEarned  [5] totalPayouts  [6] netPnL (int256)

export const VAULT_ABI = [
  {
    name: "getMetrics",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "tvl",            type: "uint256" },
      { name: "locked",         type: "uint256" },
      { name: "available",      type: "uint256" },
      { name: "utilizationBps", type: "uint256" },
      { name: "premiumsEarned", type: "uint256" },
      { name: "totalPayouts",   type: "uint256" },
      { name: "netPnL",         type: "int256"  },
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

// ─── ReinsurancePool ─────────────────────────────────────────────────────────

export const REINSURANCE_POOL_ABI = [
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
  {
    name: "receiveYield",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
  },
] as const;

// ─── CCIP Escrow Factory ──────────────────────────────────────────────────────

export const FACTORY_ABI = [
  {
    name: "isRegisteredEscrow",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "escrow", type: "address" }],
    outputs: [{ type: "bool" }],
  },
] as const;

// ─── CCIP Escrow ─────────────────────────────────────────────────────────────

export const ESCROW_ABI = [
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

// ─── Option status enum — mirrors Bruma.sol ──────────────────────────────────

export const OptionStatus = {
  Active:   0,
  Expired:  1,
  Settling: 2,
  Settled:  3,
} as const;