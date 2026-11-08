import { agentError, agentSubject, readJson } from "@/lib/server/agent-route";
import { pollEnrollment } from "@/lib/server/pairing";
import { NextResponse } from "next/server";

export async function POST(request: Request) {
  try {
    const body = (await readJson(request)) as {
      enrollmentId?: string;
      publicKey?: string;
      nonce?: string;
      timestamp?: number;
      signature?: string;
    };
    const result = pollEnrollment(
      {
        enrollmentId: String(body.enrollmentId ?? ""),
        publicKey: String(body.publicKey ?? ""),
        nonce: String(body.nonce ?? ""),
        timestamp: Number(body.timestamp),
        signature: String(body.signature ?? ""),
      },
      agentSubject(request),
    );
    return NextResponse.json(result);
  } catch (cause) {
    return agentError(cause);
  }
}
