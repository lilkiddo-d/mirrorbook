#!/usr/bin/env bash
# Seed a local fork deployment (scripts/fork-deploy.sh) with demo activity so the UI has data:
# a manager launches a vault, a follower deposits USDG, the manager buys NVDA via Uniswap, a snapshot is recorded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${RPC:-http://127.0.0.1:18545}"
J="$ROOT/deployments/31337.json"
get() { (cd "$ROOT" && python -c "import json;print(json.load(open('deployments/31337.json'))['$1'])"); }
FACTORY=$(get vaultFactory); EXEC=$(get tradeExecutor); TRACKER=$(get performanceTracker); ADAPTER=$(get dexAdapter)
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
WHALE=0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 # Uniswap USDG/NVDA pool, used only as a USDG source on the fork
MANAGER=${MANAGER:-0x4444d1e5a1c0ffee00000000000000000000beef}
FOLLOWER=${FOLLOWER:-0x5555d1e5a1c0ffee00000000000000000000beef}

for a in $MANAGER $FOLLOWER $WHALE; do
  cast rpc anvil_setBalance $a 0x8AC7230489E80000 --rpc-url $RPC >/dev/null
  cast rpc anvil_impersonateAccount $a --rpc-url $RPC >/dev/null
done
send() { local from=$1; shift; cast send --unlocked --from "$from" --rpc-url $RPC "$@" >/dev/null; }

send $MANAGER $FACTORY "createVault((string,string,uint16,uint16,uint32,string,(uint16,uint16,uint16)))" \
  '("Megacap Momentum","mMOMO",100,1000,0,"Concentrated US megacap tech, rebalanced weekly",(6000,10,300))'
VAULT=$(cast call $FACTORY "vaultsOf(address)(address[])" $MANAGER --rpc-url $RPC | tr -d '[] ' | awk -F, '{print $NF}')
echo "vault: $VAULT"

send $WHALE $USDG "transfer(address,uint256)" $FOLLOWER 5000000000
send $FOLLOWER $USDG "approve(address,uint256)" $VAULT 5000000000
send $FOLLOWER $VAULT "deposit(uint256,address)" 5000000000 $FOLLOWER

DEADLINE=$(( $(cast block --rpc-url $RPC -f timestamp) + 600 ))
DATA=$(cast abi-encode "f(uint24)" 500)
send $MANAGER $EXEC "execute((address,address,address,address,uint256,uint256,uint256,bytes))" \
  "($VAULT,$ADAPTER,$USDG,$NVDA,1500000000,0,$DEADLINE,$DATA)"
cast send --unlocked --from $MANAGER --rpc-url $RPC $TRACKER "record(address)" $VAULT >/dev/null || true

echo "NAV: $(cast call $VAULT 'navFresh()(uint256,bool)' --rpc-url $RPC | tr '\n' ' ')"
echo "NVDA held: $(cast call $NVDA 'balanceOf(address)(uint256)' $VAULT --rpc-url $RPC)"
echo "SEED OK"
