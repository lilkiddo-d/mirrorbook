/**
 * Follower-stop keeper: discovers armed stops from `StopSet` events and executes the triggered ones.
 * Execution is permissionless and fully verified on-chain (trigger price, fresh oracle, allowance);
 * proceeds always go to the follower.
 *
 *   RPC_URL=... KEEPER_PASSWORD_FILE=~/.mirrorbook-keeper-pass INTERVAL_SECONDS=60 pnpm keeper:stops
 */
import { parseAbiItem, type Address } from "viem";
import { followerStopsAbi } from "./abis.js";
import { castSend, client, loadDeployment, log, loop } from "./common.js";

const LOG_CHUNK = 50_000n;
const stopSet = parseAbiItem(
  "event StopSet(address indexed vault, address indexed follower, uint256 entryPrice, uint16 dropBps)",
);

const known = new Map<string, { vault: Address; follower: Address }>();
let fromBlock: bigint | undefined;

async function discover(stops: Address, start: bigint) {
  const head = await client.getBlockNumber();
  let from = fromBlock ?? start;
  while (from <= head) {
    const to = from + LOG_CHUNK - 1n > head ? head : from + LOG_CHUNK - 1n;
    const logs = await client.getLogs({ address: stops, event: stopSet, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const { vault, follower } = l.args as { vault: Address; follower: Address };
      known.set(`${vault}:${follower}`.toLowerCase(), { vault, follower });
    }
    from = to + 1n;
  }
  fromBlock = from;
}

async function tick() {
  const d = await loadDeployment();
  await discover(d.followerStops, BigInt(d.deployedAtBlock ?? 0));
  let fired = 0;
  for (const [key, s] of known) {
    const triggered = await client.readContract({
      address: d.followerStops,
      abi: followerStopsAbi,
      functionName: "isTriggered",
      args: [s.vault, s.follower],
    });
    if (!triggered) {
      const [, , active] = await client.readContract({
        address: d.followerStops,
        abi: followerStopsAbi,
        functionName: "stops",
        args: [s.vault, s.follower],
      });
      if (!active) known.delete(key);
      continue;
    }
    try {
      await client.simulateContract({
        address: d.followerStops,
        abi: followerStopsAbi,
        functionName: "execute",
        args: [s.vault, s.follower],
      });
      const hash = await castSend(d.followerStops, "execute(address,address)", [s.vault, s.follower]);
      fired++;
      log(`stops: executed ${s.follower} in ${s.vault} tx=${hash}`);
    } catch (e) {
      log(`stops: ${s.follower} in ${s.vault} not executable:`, (e as Error).message.split("\n")[0]);
    }
  }
  log(`stops: ${known.size} armed, ${fired} executed`);
}

loop("stops", tick);
