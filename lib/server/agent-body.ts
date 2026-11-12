import { UserError } from "@/lib/server/errors";

/** Reject oversized agent payloads before JSON parse (DoS / memory). */
export const AGENT_BODY_LIMIT = 64 * 1024;

export async function readAgentJson(request: Request): Promise<unknown> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader) {
    const length = Number(lengthHeader);
    if (!Number.isFinite(length) || length < 0) {
      throw new UserError("Некорректный запрос.");
    }
    if (length > AGENT_BODY_LIMIT) {
      throw new UserError("Слишком большой запрос.", 413);
    }
  }
  let text: string;
  try {
    text = await request.text();
  } catch {
    throw new UserError("Некорректный запрос.");
  }
  if (text.length > AGENT_BODY_LIMIT) {
    throw new UserError("Слишком большой запрос.", 413);
  }
  if (!text) return {};
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new UserError("Некорректный запрос.");
  }
}
