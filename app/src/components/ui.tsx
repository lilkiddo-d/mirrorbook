"use client";

import { ReactNode } from "react";
import { deployment, explorer } from "@/config/chain";

export function Stat({ label, value, tone }: { label: string; value: ReactNode; tone?: "pos" | "neg" }) {
  return (
    <div className="panel stat">
      <div className="label">{label}</div>
      <div className={`value ${tone ?? ""}`}>{value}</div>
    </div>
  );
}

export function TxStatus({ pending, error, hash }: { pending: boolean; error?: string; hash?: string }) {
  if (pending) return <div className="small muted">Waiting for confirmation…</div>;
  if (error) return <div className="error">{error}</div>;
  if (hash)
    return (
      <div className="success">
        Confirmed: <a href={explorer(`tx/${hash}`)} target="_blank" rel="noreferrer">{hash.slice(0, 18)}…</a>
      </div>
    );
  return null;
}

export function NotDeployed() {
  if (deployment) return null;
  return (
    <div className="notice">
      Mirrorbook contracts are not deployed for this network yet. Run <code>script/Deploy.s.sol</code> (see DEPLOY.md);
      it writes <code>app/src/config/deployments/&lt;chainId&gt;.json</code> automatically.
    </div>
  );
}

export function VerifiedBadge({ verified }: { verified?: boolean }) {
  if (!verified) return null;
  return <span className="badge verified" title="Manager has staked the project token (slashable)">✓ Verified</span>;
}

export function tone(v?: bigint): "pos" | "neg" | undefined {
  if (v === undefined) return undefined;
  return v >= 0n ? "pos" : "neg";
}
