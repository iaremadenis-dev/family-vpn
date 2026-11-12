import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  if (
    pathname === "/login" ||
    pathname.startsWith("/api/agent/") ||
    pathname.startsWith("/releases/")
  ) {
    return NextResponse.next();
  }

  const session = request.cookies.get("family_vpn_session")?.value;
  // Presence + minimum entropy only; authoritative checks remain in requireAdmin/readSession.
  if (!session || session.length < 32) {
    return NextResponse.redirect(new URL("/login", request.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.png$).*)"],
};
