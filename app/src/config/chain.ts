import { defineChain, type Address } from "viem";
import { robinhoodChain, stocks, tokens } from "@config/chains";
import mainnetDeployment from "./deployments/4663.json";
import forkDeployment from "./deployments/31337.json";

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || robinhoodChain.id);
const RPC = process.env.NEXT_PUBLIC_RPC_URL || "";

export const robinhood = defineChain({
  id: robinhoodChain.id,
  name: robinhoodChain.name,
  nativeCurrency: robinhoodChain.nativeCurrency,
  rpcUrls: { default: { http: [CHAIN_ID === robinhoodChain.id && RPC ? RPC : robinhoodChain.rpcUrls.public] } },
  blockExplorers: { default: { name: "Blockscout", url: robinhoodChain.explorer } },
});

/** Local anvil fork of Robinhood Chain mainnet (`anvil --fork-url ... --chain-id 31337`). */
export const robinhoodFork = defineChain({
  id: 31337,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: robinhoodChain.nativeCurrency,
  rpcUrls: { default: { http: [CHAIN_ID === 31337 && RPC ? RPC : "http://127.0.0.1:8545"] } },
  blockExplorers: { default: { name: "Blockscout", url: robinhoodChain.explorer } },
  testnet: true,
});

export const activeChain = CHAIN_ID === 31337 ? robinhoodFork : robinhood;

export type Deployment = {
  chainId: number;
  asset: Address;
  timelock: Address;
  oracleAdapter: Address;
  marketClock: Address;
  vaultFactory: Address;
  guardrails: Address;
  feeEngine: Address;
  performanceTracker: Address;
  tradeExecutor: Address;
  followerStops: Address;
  feeCollector: Address;
  complianceRegistry: Address;
  projectTokenHooks: Address;
  dexAdapter: Address;
};

const all: Record<number, Partial<Deployment>> = {
  4663: mainnetDeployment as Partial<Deployment>,
  31337: forkDeployment as Partial<Deployment>,
};

export const deployment: Deployment | null = all[CHAIN_ID]?.vaultFactory ? (all[CHAIN_ID] as Deployment) : null;

export const USDG = tokens.USDG as Address;
export const STOCKS = stocks;
export const symbolOf = (addr: string) =>
  addr.toLowerCase() === USDG.toLowerCase()
    ? "USDG"
    : (stocks.find((s) => s.token.toLowerCase() === addr.toLowerCase())?.symbol ?? `${addr.slice(0, 6)}…`);

const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim();
/** $MIRR address, or null => every token feature is hidden. */
export const PROJECT_TOKEN: Address | null = /^0x[0-9a-fA-F]{40}$/.test(rawToken) ? (rawToken as Address) : null;
export const explorer = (path: string) => `${robinhoodChain.explorer}/${path}`;
