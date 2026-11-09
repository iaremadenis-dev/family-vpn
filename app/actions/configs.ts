"use server";

import { revalidatePath } from "next/cache";
import { writeAudit } from "@/lib/server/audit";
import {
  createConfig,
  deleteConfig,
  getConfigDownload,
  revokeConfig,
} from "@/lib/server/configs";
import { publicError } from "@/lib/server/errors";
import { assertSameOrigin, requireAdmin } from "@/lib/server/guard";

export type ActionResult = { error: string | null };

export async function createConfigAction(input: {
  deviceName: string;
  serverId: string;
}): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const config = await createConfig(input);
    writeAudit("config.create", config.deviceName);
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось создать конфигурацию.") };
  }
}

export async function revokeConfigAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await revokeConfig(id);
    writeAudit("config.revoke");
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось отозвать конфигурацию.") };
  }
}

export async function deleteConfigAction(id: string): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await deleteConfig(id);
    writeAudit("config.delete");
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось удалить конфигурацию.") };
  }
}

export async function downloadConfigAction(
  id: string,
): Promise<{ error: string | null; fileName?: string; content?: string }> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const file = await getConfigDownload(id);
    writeAudit("config.download");
    return { error: null, fileName: file.fileName, content: file.content };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось скачать конфигурацию.") };
  }
}

function refresh() {
  revalidatePath("/", "layout");
  revalidatePath("/configurations");
}
