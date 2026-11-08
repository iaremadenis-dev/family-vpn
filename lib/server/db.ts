import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const globalForDb = globalThis as unknown as { familyVpnDb?: DatabaseSync };

export function dataDirectory(): string {
  const configured = process.env.FAMILY_VPN_DATA_DIR?.trim();
  if (configured) return path.resolve(configured);
  return path.join(process.cwd(), "data");
}

export function getDb(): DatabaseSync {
  if (globalForDb.familyVpnDb) return globalForDb.familyVpnDb;

  const directory = dataDirectory();
  mkdirSync(directory, { recursive: true });
  const db = new DatabaseSync(path.join(directory, "family-vpn.sqlite"));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
  `);
  migrate(db);
  globalForDb.familyVpnDb = db;
  return db;
}

function migrate(db: DatabaseSync) {
  const row = db.prepare("PRAGMA user_version").get();
  const version = Number(row?.user_version ?? 0);
  if (version >= 1) return;

  db.exec(`
    BEGIN IMMEDIATE;
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
      updated_at TEXT NOT NULL
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
    PRAGMA user_version = 1;
    COMMIT;
  `);
}
