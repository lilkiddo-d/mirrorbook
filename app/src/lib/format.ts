import { formatUnits } from "viem";

export const WAD = 10n ** 18n;

export function usd(v: bigint | undefined, decimals = 6, digits = 2): string {
  if (v === undefined) return "—";
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: digits });
}

export function num(v: bigint | undefined, decimals = 18, digits = 4): string {
  if (v === undefined) return "—";
  return Number(formatUnits(v, decimals)).toLocaleString("en-US", { maximumFractionDigits: digits });
}

/** 1e18-scaled fraction -> "12.34%" */
export function pctWad(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return "—";
  return `${(Number(v) / 1e16).toFixed(digits)}%`;
}

export function bps(v: number | bigint | undefined): string {
  if (v === undefined) return "—";
  return `${(Number(v) / 100).toFixed(2)}%`;
}

export function ratioWad(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return "—";
  return (Number(v) / 1e18).toFixed(digits);
}

export function short(a?: string): string {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—";
}

export function dayToDate(day: number): string {
  return new Date(day * 86_400_000).toISOString().slice(0, 10);
}

export function errMsg(e: unknown): string {
  const m = (e as { shortMessage?: string; message?: string })?.shortMessage ?? (e as Error)?.message ?? String(e);
  return m.split("\n")[0];
}
