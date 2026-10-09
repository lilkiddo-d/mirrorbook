# Project token ($MIRR) integration

**This repository does not contain, deploy or mint any ERC-20.** $MIRR is launched separately on a launchpad. Mirrorbook
only consumes its address, once, through governance. A mock ERC-20 exists only under `contracts/test/`.

## What works before the token exists

Everything. Until `setProjectToken` is called:
- `ProjectTokenHooks.stake / requestUnstake / withdrawUnstaked / notifyRewardAmount / slash` revert with `TokenNotSet`.
- `isVerified(manager)` returns `false`, so every manager pays the normal protocol cut (default 15% of fees).
- `FeeCollector.distribute()` sends 100% of protocol fees to the treasury.
- The frontend hides staking, badges and the Stake page while `NEXT_PUBLIC_PROJECT_TOKEN` is empty.

## Features switched on by the token

| Feature | Contract | Behaviour |
| --- | --- | --- |
| Fee sharing | `FeeCollector` → `ProjectTokenHooks` | `stakerShareBps` (default 50%, max 80%) of harvested protocol fees (USDG) is streamed to stakers pro-rata. The rest goes to the treasury. |
| Verified managers | `ProjectTokenHooks.isVerified`, `FeeEngine.protocolCutFor` | Stake ≥ `verifiedMinStake` → "Verified" badge and the lower protocol cut (default 10% instead of 15%, both capped at 30% in code). |
| Slashing | `ProjectTokenHooks.slash` (SLASHER_ROLE = Timelock) | If a manager breaches guardrails through an exploit, governance can slash their stake (active first, then stake in the 7-day unstake cooldown) to a compensation address. |
| Unstake cooldown | `ProjectTokenHooks` | 7 days. Cooling stake earns nothing, doesn't count for Verified, and remains slashable. |

## Wiring the token (after launch)

`setProjectToken` is **one-shot** and callable only by the Timelock (48 h). Use the bundled script. It schedules a batch
that sets the token and the Verified threshold together, using the addresses in `deployments/4663.json`.

```bash
cd contracts
# 1) schedule (Timelock proposer account)
forge script script/SetProjectToken.s.sol --sig "schedule(address,uint256)" <MIRR_ADDRESS> <VERIFIED_MIN_STAKE_WEI> \
  --rpc-url robinhood --account mirrorbook-deployer --sender <PROPOSER_ADDRESS> --broadcast
# 2) execute, >= 48 h later (anyone)
forge script script/SetProjectToken.s.sol --sig "execute(address,uint256)" <MIRR_ADDRESS> <VERIFIED_MIN_STAKE_WEI> \
  --rpc-url robinhood --account mirrorbook-deployer --sender <PROPOSER_ADDRESS> --broadcast
```

Example: a 100,000 MIRR threshold with 18 decimals is `100000000000000000000000`.

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<MIRR_ADDRESS>` in Vercel and redeploy the app.

Optional governance follow-ups, each through the Timelock:
- `FeeCollector.setStakerShare(bps)` — staker share of protocol fees (≤ 8000).
- `FeeEngine.setProtocolCut(cut, verifiedCut)` — ≤ 3000, and `verifiedCut ≤ cut`.

## Requirements for the token contract

Plain ERC-20: no fee-on-transfer, no rebasing, no transfer hooks that call back into other contracts. Staking accounting
assumes the amount transferred equals the amount received. Check this before scheduling `setProjectToken`; it can't be
changed afterwards.
