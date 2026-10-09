# Decisions

One line of reasoning per decision. Dates are 2026-10-08/09 unless noted.

## Chain & external dependencies
- **Stablecoin = USDG** (`0x5fc5…d168`, 6 dp) — it is the only stablecoin on Robinhood's official Token Contracts page and has a Chainlink USDG/USD feed.
- **Stock-token addresses come from Robinhood's asset registry API** (`api.robinhood.com/rhj/assets`, chainId 4663) — the docs page renders that registry live; it is the canonical list ("a token with a matching ticker but a different address is not a Robinhood Stock Token").
- **Initial whitelist = 11 liquid names** (AAPL, NVDA, TSLA, MSFT, AMZN, GOOGL, META, AMD, COIN, SPY, QQQ) — each has both a registry token and a Chainlink "Robinhood <SYM> / USD" feed; more can be added via Timelock.
- **Fork test asserts on-chain `symbol()` and feed `description()` match** for every whitelisted pair — so a wrong address can never ship silently.
- **DEX = Uniswap v3 SwapRouter02 via `DexAdapter`** — official Uniswap deployment on 4663 with real USDG/stock pools (e.g. USDG/NVDA 0.05% holds ~$1.6M); RFQ venues (0x, 1inch Fusion) need off-chain quotes and can be added as another `IDexAdapter`.
- **No L2 Sequencer Uptime feed exists for Robinhood Chain** → `OracleAdapter` has an optional sequencer feed (disabled = `address(0)`), pluggable by Timelock when Chainlink publishes one. Documented gap.
- **No Multicall3 assumption** — the frontend uses JSON-RPC batching instead, which works on any RPC.
- **Verification = Sourcify** (`--verify --verifier sourcify`) — Robinhood's guide uses Blockscout, but its API answers scripted requests with a Cloudflare challenge (HTTP 403, observed 2026-10-09); Sourcify lists chain 4663 as supported and Blockscout imports Sourcify sources. Blockscout stays documented as a fallback.
- **`deployedAtBlock` comes from `eth_blockNumber`** — on Arbitrum Orbit chains `block.number` (and Forge's emulation of it) is the L1 block, which would make keepers scan logs from the wrong height.
- **Fork rehearsals use a fresh impersonated deployer** — anvil's default account 0 has 1,788 txs on Robinhood mainnet, so its CREATE addresses are occupied.
- **Slither triage file (`contracts/slither.db.json`)** records the 19 reviewed false positives — Slither 0.11.6 ignores inline `slither-disable` comments on Windows (path normalisation bug); the comments stay for Linux/CI and as documentation.

## Vault design
- **Withdrawals: hybrid "cash when priced, in-kind always"** — cash exits at oracle NAV only while the market is open and oracles are fresh (prevents stale-price arbitrage against remaining followers); `redeemInKind` is always available, even when paused or closed. Queuing until open was rejected: it traps followers during exactly the moments they most want out.
- **Deposits also require live prices when the vault holds stocks** — same stale-price arbitrage in reverse; cash-only vaults accept deposits anytime.
- **Cash exits are capped by idle cash** — the vault never force-sells on a follower's behalf (that would be front-runnable and push slippage onto everyone); in-kind covers the rest.
- **ERC-4626 with a 6-decimal virtual-share offset** — standard inflation-attack mitigation; shares have 12 decimals, launch price 1 USDG/share.
- **Vaults are EIP-1167 clones of one implementation** — cheap launches; the implementation is initializer-locked.
- **Factory doubles as the module registry** — every vault reads oracle/adapter/compliance/etc. from it, so "swappable" is one Timelock tx for all vaults.
- **Only stablecoin↔stock trades** (no stock↔stock) — keeps routing to the deep USDG pools and makes the oracle bound simple; buys require whitelist, sells only require a price so de-listed names can be unwound.
- **Max 10 distinct holdings per vault** — bounds every NAV/in-kind loop.
- **Slippage bound is oracle-derived, not manager-supplied** — `minOut = oracleValue × (1 − maxSlippage)`; the manager's own `minAmountOut` can only tighten it.
- **Position cap checked post-trade against fresh NAV** — simplest correct check; trades that would breach revert.
- **Min-hold lock (≤ 7 days, manager-chosen) applies to all exits and to share transfers** — blocks deposit→sandwich→exit around a manager trade; locked shares cannot be transferred, which avoids lock-griefing via dust transfers.
- **Manager may hold shares (own capital or fee shares) and redeem them like any follower** — "no withdrawals by the manager" means no access to follower assets; there is no manager withdrawal function.
- **Pause stops deposits and trades but never in-kind exits** — a guardian must not be able to trap funds.

## Fees
- **Fees are paid by minting shares** — no asset ever leaves the vault to pay a fee.
- **Management ≤ 2%/yr, performance ≤ 25% over HWM, protocol cut ≤ 30% of fees** — constants in `FeeEngine`; defaults 15% cut, 10% for verified managers.
- **Fee accrual runs before every deposit/withdraw/in-kind exit, even within the same block** — the invariant test found that skipping same-block accrual let a pending performance fee be charged on a new depositor's capital; fixed.
- **Performance fee only crystallizes with a fresh NAV**; management fee accrues regardless (time-based).
- **Fee and guardrail increases wait 7 days, decreases apply instantly** — followers get notice to exit.

## Track record
- **One snapshot per vault per UTC day, permissionless, first caller wins; TradeExecutor records before the day's first trade** — dense history without trusting the manager; ring buffer of 400 > 365.
- **Stats computed on-chain in a view** (return, max drawdown, per-period stdev, Sharpe-like = mean/stdev × √365, capped ±100) — the leaderboard reads them directly; nothing is self-reported.
- **Leaderboard eligibility: ≥ max(5, window/6) snapshots and ≥ 100 USDG AUM** — suppresses 2-point Sharpe and dust self-funded vaults.

## Market hours
- **MarketClock default closure = [Sat 00:00, Mon 01:00) UTC** — conservative envelope of Fri 20:00 → Sun 20:00 ET across DST, matching Chainlink's "us_equities_24/5" schedule; holidays are flagged by an operator, guardian can force-close.
- **Stock feed staleness limit 25 h** (24 h heartbeat + 1 h); **round-to-round deviation breaker 25%** for stocks, **2%** plus a [0.97, 1.03] band for USDG; Robinhood's advisory `oraclePaused()` flag is honored.

## Follower stops
- **Stop entry = share price at arming; trigger verified on-chain; anyone may execute** — keepers need no privileges, and funds always go to the follower.
- **Stop exits in cash if idle cash suffices and cash ops are open, otherwise in kind** — guarantees the exposure is cut even when liquidity is thin.
- **Authorization via ERC-20 share allowance** — no special vault hook needed.

## Governance & security
- **OpenZeppelin `TimelockController` with a 48 h floor that can never be lowered**; anyone can execute a matured operation; proposer defaults to the deployer and should be moved to a multisig.
- **Guardian (pause, holiday operator, compliance admin) is separate from admin** — fast reaction without admin power.
- **Every AccessControl admin role is handed to the Timelock and renounced by the deployer inside the deploy script** — fork test asserts it.
- **Keepers hold no on-chain roles** — snapshot and stop execution are permissionless, so a compromised keeper key can only waste its own gas.
- **Keepers sign through `cast send --account mirrorbook-keeper`** — the TypeScript process never touches key material.

## Project token
- **No ERC-20 is written or deployed**; `ProjectTokenHooks.setProjectToken` is one-shot and admin-only (Timelock). Mock ERC-20 lives only under `test/`.
- **Stakers receive a share (default 50%, max 80%) of protocol fees in USDG** via a reward-per-share accumulator; unstaking has a 7-day cooldown during which stake stays slashable.
- **Slashing is a governance (Timelock) decision**, not automatic — "breached by exploit" cannot be detected reliably on-chain, and auto-slashing is itself an attack surface.

## Compliance
- **ComplianceRegistry installed but disabled** — gates deposits, share receipt and vault creation by allowlist when enabled; exits are never gated.
- **Frontend geoblock is opt-in via `NEXT_PUBLIC_GEOBLOCK_COUNTRIES`** (Vercel IP country header); example list from Robinhood's Restricted Jurisdictions page.
- **Branding is neutral** ("Mirrorbook"); no third-party names or logos are used as branding.

## Tooling
- **OpenZeppelin v5.6.1 via npm (`node_modules`) remappings** rather than git submodules — the repo root is the git root, and npm pins exact versions.
- **Solidity 0.8.28, EVM cancun, optimizer 200 runs.**
- **Coverage measured without `--ir-minimum`** — via-IR source maps misattribute internal calls; the plain build is exact.
- **Frontend: Next.js 16 + wagmi 2 + RainbowKit 2** — RainbowKit 2 requires wagmi 2 (not 3).
