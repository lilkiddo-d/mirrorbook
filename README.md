# Mirrorbook

Copy trading for tokenized stocks on Robinhood Chain. Managers run on-chain stock-token portfolios in ERC-4626 vaults.
Followers deposit USDG and mirror them. Guardrails, fees and track records are enforced and computed by the contracts,
not self-reported.

> Unaudited, experimental software. Read [THREAT_MODEL.md](THREAT_MODEL.md) and the in-app risk disclosure.

## How it works

- **Launch a vault** — anyone calls `VaultFactory.createVault` (an EIP-1167 clone of `ManagerVault`) with fees
  (≤ 2%/yr management, ≤ 25% performance over the high-water mark) and guardrails (max position %, max trades/day,
  max slippage vs. oracle ≤ 5%).
- **Trade** — the manager can only call `TradeExecutor.execute`: USDG ↔ whitelisted stock, through a governance-approved
  `DexAdapter` (Uniswap v3), during market hours (`MarketClock`), with a minimum output derived from Chainlink. The manager
  has no withdraw/transfer/arbitrary-call power.
- **Follow** — deposit USDG. Exit in USDG from idle cash while prices are live, or **in kind at any time** (pro-rata slice
  of every holding, even while paused or the market is closed).
- **Track record** — `PerformanceTracker` stores one oracle-priced share price per vault per day (400-day ring buffer)
  and computes return, max drawdown, volatility and a Sharpe-like ratio on-chain. The leaderboard ranks by it over
  30/90/365 days.
- **Follower stops** — arm a stop at X% below your entry. Keepers execute it permissionlessly; the contract verifies the
  trigger and pays you.
- **Fees** — minted as vault shares. The protocol takes a capped cut (15%, 10% for verified managers, ≤ 30% in code).
- **Governance** — every admin role sits behind a 48 h `Timelock`. A guardian can pause deposits and trading, never exits.
- **Project token** — optional, wired later; see [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).
- **Compliance** — pluggable `ComplianceRegistry` allowlist (off by default), optional frontend geoblock, risk page.

## Repository

```
contracts/   Foundry: src/ (13 protocol contracts + ComplianceRegistry), test/ (unit, fuzz, invariant, fork), script/
app/         Next.js 16 + wagmi 2 + RainbowKit: leaderboard, vault profile, manager console, stops, staking, risks
scripts/     keepers (daily snapshots, follower stops), ABI export, fork rehearsal
config/      chains.ts: Robinhood Chain addresses with sources
deployments/ written by the deploy script (<chainId>.json)
docs: DEPLOY.md · DECISIONS.md · THREAT_MODEL.md · TOKEN_INTEGRATION.md
```

| Contract | Role |
| --- | --- |
| `VaultFactory` | launches vaults; registry of swappable modules |
| `ManagerVault` | ERC-4626 vault, NAV, in-kind exits, fee accrual |
| `Guardrails` | stock whitelist, per-vault limits, daily trade budget |
| `TradeExecutor` | the only trade path; oracle-bounded slippage |
| `DexAdapter` | Uniswap v3 SwapRouter02 adapter (swappable `IDexAdapter`) |
| `OracleAdapter` | Chainlink with staleness, deviation, band, pause and sequencer checks (swappable) |
| `MarketClock` | 24/5 schedule, holidays, emergency close |
| `PerformanceTracker` | daily snapshots + on-chain risk stats |
| `FeeEngine` | fee math and capped protocol cut |
| `FeeCollector` | harvests protocol fee shares; splits treasury / stakers |
| `FollowerStops` | per-follower stop-loss |
| `ProjectTokenHooks` | staking, verified badge, slashing (inert until token set) |
| `Timelock` | 48 h governance delay |
| `ComplianceRegistry` | optional allowlist hook |

## Development

Prerequisites: Foundry, Node 22+, pnpm.

```bash
pnpm install
cd contracts && forge build
forge test --no-match-path "test/fork/*"   # unit + fuzz + invariant
forge test --match-path "test/fork/*"      # against Robinhood Chain mainnet state
forge coverage --no-match-path "test/fork/*" --report summary
node ../scripts/export-abis.mjs            # refresh app/scripts ABIs after contract changes
```

Local end-to-end on a mainnet fork:

```bash
bash scripts/fork-deploy.sh                # anvil fork on :18545 + full deploy -> deployments/31337.json
cd app && cp .env.example .env.local       # set NEXT_PUBLIC_CHAIN_ID=31337, NEXT_PUBLIC_RPC_URL=http://127.0.0.1:18545
pnpm dev
```

Mainnet deployment: see [DEPLOY.md](DEPLOY.md).
