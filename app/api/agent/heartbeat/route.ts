import { agentError, agentSubject, readJson } from "@/lib/server/agent-route";
import { heartbeatAgent, type AgentReport } from "@/lib/server/pairing";
import { NextResponse } from "next/server";

export async function POST(request: Request) {
  try {
    const body = (await readJson(request)) as {
      version?: string;
      report?: AgentReport;
      peers?: unknown;
      jobResults?: unknown;
    };
    const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
    const result = heartbeatAgent(
      token,
      {
        version: String(body.version ?? ""),
        report: body.report as AgentReport,
        peers: body.peers,
        jobResults: body.jobResults,
      },
      agentSubject(request),
    );
    return NextResponse.json(result);
  } catch (cause) {
    return agentError(cause);
  }
}
