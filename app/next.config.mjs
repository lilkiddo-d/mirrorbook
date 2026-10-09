import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The monorepo root holds config/chains.ts, shared with scripts and docs.
  turbopack: {
    root: path.join(here, ".."),
    // See src/lib/base-account-stub.js: keeps an unused wallet connector's heavy optional deps out.
    resolveAlias: { "@base-org/account": "./src/lib/base-account-stub.js" },
  },
  outputFileTracingRoot: path.join(here, ".."),
  experimental: { externalDir: true },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        ],
      },
    ];
  },
};

export default nextConfig;
