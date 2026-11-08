import { getDb } from "@/lib/server/db";
import { requireAdmin } from "@/lib/server/guard";
import type { AuditEntry } from "@/lib/types";

export function writeAudit(action: string, target: string | null = null) {
  const db = getDb();
  db.prepare("INSERT INTO audit_log (action, target, created_at) VALUES (?, ?, ?)").run(
    action,
    target,
    new Date().toISOString(),
  );
  db.prepare(
    `DELETE FROM audit_log
     WHERE id NOT IN (SELECT id FROM audit_log ORDER BY id DESC LIMIT 500)`,
  ).run();
}

export async function listAudit(limit = 12): Promise<AuditEntry[]> {
  await requireAdmin();
  const rows = getDb()
    .prepare(
      "SELECT id, action, target, created_at FROM audit_log ORDER BY id DESC LIMIT ?",
    )
    .all(Math.min(Math.max(limit, 1), 50));

  return rows.map((row) => ({
    id: Number(row.id),
    action: String(row.action),
    target: row.target === null ? null : String(row.target),
    createdAt: String(row.created_at),
  }));
}
