"use server";

import { revalidatePath } from "next/cache";
import { writeAudit } from "@/lib/server/audit";
import { publicError } from "@/lib/server/errors";
import { assertSameOrigin, requireAdmin } from "@/lib/server/guard";
import { acceptAgentNetworkReport, claimPairingCode, revokeAgent } from "@/lib/server/pairing";
import { createHash } from "node:crypto";
import { headers } from "next/headers";
import { clientAddressFromHeaders } from "@/lib/server/client-ip";
import {
  deleteServer,
  getServer,
  setDefaultServer,
  updateServer,
} from "@/lib/server/servers";
import type { ClaimedServerSummary, ServerRecord } from "@/lib/types";

export type ActionResult = { error: string | null };

export type ClaimServerResult = ActionResult & {
  claimed?: ClaimedServerSummary;
};

export async function claimServerAction(input: {
  name: string;
  location: string;
  code: string;
}): Promise<ClaimServerResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const server = claimPairingCode({ ...input, subjectHash: await adminSubject() });
    writeAudit("agent.pair", server.name);
    refresh();
    return { error: null, claimed: server };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось привязать сервер.") };
  }
}

export async function refreshServerAction(id: string): Promise<ActionResult & { server?: ServerRecord }> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const server = await getServer(id);
    if (!server) return { error: "Сервер не найден." };
    return { error: null, server };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось обновить статус сервера.") };
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

/** Explicit admin confirmation to adopt endpoint/WG key/subnet from the latest agent report. */
export async function acceptAgentNetworkAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const report = acceptAgentNetworkReport(id);
    writeAudit("server.network_accept", `${report.endpoint}:${report.listenPort}`);
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось подтвердить сетевые параметры.") };
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
  const subject = clientAddressFromHeaders(headerList) ?? "admin";
  return createHash("sha256").update(`claim:${subject}`).digest("hex");
}
