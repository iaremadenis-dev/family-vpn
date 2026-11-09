import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const globalForDb = globalThis as unknown as { familyVpnDb?: DatabaseSync };
const migrated = new WeakSet<DatabaseSync>();

export function dataDirectory(): string {
  const configured = process.env.FAMILY_VPN_DATA_DIR?.trim();
  if (configured) return path.resolve(configured);
  return path.join(process.cwd(), "data");
}

export function getDb(): DatabaseSync {
  if (!globalForDb.familyVpnDb) {
    const directory = dataDirectory();
    mkdirSync(directory, { recursive: true });
    const db = new DatabaseSync(path.join(directory, "family-vpn.sqlite"));
    db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA busy_timeout = 5000;
    `);
    globalForDb.familyVpnDb = db;
  }
  if (!migrated.has(globalForDb.familyVpnDb)) {
    migrate(globalForDb.familyVpnDb);
    migrated.add(globalForDb.familyVpnDb);
  }
  return globalForDb.familyVpnDb;
}

export function resetDbForTests() {
  const db = globalForDb.familyVpnDb;
  globalForDb.familyVpnDb = undefined;
  db?.close();
}

function migrate(db: DatabaseSync) {
  const row = db.prepare("PRAGMA user_version").get();
  const version = Number(row?.user_version ?? 0);
  if (version >= 3) {
    ensureAgentTables(db);
    ensureConfigTables(db);
    return;
  }

  db.exec("BEGIN IMMEDIATE");
  try {
    if (version < 1) {
      db.exec(baseSchema);
    } else if (version === 1) {
      db.exec(upgradeFromV1);
    }
    if (version < 2) {
      db.exec(agentSchema);
    }
    if (version < 3) {
      db.exec(configSchema);
      db.exec(upgradeServersForConfigs);
    }
    db.exec("PRAGMA user_version = 3");
    db.exec("COMMIT");
  } catch (cause) {
    db.exec("ROLLBACK");
    throw cause;
  }
}

function ensureAgentTables(db: DatabaseSync) {
  const agents = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'agents'")
    .get();
  if (!agents) db.exec(agentSchema);
}

function ensureConfigTables(db: DatabaseSync) {
  const configs = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'configs'")
    .get();
  if (!configs) db.exec(configSchema);
  const column = db
    .prepare("SELECT 1 AS ok FROM pragma_table_info('servers') WHERE name = 'used_vpn_ips_json'")
    .get();
  if (!column) db.exec(upgradeServersForConfigs);
}

const baseSchema = `
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
      is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      wg_public_key TEXT,
      vpn_subnet TEXT,
      external_interface TEXT,
      agent_version TEXT,
      last_seen_at TEXT,
      wg_up INTEGER
    );
    CREATE UNIQUE INDEX servers_endpoint_port ON servers (endpoint, listen_port);
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
`;

const upgradeFromV1 = `
    ALTER TABLE servers ADD COLUMN wg_public_key TEXT;
    ALTER TABLE servers ADD COLUMN vpn_subnet TEXT;
    ALTER TABLE servers ADD COLUMN external_interface TEXT;
    ALTER TABLE servers ADD COLUMN agent_version TEXT;
    ALTER TABLE servers ADD COLUMN last_seen_at TEXT;
    ALTER TABLE servers ADD COLUMN wg_up INTEGER;
`;

const agentSchema = `
    CREATE TABLE IF NOT EXISTS enrollments (
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
    CREATE TABLE IF NOT EXISTS agents (
      server_id TEXT PRIMARY KEY,
      public_key TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      delivery_token TEXT,
      version TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS agent_attempts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      scope TEXT NOT NULL,
      subject_hash TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
`;

const upgradeServersForConfigs = `
    ALTER TABLE servers ADD COLUMN used_vpn_ips_json TEXT;
`;

const configSchema = `
    CREATE TABLE IF NOT EXISTS configs (
      id TEXT PRIMARY KEY,
      server_id TEXT NOT NULL,
      device_name TEXT NOT NULL,
      client_public_key TEXT NOT NULL UNIQUE,
      client_private_key_enc TEXT NOT NULL,
      vpn_ip TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'revoking', 'revoked', 'error')),
      last_error TEXT,
      rx_bytes INTEGER,
      tx_bytes INTEGER,
      last_handshake_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      revoked_at TEXT,
      FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE RESTRICT,
      UNIQUE (server_id, vpn_ip)
    );
    CREATE INDEX IF NOT EXISTS configs_server_id ON configs (server_id);
    CREATE TABLE IF NOT EXISTS agent_jobs (
      id TEXT PRIMARY KEY,
      server_id TEXT NOT NULL,
      config_id TEXT,
      type TEXT NOT NULL CHECK (type IN ('add_peer', 'remove_peer')),
      public_key TEXT NOT NULL,
      allowed_ips TEXT,
      status TEXT NOT NULL CHECK (status IN ('queued', 'delivered', 'succeeded', 'failed')),
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE CASCADE,
      FOREIGN KEY (config_id) REFERENCES configs(id) ON DELETE SET NULL
    );
    CREATE INDEX IF NOT EXISTS agent_jobs_server_status ON agent_jobs (server_id, status, created_at);
`;
