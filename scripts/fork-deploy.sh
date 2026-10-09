#!/usr/bin/env bash
# Rehearse the full mainnet deployment on a local anvil fork of Robinhood Chain.
#   bash scripts/fork-deploy.sh            # fork on :18545, deploy, keep the fork running
# The public RPC is not an archive node, so the fork must be used right after it starts.
# A fresh, impersonated deployer is used (anvil's well-known dev accounts have mainnet history,
# so their CREATE addresses are already taken on Robinhood Chain).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-18545}"
UPSTREAM="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
RPC="http://127.0.0.1:${PORT}"
DEPLOYER="${DEPLOYER:-0x1111d1e5a1c0ffee00000000000000000000beef}"
LOG="${ROOT}/deployments/fork-deploy.log"

# Throttled: the public RPC sits behind Cloudflare and rate-limits bursts of fork requests.
anvil --fork-url "$UPSTREAM" --chain-id 31337 --port "$PORT" --silent \
  --compute-units-per-second 100 --retries 10 --fork-retry-backoff 2000 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' INT TERM
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done

cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_impersonateAccount "$DEPLOYER" --rpc-url "$RPC" >/dev/null

cd "$ROOT/contracts"
forge script script/Deploy.s.sol --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast >"$LOG" 2>&1 \
  || { echo "DEPLOY FAILED - see $LOG"; tail -20 "$LOG"; kill $ANVIL; exit 1; }
grep -E "VaultFactory:|Timelock:|ONCHAIN EXECUTION COMPLETE" "$LOG" || true
echo "FORK DEPLOY OK - fork running at $RPC (pid $ANVIL); addresses in deployments/31337.json"
wait $ANVIL
