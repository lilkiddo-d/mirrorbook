"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { ReactNode, useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider, createConfig, http } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { activeChain } from "@/config/chain";

const wcProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

const chains = [activeChain] as const;

const config = createConfig({
  chains,
  connectors: [injected(), ...(wcProjectId ? [walletConnect({ projectId: wcProjectId, showQrModal: false })] : [])],
  // JSON-RPC batching instead of Multicall3 (not assumed to exist on Robinhood Chain).
  transports: { [activeChain.id]: http(undefined, { batch: true }) } as Record<
    (typeof chains)[number]["id"],
    ReturnType<typeof http>
  >,
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [qc] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchInterval: 15_000 } } }));
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={qc}>
        <RainbowKitProvider theme={darkTheme({ accentColor: "#7c5cff" })} initialChain={activeChain}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
