import { readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, type Address } from "viem";
import { vaultFactoryAbi } from "./abis.js";

const run = promisify(execFile);
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const RPC_URL = process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
/** Foundry keystore account used for signing. The keeper never sees a private key. */
export const KEEPER_ACCOUNT = process.env.KEEPER_ACCOUNT ?? "mirrorbook-keeper";
/** Optional file holding the keystore password (for unattended runs). Otherwise cast prompts. */
export const KEEPER_PASSWORD_FILE = process.env.KEEPER_PASSWORD_FILE;
export const DRY_RUN = process.env.DRY_RUN === "1";
export const INTERVAL_MS = Number(process.env.INTERVAL_SECONDS ?? 0) * 1000;

export const client = createPublicClient({ transport: http(RPC_URL, { batch: true }) });

export type Deployment = {
  vaultFactory: Address;
  performanceTracker: Address;
  followerStops: Address;
  deployedAtBlock: number;
};

export async function loadDeployment(): Promise<Deployment> {
  const chainId = await client.getChainId();
  const file = process.env.DEPLOYMENT_FILE ?? join(root, "deployments", `${chainId}.json`);
  return JSON.parse(readFileSync(file, "utf8")) as Deployment;
}

export async function allVaults(factory: Address): Promise<Address[]> {
  const n = await client.readContract({ address: factory, abi: vaultFactoryAbi, functionName: "vaultCount" });
  const out: Address[] = [];
  for (let i = 0n; i < n; i += 100n) {
    const page = await client.readContract({
      address: factory,
      abi: vaultFactoryAbi,
      functionName: "vaults",
      args: [i, 100n],
    });
    out.push(...page);
  }
  return out;
}

/** Sends a transaction through `cast send --account <keystore>`; signing happens inside Foundry. */
export async function castSend(to: Address, sig: string, args: string[]): Promise<string> {
  const cmd = ["send", to, sig, ...args, "--rpc-url", RPC_URL, "--account", KEEPER_ACCOUNT, "--json"];
  if (KEEPER_PASSWORD_FILE) cmd.push("--password-file", KEEPER_PASSWORD_FILE);
  if (DRY_RUN) {
    log(`[dry-run] cast ${cmd.filter((c) => c !== KEEPER_PASSWORD_FILE).join(" ")}`);
    return "dry-run";
  }
  const { stdout } = await run("cast", cmd, { maxBuffer: 10 * 1024 * 1024 });
  const receipt = JSON.parse(stdout) as { transactionHash: string; status: string };
  if (receipt.status !== "0x1" && receipt.status !== "1") throw new Error(`tx reverted: ${receipt.transactionHash}`);
  return receipt.transactionHash;
}

export function log(...a: unknown[]) {
  console.log(new Date().toISOString(), ...a);
}

export async function loop(name: string, tick: () => Promise<void>) {
  for (;;) {
    try {
      await tick();
    } catch (e) {
      log(`${name} tick failed:`, (e as Error).message);
    }
    if (!INTERVAL_MS) return;
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}
