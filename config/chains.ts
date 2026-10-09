/**
 * Robinhood Chain configuration — every value below was read from an official source
 * on 2026-10-08 and cross-checked on-chain against https://rpc.mainnet.chain.robinhood.com.
 *
 * Sources
 *  - Network (chain id, RPC, explorer, gas token):
 *      https://docs.robinhood.com/chain/connecting-to-robinhood-chain
 *  - Contract verification (Blockscout verifier):
 *      https://docs.robinhood.com/chain/deploy-smart-contracts
 *  - WETH + USDG (canonical):
 *      https://docs.robinhood.com/chain/contracts  (Token Contracts page)
 *  - Stock tokens (canonical registry, chainId 4663 deployments):
 *      https://api.robinhood.com/rhj/assets  (documented at https://docs.robinhood.com/chain/stock-token-apis)
 *  - Chainlink feeds (source of truth per Robinhood docs):
 *      https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *      raw: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 *  - Uniswap v3 deployments:
 *      https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *
 * Known gaps (see DECISIONS.md):
 *  - No Chainlink L2 Sequencer Uptime feed is published for Robinhood Chain → OracleAdapter
 *    accepts an optional sequencer feed (address(0) = disabled) so it can be plugged in later.
 *  - Stock tokens mainly trade via RFQ (0x, 1inch Fusion). On-chain AMM depth may be thin;
 *    DexAdapter is swappable (Uniswap v3 adapter shipped; RFQ/propAMM adapters can be added).
 */

export type StockConfig = {
  symbol: string;
  token: `0x${string}`;
  feed: `0x${string}`; // Chainlink "Robinhood <SYM> / USD" proxy, 8 decimals, 24/5 market hours
};

export const robinhoodChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    public: "https://rpc.mainnet.chain.robinhood.com",
    alchemyTemplate: "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
  },
  explorer: "https://robinhoodchain.blockscout.com",
  verifier: { type: "blockscout", url: "https://robinhoodchain.blockscout.com/api/" },
  testnet: {
    id: 46630,
    rpc: "https://rpc.testnet.chain.robinhood.com",
    explorer: "https://explorer.testnet.chain.robinhood.com",
  },
} as const;

export const tokens = {
  WETH: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  /** USDG (Global Dollar) — 6 decimals, the canonical stablecoin on the Token Contracts page. */
  USDG: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
} as const;

export const chainlink = {
  USDG_USD: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2",
  ETH_USD: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9",
  /** Heartbeat published by Chainlink for every feed above (seconds). */
  heartbeat: 86400,
  sequencerUptimeFeed: null as null | `0x${string}`, // not published for Robinhood Chain
} as const;

/** Initial stock whitelist (token from RHJ registry, feed from Chainlink directory). */
export const stocks: StockConfig[] = [
  { symbol: "AAPL", token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0" },
  { symbol: "NVDA", token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15" },
  { symbol: "TSLA", token: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", feed: "0x4A1166a659A55625345e9515b32adECea5547C38" },
  { symbol: "MSFT", token: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E" },
  { symbol: "AMZN", token: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C" },
  { symbol: "GOOGL", token: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b" },
  { symbol: "META", token: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1" },
  { symbol: "AMD", token: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72" },
  { symbol: "COIN", token: "0x6330D8C3178a418788dF01a47479c0ce7CCF450b", feed: "0xA3a468A452940B7D6b69991207B508c609a98Ef2" },
  { symbol: "SPY", token: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A" },
  { symbol: "QQQ", token: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae" },
];

export const uniswapV3 = {
  factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
  swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2",
  quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7",
  universalRouter: "0x8876789976decbfcbbbe364623c63652db8c0904",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
} as const;
