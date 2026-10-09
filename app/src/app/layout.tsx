import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Mirrorbook — on-chain copy trading for tokenized stocks",
  description:
    "Follow managers who run tokenized-stock portfolios on-chain. Guardrails, fees and track records are enforced and verified by smart contracts.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main className="container">{children}</main>
          <footer className="footer container">
            <span>
              Mirrorbook is experimental, unaudited software. Tokenized stocks carry market, liquidity, oracle and
              issuer risk. <a href="/risk">Read the risk disclosure</a>.
            </span>
            <span className="muted">Not affiliated with any brokerage or token issuer.</span>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
