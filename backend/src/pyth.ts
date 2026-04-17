const HERMES_BASE_URL = "https://hermes.pyth.network";

// Asset symbol -> Pyth feed ID (without 0x prefix for Hermes API)
const FEED_IDS: Record<string, string> = {
  ETH: "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  BTC: "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  MON: "31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1",
};

interface HermesResponse {
  binary?: {
    data?: string[];
  };
}

/**
 * Fetches fresh price update data from Pyth Hermes for the given assets.
 * Returns hex-encoded bytes[] ready to pass to settleTrade / settleBatch.
 */
export async function fetchPriceUpdateData(
  assets: string[]
): Promise<`0x${string}`[]> {
  const feedIds = assets
    .map((a) => FEED_IDS[a])
    .filter((id): id is string => !!id);

  if (feedIds.length === 0) return [];

  const params = new URLSearchParams();
  for (const id of feedIds) {
    params.append("ids[]", id);
  }

  const url = `${HERMES_BASE_URL}/v2/updates/price/latest?${params.toString()}&encoding=hex`;
  const res = await fetch(url);

  if (!res.ok) {
    console.error(`[pyth] Hermes API error: ${res.status} ${res.statusText}`);
    return [];
  }

  const json = (await res.json()) as HermesResponse;
  const rawData = json.binary?.data ?? [];

  return rawData.map((d) => `0x${d}` as `0x${string}`);
}

export function getSupportedAssets(): string[] {
  return Object.keys(FEED_IDS);
}
