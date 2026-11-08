import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";
import { requireAdmin } from "@/lib/server/guard";
import { hashPassword, validatePassword, verifyPassword } from "@/lib/server/password";

export function hasAdmin(): boolean {
  const row = getDb().prepare("SELECT id FROM admin WHERE id = 1").get();
  return Boolean(row);
}

export function createAdmin(displayName: string, password: string) {
  const name = validateDisplayName(displayName);
  const passwordError = validatePassword(password);
  if (passwordError) throw new UserError(passwordError);
  if (hasAdmin()) throw new UserError("Администратор уже создан.");

  getDb()
    .prepare(
      "INSERT INTO admin (id, display_name, password_hash, created_at) VALUES (1, ?, ?, ?)",
    )
    .run(name, hashPassword(password), new Date().toISOString());
}

export function verifyAdminPassword(password: string): boolean {
  const row = getDb().prepare("SELECT password_hash FROM admin WHERE id = 1").get();
  if (!row || typeof row.password_hash !== "string") return false;
  return verifyPassword(password, row.password_hash);
}

export async function renameAdmin(displayName: string) {
  await requireAdmin();
  const name = validateDisplayName(displayName);
  getDb().prepare("UPDATE admin SET display_name = ? WHERE id = 1").run(name);
}

export async function changeAdminPassword(currentPassword: string, nextPassword: string) {
  await requireAdmin();
  if (!verifyAdminPassword(currentPassword)) {
    throw new UserError("Текущий пароль неверный.");
  }
  const passwordError = validatePassword(nextPassword);
  if (passwordError) throw new UserError(passwordError);
  if (currentPassword === nextPassword) {
    throw new UserError("Новый пароль должен отличаться от текущего.");
  }
  getDb()
    .prepare("UPDATE admin SET password_hash = ? WHERE id = 1")
    .run(hashPassword(nextPassword));
}

function validateDisplayName(value: string): string {
  const name = value.trim();
  if (!name) throw new UserError("Укажите имя.");
  if (name.length > 40) throw new UserError("Имя длиннее 40 символов.");
  if (/[\u0000-\u001F]/.test(name)) throw new UserError("Имя содержит недопустимые символы.");
  return name;
}
