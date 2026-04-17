import { config } from "./config.js";

interface GoldskyTrade {
  tradeId: string;
  creator: string;
  asset: string;
  direction: number;
  entryPrice: string;
  stakeAmount: string;
  expiry: string;
  blockTimestamp: string;
}

interface GoldskyResponse {
  data?: {
    tradeCreateds?: GoldskyTrade[];
  };
  errors?: Array<{ message: string }>;
}

const OPEN_TRADES_QUERY = `
  query OpenTrades($first: Int!, $skip: Int!) {
    tradeCreateds(
      first: $first
      skip: $skip
      orderBy: blockTimestamp
      orderDirection: asc
    ) {
      tradeId
      creator
      asset
      direction
      entryPrice
      stakeAmount
      expiry
      blockTimestamp
    }
  }
`;

export async function fetchRecentTrades(
  first = 100,
  skip = 0
): Promise<GoldskyTrade[]> {
  const res = await fetch(config.goldskyUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query: OPEN_TRADES_QUERY,
      variables: { first, skip },
    }),
  });

  const json = (await res.json()) as GoldskyResponse;

  if (json.errors?.length) {
    console.error("[goldsky] query error:", json.errors);
    return [];
  }

  return json.data?.tradeCreateds ?? [];
}
