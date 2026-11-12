import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { AGENT_BODY_LIMIT, readAgentJson } from "@/lib/server/agent-body";
import { clientAddressFromHeaders } from "@/lib/server/client-ip";
import { UserError } from "@/lib/server/errors";

export { AGENT_BODY_LIMIT, readAgentJson as readJson };

export function agentSubject(request: Request): string {
  const subject = clientAddressFromHeaders(request.headers) ?? "agent-direct";
  return createHash("sha256").update(`agent:${subject}`).digest("hex");
}

export function agentError(cause: unknown): NextResponse {
  if (cause instanceof UserError) {
    return NextResponse.json({ error: cause.message }, { status: cause.status });
  }
  return NextResponse.json({ error: "Не удалось выполнить запрос." }, { status: 500 });
}
