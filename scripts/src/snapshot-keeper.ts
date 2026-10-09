/**
 * Daily snapshot keeper: records each vault's oracle-priced share price into the PerformanceTracker
 * (at most one per vault per UTC day; the contract ignores duplicates and stale prices).
 *
 *   RPC_URL=... KEEPER_PASSWORD_FILE=~/.mirrorbook-keeper-pass INTERVAL_SECONDS=3600 pnpm keeper:snapshot
 *
 * Run it hourly: the first successful call of each UTC day wins, so a recurring schedule keeps the
 * record dense even when a vault's prices are briefly stale.
 */
import type { Address } from "viem";
import { performanceTrackerAbi } from "./abis.js";
import { allVaults, castSend, client, loadDeployment, log, loop } from "./common.js";

const BATCH = 50; // PerformanceTracker.MAX_BATCH

async function tick() {
  const d = await loadDeployment();
  const vaults = await allVaults(d.vaultFactory);
  const today = Math.floor(Date.now() / 86_400_000);
  const due: Address[] = [];
  for (const v of vaults) {
    const [, count, lastDay] = await client.readContract({
      address: d.performanceTracker,
      abi: performanceTrackerAbi,
      functionName: "tracks",
      args: [v],
    });
    if (count === 0 || lastDay < today) due.push(v);
  }
  log(`snapshot: ${vaults.length} vaults, ${due.length} due`);
  for (let i = 0; i < due.length; i += BATCH) {
    const batch = due.slice(i, i + BATCH);
    // Simulate first: skip the tx if nothing would be recorded (e.g. market data stale).
    const { result } = await client.simulateContract({
      address: d.performanceTracker,
      abi: performanceTrackerAbi,
      functionName: "recordMany",
      args: [batch],
    });
    if (result === 0n) {
      log("snapshot: nothing recordable right now (prices stale?)");
      continue;
    }
    const hash = await castSend(d.performanceTracker, "recordMany(address[])", [`[${batch.join(",")}]`]);
    log(`snapshot: recorded ${result} vault(s) tx=${hash}`);
  }
}

loop("snapshot", tick);
