import { agentError, agentSubject, readJson } from "@/lib/server/agent-route";
import { heartbeatAgent, type AgentReport } from "@/lib/server/pairing";
import { NextResponse } from "next/server";

export async function POST(request: Request) {
  try {
    const body = (await readJson(request)) as { version?: string; report?: AgentReport };
    const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
    heartbeatAgent(
      token,
      { version: String(body.version ?? ""), report: body.report as AgentReport },
      agentSubject(request),
    );
    return NextResponse.json({ ok: true });
  } catch (cause) {
    return agentError(cause);
  }
}
