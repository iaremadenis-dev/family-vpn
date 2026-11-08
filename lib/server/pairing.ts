import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  verify,
} from "node:crypto";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";

export const PAIRING_TTL_MS = 15 * 60 * 1000;
export const HEARTBEAT_FRESH_MS = 45 * 1000;
const CLOCK_SKEW_MS = 2 * 60 * 1000;
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
  const bytes = randomBytes(20);
  const raw = Array.from(bytes, (byte) => CODE_ALPHABET[byte % 32]).join("");
  return raw.replace(/(.{5})/g, "$1-").slice(0, 23);
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
  assertAttemptAllowed("enroll", subjectHash, 8);
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
  if (typeof row.delivery_token === "string" && row.delivery_token) {
    return { status: "paired", token: row.delivery_token };
  }
  return { status: "paired" };
}

export function claimPairingCode(input: {
  name: string;
  location: string;
  code: string;
  subjectHash: string;
}): { serverId: string; name: string } {
  assertAttemptAllowed("claim", input.subjectHash, 8);
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

  const serverId = randomUUID();
  const token = randomBytes(32).toString("base64url");
  const now = new Date().toISOString();
  const count = db.prepare("SELECT COUNT(*) AS count FROM servers").get();
  const isDefault = Number(count?.count ?? 0) === 0;

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
      String(enrollment.version),
      report.interfaceUp ? 1 : 0,
    );
    db.prepare(
      `INSERT INTO agents
        (server_id, public_key, token_hash, delivery_token, version, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(serverId, String(enrollment.public_key), sha256(token), token, String(enrollment.version), now);
    db.prepare("UPDATE enrollments SET claimed_at = ?, server_id = ? WHERE id = ?").run(
      now,
      serverId,
      String(enrollment.id),
    );
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
  return { serverId, name };
}

export function heartbeatAgent(
  token: string,
  input: { version: string; report: AgentReport },
  subjectHash: string,
): { ok: true } {
  if (!token) {
    recordAttempt("heartbeat", subjectHash);
    throw new UserError("Нет учётных данных агента.", 401);
  }
  const version = assertVersion(input.version);
  const report = assertReport(input.report);
  const row = getDb()
    .prepare("SELECT server_id, revoked_at FROM agents WHERE token_hash = ?")
    .get(sha256(token));
  if (!row || row.revoked_at) {
    recordAttempt("heartbeat", subjectHash);
    throw new UserError("Доступ агента отозван.", 401);
  }

  const now = new Date().toISOString();
  const db = getDb();
  db.prepare(
    `UPDATE servers
     SET endpoint = ?, listen_port = ?, wg_public_key = ?, vpn_subnet = ?,
         external_interface = ?, agent_version = ?, last_seen_at = ?, wg_up = ?, updated_at = ?
     WHERE id = ?`,
  ).run(
    report.endpoint,
    report.listenPort,
    report.publicKey || null,
    report.subnet || null,
    report.externalInterface || null,
    version,
    now,
    report.interfaceUp ? 1 : 0,
    now,
    String(row.server_id),
  );
  db.prepare(
    "UPDATE agents SET version = ?, delivery_token = NULL WHERE server_id = ?",
  ).run(version, String(row.server_id));
  return { ok: true };
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

