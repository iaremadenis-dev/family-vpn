import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { describe, test } from "node:test";
import { SCHEMA_VERSION, getDb, resetDbForTests } from "@/lib/server/db";

const STABLE_PANEL = "d587d590518d";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-schema-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

describe("panel schema 3 and 4", () => {
  test("migration keeps accounts, keys, and sessions, and the stable panel still opens schema 4", () => {
    const master = randomBytes(32);
    const masterFile = path.join(dataDir, "master.key");
    writeFileSync(masterFile, master);
    const masterHash = sha256(masterFile);
    const secret = seal(master, "client-private-key");
    const file = path.join(dataDir, "family-vpn.sqlite");
    const created = new DatabaseSync(file);
    created.exec(`
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
      CREATE TABLE agents (
        server_id TEXT PRIMARY KEY,
        public_key TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        delivery_token TEXT,
        version TEXT,
        revoked_at TEXT,
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
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      INSERT INTO admin (id, display_name, password_hash, created_at)
        VALUES (1, 'Ada', 'scrypt$kept-password-hash', 't0');
      INSERT INTO sessions (token_hash, expires_at, created_at)
        VALUES ('session-hash', '2999-01-01T00:00:00.000Z', 't0');
      INSERT INTO servers
        (id, name, location, endpoint, listen_port, is_default, created_at, updated_at,
         wg_public_key, vpn_subnet, agent_version, used_vpn_ips_json)
        VALUES
        ('nl', 'NL-01', 'Amsterdam', '203.0.113.10', 51820, 1, 't0', 't1',
         'server-public', '10.200.0.0/24', '0.4.0', '["10.200.0.2"]');
      INSERT INTO agents (server_id, public_key, token_hash, version, created_at)
        VALUES ('nl', 'agent-public', 'agent-token-hash', '0.4.0', 't0');
      INSERT INTO configs
        (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip, status, created_at, updated_at)
        VALUES ('cfg', 'nl', 'phone', 'client-public', '${secret}', '10.200.0.2', 'active', 't0', 't1');
      INSERT INTO audit_log (action, target, created_at) VALUES ('pair', 'nl', 't0');
      PRAGMA user_version = 3;
    `);
    created.close();

    const schema3 = path.join(dataDir, "schema3");
    mkdirSync(schema3);
    const schema3Db = path.join(schema3, "family-vpn.sqlite");
    const preSnap = run(process.execPath, [tool("archive-tool.mjs"), "snapshot", file, schema3Db]);
    assert.equal(preSnap.status, 0, preSnap.stderr);
    writeFileSync(path.join(schema3, "master.key"), readFileSync(masterFile));
    assert.equal(run(process.execPath, [tool("archive-tool.mjs"), "manifest", schema3]).status, 0);
    const preVerify = run(process.execPath, [tool("archive-tool.mjs"), "verify", schema3]);
    assert.equal(preVerify.status, 0, preVerify.stderr);
    assert.match(preVerify.stdout, /schema=3/);

    resetDbForTests();
    const migrated = getDb();
    assert.equal(userVersion(migrated), SCHEMA_VERSION);
    assert.equal(text(migrated, "SELECT password_hash FROM admin WHERE id = 1"), "scrypt$kept-password-hash");
    assert.equal(text(migrated, "SELECT token_hash FROM sessions"), "session-hash");
    assert.equal(text(migrated, "SELECT vpn_subnet FROM servers"), "10.200.0.0/24");
    assert.equal(text(migrated, "SELECT token_hash FROM agents"), "agent-token-hash");
    assert.equal(text(migrated, "SELECT client_private_key_enc FROM configs"), secret);
    assert.equal(text(migrated, "SELECT action FROM audit_log"), "pair");
    assert.equal(migrated.prepare("SELECT cpu_percent FROM servers").get()?.cpu_percent, null);
    assert.equal(sha256(masterFile), masterHash);
    resetDbForTests();

    const snapshot = path.join(dataDir, "snapshot");
    mkdirSync(snapshot, { recursive: true });
    const snapshotDb = path.join(snapshot, "family-vpn.sqlite");
    const snapped = run(process.execPath, [tool("archive-tool.mjs"), "snapshot", file, snapshotDb]);
    assert.equal(snapped.status, 0, snapped.stderr);
    writeFileSync(path.join(snapshot, "master.key"), readFileSync(masterFile));
    const verified = run(process.execPath, [tool("archive-tool.mjs"), "manifest", snapshot]);
    assert.equal(verified.status, 0, verified.stderr);
    const current = run(process.execPath, [tool("archive-tool.mjs"), "verify", snapshot]);
    assert.equal(current.status, 0, current.stderr);
    assert.match(current.stdout, /schema=4/);

    const oldTool = path.join(dataDir, "old-archive-tool.mjs");
    writeFileSync(oldTool, gitShow(`${STABLE_PANEL}:panel/archive-tool.mjs`));
    const rejected = run(process.execPath, [oldTool, "verify", snapshot]);
    assert.notEqual(rejected.status, 0);
    assert.match(`${rejected.stdout}\n${rejected.stderr}`, /SCHEMA_TOO_NEW/);

    const oldDb = path.join(dataDir, "old-db.ts");
    const opener = path.join(dataDir, "open-old.mjs");
    writeFileSync(oldDb, gitShow(`${STABLE_PANEL}:lib/server/db.ts`));
    writeFileSync(opener, openerSource);
    const opened = run(process.execPath, ["--experimental-strip-types", opener, oldDb], {
      FAMILY_VPN_DATA_DIR: dataDir,
    });
    assert.equal(opened.status, 0, `${opened.stdout}\n${opened.stderr}`);
    const old = JSON.parse(opened.stdout) as {
      schemaVersion: number;
      userVersion: number;
      passwordHash: string;
      sessionHash: string;
      subnet: string;
      agentTokenHash: string;
      configSecret: string;
      audit: string;
      cpuPercent: number | null;
      cpuColumns: number;
    };
    assert.equal(old.schemaVersion, 3);
    assert.equal(old.userVersion, 4);
    assert.equal(old.passwordHash, "scrypt$kept-password-hash");
    assert.equal(old.sessionHash, "session-hash");
    assert.equal(old.subnet, "10.200.0.0/24");
    assert.equal(old.agentTokenHash, "agent-token-hash");
    assert.equal(old.configSecret, secret);
    assert.equal(old.audit, "pair");
    assert.equal(old.cpuPercent, null);
    assert.equal(old.cpuColumns, 1);
    assert.equal(sha256(masterFile), masterHash);

    resetDbForTests();
    const again = getDb();
    assert.equal(userVersion(again), 4);
    assert.equal(text(again, "SELECT client_private_key_enc FROM configs"), secret);
    assert.equal(openSeal(master, secret), "client-private-key");
    resetDbForTests();

    rmSync(`${file}-wal`, { force: true });
    rmSync(`${file}-shm`, { force: true });
    copyFileSync(schema3Db, file);
    const restored = path.join(dataDir, "restored-by-old-tool");
    mkdirSync(restored);
    const oldSnap = run(process.execPath, [oldTool, "snapshot", file, path.join(restored, "family-vpn.sqlite")]);
    assert.equal(oldSnap.status, 0, oldSnap.stderr);
    writeFileSync(path.join(restored, "master.key"), readFileSync(masterFile));
    assert.equal(run(process.execPath, [oldTool, "manifest", restored]).status, 0, "old manifest failed");
    const oldVerify = run(process.execPath, [oldTool, "verify", restored]);
    assert.equal(oldVerify.status, 0, `${oldVerify.stdout}\n${oldVerify.stderr}`);
    assert.match(oldVerify.stdout, /schema=3/);
    assert.match(oldVerify.stdout, /KEY_OK/);

    rmSync(dataDir, { recursive: true, force: true });
  });
});

const openerSource = `
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.argv[2]).href);
const db = mod.getDb();
const out = {
  schemaVersion: mod.SCHEMA_VERSION,
  userVersion: Number(db.prepare("PRAGMA user_version").get().user_version),
  passwordHash: db.prepare("SELECT password_hash FROM admin WHERE id = 1").get().password_hash,
  sessionHash: db.prepare("SELECT token_hash FROM sessions").get().token_hash,
  subnet: db.prepare("SELECT vpn_subnet FROM servers").get().vpn_subnet,
  agentTokenHash: db.prepare("SELECT token_hash FROM agents").get().token_hash,
  configSecret: db.prepare("SELECT client_private_key_enc FROM configs").get().client_private_key_enc,
  audit: db.prepare("SELECT action FROM audit_log").get().action,
  cpuPercent: db.prepare("SELECT cpu_percent FROM servers").get().cpu_percent,
  cpuColumns: Number(db.prepare("SELECT COUNT(*) AS count FROM pragma_table_info('servers') WHERE name = 'cpu_percent'").get().count),
};
db.close();
process.stdout.write(JSON.stringify(out));
`;

function seal(master: Buffer, plaintext: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", master, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString("base64");
}

function openSeal(master: Buffer, payload: string): string {
  const raw = Buffer.from(payload, "base64");
  const decipher = createDecipheriv("aes-256-gcm", master, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
}

function userVersion(db: ReturnType<typeof getDb>): number {
  return Number(db.prepare("PRAGMA user_version").get()?.user_version ?? 0);
}

function text(db: ReturnType<typeof getDb>, sql: string): string {
  const row = db.prepare(sql).get();
  const value = row ? Object.values(row)[0] : "";
  return String(value);
}

function sha256(file: string): string {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function tool(name: string): string {
  return path.join(root, "panel", name);
}

function gitShow(spec: string): string {
  const result = spawnSync("git", ["show", spec], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function run(command: string, args: string[], extraEnv: Record<string, string> = {}) {
  return spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ...extraEnv },
  });
}
