import dotenv from "dotenv";
import { type Hex, type Address } from "viem";

dotenv.config();

function requireEnv(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

export const config = {
  rpcUrl: requireEnv("MONAD_TESTNET_RPC_URL"),
  privateKey: requireEnv("PRIVATE_KEY") as Hex,
  registryProxy: requireEnv("ONESTROKE_REGISTRY_PROXY") as Address,
  usdcAddress: requireEnv("MOCK_USDC_ADDRESS") as Address,
  goldskyUrl: requireEnv("GOLDSKY_GRAPHQL_URL"),
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS ?? "30000"),
} as const;
