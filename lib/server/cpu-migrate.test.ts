import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { describe, test } from "node:test";
import { SCHEMA_VERSION, getDb, resetDbForTests } from "@/lib/server/db";

const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-cpu-migrate-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

describe("cpu column migration", () => {
  test("adds cpu_percent to an existing database and keeps its rows", () => {
    resetDbForTests();
    const file = path.join(dataDir, "family-vpn.sqlite");
    rmSync(file, { force: true });
    const created = new DatabaseSync(file);
    created.exec(`
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
      INSERT INTO servers
        (id, name, location, endpoint, listen_port, is_default, created_at, updated_at, agent_version)
      VALUES
        ('srv', 'NL-01', 'Amsterdam', '203.0.113.10', 51820, 1, 't0', 't1', '0.4.0');
      PRAGMA user_version = 3;
    `);
    created.close();

    const db = getDb();
    assert.equal(userVersion(db), SCHEMA_VERSION);
    assert.equal(cpuColumns(db), 1);
    const row = db.prepare("SELECT name, agent_version, cpu_percent FROM servers WHERE id = 'srv'").get();
    assert.equal(row?.name, "NL-01");
    assert.equal(row?.agent_version, "0.4.0");
    assert.equal(row?.cpu_percent, null);

    resetDbForTests();
    const reopened = getDb();
    assert.equal(userVersion(reopened), SCHEMA_VERSION);
    assert.equal(cpuColumns(reopened), 1);
    assert.equal(reopened.prepare("SELECT name FROM servers WHERE id = 'srv'").get()?.name, "NL-01");
  });

  test("repairs a current database that lost the cpu column", () => {
    resetDbForTests();
    rmSync(path.join(dataDir, "family-vpn.sqlite"), { force: true });
    const db = getDb();
    db.exec(`
      INSERT INTO servers
        (id, name, location, endpoint, listen_port, is_default, created_at, updated_at)
      VALUES
        ('kept', 'DE-02', 'Frankfurt', '198.51.100.20', 51820, 0, 't0', 't1');
      ALTER TABLE servers DROP COLUMN cpu_percent;
      PRAGMA user_version = 4;
    `);
    resetDbForTests();
    const repaired = getDb();
    assert.equal(cpuColumns(repaired), 1);
    assert.equal(repaired.prepare("SELECT name FROM servers WHERE id = 'kept'").get()?.name, "DE-02");
    assert.equal(repaired.prepare("SELECT cpu_percent FROM servers WHERE id = 'kept'").get()?.cpu_percent, null);
  });
});

function userVersion(db: ReturnType<typeof getDb>): number {
  return Number(db.prepare("PRAGMA user_version").get()?.user_version ?? 0);
}

function cpuColumns(db: ReturnType<typeof getDb>): number {
  return Number(
    db.prepare("SELECT COUNT(*) AS count FROM pragma_table_info('servers') WHERE name = 'cpu_percent'").get()?.count ??
      0,
  );
}
