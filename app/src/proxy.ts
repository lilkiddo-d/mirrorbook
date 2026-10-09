import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. Set NEXT_PUBLIC_GEOBLOCK_COUNTRIES to a comma-separated list of ISO country codes.
 * Country comes from Vercel's `x-vercel-ip-country` header (absent locally => never blocks).
 * The risk disclosure and the block page itself stay reachable.
 */
const BLOCKED = new Set(
  (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter(Boolean),
);

export function proxy(req: NextRequest) {
  if (BLOCKED.size === 0) return NextResponse.next();
  const { pathname } = req.nextUrl;
  if (pathname.startsWith("/blocked") || pathname.startsWith("/risk")) return NextResponse.next();
  const country = req.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && BLOCKED.has(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
