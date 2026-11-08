"use server";

import { revalidatePath } from "next/cache";
import { writeAudit } from "@/lib/server/audit";
import { publicError } from "@/lib/server/errors";
import { assertSameOrigin, requireAdmin } from "@/lib/server/guard";
import {
  createServer,
  deleteServer,
  setDefaultServer,
  updateServer,
} from "@/lib/server/servers";
import type { ServerInput } from "@/lib/types";

export type ActionResult = { error: string | null };

export async function createServerAction(input: ServerInput): Promise<ActionResult> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    const server = await createServer(input);
    writeAudit("server.create", server.name);
    refresh();
    return { error: null };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось сохранить сервер.") };
  }
}

export async function updateServerAction(id: string, input: ServerInput): Promise<ActionResult> {
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
