import { config } from "./config.js";
import { publicClient, account } from "./client.js";
import { registryAbi } from "./abi.js";
import { runSettlementCycle } from "./settler.js";

async function printStatus(): Promise<void> {
  const [nextTradeId, treasury] = await Promise.all([
    publicClient.readContract({
      address: config.registryProxy,
      abi: registryAbi,
      functionName: "nextTradeId",
    }),
    publicClient.readContract({
      address: config.registryProxy,
      abi: registryAbi,
      functionName: "getTreasuryBalance",
    }),
  ]);

  console.log("=== OneStroke Settlement Bot ===");
  console.log(`  Bot wallet:    ${account.address}`);
  console.log(`  Registry:      ${config.registryProxy}`);
  console.log(`  Total trades:  ${Number(nextTradeId) - 1}`);
  console.log(`  Treasury:      ${Number(treasury) / 1e6} USDC`);
  console.log(`  Poll interval: ${config.pollIntervalMs / 1000}s`);
  console.log("===============================\n");
}

async function loop(): Promise<void> {
  await printStatus();

  while (true) {
    try {
      await runSettlementCycle();
    } catch (err) {
      console.error("[main] Settlement cycle error:", err);
    }

    await new Promise((resolve) => setTimeout(resolve, config.pollIntervalMs));
  }
}

loop().catch((err) => {
  console.error("[main] Fatal error:", err);
  process.exit(1);
});
