"use client";

import Link from "next/link";
import { useState } from "react";
import { maxUint256, type Address } from "viem";
import { useReadContracts } from "wagmi";
import { deployment } from "@/config/chain";
import { followerStopsAbi, managerVaultAbi } from "@/config/abis";
import { num, short } from "@/lib/format";
import { useMe, useTx, useVaultAddresses } from "@/lib/hooks";
import { NotDeployed, TxStatus } from "@/components/ui";

export default function StopsPage() {
  const { me } = useMe();
  const { vaults } = useVaultAddresses();
  const bal = useReadContracts({
    contracts: vaults.map((v) => ({
      address: v,
      abi: managerVaultAbi,
      functionName: "balanceOf" as const,
      args: [me!] as const,
    })),
    query: { enabled: !!me && vaults.length > 0 },
  });
  const positions = vaults.filter((_, i) => ((bal.data?.[i]?.result as bigint | undefined) ?? 0n) > 0n);

  return (
    <div className="stack">
      <h1>Follower stops</h1>
      <p className="muted">
        A stop exits your position automatically if the vault&apos;s share price falls a chosen percentage below your entry.
        Keepers execute it permissionlessly; the contract verifies the trigger on-chain and always sends funds to you —
        in USDG when the vault has idle cash and prices are live, otherwise in kind. Arming a stop approves your vault
        shares to the FollowerStops contract.
      </p>
      <NotDeployed />
      {!me && <div className="panel muted">Connect a wallet to manage stops.</div>}
      {me && positions.length === 0 && (
        <div className="panel muted">
          You don&apos;t follow any vault yet. <Link href="/">Browse the leaderboard →</Link>
        </div>
      )}
      {me && positions.map((v) => <StopRow key={v} vault={v} me={me} />)}
    </div>
  );
}

function StopRow({ vault, me }: { vault: Address; me: Address }) {
  const d = deployment!;
  const [drop, setDrop] = useState("10");
  const tx = useTx();
  const r = useReadContracts({
    contracts: [
      { address: vault, abi: managerVaultAbi, functionName: "name" },
      { address: vault, abi: managerVaultAbi, functionName: "balanceOf", args: [me] },
      { address: vault, abi: managerVaultAbi, functionName: "allowance", args: [me, d.followerStops] },
      { address: d.followerStops, abi: followerStopsAbi, functionName: "stops", args: [vault, me] },
      { address: d.followerStops, abi: followerStopsAbi, functionName: "triggerPrice", args: [vault, me] },
      { address: vault, abi: managerVaultAbi, functionName: "sharePrice" },
    ],
  });
  const g = <T,>(i: number) => r.data?.[i]?.result as T | undefined;
  const shares = g<bigint>(1) ?? 0n;
  const allowance = g<bigint>(2) ?? 0n;
  const stop = g<readonly [bigint, number, boolean]>(3);
  const active = stop?.[2] ?? false;
  const price = g<readonly [bigint, boolean]>(5);

  return (
    <div className="panel stack">
      <div className="spread">
        <h2>
          <Link href={`/vault/${vault}`}>{g<string>(0) ?? short(vault)}</Link>
        </h2>
        <span className="small muted">
          {num(shares, 12, 4)} shares · price {price ? (Number(price[0]) / 1e18).toFixed(4) : "—"}
        </span>
      </div>
      {active ? (
        <div className="row">
          <span className="badge verified">
            Stop armed: entry {(Number(stop![0]) / 1e18).toFixed(4)}, −{(stop![1] / 100).toFixed(1)}% → triggers at{" "}
            {(Number(g<bigint>(4) ?? 0n) / 1e18).toFixed(4)}
          </span>
          {allowance < shares && <span className="badge warn">Allowance below balance — stop covers part only</span>}
          <button
            className="secondary"
            disabled={tx.pending}
            onClick={async () => {
              await tx.send({ address: d.followerStops, abi: followerStopsAbi, functionName: "cancelStop", args: [vault] });
              r.refetch();
            }}
          >
            Cancel stop
          </button>
        </div>
      ) : (
        <div className="row">
          <div className="field">
            <label>Exit if price falls (%)</label>
            <input value={drop} onChange={(e) => setDrop(e.target.value)} />
          </div>
          {allowance < shares ? (
            <button
              disabled={tx.pending}
              onClick={async () => {
                await tx.send({ address: vault, abi: managerVaultAbi, functionName: "approve", args: [d.followerStops, maxUint256] });
                r.refetch();
              }}
            >
              1. Approve shares
            </button>
          ) : (
            <button
              disabled={tx.pending || !(Number(drop) >= 1 && Number(drop) <= 90)}
              onClick={async () => {
                await tx.send({
                  address: d.followerStops,
                  abi: followerStopsAbi,
                  functionName: "setStop",
                  args: [vault, Math.round(Number(drop) * 100)],
                });
                r.refetch();
              }}
            >
              Arm stop
            </button>
          )}
        </div>
      )}
      <TxStatus {...tx} />
    </div>
  );
}
