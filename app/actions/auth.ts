"use server";

import { redirect } from "next/navigation";
import { hasAdmin, verifyAdminPassword } from "@/lib/server/admin";
import { completeSetup } from "@/lib/server/setup-token";
import { UserError, publicError } from "@/lib/server/errors";
import { writeAudit } from "@/lib/server/audit";
import { assertSameOrigin } from "@/lib/server/guard";
import {
  assertLoginAllowed,
  clearLoginFailures,
  recordLoginFailure,
} from "@/lib/server/rate-limit";
import { createSession, destroySession } from "@/lib/server/session";

export type AuthFormState = { error: string } | null;

export async function setupAdmin(
  _state: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  try {
    await assertSameOrigin();
    await assertLoginAllowed();
    if (hasAdmin()) return { error: "Администратор уже создан. Войдите паролем." };

    const password = String(formData.get("password") ?? "");
    const confirm = String(formData.get("confirm") ?? "");
    if (password !== confirm) return { error: "Пароли не совпадают." };

    completeSetup(
      String(formData.get("name") ?? ""),
      password,
      String(formData.get("activation") ?? ""),
    );
    await clearLoginFailures();
    await createSession();
    writeAudit("admin.setup");
  } catch (cause) {
    if (cause instanceof UserError && cause.code === "setup_token") {
      await recordLoginFailure();
    }
    return { error: publicError(cause, "Не удалось создать администратора.") };
  }

  redirect("/");
}

export async function login(
  _state: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  const password = String(formData.get("password") ?? "");
  try {
    await assertSameOrigin();
    await assertLoginAllowed();
    if (!hasAdmin() || !verifyAdminPassword(password)) {
      await recordLoginFailure();
      writeAudit("admin.login_failed");
      return { error: "Неверный пароль." };
    }
    await clearLoginFailures();
    await createSession();
    writeAudit("admin.login");
  } catch (cause) {
    return { error: publicError(cause, "Не удалось войти.") };
  }

  redirect("/");
}

export async function logout(): Promise<void> {
  await assertSameOrigin();
  writeAudit("admin.logout");
  await destroySession();
  redirect("/login");
}
