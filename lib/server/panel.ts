import { requireAdmin } from "@/lib/server/guard";
import { getDb } from "@/lib/server/db";
import type { PanelSummary } from "@/lib/types";

export async function getPanelSummary(): Promise<PanelSummary> {
  const session = await requireAdmin();
  const row = getDb().prepare("SELECT COUNT(*) AS count FROM servers").get();
  return {
    adminName: session.displayName,
    serverCount: Number(row?.count ?? 0),
  };
}
