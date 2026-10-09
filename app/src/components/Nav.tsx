"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { PROJECT_TOKEN } from "@/config/chain";

const links = [
  { href: "/", label: "Leaderboard" },
  { href: "/console", label: "Manager console" },
  { href: "/stops", label: "My stops" },
  ...(PROJECT_TOKEN ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risks" },
];

export function Nav() {
  const path = usePathname();
  return (
    <header className="nav">
      <div className="container">
        <Link href="/" className="brand">
          <span className="brand-mark" /> Mirrorbook
        </Link>
        <nav className="nav-links">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </nav>
        <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
      </div>
    </header>
  );
}
