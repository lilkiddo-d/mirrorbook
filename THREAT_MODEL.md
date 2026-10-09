# Threat model

Scope: `contracts/src/*` as deployed by `script/Deploy.s.sol` on Robinhood Chain (4663), the keepers in
`/scripts`, and the `/app` frontend. Status: **unaudited**. Get an external audit before inviting real capital.

## Assets and actors

| Asset | Where it lives |
| --- | --- |
| Follower deposits (USDG + stock tokens) | each `ManagerVault` clone |
| Protocol fees (vault shares → USDG) | `FeeCollector`, then treasury / `ProjectTokenHooks` |
| Staked project token | `ProjectTokenHooks` |
| Track-record integrity | `PerformanceTracker` |
| Admin power | `Timelock` (48 h floor), guardian EOA/multisig |

| Actor | Trust |
| --- | --- |
| Follower | untrusted |
| Manager | **untrusted** — the main adversary |
| Keeper | untrusted, holds no roles (snapshot and stop execution are permissionless) |
| Guardian | semi-trusted: pause/unpause, holidays, force-close market, compliance allowlist |
| Timelock proposer | trusted, delayed 48 h; should be a multisig |
| Chainlink, USDG issuer, stock-token issuer, Uniswap, sequencer | external dependencies |

## Top risks

### 1. Manager drains a vault through bad trades / own pools

The attack: route vault trades through a pool the manager controls at a terrible price, or churn trades to bleed value.

Controls:
- A manager has **no transfer, withdraw, approve or arbitrary-call** function. The only asset-moving path is
  `TradeExecutor.execute` → `ManagerVault.executeSwap` (callable only by the executor).
- Only governance-whitelisted adapters (`VaultFactory.isAdapter`) can be used. `DexAdapter` only routes through the
  **canonical Uniswap v3 factory pool** for an allowed fee tier — the manager cannot supply a pool or router address.
- Only USDG ↔ whitelisted-stock pairs (`Guardrails.checkPair`).
- **Oracle-derived minimum output**: `minOut = Chainlink value × (1 − maxSlippageBps)`, hard-capped at 5%. The
  manager's own `minAmountOut` can only tighten it. A pool the manager seeded at a bad price simply makes the trade revert.
- The vault re-checks its own **balance deltas** (output ≥ min, input ≤ amountIn) and resets the adapter approval to 0.
- **Trades per day** (≤ 50) and **max position size** bound the damage rate and concentration.
- Loosening any guardrail or raising fees takes **7 days**; followers can exit first.
- Verified managers' stake is slashable by governance.

Residual risk: a manager can lose up to `maxSlippage` per trade × `maxTradesPerDay` per day by trading against a pool
where they hold the other side (e.g. a thin 1% tier). With defaults (1%, 10/day) that is a real but bounded leak that
shows up in the on-chain track record. Followers should prefer vaults with tight slippage settings.

Tests: `invariant_managerNeverReceivesAssets`, `invariant_tradesWithinSlippage` (attack paths: direct `executeSwap`,
stealing via `redeem`/`redeemInKind`/`transferFrom`, rogue adapter, non-whitelisted token), `test_fork_adapterRejectsBadPrice`
(a real 1% pool cannot be used under a 5 bps budget).

### 2. Front-running / stale-price arbitrage against followers

The attack: deposit just before a manager's profitable trade or a known price move, then exit; or exit at a stale NAV
while the market is closed.

Controls:
- Cash deposits and withdrawals need a **live NAV**: fresh oracles and, if the vault holds stocks, an **open market**
  (`MarketClock`). Weekend/holiday gaps cannot be arbitraged through cash flows.
- **Minimum hold period** (manager-set, ≤ 7 days) on all exits, and locked shares cannot be transferred.
- **Fee accrual before every deposit and exit** (even within one block), so a pending performance fee can't be pushed onto
  newcomers or dodged by leavers (a bug the invariant suite found and that is now fixed).
- ERC-4626 virtual shares (offset 6) prevent the first-depositor inflation attack; rounding always favours the vault.
- Robinhood Chain orders transactions first-come-first-served through its sequencer (no public mempool auction).

Residual risk: within open hours, Chainlink equity feeds update on a 0.5% deviation or 24 h heartbeat, so NAV can lag the
true price by < 0.5%. A min-hold period makes this hard to exploit risk-free; it is not eliminated.

### 3. Track-record gaming

The attacks: self-report returns; cherry-pick snapshot times; spin up many vaults and advertise the lucky one; wash AUM.

Controls:
- Snapshots are **oracle-priced share prices written on-chain**, one per vault per UTC day, never editable. Fees are
  netted (pending fees are included in the share price).
- Snapshots are **permissionless**: keepers record daily, and `TradeExecutor` records before the manager's first trade
  of the day, so a manager can't just skip bad days.
- Stats (return, max drawdown, volatility, Sharpe-like) are computed **on-chain** from the stored series.
- The leaderboard requires ≥ max(5, window/6) snapshots and ≥ 100 USDG AUM, and `VaultFactory.vaultsOf(manager)`
  exposes every vault a manager has launched (survivorship is visible).

Residual risk: within a day, the first caller picks the snapshot moment, and a manager can call `record` at a favourable
time. Daily granularity and the keeper's fixed schedule limit this. Sybil managers (fresh addresses) can't be prevented
on a permissionless chain. The Verified badge (slashable stake) is the counter-signal.

### 4. Oracle failure or manipulation
- Rejects non-positive answers, incomplete rounds, data older than 25 h (stocks) / 25 h (USDG), round-to-round jumps
  > 25% (stocks) / 2% (USDG), USDG outside [0.97, 1.03], and stock tokens flagged `oraclePaused()`.
- Stale or invalid prices block trades, cash flows, performance fees and stop execution. **In-kind exits still work.**
- Gap: Chainlink publishes no L2 sequencer-uptime feed for Robinhood Chain yet. `OracleAdapter.setSequencerUptimeFeed`
  can enable it via Timelock when one appears.
- The oracle is swappable (`VaultFactory.setModule("oracle", …)`, Timelock).

### 5. Governance / key compromise
- All admin roles sit with the **Timelock (≥ 48 h, the floor can't be lowered)**. The deployer renounces everything inside
  the deploy script (fork test asserts this).
- The guardian can pause deposits and trading but **cannot touch funds and cannot block in-kind exits**.
- Malicious-module risk: a Timelock proposal could swap in a hostile adapter or oracle. The 48 h delay is the window for
  followers to exit in kind. Watch `CallScheduled` events on the Timelock.
- Keepers hold no roles; a leaked keeper key can only spend its own gas.

### 6. Smart-contract bugs
- Checks-effects-interactions, `ReentrancyGuard` on every vault entry point, `SafeERC20`, no unbounded loops
  (≤ 10 holdings per vault, ≤ 64 whitelisted stocks, batch limits, paginated views), events on every state change.
- 129 unit tests, fuzzing, 4 invariants, mainnet fork tests, ≥ 99% line coverage on core contracts.
- Slither: high/medium findings fixed or reviewed; see the table below.

## Slither triage (accepted findings)

Slither 0.11.6 reports 19 medium/high items after fixes (0 with the triage file), all reviewed as false positives. They're recorded in
`contracts/slither.db.json` (Slither's triage file) and annotated inline with `slither-disable-next-line` and a reason.
(The inline comments are ignored by Slither on Windows because of a path-normalisation bug in 0.11.6; they work on Linux.)

| Detector | Where | Why it's safe |
| --- | --- | --- |
| reentrancy-balance (High) | `ManagerVault._swap` | Balance deltas around the adapter call are the security check itself. Every vault entry point shares one `nonReentrant` guard and the adapter is governance-whitelisted, so the pre-call balances cannot go stale. |
| incorrect-equality (13×) | `== 0` / day-index checks | Comparisons against zero or a UTC day index. A donation can only make a "nothing to do" branch not be taken; no check relies on an exact attacker-controlled balance. |
| unused-return (5×) | try/catch on Chainlink, `record()`, adapter output, in-kind token list | Values deliberately unused: deprecated Chainlink fields, snapshot side-effect only, the vault trusts balance deltas over the adapter's report. |

Fixed rather than accepted: weak-prng (modulo replaced with `addmod`/ring arithmetic), divide-before-multiply
(Sharpe computed from the sum), uninitialized locals, unused return in `FollowerStops`.

## Out of scope / known limitations
- Issuer, legal and custody risk of stock tokens and USDG (freezes or blacklists by issuers would affect vault balances).
- Liquidity: stock tokens trade mostly by RFQ; large orders may be impossible within slippage. An RFQ adapter is future work.
- Frontend geoblocking is best-effort (IP based). The contracts are permissionless unless `ComplianceRegistry` is enabled.
- Leaderboard ranking is a UI choice computed from on-chain stats, not an on-chain ranking.
