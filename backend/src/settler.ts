import { type Hex } from "viem";
import { publicClient, walletClient, account } from "./client.js";
import { registryAbi } from "./abi.js";
import { config } from "./config.js";
import { fetchPriceUpdateData } from "./pyth.js";

const STATUS_LABELS = ["OPEN", "HIT_TP", "HIT_SL", "EXPIRED", "CANCELLED"];

interface PreviewResult {
  settleable: boolean;
  expectedStatus: number;
  marketPrice: bigint;
  payoutAmount: bigint;
  pnl: bigint;
  priceFresh: boolean;
}

/**
 * Scans all trades from ID 1..nextTradeId-1, checks which are settleable,
 * and settles them.
 */
export async function runSettlementCycle(): Promise<void> {
  const nextTradeId = await publicClient.readContract({
    address: config.registryProxy,
    abi: registryAbi,
    functionName: "nextTradeId",
  });

  const total = Number(nextTradeId) - 1;
  if (total === 0) {
    console.log("[settler] No trades exist yet");
    return;
  }

  console.log(`[settler] Scanning ${total} trade(s)...`);

  // Collect settleable trades grouped by asset
  const settleableByAsset: Map<string, { tradeId: bigint; preview: PreviewResult }[]> = new Map();
  let skipped = 0;

  for (let id = 1; id <= total; id++) {
    try {
      const preview = await previewTrade(BigInt(id));
      if (!preview) {
        skipped++;
        continue;
      }

      if (!preview.settleable) {
        skipped++;
        continue;
      }

      const trade = await publicClient.readContract({
        address: config.registryProxy,
        abi: registryAbi,
        functionName: "getTrade",
        args: [BigInt(id)],
      });

      const asset = trade.asset;
      if (!settleableByAsset.has(asset)) {
        settleableByAsset.set(asset, []);
      }
      settleableByAsset.get(asset)!.push({ tradeId: BigInt(id), preview });
    } catch (err) {
      console.error(`[settler] Error checking trade #${id}:`, err);
    }
  }

  if (settleableByAsset.size === 0) {
    console.log(`[settler] No settleable trades found (${skipped} skipped)`);
    return;
  }

  // Settle each group
  for (const [asset, trades] of settleableByAsset) {
    console.log(`[settler] ${trades.length} settleable ${asset} trade(s)`);

    const allFresh = trades.every((t) => t.preview.priceFresh);

    if (allFresh) {
      // Price is fresh onchain — settle without Pyth update
      await settleTrades(
        trades.map((t) => t.tradeId),
        [],
        0n
      );
    } else {
      // Price is stale — fetch Hermes update
      console.log(`[settler] Price stale for ${asset}, fetching Hermes update...`);
      const updateData = await fetchPriceUpdateData([asset]);

      if (updateData.length === 0) {
        console.error(`[settler] Failed to fetch Hermes data for ${asset}, using executorForceSettle fallback`);
        for (const t of trades) {
          await executorFallback(t.tradeId, t.preview.marketPrice);
        }
        continue;
      }

      // Quote the fee
      const fee = await publicClient.readContract({
        address: config.registryProxy,
        abi: registryAbi,
        functionName: "quoteUpdateFee",
        args: [updateData],
      });

      await settleTrades(
        trades.map((t) => t.tradeId),
        updateData,
        fee
      );
    }
  }
}

async function previewTrade(tradeId: bigint): Promise<PreviewResult | null> {
  try {
    const [settleable, expectedStatus, marketPrice, payoutAmount, pnl, priceFresh] =
      await publicClient.readContract({
        address: config.registryProxy,
        abi: registryAbi,
        functionName: "previewSettlement",
        args: [tradeId],
      });

    return { settleable, expectedStatus, marketPrice, payoutAmount, pnl, priceFresh };
  } catch {
    return null;
  }
}

async function settleTrades(
  tradeIds: bigint[],
  priceUpdateData: Hex[],
  fee: bigint
): Promise<void> {
  try {
    if (tradeIds.length === 1) {
      const hash = await walletClient.writeContract({
        address: config.registryProxy,
        abi: registryAbi,
        functionName: "settleTrade",
        args: [tradeIds[0], priceUpdateData],
        value: fee,
        gas: 500_000n,
      });

      console.log(`[settler] settleTrade #${tradeIds[0]} tx: ${hash}`);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      console.log(
        `[settler] Confirmed in block ${receipt.blockNumber}, status: ${receipt.status}`
      );
    } else {
      const hash = await walletClient.writeContract({
        address: config.registryProxy,
        abi: registryAbi,
        functionName: "settleBatch",
        args: [tradeIds, priceUpdateData],
        value: fee,
        gas: 500_000n * BigInt(tradeIds.length),
      });

      console.log(
        `[settler] settleBatch [${tradeIds.map(String).join(",")}] tx: ${hash}`
      );
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      console.log(
        `[settler] Confirmed in block ${receipt.blockNumber}, status: ${receipt.status}`
      );
    }
  } catch (err) {
    console.error(`[settler] Settlement tx failed:`, err);
    // Fallback: try executorForceSettle individually
    for (const id of tradeIds) {
      const preview = await previewTrade(id);
      if (preview?.settleable && preview.marketPrice > 0n) {
        await executorFallback(id, preview.marketPrice);
      }
    }
  }
}

async function executorFallback(
  tradeId: bigint,
  marketPrice: bigint
): Promise<void> {
  try {
    const hash = await walletClient.writeContract({
      address: config.registryProxy,
      abi: registryAbi,
      functionName: "executorForceSettle",
      args: [tradeId, marketPrice],
      gas: 500_000n,
    });

    console.log(`[settler] executorForceSettle #${tradeId} tx: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(
      `[settler] Force-settled in block ${receipt.blockNumber}, status: ${receipt.status}`
    );
  } catch (err) {
    console.error(`[settler] executorForceSettle #${tradeId} failed:`, err);
  }
}
