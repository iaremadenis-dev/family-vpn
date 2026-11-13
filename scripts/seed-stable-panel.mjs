#!/usr/bin/env node
/**
 * Seeds a schema-3 panel database for the update integration test.
 * Does not talk to a VPS. Passwords and tokens are test-only.
 */
import { createCipheriv, createHash, randomBytes, scryptSync } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const dataDir = process.argv[2];
const password = process.argv[3] ?? "correct-horse-battery";
const agentToken = process.argv[4] ?? "test-agent-token-0001";
if (!dataDir) {
  console.error("usage: seed-stable-panel.mjs <data-dir> [password] [agent-token]");
  process.exit(2);
}

mkdirSync(dataDir, { recursive: true });
const master = randomBytes(32);
writeFileSync(path.join(dataDir, "master.key"), master, { mode: 0o600 });

const salt = randomBytes(16);
const hash = scryptSync(password, salt, 32, {
  N: 16384,
  r: 8,
  p: 1,
  maxmem: 64 * 1024 * 1024,
});
const passwordHash = [
  "scrypt",
  16384,
  8,
  1,
  salt.toString("base64url"),
  hash.toString("base64url"),
].join("$");

const iv = randomBytes(12);
const cipher = createCipheriv("aes-256-gcm", master, iv);
const encrypted = Buffer.concat([cipher.update("client-private-key-test", "utf8"), cipher.final()]);
const secret = Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString("base64");

const file = path.join(dataDir, "family-vpn.sqlite");
const db = new DatabaseSync(file);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE admin (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    display_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE servers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    location TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    listen_port INTEGER NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    wg_public_key TEXT,
    vpn_subnet TEXT,
    external_interface TEXT,
    agent_version TEXT,
    last_seen_at TEXT,
    wg_up INTEGER,
    used_vpn_ips_json TEXT
  );
  CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    target TEXT,
    created_at TEXT NOT NULL
  );
  CREATE TABLE login_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE enrollments (
    id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    public_key TEXT NOT NULL,
    nonce TEXT NOT NULL,
    version TEXT NOT NULL,
    report_json TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    claimed_at TEXT,
    server_id TEXT,
    created_at TEXT NOT NULL
  );
  CREATE TABLE agents (
    server_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    delivery_token TEXT,
    version TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL
  );
  CREATE TABLE agent_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope TEXT NOT NULL,
    subject_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE configs (
    id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    device_name TEXT NOT NULL,
    client_public_key TEXT NOT NULL UNIQUE,
    client_private_key_enc TEXT NOT NULL,
    vpn_ip TEXT NOT NULL,
    status TEXT NOT NULL,
    last_error TEXT,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    last_handshake_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revoked_at TEXT,
    UNIQUE (server_id, vpn_ip)
  );
  CREATE TABLE agent_jobs (
    id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    config_id TEXT,
    type TEXT NOT NULL,
    public_key TEXT NOT NULL,
    allowed_ips TEXT,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT
  );
`);

const now = new Date().toISOString();
db.prepare(
  "INSERT INTO admin (id, display_name, password_hash, created_at) VALUES (1, ?, ?, ?)",
).run("Ada", passwordHash, now);
db.prepare(
  `INSERT INTO servers
    (id, name, location, endpoint, listen_port, is_default, created_at, updated_at,
     wg_public_key, vpn_subnet, external_interface, agent_version, last_seen_at, wg_up, used_vpn_ips_json)
   VALUES (?, 'NL-01', 'Amsterdam', '203.0.113.10', 51820, 1, ?, ?,
     ?, '10.200.0.0/24', 'eth0', '0.4.0', ?, 1, ?)`,
).run("nl-test", now, now, `${"A".repeat(43)}=`, now, JSON.stringify(["10.200.0.2"]));
db.prepare(
  `INSERT INTO agents (server_id, public_key, token_hash, delivery_token, version, created_at)
   VALUES (?, ?, ?, NULL, '0.4.0', ?)`,
).run("nl-test", `${"C".repeat(43)}=`, sha256(agentToken), now);
db.prepare(
  `INSERT INTO configs
    (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip,
     status, rx_bytes, tx_bytes, last_handshake_at, created_at, updated_at)
   VALUES ('cfg-test', 'nl-test', 'phone', ?, ?, '10.200.0.2',
     'active', 1000, 2000, ?, ?, ?)`,
).run(`${"B".repeat(43)}=`, secret, now, now, now);
db.prepare("INSERT INTO audit_log (action, target, created_at) VALUES ('pair', 'nl-test', ?)").run(now);
db.exec("PRAGMA user_version = 3");
db.close();

writeFileSync(
  path.join(dataDir, "seed.json"),
  `${JSON.stringify(
    {
      displayName: "Ada",
      password,
      agentToken,
      masterSha256: sha256(master),
      schema: 3,
    },
    null,
    2,
  )}\n`,
  { mode: 0o600 },
);
console.log("SEED_OK");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
