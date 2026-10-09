// The Base Account connector (pulled in by RainbowKit via @wagmi/connectors) lazily imports
// @base-org/account, whose Coinbase CDP SDK drags in optional, uninstalled x402 packages.
// Mirrorbook does not offer that connector, so the import resolves to this stub instead.
export function createBaseAccountSDK() {
  throw new Error("Base Account wallet is not supported by this app");
}
