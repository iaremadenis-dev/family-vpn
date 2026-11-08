"use server";

import { revalidatePath } from "next/cache";
import { writeAudit } from "@/lib/server/audit";
import { publicError } from "@/lib/server/errors";
import { assertSameOrigin, requireAdmin } from "@/lib/server/guard";
import { claimPairingCode, revokeAgent } from "@/lib/server/pairing";
import { createHash } from "node:crypto";
import { headers } from "next/headers";
import {
  deleteServer,
  setDefaultServer,
  updateServer,
} from "@/lib/server/servers";

export type ActionResult = { error: string | null };

export async function claimServerAction(input: {
  name: string;
  location: string;
  code: string;
}): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const server = claimPairingCode({ ...input, subjectHash: await adminSubject() });
    writeAudit("agent.pair", server.name);
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось привязать сервер.") };
  }
}

export async function revokeAgentAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    revokeAgent(id);
    writeAudit("agent.revoke");
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось отозвать агента.") };
  }
}

export async function updateServerAction(
  id: string,
  input: { name: string; location: string },
): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await updateServer(id, input);
    writeAudit("server.update", input.name.trim());
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось изменить сервер.") };
  }
}

export async function deleteServerAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await deleteServer(id);
    writeAudit("server.delete");
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось удалить сервер.") };
  }
}

export async function setDefaultServerAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await setDefaultServer(id);
    writeAudit("server.default");
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось выбрать основной сервер.") };
  }
}

function refresh() {
  revalidatePath("/", "layout");
  revalidatePath("/servers");
}

async function adminSubject(): Promise<string> {
  const headerList = await headers();
  const subject =
    process.env.FAMILY_VPN_TRUST_PROXY === "1"
      ? (headerList.get("x-forwarded-for")?.split(",")[0]?.trim() || "admin")
      : "admin";
  return createHash("sha256").update(`claim:${subject}`).digest("hex");
}
