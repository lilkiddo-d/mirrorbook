"use client";

import { useMemo, useState } from "react";
import type { Abi, Address } from "viem";
import { useAccount, useConfig, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { deployment, PROJECT_TOKEN } from "@/config/chain";
import { managerVaultAbi, performanceTrackerAbi, projectTokenHooksAbi, vaultFactoryAbi } from "@/config/abis";
import { errMsg } from "./format";

export type Stats = {
  points: bigint;
  fromDay: number;
  toDay: number;
  totalReturn: bigint;
  maxDrawdown: bigint;
  volatility: bigint;
  sharpe: bigint;
};

export type VaultRow = {
  address: Address;
  name?: string;
  symbol?: string;
  manager?: Address;
  nav?: bigint;
  navFresh?: boolean;
  sharePrice?: bigint;
  mgmtBps?: number;
  perfBps?: number;
  stats?: Stats;
  verified?: boolean;
};

export function useVaultAddresses() {
  const factory = deployment?.vaultFactory;
  const count = useReadContract({
    address: factory,
    abi: vaultFactoryAbi,
    functionName: "vaultCount",
    query: { enabled: !!factory },
  });
  const n = count.data ? Number(count.data) : 0;
  const pages = Math.ceil(n / 100);
  const reads = useReadContracts({
    contracts: Array.from({ length: pages }, (_, i) => ({
      address: factory!,
      abi: vaultFactoryAbi,
      functionName: "vaults" as const,
      args: [BigInt(i * 100), 100n] as const,
    })),
    query: { enabled: !!factory && pages > 0 },
  });
  const list = useMemo(
    () => (reads.data ?? []).flatMap((r) => (r.status === "success" ? (r.result as readonly Address[]) : [])),
    [reads.data],
  );
  return { vaults: list, isLoading: count.isLoading || reads.isLoading };
}

const PER_VAULT = 8;

export function useVaultRows(vaults: readonly Address[], windowDays: number) {
  const tracker = deployment?.performanceTracker;
  const contracts = vaults.flatMap((v) => [
    { address: v, abi: managerVaultAbi, functionName: "name" },
    { address: v, abi: managerVaultAbi, functionName: "symbol" },
    { address: v, abi: managerVaultAbi, functionName: "manager" },
    { address: v, abi: managerVaultAbi, functionName: "navFresh" },
    { address: v, abi: managerVaultAbi, functionName: "sharePrice" },
    { address: v, abi: managerVaultAbi, functionName: "managementFeeBps" },
    { address: v, abi: managerVaultAbi, functionName: "performanceFeeBps" },
    { address: tracker!, abi: performanceTrackerAbi, functionName: "stats", args: [v, BigInt(windowDays)] },
  ]) as unknown as readonly { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] }[];
  const res = useReadContracts({ contracts, query: { enabled: !!tracker && vaults.length > 0 } });

  const base: VaultRow[] = useMemo(
    () =>
      vaults.map((address, i) => {
        const r = res.data?.slice(i * PER_VAULT, (i + 1) * PER_VAULT);
        const ok = (k: number) => (r?.[k]?.status === "success" ? r[k].result : undefined);
        const nav = ok(3) as readonly [bigint, boolean] | undefined;
        const sp = ok(4) as readonly [bigint, boolean] | undefined;
        return {
          address,
          name: ok(0) as string | undefined,
          symbol: ok(1) as string | undefined,
          manager: ok(2) as Address | undefined,
          nav: nav?.[0],
          navFresh: nav?.[1],
          sharePrice: sp?.[0],
          mgmtBps: ok(5) as number | undefined,
          perfBps: ok(6) as number | undefined,
          stats: ok(7) as Stats | undefined,
        };
      }),
    [vaults, res.data],
  );

  const managers = base.map((r) => r.manager).filter(Boolean) as Address[];
  const verified = useReadContracts({
    contracts: managers.map((m) => ({
      address: deployment?.projectTokenHooks as Address,
      abi: projectTokenHooksAbi,
      functionName: "isVerified" as const,
      args: [m] as const,
    })),
    query: { enabled: !!PROJECT_TOKEN && !!deployment && managers.length > 0 },
  });
  const rows = useMemo(() => {
    const vmap = new Map<string, boolean>();
    managers.forEach((m, i) => vmap.set(m.toLowerCase(), verified.data?.[i]?.result === true));
    return base.map((r) => ({ ...r, verified: r.manager ? vmap.get(r.manager.toLowerCase()) : false }));
  }, [base, verified.data, managers]);

  return { rows, isLoading: res.isLoading };
}

/** Sends a transaction and waits for its receipt, exposing status for the UI. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const config = useConfig();
  const [status, setStatus] = useState<{ pending: boolean; error?: string; hash?: string }>({ pending: false });
  async function send(req: Parameters<typeof writeContractAsync>[0]) {
    setStatus({ pending: true });
    try {
      const hash = await writeContractAsync(req);
      const receipt = await waitForTransactionReceipt(config, { hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted");
      setStatus({ pending: false, hash });
      return receipt;
    } catch (e) {
      setStatus({ pending: false, error: errMsg(e) });
      return undefined;
    }
  }
  return { send, ...status };
}

export function useMe() {
  const { address, isConnected } = useAccount();
  return { me: address, isConnected };
}
