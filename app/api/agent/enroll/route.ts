import { agentError, agentSubject, readJson } from "@/lib/server/agent-route";
import { enrollAgent, type AgentReport } from "@/lib/server/pairing";
import { NextResponse } from "next/server";

export async function POST(request: Request) {
  try {
    const body = (await readJson(request)) as {
      code?: string;
      publicKey?: string;
      version?: string;
      timestamp?: number;
      signature?: string;
      report?: AgentReport;
    };
    const result = enrollAgent(
      {
        code: String(body.code ?? ""),
        publicKey: String(body.publicKey ?? ""),
        version: String(body.version ?? ""),
        timestamp: Number(body.timestamp),
        signature: String(body.signature ?? ""),
        report: body.report as AgentReport,
      },
      agentSubject(request),
    );
    return NextResponse.json(result);
  } catch (cause) {
    return agentError(cause);
  }
}
