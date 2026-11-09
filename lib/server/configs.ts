import { randomUUID } from "node:crypto";
import { applyJobResults, assertOnlineAgent, enqueueJob } from "@/lib/server/agent-jobs";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";
import { requireAdmin } from "@/lib/server/guard";
import { decryptSecret, encryptSecret } from "@/lib/server/secret";
import { readSession } from "@/lib/server/session";
import {
  allocateVpnIp,
  assertWireGuardKey,
  buildClientConfig,
  collectUsedIps,
  generateWireGuardKeyPair,
  hostAllowedIps,
  parseUsedIpsJson,
} from "@/lib/server/wireguard";
import type { ConfigRecord, ConfigStatus } from "@/lib/types";

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function listConfigs(): Promise<ConfigRecord[]> {
  await requireAdmin();
  const rows = getDb()
    .prepare(
      `SELECT configs.*, servers.name AS server_name, servers.endpoint AS server_endpoint,
              servers.listen_port AS server_listen_port
       FROM configs
       INNER JOIN servers ON servers.id = configs.server_id
       ORDER BY configs.created_at DESC`,
    )
    .all();
  return rows.map(mapConfig);
}

export async function countConfigs(): Promise<number> {
  await requireAdmin();
  const row = getDb().prepare("SELECT COUNT(*) AS count FROM configs").get();
  return Number(row?.count ?? 0);
}

export async function createConfig(input: {
  deviceName: string;
  serverId: string;
}): Promise<ConfigRecord> {
  await requireAdmin();
  const deviceName = assertDeviceName(input.deviceName);
  assertId(input.serverId);
  assertOnlineAgent(input.serverId);

  const server = getDb()
    .prepare(
      `SELECT id, endpoint, listen_port, wg_public_key, vpn_subnet, used_vpn_ips_json
       FROM servers WHERE id = ?`,
    )
    .get(input.serverId);
  if (!server) throw new UserError("Сервер не найден.");
  if (!server.wg_public_key) throw new UserError("У сервера ещё нет публичного ключа WireGuard.");
  if (!server.vpn_subnet) throw new UserError("У сервера ещё нет VPN-подсети.");

  const keys = generateWireGuardKeyPair();
  const publicKey = assertWireGuardKey(keys.publicKey);
  const privateKeyEnc = encryptSecret(keys.privateKey);

  const db = getDb();
  const id = randomUUID();
  const now = new Date().toISOString();
  let vpnIp = "";

  db.exec("BEGIN IMMEDIATE");
  try {
    const takenRows = db
      .prepare("SELECT vpn_ip FROM configs WHERE server_id = ?")
      .all(input.serverId);
    const used = collectUsedIps([
      ...takenRows.map((row) => String(row.vpn_ip)),
      ...parseUsedIpsJson(
        server.used_vpn_ips_json == null ? null : String(server.used_vpn_ips_json),
      ),
    ]);
    vpnIp = allocateVpnIp(String(server.vpn_subnet), used);
    const allowedIps = hostAllowedIps(vpnIp);

    db.prepare(
      `INSERT INTO configs
        (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip,
         status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
    ).run(id, input.serverId, deviceName, publicKey, privateKeyEnc, vpnIp, now, now);

    enqueueJob({
      serverId: input.serverId,
      configId: id,
      type: "add_peer",
      publicKey,
      allowedIps,
    });
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    if (isUniqueViolation(cause)) {
      throw new UserError("Этот VPN-IP уже занят. Повторите создание.");
    }
    throw cause;
  }

  const created = await getConfig(id);
  if (!created) throw new UserError("Конфигурация не создана.");
  return created;
}

export async function revokeConfig(id: string): Promise<void> {
  await requireAdmin();
  assertId(id);
  const db = getDb();
  const row = db
    .prepare(
      `SELECT id, server_id, client_public_key, status
       FROM configs WHERE id = ?`,
    )
    .get(id);
  if (!row) throw new UserError("Конфигурация не найдена.");
  if (row.status === "revoked") throw new UserError("Конфигурация уже отозвана.");
  if (row.status === "revoking") throw new UserError("Отзыв уже выполняется.");

  assertOnlineAgent(String(row.server_id));
  const now = new Date().toISOString();

  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(
      `UPDATE configs SET status = 'revoking', updated_at = ?, last_error = NULL WHERE id = ?`,
    ).run(now, id);
    enqueueJob({
      serverId: String(row.server_id),
      configId: id,
      type: "remove_peer",
      publicKey: String(row.client_public_key),
    });
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

export async function deleteConfig(id: string): Promise<void> {
  await requireAdmin();
  assertId(id);
  const db = getDb();
  const row = db
    .prepare(`SELECT id, server_id, client_public_key, status FROM configs WHERE id = ?`)
    .get(id);
  if (!row) throw new UserError("Конфигурация не найдена.");

  const status = String(row.status);
  if (status === "revoking") {
    throw new UserError("Дождитесь завершения отзыва peer на сервере, затем удалите запись.");
  }
  if (status === "active" || status === "pending" || status === "error") {
    // Keep SQLite and WireGuard aligned: revoke on the VPS before deleting the row.
    assertOnlineAgent(String(row.server_id));
    const now = new Date().toISOString();
    db.exec("BEGIN IMMEDIATE");
    try {
      db.prepare(
        `UPDATE configs SET status = 'revoking', updated_at = ?, last_error = NULL WHERE id = ?`,
      ).run(now, id);
      enqueueJob({
        serverId: String(row.server_id),
        configId: id,
        type: "remove_peer",
        publicKey: String(row.client_public_key),
      });
      db.exec("COMMIT");
    } catch (cause) {
      db.exec("ROLLBACK");
      throw cause;
    }
    throw new UserError(
      "Сначала отзывается peer на сервере. После статуса «Отозвана» удалите запись ещё раз.",
    );
  }

  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM agent_jobs WHERE config_id = ?").run(id);
    db.prepare("DELETE FROM configs WHERE id = ?").run(id);
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

export async function getConfigDownload(id: string): Promise<{
  fileName: string;
  content: string;
}> {
  const session = await readSession();
  if (!session) throw new UserError("Требуется вход.", 401);
  assertId(id);
  const row = getDb()
    .prepare(
      `SELECT configs.*, servers.name AS server_name, servers.endpoint, servers.listen_port,
              servers.wg_public_key
       FROM configs
       INNER JOIN servers ON servers.id = configs.server_id
       WHERE configs.id = ?`,
    )
    .get(id);
  if (!row) throw new UserError("Конфигурация не найдена.");
  if (row.status === "revoked" || row.status === "revoking") {
    throw new UserError("Отозванную конфигурацию скачать нельзя.");
  }
  if (!row.client_private_key_enc) {
    throw new UserError("Приватный ключ этой конфигурации недоступен.");
  }
  if (!row.wg_public_key) throw new UserError("У сервера нет публичного ключа.");

  let privateKey = "";
  try {
    privateKey = decryptSecret(String(row.client_private_key_enc));
  } catch {
    throw new UserError("Не удалось расшифровать приватный ключ.");
  }

  const content = buildClientConfig({
    privateKey,
    address: String(row.vpn_ip),
    serverPublicKey: String(row.wg_public_key),
    endpoint: String(row.endpoint),
    listenPort: Number(row.listen_port),
  });
  const safeName = String(row.device_name)
    .replace(/[^\w.-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  return {
    fileName: `${safeName || "device"}.conf`,
    content,
  };
}

export async function getConfig(id: string): Promise<ConfigRecord | null> {
  await requireAdmin();
  assertId(id);
  const row = getDb()
    .prepare(
      `SELECT configs.*, servers.name AS server_name, servers.endpoint AS server_endpoint,
              servers.listen_port AS server_listen_port
       FROM configs
       INNER JOIN servers ON servers.id = configs.server_id
       WHERE configs.id = ?`,
    )
    .get(id);
  return row ? mapConfig(row) : null;
}

/** Test helper: mark a job result as if the agent responded. */
export function completeJobForTests(result: { id: string; ok: boolean; error?: string }) {
  const row = getDb().prepare("SELECT server_id FROM agent_jobs WHERE id = ?").get(result.id);
  if (!row) throw new UserError("Задание не найдено.");
  applyJobResults(String(row.server_id), [result]);
}

function mapConfig(row: Record<string, string | number | bigint | null | Uint8Array>): ConfigRecord {
  return {
    id: String(row.id),
    serverId: String(row.server_id),
    serverName: String(row.server_name),
    deviceName: String(row.device_name),
    vpnIp: String(row.vpn_ip),
    status: String(row.status) as ConfigStatus,
    lastError: row.last_error == null ? null : String(row.last_error),
    rxBytes: row.rx_bytes == null ? null : Number(row.rx_bytes),
    txBytes: row.tx_bytes == null ? null : Number(row.tx_bytes),
    lastHandshakeAt: row.last_handshake_at == null ? null : String(row.last_handshake_at),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
    revokedAt: row.revoked_at == null ? null : String(row.revoked_at),
    clientPublicKey: String(row.client_public_key),
    endpoint: `${String(row.server_endpoint)}:${Number(row.server_listen_port)}`,
  };
}

function assertDeviceName(value: string): string {
  const text = value.trim();
  if (!text) throw new UserError("Укажите название устройства.");
  if (text.length > 64) throw new UserError("Название длиннее 64 символов.");
  if (/[\u0000-\u001F]/.test(text)) throw new UserError("Название содержит недопустимые символы.");
  return text;
}

function assertId(id: string) {
  if (!UUID.test(id)) throw new UserError("Конфигурация не найдена.");
}

function isUniqueViolation(cause: unknown): boolean {
  return cause instanceof Error && /UNIQUE/i.test(cause.message);
}
