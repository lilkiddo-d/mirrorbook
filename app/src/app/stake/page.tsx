"use client";

import { useMemo, useState } from "react";
import { parseUnits } from "viem";
import { useReadContracts } from "wagmi";
import { deployment, PROJECT_TOKEN } from "@/config/chain";
import { erc20Abi, projectTokenHooksAbi } from "@/config/abis";
import { num, usd } from "@/lib/format";
import { useMe, useTx } from "@/lib/hooks";
import { NotDeployed, Stat, TxStatus } from "@/components/ui";

/** Only reachable/linked when NEXT_PUBLIC_PROJECT_TOKEN is set. */
export default function StakePage() {
  if (!PROJECT_TOKEN) {
    return <div className="panel muted">Token features are not enabled.</div>;
  }
  return <Stake />;
}

function Stake() {
  const { me } = useMe();
  const d = deployment;
  const hooks = d?.projectTokenHooks;
  const token = PROJECT_TOKEN!;
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const r = useReadContracts({
    contracts:
      hooks && me
        ? [
            { address: hooks, abi: projectTokenHooksAbi, functionName: "projectToken" },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "totalStaked" },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "staked", args: [me] },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "earned", args: [me] },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "verifiedMinStake" },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "unstaking", args: [me] },
            { address: token, abi: erc20Abi, functionName: "balanceOf", args: [me] },
            { address: token, abi: erc20Abi, functionName: "allowance", args: [me, hooks] },
            { address: hooks, abi: projectTokenHooksAbi, functionName: "isVerified", args: [me] },
          ]
        : [],
  });
  const g = <T,>(i: number) => r.data?.[i]?.result as T | undefined;
  const live = (g<string>(0) ?? "").toLowerCase() === token.toLowerCase();
  const amt = useMemo(() => {
    try {
      return amount ? parseUnits(amount, 18) : 0n;
    } catch {
      return 0n;
    }
  }, [amount]);
  const unstaking = g<readonly [bigint, bigint]>(5);
  const refresh = () => r.refetch();

  return (
    <div className="stack">
      <h1>Stake $MIRR</h1>
      <p className="muted">
        Stakers share protocol fees (paid in USDG). Managers whose stake meets the threshold get a Verified badge and a
        lower protocol cut — their stake can be slashed by governance if guardrails are breached through an exploit.
        Unstaking has a 7-day cooldown during which stake remains slashable.
      </p>
      <NotDeployed />
      {!live && d && (
        <div className="notice">The token has not been wired on-chain yet (pending the Timelock&apos;s setProjectToken).</div>
      )}
      {me && (
        <>
          <div className="grid grid-4">
            <Stat label="Total staked" value={num(g<bigint>(1), 18, 2)} />
            <Stat label="Your stake" value={num(g<bigint>(2), 18, 2)} />
            <Stat label="Claimable" value={usd(g<bigint>(3))} />
            <Stat label="Verified threshold" value={num(g<bigint>(4), 18, 0)} />
          </div>
          <div className="panel stack">
            <div className="row">
              <div className="field">
                <label>Amount (wallet {num(g<bigint>(6), 18, 2)})</label>
                <input value={amount} onChange={(e) => setAmount(e.target.value)} />
              </div>
              {(g<bigint>(7) ?? 0n) < amt ? (
                <button disabled={tx.pending || !live} onClick={async () => { await tx.send({ address: token, abi: erc20Abi, functionName: "approve", args: [hooks!, amt] }); refresh(); }}>
                  Approve
                </button>
              ) : (
                <button disabled={tx.pending || !live || amt === 0n} onClick={async () => { await tx.send({ address: hooks!, abi: projectTokenHooksAbi, functionName: "stake", args: [amt] }); refresh(); }}>
                  Stake
                </button>
              )}
              <button className="secondary" disabled={tx.pending || !live || amt === 0n} onClick={async () => { await tx.send({ address: hooks!, abi: projectTokenHooksAbi, functionName: "requestUnstake", args: [amt] }); refresh(); }}>
                Request unstake
              </button>
              <button className="secondary" disabled={tx.pending || !unstaking || unstaking[0] === 0n || Number(unstaking[1]) * 1000 > Date.now()} onClick={async () => { await tx.send({ address: hooks!, abi: projectTokenHooksAbi, functionName: "withdrawUnstaked" }); refresh(); }}>
                Withdraw unstaked
              </button>
              <button className="secondary" disabled={tx.pending} onClick={async () => { await tx.send({ address: hooks!, abi: projectTokenHooksAbi, functionName: "claimRewards" }); refresh(); }}>
                Claim fees
              </button>
            </div>
            {unstaking && unstaking[0] > 0n && (
              <div className="small muted">
                Cooling down: {num(unstaking[0], 18, 2)} — withdrawable {new Date(Number(unstaking[1]) * 1000).toLocaleString()}
              </div>
            )}
            {g<boolean>(8) && <span className="badge verified">✓ You are a verified manager</span>}
            <TxStatus {...tx} />
          </div>
        </>
      )}
    </div>
  );
}
