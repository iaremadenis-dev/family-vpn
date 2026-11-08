import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { UserError } from "@/lib/server/errors";
import { readSession, type AdminSession } from "@/lib/server/session";

export async function requireAdmin(): Promise<AdminSession> {
  const session = await readSession();
  if (!session) redirect("/login");
  return session;
}

export async function assertSameOrigin() {
  const headerList = await headers();
  const origin = headerList.get("origin");
  const host =
    process.env.FAMILY_VPN_TRUST_PROXY === "1"
      ? (headerList.get("x-forwarded-host") ?? headerList.get("host"))
      : headerList.get("host");
  if (!origin || !host) throw new UserError("Запрос отклонён.");

  let originHost = "";
  try {
    originHost = new URL(origin).host;
  } catch {
    throw new UserError("Запрос отклонён.");
  }
  if (originHost !== host) throw new UserError("Запрос отклонён.");
}
