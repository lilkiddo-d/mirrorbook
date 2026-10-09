"use client";

import { dayToDate } from "@/lib/format";

export type Point = { day: number; price: bigint };

/** Share-price curve from on-chain snapshots (1.0 = launch price). */
export function EquityChart({ points }: { points: Point[] }) {
  if (points.length < 2) {
    return <div className="muted small">Not enough daily snapshots yet to draw an equity curve.</div>;
  }
  const W = 800;
  const H = 240;
  const pad = 32;
  const ys = points.map((p) => Number(p.price) / 1e18);
  const min = Math.min(...ys);
  const max = Math.max(...ys);
  const span = max - min || 1;
  const x = (i: number) => pad + (i / (points.length - 1)) * (W - 2 * pad);
  const y = (v: number) => H - pad - ((v - min) / span) * (H - 2 * pad);
  const d = ys.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const up = ys[ys.length - 1] >= ys[0];
  const stroke = up ? "var(--accent-2)" : "var(--danger)";
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="chart" role="img" aria-label="Equity curve">
      <defs>
        <linearGradient id="fill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor={stroke} stopOpacity="0.25" />
          <stop offset="100%" stopColor={stroke} stopOpacity="0" />
        </linearGradient>
      </defs>
      {[0, 0.5, 1].map((t) => (
        <g key={t}>
          <line x1={pad} x2={W - pad} y1={y(min + t * span)} y2={y(min + t * span)} stroke="var(--border)" />
          <text x={4} y={y(min + t * span) + 4} fill="var(--muted)" fontSize="11">
            {(min + t * span).toFixed(3)}
          </text>
        </g>
      ))}
      <path d={`${d} L${x(ys.length - 1)},${H - pad} L${x(0)},${H - pad} Z`} fill="url(#fill)" />
      <path d={d} fill="none" stroke={stroke} strokeWidth="2" />
      <text x={pad} y={H - 8} fill="var(--muted)" fontSize="11">
        {dayToDate(points[0].day)}
      </text>
      <text x={W - pad} y={H - 8} fill="var(--muted)" fontSize="11" textAnchor="end">
        {dayToDate(points[points.length - 1].day)}
      </text>
    </svg>
  );
}
