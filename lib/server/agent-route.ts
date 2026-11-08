import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { UserError } from "@/lib/server/errors";

export function agentSubject(request: Request): string {
  let subject = "agent-direct";
  if (process.env.FAMILY_VPN_TRUST_PROXY === "1") {
    const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
    if (forwarded) subject = forwarded.slice(0, 200);
  }
  return createHash("sha256").update(`agent:${subject}`).digest("hex");
}

export function agentError(cause: unknown): NextResponse {
  if (cause instanceof UserError) {
    return NextResponse.json({ error: cause.message }, { status: cause.status });
  }
  return NextResponse.json({ error: "Не удалось выполнить запрос." }, { status: 500 });
}

export async function readJson(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new UserError("Некорректный запрос.");
  }
}
