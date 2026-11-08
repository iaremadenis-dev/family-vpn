"use server";

import { revalidatePath } from "next/cache";
import { changeAdminPassword, renameAdmin, verifyAdminPassword } from "@/lib/server/admin";
import { writeAudit } from "@/lib/server/audit";
import { publicError } from "@/lib/server/errors";
import { assertSameOrigin, requireAdmin } from "@/lib/server/guard";
import { assertLoginAllowed, recordLoginFailure } from "@/lib/server/rate-limit";
import { destroyOtherSessions } from "@/lib/server/session";

export type SettingsFormState = { error: string | null; saved: boolean };

export async function renameAdminAction(
  _state: SettingsFormState,
  formData: FormData,
): Promise<SettingsFormState> {
  try {
    await assertSameOrigin();
    await requireAdmin();
    await renameAdmin(String(formData.get("name") ?? ""));
    writeAudit("admin.rename");
    revalidatePath("/", "layout");
    revalidatePath("/settings");
    return { error: null, saved: true };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось сохранить имя."), saved: false };
  }
}

export async function changePasswordAction(
  _state: SettingsFormState,
  formData: FormData,
): Promise<SettingsFormState> {
  const current = String(formData.get("current") ?? "");
  const next = String(formData.get("next") ?? "");
  const confirm = String(formData.get("confirm") ?? "");
  try {
    await assertSameOrigin();
    await requireAdmin();
    await assertLoginAllowed();
    if (next !== confirm) return { error: "Пароли не совпадают.", saved: false };
    if (!verifyAdminPassword(current)) {
      await recordLoginFailure();
      return { error: "Текущий пароль неверный.", saved: false };
    }
    await changeAdminPassword(current, next);
    await destroyOtherSessions();
    writeAudit("admin.password");
    return { error: null, saved: true };
  } catch (cause) {
    return { error: publicError(cause, "Не удалось сменить пароль."), saved: false };
  }
}
