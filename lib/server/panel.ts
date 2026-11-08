import { requireAdmin } from "@/lib/server/guard";
import { getDb } from "@/lib/server/db";
import { deriveLinkStatus } from "@/lib/server/pairing";
import type { PanelSummary } from "@/lib/types";

export async function getPanelSummary(): Promise<PanelSummary> {
  const session = await requireAdmin();
  const rows = getDb()
    .prepare(
      `SELECT servers.last_seen_at, servers.wg_up, agents.server_id AS agent_server_id,
              agents.revoked_at AS agent_revoked_at
       FROM servers
       LEFT JOIN agents ON agents.server_id = servers.id`,
    )
    .all();
  const onlineCount = rows.filter((row) => {
    const paired = row.agent_server_id !== null && row.agent_server_id !== undefined;
    return (
      deriveLinkStatus({
        paired,
        revoked: paired && row.agent_revoked_at !== null && row.agent_revoked_at !== undefined,
        lastSeenAt: row.last_seen_at === null || row.last_seen_at === undefined ? null : String(row.last_seen_at),
        wgUp: row.wg_up === null || row.wg_up === undefined ? null : Number(row.wg_up) === 1,
      }) === "online"
    );
  }).length;
  return {
    adminName: session.displayName,
    serverCount: rows.length,
    onlineCount,
  };
}
