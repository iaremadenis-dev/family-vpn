import { randomUUID } from "node:crypto";
import { requestBackup } from "@/lib/server/backup-request";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";

export type AgentJobType = "add_peer" | "remove_peer";

export type AgentJobPayload = {
  id: string;
  type: AgentJobType;
  publicKey: string;
  allowedIps?: string;
};

export type AgentJobResult = {
  id: string;
  ok: boolean;
  error?: string;
};

export type PeerStatInput = {
  publicKey: string;
  allowedIps?: string;
  rxBytes?: number;
  txBytes?: number;
  lastHandshake?: number;
};

export function enqueueJob(input: {
  serverId: string;
  configId: string;
  type: AgentJobType;
  publicKey: string;
  allowedIps?: string;
}): string {
  const now = new Date().toISOString();
  const id = randomUUID();
  getDb()
    .prepare(
      `INSERT INTO agent_jobs
        (id, server_id, config_id, type, public_key, allowed_ips, status, attempts, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?)`,
    )
    .run(
      id,
      input.serverId,
      input.configId,
      input.type,
      input.publicKey,
      input.allowedIps ?? null,
      now,
      now,
    );
  return id;
}

export function takeJobsForServer(serverId: string, limit = 8): AgentJobPayload[] {
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT id, type, public_key, allowed_ips
       FROM agent_jobs
       WHERE server_id = ? AND status IN ('queued', 'delivered')
       ORDER BY created_at ASC
       LIMIT ?`,
    )
    .all(serverId, limit);
  const now = new Date().toISOString();
  const jobs: AgentJobPayload[] = [];
  for (const row of rows) {
    db.prepare(
      `UPDATE agent_jobs
       SET status = 'delivered', attempts = attempts + 1, updated_at = ?
       WHERE id = ? AND status IN ('queued', 'delivered')`,
    ).run(now, String(row.id));
    jobs.push({
      id: String(row.id),
      type: String(row.type) as AgentJobType,
      publicKey: String(row.public_key),
      allowedIps: row.allowed_ips == null ? undefined : String(row.allowed_ips),
    });
  }
  return jobs;
}

export function applyJobResults(serverId: string, results: AgentJobResult[]) {
  if (!Array.isArray(results) || results.length === 0) return;
  const db = getDb();
  const now = new Date().toISOString();

  db.exec("BEGIN IMMEDIATE");
  let changed = false;
  try {
    for (const result of results.slice(0, 32)) {
      if (!result || typeof result.id !== "string") continue;
      const row = db
        .prepare(
          `SELECT id, config_id, type, status
           FROM agent_jobs
           WHERE id = ? AND server_id = ?`,
        )
        .get(result.id, serverId);
      if (!row) continue;
      if (row.status === "succeeded" || row.status === "failed") continue;

      const ok = Boolean(result.ok);
      const error =
        ok || typeof result.error !== "string"
          ? null
          : result.error.trim().slice(0, 200) || "Ошибка агента";

      db.prepare(
        `UPDATE agent_jobs
         SET status = ?, last_error = ?, updated_at = ?, completed_at = ?
         WHERE id = ?`,
      ).run(ok ? "succeeded" : "failed", error, now, now, String(row.id));
      changed = true;

      if (!row.config_id) continue;
      if (String(row.type) === "add_peer") {
        if (ok) {
          db.prepare(
            `UPDATE configs
             SET status = 'active', last_error = NULL, updated_at = ?
             WHERE id = ? AND status IN ('pending', 'error')`,
          ).run(now, String(row.config_id));
        } else {
          db.prepare(
            `UPDATE configs
             SET status = 'error', last_error = ?, updated_at = ?
             WHERE id = ? AND status IN ('pending', 'error')`,
          ).run(error ?? "Не удалось зарегистрировать peer.", now, String(row.config_id));
        }
      } else if (String(row.type) === "remove_peer") {
        if (ok) {
          db.prepare(
            `UPDATE configs
             SET status = 'revoked', last_error = NULL, revoked_at = COALESCE(revoked_at, ?), updated_at = ?,
                 client_private_key_enc = ''
             WHERE id = ? AND status IN ('revoking', 'active', 'pending', 'error')`,
          ).run(now, now, String(row.config_id));
        } else {
          db.prepare(
            `UPDATE configs
             SET status = 'error', last_error = ?, updated_at = ?
             WHERE id = ? AND status = 'revoking'`,
          ).run(error ?? "Не удалось отозвать peer.", now, String(row.config_id));
        }
      }
    }
    db.exec("COMMIT");
    if (changed) requestBackup("config");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

export function applyPeerStats(serverId: string, peers: PeerStatInput[]) {
  if (!Array.isArray(peers)) return;
  const db = getDb();
  const now = new Date().toISOString();
  const usedIps = new Set<string>();

  for (const peer of peers.slice(0, 512)) {
    if (!peer || typeof peer.publicKey !== "string") continue;
    const publicKey = peer.publicKey.trim();
    if (!publicKey) continue;

    if (typeof peer.allowedIps === "string") {
      for (const part of peer.allowedIps.split(",")) {
        const host = part.trim().split("/")[0];
        if (host && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) usedIps.add(host);
      }
    }

    const config = db
      .prepare(
        `SELECT id FROM configs
         WHERE server_id = ? AND client_public_key = ? AND status IN ('active', 'pending', 'revoking', 'error')`,
      )
      .get(serverId, publicKey);
    if (!config) continue;

    const rx = toNonNegInt(peer.rxBytes);
    const tx = toNonNegInt(peer.txBytes);
    const handshake =
      typeof peer.lastHandshake === "number" &&
      Number.isFinite(peer.lastHandshake) &&
      peer.lastHandshake > 0
        ? new Date(peer.lastHandshake * 1000).toISOString()
        : null;

    db.prepare(
      `UPDATE configs
       SET rx_bytes = ?, tx_bytes = ?, last_handshake_at = ?, updated_at = ?
       WHERE id = ?`,
    ).run(rx, tx, handshake, now, String(config.id));
  }

  db.prepare("UPDATE servers SET used_vpn_ips_json = ?, updated_at = ? WHERE id = ?").run(
    JSON.stringify([...usedIps]),
    now,
    serverId,
  );
}

export function assertOnlineAgent(serverId: string) {
  const row = getDb()
    .prepare(
      `SELECT servers.last_seen_at, servers.wg_up, servers.agent_version,
              agents.revoked_at, agents.server_id
       FROM servers
       LEFT JOIN agents ON agents.server_id = servers.id
       WHERE servers.id = ?`,
    )
    .get(serverId);
  if (!row) throw new UserError("Сервер не найден.");
  if (!row.server_id) throw new UserError("К серверу не привязан агент.");
  if (row.revoked_at) throw new UserError("Доступ агента отозван.");
  if (Number(row.wg_up) !== 1) throw new UserError("WireGuard на сервере не поднят.");
  const seen = Date.parse(String(row.last_seen_at ?? ""));
  if (!Number.isFinite(seen) || Date.now() - seen > 45_000) {
    throw new UserError("Агент сервера сейчас не на связи. Повторите, когда статус станет Online.");
  }
  if (!agentSupportsPeers(row.agent_version == null ? null : String(row.agent_version))) {
    throw new UserError("Обновите агент до v0.4.0+, затем повторите операцию.");
  }
}

function agentSupportsPeers(version: string | null): boolean {
  if (!version) return false;
  const parts = version.split(".").map((part) => Number(part));
  if (parts.length < 3 || parts.some((part) => !Number.isInteger(part))) return false;
  const [major, minor] = parts;
  if ((major ?? 0) > 0) return true;
  return (minor ?? 0) >= 4;
}

function toNonNegInt(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null;
  return Math.min(Math.floor(value), Number.MAX_SAFE_INTEGER);
}
