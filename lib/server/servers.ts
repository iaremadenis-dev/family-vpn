import { randomUUID } from "node:crypto";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";
import { requireAdmin } from "@/lib/server/guard";
import { deriveLinkStatus } from "@/lib/server/pairing";
import type { ServerInput, ServerRecord } from "@/lib/types";

const HOST =
  /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}|[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$/;

export async function listServers(): Promise<ServerRecord[]> {
  await requireAdmin();
  const rows = getDb()
    .prepare(
      `SELECT servers.*, agents.server_id AS agent_server_id, agents.revoked_at AS agent_revoked_at
       FROM servers
       LEFT JOIN agents ON agents.server_id = servers.id
       ORDER BY servers.is_default DESC, servers.name COLLATE NOCASE ASC`,
    )
    .all();
  return rows.map(mapServer);
}

export async function getServer(id: string): Promise<ServerRecord | null> {
  await requireAdmin();
  assertId(id);
  const row = getDb()
    .prepare(
      `SELECT servers.*, agents.server_id AS agent_server_id, agents.revoked_at AS agent_revoked_at
       FROM servers
       LEFT JOIN agents ON agents.server_id = servers.id
       WHERE servers.id = ?`,
    )
    .get(id);
  return row ? mapServer(row) : null;
}

export async function createServer(input: ServerInput): Promise<ServerRecord> {
  await requireAdmin();
  const value = validateServer(input);
  const db = getDb();
  const existing = db
    .prepare("SELECT id FROM servers WHERE endpoint = ? AND listen_port = ?")
    .get(value.endpoint, value.listenPort);
  if (existing) throw new UserError("Сервер с таким адресом и портом уже есть.");

  const count = db.prepare("SELECT COUNT(*) AS count FROM servers").get();
  const isDefault = Number(count?.count ?? 0) === 0;
  const now = new Date().toISOString();
  const record: ServerRecord = {
    id: randomUUID(),
    ...value,
    isDefault,
    createdAt: now,
    updatedAt: now,
    linkStatus: "unchecked",
    paired: false,
    agentRevoked: false,
    agentVersion: null,
    lastSeenAt: null,
    wgPublicKey: null,
    vpnSubnet: null,
    externalInterface: null,
  };

  db.prepare(
    `INSERT INTO servers
      (id, name, location, endpoint, listen_port, is_default, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    record.id,
    record.name,
    record.location,
    record.endpoint,
    record.listenPort,
    record.isDefault ? 1 : 0,
    record.createdAt,
    record.updatedAt,
  );
  return record;
}

export async function updateServer(id: string, input: { name: string; location: string }) {
  await requireAdmin();
  assertId(id);
  const name = input.name.trim();
  const location = input.location.trim();
  if (!name) throw new UserError("Укажите название.");
  if (name.length > 64) throw new UserError("Название длиннее 64 символов.");
  if (/[\u0000-\u001F]/.test(name)) throw new UserError("Название содержит недопустимые символы.");
  if (!location) throw new UserError("Укажите расположение.");
  if (location.length > 80) throw new UserError("Расположение длиннее 80 символов.");
  if (/[\u0000-\u001F]/.test(location)) {
    throw new UserError("Расположение содержит недопустимые символы.");
  }
  const current = getDb().prepare("SELECT id FROM servers WHERE id = ?").get(id);
  if (!current) throw new UserError("Сервер не найден.");
  getDb()
    .prepare("UPDATE servers SET name = ?, location = ?, updated_at = ? WHERE id = ?")
    .run(name, location, new Date().toISOString(), id);
}

export async function deleteServer(id: string) {
  await requireAdmin();
  assertId(id);
  const db = getDb();
  const current = db.prepare("SELECT is_default FROM servers WHERE id = ?").get(id);
  if (!current) throw new UserError("Сервер не найден.");
  const configs = db.prepare("SELECT COUNT(*) AS count FROM configs WHERE server_id = ?").get(id);
  if (Number(configs?.count ?? 0) > 0) {
    throw new UserError("Сначала удалите конфигурации этого сервера.");
  }

  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM agent_jobs WHERE server_id = ?").run(id);
    db.prepare("DELETE FROM enrollments WHERE server_id = ?").run(id);
    db.prepare("DELETE FROM agents WHERE server_id = ?").run(id);
    db.prepare("DELETE FROM servers WHERE id = ?").run(id);
    if (Number(current.is_default) === 1) {
      const next = db
        .prepare("SELECT id FROM servers ORDER BY created_at ASC LIMIT 1")
        .get();
      if (next) {
        db.prepare("UPDATE servers SET is_default = 1, updated_at = ? WHERE id = ?").run(
          new Date().toISOString(),
          String(next.id),
        );
      }
    }
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

export async function setDefaultServer(id: string) {
  await requireAdmin();
  assertId(id);
  const db = getDb();
  const current = db.prepare("SELECT id FROM servers WHERE id = ?").get(id);
  if (!current) throw new UserError("Сервер не найден.");
  const now = new Date().toISOString();

  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("UPDATE servers SET is_default = 0").run();
    db.prepare("UPDATE servers SET is_default = 1, updated_at = ? WHERE id = ?").run(now, id);
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

export function validateServer(input: ServerInput): ServerInput {
  const name = input.name.trim();
  const location = input.location.trim();
  const endpoint = input.endpoint.trim();
  if (!name) throw new UserError("Укажите название.");
  if (name.length > 64) throw new UserError("Название длиннее 64 символов.");
  if (/[\u0000-\u001F]/.test(name)) throw new UserError("Название содержит недопустимые символы.");
  if (!location) throw new UserError("Укажите расположение.");
  if (location.length > 80) throw new UserError("Расположение длиннее 80 символов.");
  if (/[\u0000-\u001F]/.test(location)) {
    throw new UserError("Расположение содержит недопустимые символы.");
  }
  if (!endpoint || endpoint.length > 253 || !HOST.test(endpoint)) {
    throw new UserError("Укажите IPv4-адрес или доменное имя без схемы и порта.");
  }
  if (!Number.isInteger(input.listenPort) || input.listenPort < 1 || input.listenPort > 65535) {
    throw new UserError("Порт должен быть целым числом от 1 до 65535.");
  }
  return { name, location, endpoint, listenPort: input.listenPort };
}

function assertId(id: string) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    throw new UserError("Сервер не найден.");
  }
}

function mapServer(row: Record<string, string | number | bigint | null | Uint8Array>): ServerRecord {
  const paired = row.agent_server_id !== null && row.agent_server_id !== undefined;
  const revoked = paired && row.agent_revoked_at !== null && row.agent_revoked_at !== undefined;
  const lastSeenAt = row.last_seen_at === null || row.last_seen_at === undefined ? null : String(row.last_seen_at);
  return {
    id: String(row.id),
    name: String(row.name),
    location: String(row.location),
    endpoint: String(row.endpoint),
    listenPort: Number(row.listen_port),
    isDefault: Number(row.is_default) === 1,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
    paired,
    agentRevoked: revoked,
    agentVersion: row.agent_version === null || row.agent_version === undefined ? null : String(row.agent_version),
    lastSeenAt,
    wgPublicKey: row.wg_public_key === null || row.wg_public_key === undefined ? null : String(row.wg_public_key),
    vpnSubnet: row.vpn_subnet === null || row.vpn_subnet === undefined ? null : String(row.vpn_subnet),
    externalInterface:
      row.external_interface === null || row.external_interface === undefined
        ? null
        : String(row.external_interface),
    linkStatus: deriveLinkStatus({
      paired,
      revoked,
      lastSeenAt,
      wgUp: row.wg_up === null || row.wg_up === undefined ? null : Number(row.wg_up) === 1,
    }),
  };
}
