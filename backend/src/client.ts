import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { config } from "./config.js";

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: [config.rpcUrl] },
  },
});

export const account = privateKeyToAccount(config.privateKey);

export const publicClient = createPublicClient({
  chain: monadTestnet,
  transport: http(config.rpcUrl),
});

export const walletClient = createWalletClient({
  account,
  chain: monadTestnet,
  transport: http(config.rpcUrl),
});
