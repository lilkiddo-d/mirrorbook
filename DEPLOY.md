# Deploying Mirrorbook to Robinhood Chain mainnet

Chain ID **4663** · gas token **ETH** · RPC `https://rpc.mainnet.chain.robinhood.com` (rate-limited; an Alchemy URL
`https://robinhood-mainnet.g.alchemy.com/v2/<KEY>` is recommended) · explorer **Blockscout**
`https://robinhoodchain.blockscout.com` · verification via **Sourcify** (supports chain 4663; Blockscout imports
Sourcify-verified sources). Blockscout's own API currently answers scripted requests with a Cloudflare challenge
(HTTP 403), so `--verifier blockscout` fails from most machines.

Signing uses only Foundry keystore accounts: **no private key is ever placed in a file, env var or command line.**

## 0. Before you start

- Foundry ≥ 1.8, Node ≥ 22, pnpm installed. Run `pnpm install` once at the repo root.
- Decide the role addresses. All default to the deployer, which is fine for a first deploy but should be a multisig:

  | Env var | Role | Default |
  | --- | --- | --- |
  | `GUARDIAN` | pause/unpause, holiday operator, market force-close, compliance allowlist admin | deployer |
  | `TREASURY` | receives protocol fees | deployer |
  | `TIMELOCK_PROPOSER` | the only address that can schedule admin actions (48 h delay) | deployer |
  | `TIMELOCK_DELAY` | seconds, must be ≥ 172800 | 172800 |

- Fund the deployer with ETH on Robinhood Chain (bridge: https://docs.robinhood.com/chain/bridging). The deploy is about
  31 transactions and ~26.5M gas. At 2026-10-09 fees the dry run estimated **≈ 0.0011 ETH**; fund **0.01 ETH** for headroom.
- **Don't reuse a well-known dev key** (e.g. anvil/Hardhat account 0): those addresses have mainnet history, their
  contract-creation addresses are already taken, and anyone can drain them.

## 1. Import the deployer key into an encrypted keystore (once)

```bash
cast wallet import mirrorbook-deployer --interactive
```

Paste the key when prompted and choose a password. Foundry stores it encrypted in `~/.foundry/keystores/`. Get the address:

```bash
cast wallet address --account mirrorbook-deployer
```

## 2. Dry run (recommended right before deploying)

Simulates the whole deployment against live mainnet state without sending anything. It writes only
`deployments/4663.dry-run.json`. Replace `<DEPLOYER_ADDRESS>` with the address from step 1.

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <DEPLOYER_ADDRESS>
```

## 3. Deploy + verify (one command)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account mirrorbook-deployer --sender <DEPLOYER_ADDRESS> --broadcast --slow --verify --verifier sourcify
```

To set role addresses, prefix the command, e.g. `GUARDIAN=0x... TREASURY=0x... TIMELOCK_PROPOSER=0x... forge script ...`.

What it does, in one broadcast:
1. Deploys `Timelock`, `OracleAdapter` (USDG + 11 stock feeds), `MarketClock`, `VaultFactory` (+ `ManagerVault`
   implementation), `Guardrails`, `FeeEngine`, `PerformanceTracker`, `TradeExecutor`, `FollowerStops`, `FeeCollector`,
   `ComplianceRegistry` (disabled), `ProjectTokenHooks` (inert), `DexAdapter` (Uniswap v3).
2. Wires the modules, whitelists the stocks and approves the adapter.
3. Grants every admin role to the Timelock and **renounces the deployer's roles**.
4. Verifies every contract on Sourcify (shows as verified on Blockscout).
5. Writes `deployments/4663.json` and `app/src/config/deployments/4663.json`. Commit both.

If verification is interrupted, finish it without redeploying:

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account mirrorbook-deployer --sender <DEPLOYER_ADDRESS> --resume --verify --verifier sourcify
```

If Blockscout's API becomes reachable from your machine, `--verifier blockscout --verifier-url
https://robinhoodchain.blockscout.com/api/` also works.

Sanity check after deploying (should print `true` then `false`):

```bash
cast call <VAULT_FACTORY> "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 <TIMELOCK> --rpc-url https://rpc.mainnet.chain.robinhood.com
```

```bash
cast call <VAULT_FACTORY> "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 <DEPLOYER_ADDRESS> --rpc-url https://rpc.mainnet.chain.robinhood.com
```

## 4. Later: wire the project token ($MIRR)

Two steps, 48 h apart (Timelock). Details in [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

```bash
cd contracts && forge script script/SetProjectToken.s.sol --sig "schedule(address,uint256)" <MIRR_ADDRESS> <VERIFIED_MIN_STAKE_WEI> --rpc-url https://rpc.mainnet.chain.robinhood.com --account mirrorbook-deployer --sender <PROPOSER_ADDRESS> --broadcast
```

```bash
cd contracts && forge script script/SetProjectToken.s.sol --sig "execute(address,uint256)" <MIRR_ADDRESS> <VERIFIED_MIN_STAKE_WEI> --rpc-url https://rpc.mainnet.chain.robinhood.com --account mirrorbook-deployer --sender <PROPOSER_ADDRESS> --broadcast
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN` in Vercel and redeploy the app.

## 5. Keepers

Both keepers hold no on-chain roles; they only need ETH for gas. They sign through `cast send --account
mirrorbook-keeper`, so the Node process never sees key material.

```bash
cast wallet import mirrorbook-keeper --interactive
```

For unattended runs, store the keystore password in a file only you can read and point `KEEPER_PASSWORD_FILE` at it.
Run each keeper as a long-lived process (pm2, systemd, a container, …):

```bash
RPC_URL=https://rpc.mainnet.chain.robinhood.com KEEPER_PASSWORD_FILE=$HOME/.mirrorbook-keeper-pass INTERVAL_SECONDS=3600 pnpm keeper:snapshot
```

```bash
RPC_URL=https://rpc.mainnet.chain.robinhood.com KEEPER_PASSWORD_FILE=$HOME/.mirrorbook-keeper-pass INTERVAL_SECONDS=60 pnpm keeper:stops
```

- `keeper:snapshot` records each vault's daily share price (first successful call per UTC day wins; hourly is a good cadence).
- `keeper:stops` discovers armed stops from events and executes triggered ones.
- `DRY_RUN=1` prints the `cast send` commands instead of sending.

## 6. Frontend on Vercel

1. Import the repo in Vercel and set **Root Directory = `app`** (framework: Next.js). Vercel detects the pnpm workspace.
2. Environment variables:

   | Variable | Value |
   | --- | --- |
   | `NEXT_PUBLIC_CHAIN_ID` | `4663` |
   | `NEXT_PUBLIC_RPC_URL` | your Alchemy (or other) Robinhood Chain RPC URL |
   | `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | from https://cloud.reown.com (optional; injected wallets work without it) |
   | `NEXT_PUBLIC_PROJECT_TOKEN` | empty until $MIRR is wired |
   | `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | optional, e.g. `US,CA,GB,CH,CU,BY,IR,KP,RU,SY,UA,SS,SD,MM,VE` |

3. Make sure `app/src/config/deployments/4663.json` (written by step 3) is committed, then deploy.

Or from the CLI: `cd app && npx vercel --prod`.

## 7. After launch: operational checklist

- Move `TIMELOCK_PROPOSER`, `GUARDIAN` and `TREASURY` to multisigs if you used the deployer (role changes go through the Timelock).
- Flag US market holidays a few days ahead: `MarketClock.setHoliday(dayIndex, true)` from the guardian (dayIndex = unix time / 86400).
- When Chainlink publishes a Robinhood Chain sequencer-uptime feed, schedule `OracleAdapter.setSequencerUptimeFeed(feed, 3600)` through the Timelock.
- Watch the Timelock's `CallScheduled` events: any module swap gives followers 48 h to exit.

## Local rehearsal

`bash scripts/fork-deploy.sh` runs the exact same script against an anvil fork of mainnet (chain id 31337, port 18545)
and leaves the fork running. `bash scripts/fork-seed.sh` then launches a demo vault, deposits USDG and buys NVDA through
the real Uniswap pool, so the frontend has data (`NEXT_PUBLIC_CHAIN_ID=31337`, `NEXT_PUBLIC_RPC_URL=http://127.0.0.1:18545`).
The public RPC is not an archive node and rate-limits bursts: use the fork right after starting it (the script throttles anvil).
