"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { useVaultAddresses, useVaultRows, type VaultRow } from "@/lib/hooks";
import { bps, pctWad, ratioWad, short, usd } from "@/lib/format";
import { NotDeployed, VerifiedBadge } from "@/components/ui";

const WINDOWS = [30, 90, 365] as const;
const MIN_AUM = 100n * 10n ** 6n; // 100 USDG: hides empty or self-funded dust vaults from the ranking

/** Minimum snapshots for a vault to be ranked in a window (avoids 2-point Sharpe ratios). */
const minPoints = (w: number) => Math.max(5, Math.floor(w / 6));

const SQRT365 = Math.sqrt(365);

export default function Leaderboard() {
  const [win, setWin] = useState<(typeof WINDOWS)[number]>(30);
  const { vaults, isLoading } = useVaultAddresses();
  const { rows } = useVaultRows(vaults, win);

  const [ranked, unranked] = useMemo(() => {
    const eligible = (r: VaultRow) =>
      r.stats && Number(r.stats.points) >= minPoints(win) && (r.nav ?? 0n) >= MIN_AUM;
    const a = rows.filter(eligible).sort((x, y) => (y.stats!.sharpe > x.stats!.sharpe ? 1 : -1));
    const b = rows.filter((r) => !eligible(r));
    return [a, b];
  }, [rows, win]);

  return (
    <div className="stack">
      <div className="spread">
        <div>
          <h1>Manager leaderboard</h1>
          <p className="muted">
            Ranked by risk-adjusted return (Sharpe-like: mean daily return ÷ stdev × √365) computed on-chain by the
            PerformanceTracker from oracle-priced daily snapshots. Nothing here is self-reported.
          </p>
        </div>
        <div className="tabs">
          {WINDOWS.map((w) => (
            <button key={w} className={w === win ? "on" : ""} onClick={() => setWin(w)}>
              {w}d
            </button>
          ))}
        </div>
      </div>
      <NotDeployed />
      <div className="panel table-wrap">
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>Vault</th>
              <th>Manager</th>
              <th>AUM</th>
              <th>Return</th>
              <th>Max DD</th>
              <th>Vol (ann.)</th>
              <th>Sharpe</th>
              <th>Fees (mgmt / perf)</th>
              <th>Days</th>
            </tr>
          </thead>
          <tbody>
            {ranked.map((r, i) => (
              <Row key={r.address} r={r} rank={i + 1} />
            ))}
            {unranked.map((r) => (
              <Row key={r.address} r={r} />
            ))}
            {!isLoading && rows.length === 0 && (
              <tr>
                <td colSpan={10} className="muted">
                  No vaults yet. <Link href="/console">Launch the first one →</Link>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <p className="small muted">
        Ranking requires ≥ {minPoints(win)} daily snapshots in the window and ≥ 100 USDG AUM. Past performance does not
        predict future results.
      </p>
    </div>
  );
}

function Row({ r, rank }: { r: VaultRow; rank?: number }) {
  const s = r.stats;
  const annVol = s ? BigInt(Math.round(Number(s.volatility) * SQRT365)) : undefined;
  return (
    <tr>
      <td>{rank ?? <span className="badge">new</span>}</td>
      <td>
        <Link href={`/vault/${r.address}`}>{r.name ?? short(r.address)}</Link>{" "}
        <span className="muted small">{r.symbol}</span>
      </td>
      <td>
        {short(r.manager)} <VerifiedBadge verified={r.verified} />
      </td>
      <td>{usd(r.nav, 6, 0)}</td>
      <td className={s && s.totalReturn < 0n ? "neg" : "pos"}>{s && s.points > 1n ? pctWad(s.totalReturn) : "—"}</td>
      <td className="neg">{s && s.points > 1n ? pctWad(s.maxDrawdown) : "—"}</td>
      <td>{s && s.points > 2n ? pctWad(annVol) : "—"}</td>
      <td>{s && s.points > 2n ? ratioWad(s.sharpe) : "—"}</td>
      <td>
        {bps(r.mgmtBps)} / {bps(r.perfBps)}
      </td>
      <td>{s ? String(s.points) : "—"}</td>
    </tr>
  );
}
