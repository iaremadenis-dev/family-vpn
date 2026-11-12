import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  verify,
} from "node:crypto";
import {
  applyJobResults,
  applyPeerStats,
  takeJobsForServer,
  type AgentJobResult,
  type PeerStatInput,
} from "@/lib/server/agent-jobs";
import { requestBackup } from "@/lib/server/backup-request";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";
import { decryptSecret, encryptSecret } from "@/lib/server/secret";
import type { ClaimedServerSummary } from "@/lib/types";

export const PAIRING_TTL_MS = 15 * 60 * 1000;
export const HEARTBEAT_FRESH_MS = 45 * 1000;
const CLOCK_SKEW_MS = 2 * 60 * 1000;
const NONCE_TTL_MS = 10 * 60 * 1000;
/** Failed auth / abuse caps. Successful heartbeats are never counted. */
const LIMIT_ENROLL_FAIL = 8;
const LIMIT_ENROLL_OK = 20;
const LIMIT_POLL_FAIL = 60;
const LIMIT_CLAIM_FAIL = 8;
const LIMIT_HEARTBEAT_FAIL = 30;
const LEGACY_TOKEN = /^[A-Za-z0-9_-]{20,128}$/;
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const HOST =
  /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}|[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$/;
const WG_KEY = /^[A-Za-z0-9+/]{42,44}={0,2}$/;
const VERSION = /^\d+\.\d+\.\d+$/;
const IFACE = /^[A-Za-z0-9_.:-]{1,15}$/;
const CIDR =
  /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})\/(?:[1-9]|[12]\d|3[0-2])$/;

export type AgentReport = {
  endpoint: string;
  listenPort: number;
  publicKey: string;
  subnet: string;
  interfaceName: string;
  interfaceUp: boolean;
  externalInterface: string;
  existingConfig: boolean;
};

export type LinkFacts = {
  paired: boolean;
  revoked: boolean;
  lastSeenAt: string | null;
  wgUp: boolean | null;
};

export function generatePairingCode(): string {
  // 20 symbols from a 32-char alphabet ≈ 100 bits. Rejection sampling keeps the map unbiased.
  const raw = Array.from({ length: 20 }, () => {
    for (;;) {
      const byte = randomBytes(1)[0]!;
      if (byte >= 256 - (256 % CODE_ALPHABET.length)) continue;
      return CODE_ALPHABET[byte % CODE_ALPHABET.length]!;
    }
  }).join("");
  return raw.replace(/(.{5})/g, "$1-").slice(0, 23);
}

export function pairingCodeEntropyBits(code: string): number {
  const normalized = code.toUpperCase().replace(/[\s-]/g, "");
  if (normalized.length === 0) return 0;
  return normalized.length * Math.log2(CODE_ALPHABET.length);
}

export function deriveLinkStatus(facts: LinkFacts, now = Date.now()): "unchecked" | "online" | "degraded" | "offline" {
  if (!facts.paired) return "unchecked";
  if (facts.revoked) return "offline";
  if (!facts.lastSeenAt) return "unchecked";
  const seen = Date.parse(facts.lastSeenAt);
  if (!Number.isFinite(seen) || now - seen > HEARTBEAT_FRESH_MS) return "offline";
  return facts.wgUp ? "online" : "degraded";
}

export function enrollAgent(
  input: {
    code: string;
    publicKey: string;
    version: string;
    timestamp: number;
    signature: string;
    report: AgentReport;
  },
  subjectHash: string,
): { enrollmentId: string; nonce: string } {
  assertAttemptAllowed("enroll", subjectHash, LIMIT_ENROLL_FAIL);
  const code = normalizeCode(input.code);
  const publicKey = assertAgentKey(input.publicKey);
  const version = assertVersion(input.version);
  assertTimestamp(input.timestamp);
  const report = assertReport(input.report);
  const message = `family-vpn/v1 enroll\n${publicKey}\n${input.timestamp}`;
  if (!verifySignature(publicKey, message, input.signature)) {
    recordAttempt("enroll", subjectHash);
    throw new UserError("Подпись агента не принята.", 401);
  }

  const hash = sha256(code);
  const db = getDb();
  const existing = db
    .prepare(
      "SELECT id, public_key, nonce, expires_at, claimed_at FROM enrollments WHERE code_hash = ?",
    )
    .get(hash);
  const now = new Date();
  if (existing) {
    if (String(existing.public_key) !== publicKey || existing.claimed_at) {
      recordAttempt("enroll", subjectHash);
      throw new UserError("Код недействителен или срок его действия истёк.");
    }
    if (Date.parse(String(existing.expires_at)) <= now.getTime()) {
      throw new UserError("Срок кода истёк.");
    }
    return { enrollmentId: String(existing.id), nonce: String(existing.nonce) };
  }

  assertAttemptAllowed("enroll_ok", subjectHash, LIMIT_ENROLL_OK);
  const enrollmentId = randomUUID();
  const nonce = randomBytes(32).toString("base64url");
  db.prepare(
    `INSERT INTO enrollments
      (id, code_hash, public_key, nonce, version, report_json, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    enrollmentId,
    hash,
    publicKey,
    nonce,
    version,
    JSON.stringify(report),
    new Date(now.getTime() + PAIRING_TTL_MS).toISOString(),
    now.toISOString(),
  );
  recordAttempt("enroll_ok", subjectHash);
  return { enrollmentId, nonce };
}

export function pollEnrollment(
  input: {
    enrollmentId: string;
    publicKey: string;
    nonce: string;
    timestamp: number;
    signature: string;
  },
  subjectHash: string,
): { status: "pending" | "expired" | "paired"; token?: string } {
  assertAttemptAllowed("poll", subjectHash, LIMIT_POLL_FAIL);
  assertTimestamp(input.timestamp);
  const publicKey = assertAgentKey(input.publicKey);
  const message = `family-vpn/v1 poll\n${input.enrollmentId}\n${input.nonce}\n${input.timestamp}`;
  if (!verifySignature(publicKey, message, input.signature)) {
    recordAttempt("poll", subjectHash);
    throw new UserError("Подпись агента не принята.", 401);
  }

  const row = getDb()
    .prepare(
      `SELECT enrollments.public_key, enrollments.nonce, enrollments.expires_at,
              enrollments.claimed_at, enrollments.server_id, agents.delivery_token,
              agents.revoked_at
       FROM enrollments
       LEFT JOIN agents ON agents.server_id = enrollments.server_id
       WHERE enrollments.id = ?`,
    )
    .get(input.enrollmentId);
  if (!row || String(row.public_key) !== publicKey || String(row.nonce) !== input.nonce) {
    recordAttempt("poll", subjectHash);
    throw new UserError("Привязка не найдена.", 404);
  }
  if (!row.claimed_at) {
    if (Date.parse(String(row.expires_at)) <= Date.now()) return { status: "expired" };
    return { status: "pending" };
  }
  if (row.revoked_at) throw new UserError("Доступ агента отозван.", 401);
  const token = readDeliveryToken(
    typeof row.delivery_token === "string" ? row.delivery_token : null,
  );
  if (token) return { status: "paired", token };
  return { status: "paired" };
}

export type { ClaimedServerSummary };

export function claimPairingCode(input: {
  name: string;
  location: string;
  code: string;
  subjectHash: string;
}): ClaimedServerSummary {
  assertAttemptAllowed("claim", input.subjectHash, LIMIT_CLAIM_FAIL);
  const name = assertLabel(input.name, "Укажите название.", 64);
  const location = assertLabel(input.location, "Укажите расположение.", 80);
  let code = "";
  try {
    code = normalizeCode(input.code);
  } catch (cause) {
    recordAttempt("claim", input.subjectHash);
    throw cause;
  }

  const db = getDb();
  const enrollment = db
    .prepare(
      `SELECT id, report_json, expires_at, claimed_at, public_key, version
       FROM enrollments WHERE code_hash = ?`,
    )
    .get(sha256(code));
  if (!enrollment) {
    recordAttempt("claim", input.subjectHash);
    throw new UserError("Код не найден.");
  }
  if (enrollment.claimed_at) throw new UserError("Код уже использован.");
  if (Date.parse(String(enrollment.expires_at)) <= Date.now()) {
    throw new UserError("Срок кода истёк.");
  }

  const report = assertReport(JSON.parse(String(enrollment.report_json)) as AgentReport);
  const duplicate = db
    .prepare("SELECT id FROM servers WHERE endpoint = ? AND listen_port = ?")
    .get(report.endpoint, report.listenPort);
  if (duplicate) throw new UserError("Сервер с таким адресом и портом уже есть.");

  if (report.subnet) {
    const subnetConflict = db
      .prepare("SELECT name FROM servers WHERE vpn_subnet = ? LIMIT 1")
      .get(report.subnet);
    if (subnetConflict) {
      throw new UserError(
        `VPN-подсеть ${report.subnet} уже используется сервером «${String(subnetConflict.name)}». Выберите другую подсеть на новом VPS.`,
      );
    }
  }

  const serverId = randomUUID();
  const token = randomBytes(32).toString("base64url");
  const now = new Date().toISOString();
  const count = db.prepare("SELECT COUNT(*) AS count FROM servers").get();
  const isDefault = Number(count?.count ?? 0) === 0;
  const agentVersion = String(enrollment.version);
  const wgUp = Boolean(report.interfaceUp);

  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(
      `INSERT INTO servers
        (id, name, location, endpoint, listen_port, is_default, created_at, updated_at,
         wg_public_key, vpn_subnet, external_interface, agent_version, wg_up)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      serverId,
      name,
      location,
      report.endpoint,
      report.listenPort,
      isDefault ? 1 : 0,
      now,
      now,
      report.publicKey || null,
      report.subnet || null,
      report.externalInterface || null,
      agentVersion,
      wgUp ? 1 : 0,
    );
    db.prepare(
      `INSERT INTO agents
        (server_id, public_key, token_hash, delivery_token, version, created_at, last_report_json)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      serverId,
      String(enrollment.public_key),
      sha256(token),
      sealDeliveryToken(token),
      agentVersion,
      now,
      JSON.stringify(report),
    );
    db.prepare("UPDATE enrollments SET claimed_at = ?, server_id = ? WHERE id = ?").run(
      now,
      serverId,
      String(enrollment.id),
    );
    db.exec("COMMIT");
    requestBackup("agent");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }

  return {
    serverId,
    name,
    location,
    endpoint: report.endpoint,
    listenPort: report.listenPort,
    vpnSubnet: report.subnet || null,
    wgPublicKey: report.publicKey || null,
    externalInterface: report.externalInterface || null,
    agentVersion,
    wgUp,
    readyForConfigs: Boolean(report.publicKey && report.subnet && wgUp),
  };
}

export function heartbeatAgent(
  token: string,
  input: {
    version: string;
    report: AgentReport;
    peers?: unknown;
    jobResults?: unknown;
    timestamp?: number;
    nonce?: string;
    signature?: string;
  },
  subjectHash: string,
): { ok: true; jobs: ReturnType<typeof takeJobsForServer> } {
  assertAttemptAllowed("heartbeat", subjectHash, LIMIT_HEARTBEAT_FAIL);
  if (!token) {
    recordAttempt("heartbeat", subjectHash);
    throw new UserError("Нет учётных данных агента.", 401);
  }
  const version = assertVersion(input.version);
  const report = assertReport(input.report);
  const row = getDb()
    .prepare(
      "SELECT server_id, public_key, revoked_at FROM agents WHERE token_hash = ?",
    )
    .get(sha256(token));
  if (!row || row.revoked_at) {
    recordAttempt("heartbeat", subjectHash);
    throw new UserError("Доступ агента отозван.", 401);
  }

  const serverId = String(row.server_id);
  const agentPublicKey = String(row.public_key);
  const requireSignature = process.env.FAMILY_VPN_REQUIRE_HEARTBEAT_SIG === "1";
  const hasSignature =
    typeof input.signature === "string" &&
    typeof input.nonce === "string" &&
    Number.isInteger(input.timestamp);

  if (hasSignature || requireSignature) {
    if (!hasSignature) {
      recordAttempt("heartbeat", subjectHash);
      throw new UserError("Подпись heartbeat обязательна.", 401);
    }
    assertTimestamp(Number(input.timestamp));
    const nonce = assertNonce(String(input.nonce));
    const message = heartbeatMessage(agentPublicKey, Number(input.timestamp), nonce);
    if (!verifySignature(agentPublicKey, message, String(input.signature))) {
      recordAttempt("heartbeat", subjectHash);
      throw new UserError("Подпись агента не принята.", 401);
    }
    rememberNonce(serverId, nonce);
  }

  const now = new Date().toISOString();
  const db = getDb();
  const server = db
    .prepare(
      "SELECT endpoint, listen_port, wg_public_key, vpn_subnet, external_interface FROM servers WHERE id = ?",
    )
    .get(serverId);

  // Freeze identity fields after pairing (FV-002). Heartbeat only refreshes liveness.
  db.prepare(
    `UPDATE servers
     SET external_interface = ?, agent_version = ?, last_seen_at = ?, wg_up = ?, updated_at = ?
     WHERE id = ?`,
  ).run(
    report.externalInterface ||
      (server?.external_interface == null ? null : String(server.external_interface)),
    version,
    now,
    report.interfaceUp ? 1 : 0,
    now,
    serverId,
  );
  db.prepare(
    `UPDATE agents
     SET version = ?, delivery_token = NULL, last_report_json = ?
     WHERE server_id = ?`,
  ).run(version, JSON.stringify(report), serverId);

  applyJobResults(serverId, normalizeJobResults(input.jobResults));
  applyPeerStats(serverId, normalizePeerStats(input.peers));
  const jobs = takeJobsForServer(serverId);
  return { ok: true, jobs };
}

/**
 * Admin-confirmed adoption of network identity from the latest agent report.
 * Heartbeat alone never rewrites endpoint / WG public key / subnet.
 */
export function acceptAgentNetworkReport(serverId: string): AgentReport {
  const db = getDb();
  const agent = db
    .prepare("SELECT last_report_json, revoked_at FROM agents WHERE server_id = ?")
    .get(serverId);
  if (!agent || agent.revoked_at) throw new UserError("У этого сервера нет активного агента.");
  if (typeof agent.last_report_json !== "string" || !agent.last_report_json) {
    throw new UserError("Нет свежего отчёта агента для подтверждения.");
  }
  const report = assertReport(JSON.parse(String(agent.last_report_json)) as AgentReport);
  if (!report.publicKey || !report.subnet) {
    throw new UserError("Отчёт агента неполный для смены сетевых параметров.");
  }
  const duplicate = db
    .prepare(
      "SELECT id FROM servers WHERE endpoint = ? AND listen_port = ? AND id != ?",
    )
    .get(report.endpoint, report.listenPort, serverId);
  if (duplicate) throw new UserError("Сервер с таким адресом и портом уже есть.");
  const subnetConflict = db
    .prepare("SELECT name FROM servers WHERE vpn_subnet = ? AND id != ? LIMIT 1")
    .get(report.subnet, serverId);
  if (subnetConflict) {
    throw new UserError(
      `VPN-подсеть ${report.subnet} уже используется сервером «${String(subnetConflict.name)}».`,
    );
  }
  const now = new Date().toISOString();
  db.prepare(
    `UPDATE servers
     SET endpoint = ?, listen_port = ?, wg_public_key = ?, vpn_subnet = ?,
         external_interface = ?, updated_at = ?
     WHERE id = ?`,
  ).run(
    report.endpoint,
    report.listenPort,
    report.publicKey,
    report.subnet,
    report.externalInterface || null,
    now,
    serverId,
  );
  requestBackup("agent");
  return report;
}

export function heartbeatMessage(publicKey: string, timestamp: number, nonce: string): string {
  return `family-vpn/v1 heartbeat\n${publicKey}\n${timestamp}\n${nonce}`;
}

export function revokeAgent(serverId: string) {
  const row = getDb().prepare("SELECT server_id, revoked_at FROM agents WHERE server_id = ?").get(serverId);
  if (!row) throw new UserError("У этого сервера нет привязанного агента.");
  if (row.revoked_at) throw new UserError("Доступ агента уже отозван.");
  getDb()
    .prepare(
      "UPDATE agents SET revoked_at = ?, delivery_token = NULL, token_hash = ? WHERE server_id = ?",
    )
    .run(new Date().toISOString(), randomBytes(32).toString("hex"), serverId);
  requestBackup("agent");
}

function assertReport(input: AgentReport): AgentReport {
  if (!input || typeof input !== "object") throw new UserError("Отчёт агента неполный.");
  const endpoint = String(input.endpoint ?? "").trim();
  const listenPort = Number(input.listenPort);
  const publicKey = String(input.publicKey ?? "").trim();
  const subnet = String(input.subnet ?? "").trim();
  const interfaceName = String(input.interfaceName ?? "").trim();
  const externalInterface = String(input.externalInterface ?? "").trim();
  if (!HOST.test(endpoint)) throw new UserError("Адрес в отчёте агента не принят.");
  if (!Number.isInteger(listenPort) || listenPort < 1 || listenPort > 65535) {
    throw new UserError("Порт в отчёте агента не принят.");
  }
  if (input.interfaceUp && !WG_KEY.test(publicKey)) {
    throw new UserError("Публичный ключ WireGuard в отчёте не принят.");
  }
  if (!input.interfaceUp && publicKey && !WG_KEY.test(publicKey)) {
    throw new UserError("Публичный ключ WireGuard в отчёте не принят.");
  }
  if (subnet && !CIDR.test(subnet)) throw new UserError("Подсеть в отчёте агента не принята.");
  if (interfaceName && !IFACE.test(interfaceName)) {
    throw new UserError("Интерфейс в отчёте агента не принят.");
  }
  if (externalInterface && !IFACE.test(externalInterface)) {
    throw new UserError("Внешний интерфейс в отчёте агента не принят.");
  }
  return {
    endpoint,
    listenPort,
    publicKey,
    subnet,
    interfaceName,
    interfaceUp: Boolean(input.interfaceUp),
    externalInterface,
    existingConfig: Boolean(input.existingConfig),
  };
}

function assertAgentKey(value: string): string {
  const key = Buffer.from(value, "base64url");
  if (key.length !== 32) throw new UserError("Ключ агента не принят.");
  return value;
}

function assertVersion(value: string): string {
  if (!VERSION.test(value)) throw new UserError("Версия агента не принята.");
  return value;
}

function assertTimestamp(timestamp: number) {
  if (!Number.isInteger(timestamp)) throw new UserError("Время запроса не принято.");
  if (Math.abs(Date.now() - timestamp * 1000) > CLOCK_SKEW_MS) {
    throw new UserError("Время запроса отличается от панели.");
  }
}

function assertLabel(value: string, empty: string, max: number): string {
  const text = value.trim();
  if (!text) throw new UserError(empty);
  if (text.length > max) throw new UserError("Значение слишком длинное.");
  if (/[\u0000-\u001F]/.test(text)) throw new UserError("Значение содержит недопустимые символы.");
  return text;
}

function normalizeCode(value: string): string {
  const code = value.toUpperCase().replace(/[\s-]/g, "");
  if (code.length !== 20 || [...code].some((char) => !CODE_ALPHABET.includes(char))) {
    throw new UserError("Код не найден.");
  }
  if (pairingCodeEntropyBits(code) < 100) {
    throw new UserError("Код не найден.");
  }
  return code;
}

function verifySignature(publicKey: string, message: string, signature: string): boolean {
  try {
    const key = Buffer.from(publicKey, "base64url");
    const sig = Buffer.from(signature, "base64url");
    if (key.length !== 32 || sig.length !== 64) return false;
    const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), key]);
    const keyObject = createPublicKey({ key: spki, format: "der", type: "spki" });
    return verify(null, Buffer.from(message), keyObject, sig);
  } catch {
    return false;
  }
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function normalizeJobResults(input: unknown): AgentJobResult[] {
  if (!Array.isArray(input)) return [];
  const out: AgentJobResult[] = [];
  for (const item of input.slice(0, 32)) {
    if (!item || typeof item !== "object") continue;
    const row = item as { id?: unknown; ok?: unknown; error?: unknown };
    if (typeof row.id !== "string" || !row.id) continue;
    out.push({
      id: row.id,
      ok: Boolean(row.ok),
      error: typeof row.error === "string" ? row.error : undefined,
    });
  }
  return out;
}

function normalizePeerStats(input: unknown): PeerStatInput[] {
  if (!Array.isArray(input)) return [];
  const out: PeerStatInput[] = [];
  for (const item of input.slice(0, 512)) {
    if (!item || typeof item !== "object") continue;
    const row = item as {
      publicKey?: unknown;
      allowedIps?: unknown;
      rxBytes?: unknown;
      txBytes?: unknown;
      lastHandshake?: unknown;
    };
    if (typeof row.publicKey !== "string" || !WG_KEY.test(row.publicKey.trim())) continue;
    out.push({
      publicKey: row.publicKey.trim(),
      allowedIps: typeof row.allowedIps === "string" ? row.allowedIps : undefined,
      rxBytes: typeof row.rxBytes === "number" ? row.rxBytes : undefined,
      txBytes: typeof row.txBytes === "number" ? row.txBytes : undefined,
      lastHandshake: typeof row.lastHandshake === "number" ? row.lastHandshake : undefined,
    });
  }
  return out;
}

function assertAttemptAllowed(scope: string, subjectHash: string, limit: number) {
  const since = new Date(Date.now() - PAIRING_TTL_MS).toISOString();
  getDb().prepare("DELETE FROM agent_attempts WHERE created_at < ?").run(since);
  const row = getDb()
    .prepare(
      "SELECT COUNT(*) AS count FROM agent_attempts WHERE scope = ? AND subject_hash = ? AND created_at >= ?",
    )
    .get(scope, subjectHash, since);
  if (Number(row?.count ?? 0) >= limit) {
    throw new UserError("Слишком много попыток. Повторите через несколько минут.", 429);
  }
}

function recordAttempt(scope: string, subjectHash: string) {
  getDb()
    .prepare("INSERT INTO agent_attempts (scope, subject_hash, created_at) VALUES (?, ?, ?)")
    .run(scope, subjectHash, new Date().toISOString());
}

function sealDeliveryToken(token: string): string {
  return encryptSecret(token);
}

function readDeliveryToken(stored: string | null): string | null {
  if (!stored) return null;
  try {
    return decryptSecret(stored);
  } catch {
    // Pre-migration rows may still hold a short-lived plaintext token.
    if (LEGACY_TOKEN.test(stored)) return stored;
    return null;
  }
}

function assertNonce(value: string): string {
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new UserError("Nonce heartbeat не принят.");
  }
  return value;
}

function rememberNonce(serverId: string, nonce: string) {
  const db = getDb();
  const cutoff = new Date(Date.now() - NONCE_TTL_MS).toISOString();
  db.prepare("DELETE FROM agent_nonces WHERE created_at < ?").run(cutoff);
  const existing = db
    .prepare("SELECT 1 AS ok FROM agent_nonces WHERE server_id = ? AND nonce = ?")
    .get(serverId, nonce);
  if (existing) {
    throw new UserError("Повтор heartbeat отклонён.", 401);
  }
  db.prepare(
    "INSERT INTO agent_nonces (server_id, nonce, created_at) VALUES (?, ?, ?)",
  ).run(serverId, nonce, new Date().toISOString());
}

