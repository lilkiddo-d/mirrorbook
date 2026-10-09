#!/usr/bin/env bash
# One-command Robinhood Chain mainnet deployment.
#   bash scripts/deploy-mainnet.sh
# Optional env: RPC_URL (default public RPC; a private Alchemy URL is recommended),
#               GUARDIAN, TREASURY, TIMELOCK_PROPOSER (default: the deployer), ACCOUNT (default mirrorbook-deployer).
# Signing happens only inside Foundry via the encrypted keystore; you type its password when prompted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
ACCOUNT="${ACCOUNT:-mirrorbook-deployer}"
MIN_BALANCE_WEI=5000000000000000 # 0.005 ETH

chain=$(cast chain-id --rpc-url "$RPC_URL")
[ "$chain" = "4663" ] || { echo "RPC is chain $chain, expected Robinhood Chain (4663)"; exit 1; }

echo "Unlocking keystore '$ACCOUNT' to read its address (enter the keystore password):"
DEPLOYER=$(cast wallet address --account "$ACCOUNT")
BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
echo "Deployer:  $DEPLOYER"
echo "Balance:   $(cast from-wei "$BAL") ETH"
echo "Guardian:  ${GUARDIAN:-$DEPLOYER (deployer)}"
echo "Treasury:  ${TREASURY:-$DEPLOYER (deployer)}"
echo "Proposer:  ${TIMELOCK_PROPOSER:-$DEPLOYER (deployer)}"
python - "$BAL" "$MIN_BALANCE_WEI" <<'PY' || { echo "Fund the deployer with at least 0.005 ETH (0.01 recommended) on Robinhood Chain."; exit 1; }
import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)
PY

cd "$ROOT/contracts"
echo; echo "== Dry run against live mainnet state =="
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --sender "$DEPLOYER" 2>&1 \
  | grep -E "VaultFactory:|Timelock:|Estimated total gas|Estimated amount required|SIMULATION COMPLETE|Error" || true
grep -q '"vaultFactory"' "$ROOT/deployments/4663.dry-run.json" || { echo "Dry run failed."; exit 1; }

echo
read -r -p "Type 'deploy' to broadcast to Robinhood Chain MAINNET (irreversible): " ok
[ "$ok" = "deploy" ] || { echo "Aborted. Nothing was sent."; exit 1; }

echo "== Broadcasting (enter the keystore password again) =="
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --account "$ACCOUNT" --sender "$DEPLOYER" \
  --broadcast --slow --verify --verifier sourcify

J="$ROOT/deployments/4663.json"
[ -f "$J" ] || { echo "deployments/4663.json missing - check the output above."; exit 1; }
get() { (cd "$ROOT" && python -c "import json;print(json.load(open('deployments/4663.json'))['$1'])"); }
FACTORY=$(get vaultFactory); TIMELOCK=$(get timelock)
Z=0x0000000000000000000000000000000000000000000000000000000000000000
echo
echo "== Post-deploy checks =="
echo "VaultFactory: $FACTORY"
echo "Timelock:     $TIMELOCK"
echo "Timelock is admin (want true):       $(cast call "$FACTORY" 'hasRole(bytes32,address)(bool)' $Z "$TIMELOCK" --rpc-url "$RPC_URL")"
echo "Deployer is admin (want false):      $(cast call "$FACTORY" 'hasRole(bytes32,address)(bool)' $Z "$DEPLOYER" --rpc-url "$RPC_URL")"
echo "Timelock delay (want 172800):        $(cast call "$TIMELOCK" 'getMinDelay()(uint256)' --rpc-url "$RPC_URL")"
echo
echo "Done. Next: commit deployments/4663.json and app/src/config/deployments/4663.json, then deploy the app (DEPLOY.md section 6)."
echo "If verification was interrupted, rerun the broadcast command with --resume instead of --broadcast."
