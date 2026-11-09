import { createDecipheriv, createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA_MAX = 3;
const PANEL_KIND = "family-vpn-panel";
const WG_KIND = "family-vpn-wireguard";

function die(token, detail = "") {
  console.error(detail ? `${token} ${detail}` : token);
  process.exit(1);
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function snapshot(source, destination) {
  if (!existsSync(source)) die("SQLITE_MISSING");
  if (existsSync(destination)) die("SNAPSHOT_EXISTS");
  mkdirSync(path.dirname(destination), { recursive: true });
  const db = new DatabaseSync(source);
  db.exec("PRAGMA busy_timeout = 5000");
  const sqlPath = destination.replaceAll("\\", "/").replaceAll("'", "''");
  db.exec(`VACUUM INTO '${sqlPath}'`);
  db.close();
}

function openRead(file) {
  const db = new DatabaseSync(file);
  db.exec("PRAGMA query_only = ON");
  db.exec("PRAGMA busy_timeout = 5000");
  return db;
}

function tableExists(db, name) {
  return Boolean(
    db.prepare("SELECT 1 AS ok FROM sqlite_master WHERE type = 'table' AND name = ?").get(name),
  );
}

function fileMeta(file) {
  return { sha256: sha256(file), bytes: statSync(file).size };
}

function panelManifest(directory) {
  const sqlite = path.join(directory, "family-vpn.sqlite");
  if (!existsSync(sqlite)) die("SQLITE_MISSING");
  const db = openRead(sqlite);
  const schema = Number(db.prepare("PRAGMA user_version").get()?.user_version ?? 0);
  const admin = tableExists(db, "admin")
    ? db.prepare("SELECT id FROM admin WHERE id = 1").get()
    : undefined;
  const servers = tableExists(db, "servers")
    ? db.prepare("SELECT id, endpoint, listen_port FROM servers ORDER BY id").all()
    : [];
  const agents = tableExists(db, "agents")
    ? db.prepare("SELECT server_id, public_key FROM agents ORDER BY server_id").all()
    : [];
  const configCount = tableExists(db, "configs")
    ? Number(db.prepare("SELECT COUNT(*) AS count FROM configs").get()?.count ?? 0)
    : 0;
  db.close();

  const files = { "family-vpn.sqlite": fileMeta(sqlite) };
  for (const name of ["master.key", "panel.env"]) {
    const file = path.join(directory, name);
    if (existsSync(file)) files[name] = fileMeta(file);
  }
  const body = {
    kind: PANEL_KIND,
    manifest_version: 1,
    schema_version: schema,
    created_at: new Date().toISOString(),
    admin_present: Boolean(admin),
    config_count: configCount,
    servers: servers.map((row) => ({
      id: String(row.id),
      endpoint: String(row.endpoint),
      listen_port: Number(row.listen_port),
    })),
    agents: agents.map((row) => ({
      server_id: String(row.server_id),
      public_key: String(row.public_key),
    })),
    files,
  };
  writeFileSync(path.join(directory, "manifest.json"), `${JSON.stringify(body, null, 2)}\n`, {
    mode: 0o600,
  });
}

function decryptConfig(master, payload) {
  const raw = Buffer.from(String(payload), "base64");
  if (raw.length < 28) throw new Error("short");
  const decipher = createDecipheriv("aes-256-gcm", master, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
}

function assertFiles(directory, manifest) {
  const files = manifest.files ?? {};
  for (const [name, meta] of Object.entries(files)) {
    if (name.includes("/") || name.includes("\\") || name.startsWith(".")) die("BAD_FILE_NAME");
    const file = path.join(directory, name);
    if (!existsSync(file)) die("FILE_MISSING", name);
    if (sha256(file) !== meta.sha256) die("CHECKSUM", name);
    if (statSync(file).size !== meta.bytes) die("SIZE", name);
  }
}

function panelVerify(directory) {
  const manifestFile = path.join(directory, "manifest.json");
  if (!existsSync(manifestFile)) die("MANIFEST_MISSING");
  const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
  if (manifest.kind !== PANEL_KIND) die("KIND_MISMATCH");
  if (manifest.manifest_version !== 1) die("MANIFEST_VERSION");
  if (!Number.isInteger(manifest.schema_version) || manifest.schema_version > SCHEMA_MAX) {
    die("SCHEMA_TOO_NEW");
  }
  assertFiles(directory, manifest);
  if (!manifest.files?.["family-vpn.sqlite"]) die("SQLITE_MISSING");

  const db = openRead(path.join(directory, "family-vpn.sqlite"));
  const integrity = String(db.prepare("PRAGMA integrity_check").get()?.integrity_check ?? "");
  if (integrity !== "ok") die("INTEGRITY");
  const schema = Number(db.prepare("PRAGMA user_version").get()?.user_version ?? 0);
  if (schema !== manifest.schema_version) die("SCHEMA_MISMATCH");
  const admin = tableExists(db, "admin")
    ? db.prepare("SELECT id FROM admin WHERE id = 1").get()
    : undefined;
  if (Boolean(admin) !== Boolean(manifest.admin_present)) die("ADMIN_MISMATCH");
  const dbIds = tableExists(db, "servers")
    ? db.prepare("SELECT id FROM servers ORDER BY id").all().map((row) => String(row.id))
    : [];
  const manifestIds = (manifest.servers ?? []).map((row) => String(row.id)).sort();
  if (JSON.stringify([...dbIds].sort()) !== JSON.stringify(manifestIds)) die("SERVER_MISMATCH");
  const encrypted = tableExists(db, "configs")
    ? db
        .prepare(
          "SELECT client_private_key_enc FROM configs WHERE client_private_key_enc != ''",
        )
        .all()
    : [];
  db.close();

  const keyFile = path.join(directory, "master.key");
  if (encrypted.length > 0) {
    if (!existsSync(keyFile)) die("KEY_MISSING");
    const master = readFileSync(keyFile);
    if (master.length !== 32) die("KEY_LENGTH");
    try {
      for (const row of encrypted) decryptConfig(master, row.client_private_key_enc);
    } catch {
      die("KEY_MISMATCH");
    }
    console.log("KEY_OK");
  } else {
    if (existsSync(keyFile) && readFileSync(keyFile).length !== 32) die("KEY_LENGTH");
    console.log("KEY_ABSENT");
  }
  console.log(`VERIFY_OK admin=${admin ? 1 : 0} servers=${dbIds.length} schema=${schema}`);
}

function wgManifest(directory) {
  const names = ["wg0.conf", "agent.json", "family-vpn-agent.service"];
  const files = {};
  for (const name of names) {
    const file = path.join(directory, name);
    if (existsSync(file)) files[name] = fileMeta(file);
  }
  if (!files["wg0.conf"]) die("WG_CONF_MISSING");
  if (existsSync(path.join(directory, "family-vpn.sqlite")) || existsSync(path.join(directory, "master.key"))) {
    die("MIXED_ARCHIVE");
  }
  const body = {
    kind: WG_KIND,
    manifest_version: 1,
    created_at: new Date().toISOString(),
    files,
  };
  writeFileSync(path.join(directory, "manifest.json"), `${JSON.stringify(body, null, 2)}\n`, {
    mode: 0o600,
  });
}

function wgVerify(directory) {
  const manifestFile = path.join(directory, "manifest.json");
  if (!existsSync(manifestFile)) die("MANIFEST_MISSING");
  const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
  if (manifest.kind !== WG_KIND) die("KIND_MISMATCH");
  if (manifest.manifest_version !== 1) die("MANIFEST_VERSION");
  if (existsSync(path.join(directory, "family-vpn.sqlite")) || existsSync(path.join(directory, "master.key"))) {
    die("MIXED_ARCHIVE");
  }
  assertFiles(directory, manifest);
  if (!manifest.files?.["wg0.conf"]) die("WG_CONF_MISSING");
  console.log("WG_VERIFY_OK");
}

const [command, first, second] = process.argv.slice(2);
if (command === "snapshot") snapshot(first, second);
else if (command === "manifest") panelManifest(first);
else if (command === "verify") panelVerify(first);
else if (command === "wg-manifest") wgManifest(first);
else if (command === "wg-verify") wgVerify(first);
else die("ARCHIVE_USAGE");
