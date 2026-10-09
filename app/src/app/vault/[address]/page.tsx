"use client";

import { use, useMemo, useState } from "react";
import Link from "next/link";
import { isAddress, parseUnits, type Address } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { deployment, explorer, PROJECT_TOKEN, symbolOf, USDG } from "@/config/chain";
import {
  erc20Abi,
  guardrailsAbi,
  managerVaultAbi,
  marketClockAbi,
  oracleAdapterAbi,
  performanceTrackerAbi,
  projectTokenHooksAbi,
} from "@/config/abis";
import { bps, num, pctWad, ratioWad, short, usd } from "@/lib/format";
import { useMe, useTx, type Stats } from "@/lib/hooks";
import { EquityChart } from "@/components/EquityChart";
import { NotDeployed, Stat, TxStatus, VerifiedBadge, tone } from "@/components/ui";

export default function VaultPage({ params }: { params: Promise<{ address: string }> }) {
  const { address } = use(params);
  if (!isAddress(address)) return <div className="error">Invalid vault address.</div>;
  return <Vault vault={address as Address} />;
}

function Vault({ vault }: { vault: Address }) {
  const d = deployment;
  const base = { address: vault, abi: managerVaultAbi } as const;
  const info = useReadContracts({
    contracts: [
      { ...base, functionName: "name" },
      { ...base, functionName: "symbol" },
      { ...base, functionName: "manager" },
      { ...base, functionName: "navFresh" },
      { ...base, functionName: "sharePrice" },
      { ...base, functionName: "managementFeeBps" },
      { ...base, functionName: "performanceFeeBps" },
      { ...base, functionName: "heldTokens" },
      { ...base, functionName: "cashOpsOpen" },
      { ...base, functionName: "minHoldPeriod" },
      { ...base, functionName: "highWaterMark" },
      { ...base, functionName: "totalSupply" },
      { ...base, functionName: "metadataURI" },
      { ...base, functionName: "paused" },
    ],
  });
  const r = info.data;
  const v = <T,>(i: number) => (r?.[i]?.status === "success" ? (r[i].result as T) : undefined);
  const name = v<string>(0);
  const manager = v<Address>(2);
  const nav = v<readonly [bigint, boolean]>(3);
  const sp = v<readonly [bigint, boolean]>(4);
  const held = v<readonly Address[]>(7) ?? [];
  const cashOpen = v<boolean>(8);

  const extra = useReadContracts({
    contracts: d
      ? [
          { address: d.guardrails, abi: guardrailsAbi, functionName: "configOf", args: [vault] },
          { address: d.guardrails, abi: guardrailsAbi, functionName: "tradesToday", args: [vault] },
          { address: d.marketClock, abi: marketClockAbi, functionName: "isOpen" },
          { address: d.performanceTracker, abi: performanceTrackerAbi, functionName: "history", args: [vault, 400n] },
          { address: d.performanceTracker, abi: performanceTrackerAbi, functionName: "stats", args: [vault, 30n] },
          { address: d.performanceTracker, abi: performanceTrackerAbi, functionName: "stats", args: [vault, 90n] },
          { address: d.performanceTracker, abi: performanceTrackerAbi, functionName: "stats", args: [vault, 365n] },
        ]
      : [],
  });
  const e = extra.data;
  const ev = <T,>(i: number) => (e?.[i]?.status === "success" ? (e[i].result as T) : undefined);
  const rails = ev<{ maxPositionBps: number; maxTradesPerDay: number; maxSlippageBps: number }>(0);
  const history = ev<readonly { day: number; price: bigint }[]>(3) ?? [];
  const stats = [ev<Stats>(4), ev<Stats>(5), ev<Stats>(6)];

  const holdings = useReadContracts({
    contracts: held.map((t) => ({ address: t, abi: erc20Abi, functionName: "balanceOf" as const, args: [vault] as const })),
    query: { enabled: held.length > 0 },
  });
  const balances = held.map((_, i) => holdings.data?.[i]?.result as bigint | undefined);
  const values = useReadContracts({
    contracts: held.map((t, i) => ({
      address: d?.oracleAdapter as Address,
      abi: oracleAdapterAbi,
      functionName: "convert" as const,
      args: [t, balances[i] ?? 0n, USDG] as const,
    })),
    query: { enabled: held.length > 0 && !!d && balances.every((b) => b !== undefined) },
  });
  const cash = useReadContract({ address: USDG, abi: erc20Abi, functionName: "balanceOf", args: [vault] });

  const verified = useReadContract({
    address: d?.projectTokenHooks,
    abi: projectTokenHooksAbi,
    functionName: "isVerified",
    args: manager ? [manager] : undefined,
    query: { enabled: !!PROJECT_TOKEN && !!manager && !!d },
  });

  return (
    <div className="stack">
      <NotDeployed />
      <div className="spread">
        <div>
          <h1>
            {name ?? "Vault"} <span className="muted">{v<string>(1)}</span>
          </h1>
          <div className="row small muted">
            <span>
              Manager <a href={explorer(`address/${manager}`)}>{short(manager)}</a>
            </span>
            <VerifiedBadge verified={verified.data === true} />
            <span>
              Vault <a href={explorer(`address/${vault}`)}>{short(vault)}</a>
            </span>
            {v<boolean>(13) && <span className="badge warn">Paused (in-kind exits still open)</span>}
            {ev<boolean>(2) === false && <span className="badge warn">Market closed</span>}
          </div>
          {v<string>(12) && <div className="small muted">Strategy: {v<string>(12)}</div>}
        </div>
        <Link href="/stops" className="btn">
          Set a stop
        </Link>
      </div>

      <div className="grid grid-4">
        <Stat label="AUM (NAV)" value={usd(nav?.[0])} />
        <Stat label="Share price" value={sp ? (Number(sp[0]) / 1e18).toFixed(4) : "—"} />
        <Stat label="Fees" value={`${bps(v<number>(5))} / ${bps(v<number>(6))}`} />
        <Stat label="High-water mark" value={v<bigint>(10) ? (Number(v<bigint>(10)) / 1e18).toFixed(4) : "—"} />
      </div>

      <div className="panel">
        <div className="spread">
          <h2>Equity curve</h2>
          <span className="small muted">{history.length} on-chain daily snapshots</span>
        </div>
        <EquityChart points={history.map((h) => ({ day: Number(h.day), price: h.price }))} />
      </div>

      <div className="grid grid-3">
        {[30, 90, 365].map((w, i) => (
          <div key={w} className="panel">
            <h3>{w} days</h3>
            <table>
              <tbody>
                <tr><td>Return</td><td className={tone(stats[i]?.totalReturn)}>{stats[i] && stats[i]!.points > 1n ? pctWad(stats[i]!.totalReturn) : "—"}</td></tr>
                <tr><td>Max drawdown</td><td>{stats[i] && stats[i]!.points > 1n ? pctWad(stats[i]!.maxDrawdown) : "—"}</td></tr>
                <tr><td>Sharpe-like</td><td>{stats[i] && stats[i]!.points > 2n ? ratioWad(stats[i]!.sharpe) : "—"}</td></tr>
                <tr><td>Snapshots</td><td>{stats[i] ? String(stats[i]!.points) : "—"}</td></tr>
              </tbody>
            </table>
          </div>
        ))}
      </div>

      <div className="grid grid-2">
        <div className="panel">
          <h2>Holdings</h2>
          <table>
            <thead>
              <tr><th>Asset</th><th>Amount</th><th>Value (oracle)</th><th>Weight</th></tr>
            </thead>
            <tbody>
              <tr>
                <td>USDG</td>
                <td>{num(cash.data, 6, 2)}</td>
                <td>{usd(cash.data)}</td>
                <td>{nav?.[0] && cash.data !== undefined ? pctWad((cash.data * 10n ** 18n) / nav[0]) : "—"}</td>
              </tr>
              {held.map((t, i) => {
                const val = (values.data?.[i]?.result as readonly [bigint, boolean] | undefined)?.[0];
                return (
                  <tr key={t}>
                    <td><a href={explorer(`address/${t}`)}>{symbolOf(t)}</a></td>
                    <td>{num(balances[i], 18, 4)}</td>
                    <td>{usd(val)}</td>
                    <td>{nav?.[0] && val !== undefined ? pctWad((val * 10n ** 18n) / nav[0]) : "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <h3 style={{ marginTop: 16 }}>Guardrails (enforced in code)</h3>
          <div className="small">
            Max position {bps(rails?.maxPositionBps)} · Max trades/day {rails?.maxTradesPerDay ?? "—"} (today{" "}
            {String(ev<number>(1) ?? "—")}) · Max slippage vs oracle {bps(rails?.maxSlippageBps)} · Min hold{" "}
            {v<number>(9) !== undefined ? `${Number(v<number>(9)) / 3600}h` : "—"}
          </div>
        </div>
        <FollowPanel vault={vault} cashOpen={cashOpen} navFresh={nav?.[1]} />
      </div>
    </div>
  );
}

function FollowPanel({ vault, cashOpen, navFresh }: { vault: Address; cashOpen?: boolean; navFresh?: boolean }) {
  const { me } = useMe();
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const reads = useReadContracts({
    contracts: me
      ? [
          { address: vault, abi: managerVaultAbi, functionName: "balanceOf", args: [me] },
          { address: vault, abi: managerVaultAbi, functionName: "maxRedeem", args: [me] },
          { address: vault, abi: managerVaultAbi, functionName: "unlockTime", args: [me] },
          { address: USDG, abi: erc20Abi, functionName: "allowance", args: [me, vault] },
          { address: USDG, abi: erc20Abi, functionName: "balanceOf", args: [me] },
          { address: vault, abi: managerVaultAbi, functionName: "maxDeposit", args: [me] },
        ]
      : [],
  });
  const g = <T,>(i: number) => reads.data?.[i]?.result as T | undefined;
  const shares = g<bigint>(0) ?? 0n;
  const maxRedeem = g<bigint>(1) ?? 0n;
  const unlock = Number(g<bigint>(2) ?? 0n);
  const allowance = g<bigint>(3) ?? 0n;
  const wallet = g<bigint>(4);
  const canDeposit = (g<bigint>(5) ?? 0n) > 0n;
  const assetsOf = useReadContract({
    address: vault,
    abi: managerVaultAbi,
    functionName: "convertToAssets",
    args: [shares],
    query: { enabled: shares > 0n },
  });
  const amt = useMemo(() => {
    try {
      return amount ? parseUnits(amount, 6) : 0n;
    } catch {
      return 0n;
    }
  }, [amount]);
  const refresh = () => reads.refetch();
  const locked = unlock * 1000 > Date.now();

  return (
    <div className="panel stack">
      <h2>Follow</h2>
      {!me && <div className="muted">Connect a wallet to follow this manager.</div>}
      {me && (
        <>
          <div className="small muted">
            Your position: {num(shares, 12, 4)} shares ≈ {usd(assetsOf.data)} · Wallet {usd(wallet)}
            {locked && <> · Locked until {new Date(unlock * 1000).toLocaleString()}</>}
          </div>
          <div className="row">
            <div className="field">
              <label>Amount (USDG)</label>
              <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="1000" inputMode="decimal" />
            </div>
          </div>
          {!canDeposit && (
            <div className="small muted">
              Cash deposits are open only while prices are live (market open, fresh oracles){navFresh === false ? " — an oracle is stale right now" : ""}.
            </div>
          )}
          <div className="row">
            {allowance < amt ? (
              <button
                disabled={tx.pending || amt === 0n}
                onClick={async () => {
                  await tx.send({ address: USDG, abi: erc20Abi, functionName: "approve", args: [vault, amt] });
                  refresh();
                }}
              >
                Approve USDG
              </button>
            ) : (
              <button
                disabled={tx.pending || amt === 0n || !canDeposit}
                onClick={async () => {
                  await tx.send({ address: vault, abi: managerVaultAbi, functionName: "deposit", args: [amt, me] });
                  refresh();
                }}
              >
                Follow (deposit)
              </button>
            )}
            <button
              className="secondary"
              disabled={tx.pending || maxRedeem === 0n || !cashOpen}
              title="Redeem in USDG from idle cash (needs live prices)"
              onClick={async () => {
                await tx.send({ address: vault, abi: managerVaultAbi, functionName: "redeem", args: [maxRedeem, me, me] });
                refresh();
              }}
            >
              Unfollow in USDG
            </button>
            <button
              className="secondary"
              disabled={tx.pending || shares === 0n || locked}
              title="Always available: receive your pro-rata slice of every holding"
              onClick={async () => {
                await tx.send({ address: vault, abi: managerVaultAbi, functionName: "redeemInKind", args: [shares, me, me] });
                refresh();
              }}
            >
              Unfollow in kind
            </button>
          </div>
          {maxRedeem < shares && shares > 0n && (
            <div className="small muted">
              USDG exits are limited to idle cash ({num(maxRedeem, 12, 2)} shares now). In-kind exit is always available,
              including while the market is closed or the vault is paused.
            </div>
          )}
          <TxStatus {...tx} />
        </>
      )}
    </div>
  );
}
