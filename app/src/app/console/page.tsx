"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { encodeAbiParameters, parseUnits, type Address } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { deployment, symbolOf, USDG } from "@/config/chain";
import { erc20Abi, guardrailsAbi, managerVaultAbi, marketClockAbi, tradeExecutorAbi, vaultFactoryAbi } from "@/config/abis";
import { bps, num, short, usd } from "@/lib/format";
import { useMe, useTx } from "@/lib/hooks";
import { NotDeployed, TxStatus } from "@/components/ui";

export default function Console() {
  const { me } = useMe();
  const d = deployment;
  const mine = useReadContract({
    address: d?.vaultFactory,
    abi: vaultFactoryAbi,
    functionName: "vaultsOf",
    args: me ? [me] : undefined,
    query: { enabled: !!me && !!d },
  });
  const vaults = (mine.data ?? []) as readonly Address[];
  const [sel, setSel] = useState<Address | undefined>();
  useEffect(() => {
    if (!sel && vaults.length) setSel(vaults[vaults.length - 1]);
  }, [vaults, sel]);

  return (
    <div className="stack">
      <h1>Manager console</h1>
      <p className="muted">
        You trade only whitelisted stock tokens against USDG through the TradeExecutor. Position size, trades per day and
        slippage vs. the Chainlink price are enforced on-chain. You can never withdraw followers&apos; assets.
      </p>
      <NotDeployed />
      {!me && <div className="panel muted">Connect a wallet to manage vaults.</div>}
      {me && d && (
        <>
          <div className="panel">
            <div className="spread">
              <h2>Your vaults</h2>
              <div className="row">
                {vaults.map((v) => (
                  <button key={v} className={v === sel ? "" : "secondary"} onClick={() => setSel(v)}>
                    {short(v)}
                  </button>
                ))}
              </div>
            </div>
            {vaults.length === 0 && <div className="muted">No vaults yet — launch one below.</div>}
          </div>
          {sel && <ManageVault vault={sel} />}
          <CreateVault onCreated={() => mine.refetch()} />
        </>
      )}
    </div>
  );
}

function pctToBps(s: string): number {
  return Math.round(Number(s) * 100);
}

function CreateVault({ onCreated }: { onCreated: () => void }) {
  const [f, setF] = useState({
    name: "",
    symbol: "",
    mgmt: "1",
    perf: "10",
    hold: "24",
    uri: "",
    pos: "40",
    trades: "10",
    slip: "1",
  });
  const tx = useTx();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });
  const input = (k: keyof typeof f, label: string, ph?: string) => (
    <div className="field">
      <label>{label}</label>
      <input value={f[k]} onChange={set(k)} placeholder={ph} />
    </div>
  );
  return (
    <div className="panel stack">
      <h2>Launch a vault</h2>
      <div className="row">
        {input("name", "Name", "Megacap Momentum")}
        {input("symbol", "Symbol", "mMOMO")}
        {input("uri", "Strategy note / URI", "ipfs://… or a one-line thesis")}
      </div>
      <div className="row">
        {input("mgmt", "Mgmt fee %/yr (≤2)")}
        {input("perf", "Perf fee % over HWM (≤25)")}
        {input("hold", "Min hold (hours, ≤168)")}
      </div>
      <div className="row">
        {input("pos", "Max position % per stock")}
        {input("trades", "Max trades / day (≤50)")}
        {input("slip", "Max slippage % vs oracle (≤5)")}
      </div>
      <div className="row">
        <button
          disabled={tx.pending || !f.name || !f.symbol}
          onClick={async () => {
            const rc = await tx.send({
              address: deployment!.vaultFactory,
              abi: vaultFactoryAbi,
              functionName: "createVault",
              args: [
                {
                  name: f.name,
                  symbol: f.symbol,
                  managementFeeBps: pctToBps(f.mgmt),
                  performanceFeeBps: pctToBps(f.perf),
                  minHoldPeriod: Math.round(Number(f.hold) * 3600),
                  metadataURI: f.uri,
                  guardrails: {
                    maxPositionBps: pctToBps(f.pos),
                    maxTradesPerDay: Number(f.trades),
                    maxSlippageBps: pctToBps(f.slip),
                  },
                },
              ],
            });
            if (rc) onCreated();
          }}
        >
          Launch vault
        </button>
        <span className="small muted">Fees and guardrails are validated against the hard caps in code.</span>
      </div>
      <TxStatus {...tx} />
    </div>
  );
}

function ManageVault({ vault }: { vault: Address }) {
  const d = deployment!;
  const info = useReadContracts({
    contracts: [
      { address: vault, abi: managerVaultAbi, functionName: "name" },
      { address: vault, abi: managerVaultAbi, functionName: "navFresh" },
      { address: USDG, abi: erc20Abi, functionName: "balanceOf", args: [vault] },
      { address: vault, abi: managerVaultAbi, functionName: "heldTokens" },
      { address: d.guardrails, abi: guardrailsAbi, functionName: "configOf", args: [vault] },
      { address: d.guardrails, abi: guardrailsAbi, functionName: "tradesToday", args: [vault] },
      { address: d.guardrails, abi: guardrailsAbi, functionName: "whitelist" },
      { address: d.marketClock, abi: marketClockAbi, functionName: "isOpen" },
      { address: vault, abi: managerVaultAbi, functionName: "managementFeeBps" },
      { address: vault, abi: managerVaultAbi, functionName: "performanceFeeBps" },
      { address: vault, abi: managerVaultAbi, functionName: "pendingFees" },
      { address: d.guardrails, abi: guardrailsAbi, functionName: "pendingConfig", args: [vault] },
    ],
  });
  const g = <T,>(i: number) => info.data?.[i]?.result as T | undefined;
  const rails = g<{ maxPositionBps: number; maxTradesPerDay: number; maxSlippageBps: number }>(4);
  const whitelist = g<readonly Address[]>(6) ?? [];
  const held = g<readonly Address[]>(3) ?? [];
  const marketOpen = g<boolean>(7);
  const pendingFees = g<readonly [number, number, bigint]>(10);
  const pendingRails = g<readonly [{ maxPositionBps: number; maxTradesPerDay: number; maxSlippageBps: number }, bigint]>(11);

  return (
    <div className="grid grid-2">
      <div className="panel stack">
        <div className="spread">
          <h2>{g<string>(0) ?? "Vault"}</h2>
          <Link href={`/vault/${vault}`}>Public profile →</Link>
        </div>
        <div className="small muted">
          NAV {usd(g<readonly [bigint, boolean]>(1)?.[0])} · Cash {usd(g<bigint>(2))} · Market{" "}
          {marketOpen ? "open" : "closed"} · Trades today {String(g<number>(5) ?? 0)}/{rails?.maxTradesPerDay ?? "—"}
        </div>
        <TradeForm vault={vault} whitelist={whitelist} held={held} maxSlipBps={rails?.maxSlippageBps ?? 100} onDone={() => info.refetch()} />
      </div>
      <div className="panel stack">
        <h2>Settings</h2>
        <div className="small muted">
          Current: fees {bps(g<number>(8))} / {bps(g<number>(9))} · max position {bps(rails?.maxPositionBps)} · max
          slippage {bps(rails?.maxSlippageBps)}
        </div>
        {pendingFees && pendingFees[2] > 0n && (
          <PendingBox
            label={`Fee change to ${bps(pendingFees[0])} / ${bps(pendingFees[1])}`}
            eta={pendingFees[2]}
            req={{ address: vault, abi: managerVaultAbi, functionName: "applyPendingFees" }}
          />
        )}
        {pendingRails && pendingRails[1] > 0n && (
          <PendingBox
            label="Guardrail loosening"
            eta={pendingRails[1]}
            req={{ address: d.guardrails, abi: guardrailsAbi, functionName: "applyPendingConfig", args: [vault] }}
          />
        )}
        <SettingsForm vault={vault} rails={rails} onDone={() => info.refetch()} />
      </div>
    </div>
  );
}

function PendingBox({ label, eta, req }: { label: string; eta: bigint; req: Parameters<ReturnType<typeof useTx>["send"]>[0] }) {
  const tx = useTx();
  const ready = Number(eta) * 1000 <= Date.now();
  return (
    <div className="notice small">
      {label} queued — effective {new Date(Number(eta) * 1000).toLocaleString()} (followers can exit first).{" "}
      <button className="secondary" disabled={!ready || tx.pending} onClick={() => tx.send(req)}>
        Apply
      </button>
      <TxStatus {...tx} />
    </div>
  );
}

function TradeForm({
  vault,
  whitelist,
  held,
  maxSlipBps,
  onDone,
}: {
  vault: Address;
  whitelist: readonly Address[];
  held: readonly Address[];
  maxSlipBps: number;
  onDone: () => void;
}) {
  const tokens = useMemo(() => Array.from(new Set([...whitelist, ...held])), [whitelist, held]);
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [stock, setStock] = useState<Address | "">("");
  const [amount, setAmount] = useState("");
  const [fee, setFee] = useState(500);
  const tx = useTx();
  useEffect(() => {
    if (!stock && tokens.length) setStock(tokens[0]);
  }, [tokens, stock]);
  const tokenIn = side === "buy" ? USDG : (stock as Address);
  const tokenOut = side === "buy" ? (stock as Address) : USDG;
  const amountIn = useMemo(() => {
    try {
      return amount ? parseUnits(amount, side === "buy" ? 6 : 18) : 0n;
    } catch {
      return 0n;
    }
  }, [amount, side]);
  const preview = useReadContract({
    address: deployment!.tradeExecutor,
    abi: tradeExecutorAbi,
    functionName: "oracleMinOut",
    args: [tokenIn, tokenOut, amountIn, maxSlipBps],
    query: { enabled: !!stock && amountIn > 0n },
  });
  const bal = useReadContract({
    address: tokenIn,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
    query: { enabled: !!stock },
  });
  return (
    <div className="stack">
      <h3>Trade</h3>
      <div className="row">
        <div className="tabs">
          <button className={side === "buy" ? "on" : ""} onClick={() => setSide("buy")}>Buy</button>
          <button className={side === "sell" ? "on" : ""} onClick={() => setSide("sell")}>Sell</button>
        </div>
        <select value={stock} onChange={(e) => setStock(e.target.value as Address)}>
          {tokens.map((t) => (
            <option key={t} value={t}>{symbolOf(t)}</option>
          ))}
        </select>
        <select value={fee} onChange={(e) => setFee(Number(e.target.value))} title="Uniswap v3 fee tier">
          <option value={500}>0.05% pool</option>
          <option value={3000}>0.30% pool</option>
          <option value={10000}>1.00% pool</option>
        </select>
      </div>
      <div className="row">
        <div className="field">
          <label>Amount in ({side === "buy" ? "USDG" : symbolOf(stock || "0x")}) — vault has {num(bal.data, side === "buy" ? 6 : 18, 4)}</label>
          <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.0" inputMode="decimal" />
        </div>
      </div>
      <div className="small muted">
        Oracle-enforced minimum out ({bps(maxSlipBps)} max slippage):{" "}
        {preview.data ? `${num(preview.data[0], side === "buy" ? 18 : 6, 6)} ${symbolOf(tokenOut || "0x")}` : "—"}
        {preview.data && !preview.data[1] && <span className="error"> — price stale/unavailable</span>}
      </div>
      <button
        disabled={tx.pending || amountIn === 0n || !stock}
        onClick={async () => {
          await tx.send({
            address: deployment!.tradeExecutor,
            abi: tradeExecutorAbi,
            functionName: "execute",
            args: [
              {
                vault,
                adapter: deployment!.dexAdapter,
                tokenIn,
                tokenOut,
                amountIn,
                minAmountOut: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
                adapterData: encodeAbiParameters([{ type: "uint24" }], [fee]),
              },
            ],
          });
          onDone();
        }}
      >
        Execute {side}
      </button>
      <TxStatus {...tx} />
    </div>
  );
}

function SettingsForm({
  vault,
  rails,
  onDone,
}: {
  vault: Address;
  rails?: { maxPositionBps: number; maxTradesPerDay: number; maxSlippageBps: number };
  onDone: () => void;
}) {
  const [fees, setFees] = useState({ mgmt: "", perf: "" });
  const [r, setR] = useState({ pos: "", trades: "", slip: "" });
  const tx = useTx();
  return (
    <div className="stack">
      <h3>Fees (cuts apply now, increases wait 7 days)</h3>
      <div className="row">
        <div className="field"><label>Mgmt %/yr</label><input value={fees.mgmt} onChange={(e) => setFees({ ...fees, mgmt: e.target.value })} /></div>
        <div className="field"><label>Perf %</label><input value={fees.perf} onChange={(e) => setFees({ ...fees, perf: e.target.value })} /></div>
        <button
          className="secondary"
          disabled={tx.pending || !fees.mgmt || !fees.perf}
          onClick={async () => {
            await tx.send({ address: vault, abi: managerVaultAbi, functionName: "setFees", args: [pctToBps(fees.mgmt), pctToBps(fees.perf)] });
            onDone();
          }}
        >
          Update fees
        </button>
      </div>
      <h3>Guardrails (tighten now, loosen after 7 days)</h3>
      <div className="row">
        <div className="field"><label>Max pos %</label><input placeholder={rails ? String(rails.maxPositionBps / 100) : ""} value={r.pos} onChange={(e) => setR({ ...r, pos: e.target.value })} /></div>
        <div className="field"><label>Trades/day</label><input placeholder={rails ? String(rails.maxTradesPerDay) : ""} value={r.trades} onChange={(e) => setR({ ...r, trades: e.target.value })} /></div>
        <div className="field"><label>Slippage %</label><input placeholder={rails ? String(rails.maxSlippageBps / 100) : ""} value={r.slip} onChange={(e) => setR({ ...r, slip: e.target.value })} /></div>
        <button
          className="secondary"
          disabled={tx.pending || !r.pos || !r.trades || !r.slip}
          onClick={async () => {
            await tx.send({
              address: deployment!.guardrails,
              abi: guardrailsAbi,
              functionName: "setConfig",
              args: [vault, { maxPositionBps: pctToBps(r.pos), maxTradesPerDay: Number(r.trades), maxSlippageBps: pctToBps(r.slip) }],
            });
            onDone();
          }}
        >
          Update guardrails
        </button>
      </div>
      <TxStatus {...tx} />
    </div>
  );
}
