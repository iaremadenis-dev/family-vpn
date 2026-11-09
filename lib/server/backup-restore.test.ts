import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { requestBackup } from "@/lib/server/backup-request";
import { SCHEMA_VERSION, getDb, resetDbForTests } from "@/lib/server/db";
import { decryptSecret, encryptSecret } from "@/lib/server/secret";
import { assertSetupToken, completeSetup } from "@/lib/server/setup-token";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const bash = existsSync("C:/Program Files/Git/bin/bash.exe")
  ? "C:/Program Files/Git/bin/bash.exe"
  : "bash";
const work = mkdtempSync(path.join(os.tmpdir(), "family-vpn-backup-"));
const sourceDir = path.join(work, "source");
const secretText = "client-private-key-test";
const s3Secret = "s3-secret-do-not-log";
const serverId = randomUUID();

process.env.FAMILY_VPN_DATA_DIR = sourceDir;
(process.env as Record<string, string>).NODE_ENV = "production";

function normalizedRoot(): string {
  return root;
}

function run(command: string, args: string[], env: Record<string, string>) {
  return spawnSync(command, args, {
    cwd: normalizedRoot(),
    env: { ...process.env, ...env },
    encoding: "utf8",
  });
}

function ensureAge(): { age: string; keygen: string } {
  const tools = path.join(process.env.LOCALAPPDATA ?? os.tmpdir(), "FamilyVPN", "tools", "age");
  mkdirSync(tools, { recursive: true });
  const found = readdirSync(tools, { recursive: true, encoding: "utf8" }).find((name) =>
    String(name).replaceAll("\\", "/").endsWith("age.exe"),
  );
  if (!found) {
    const download = run("python", [
      "-c",
      "import io,pathlib,sys,urllib.request,zipfile; dest=pathlib.Path(sys.argv[1]); data=urllib.request.urlopen(sys.argv[2], timeout=90).read(); zipfile.ZipFile(io.BytesIO(data)).extractall(dest)",
      tools,
      "https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-windows-amd64.zip",
    ], {});
    assert.equal(download.status, 0, download.stderr);
  }
  const ageName = readdirSync(tools, { recursive: true, encoding: "utf8" }).find((name) =>
    String(name).replaceAll("\\", "/").endsWith("age.exe"),
  );
  assert.ok(ageName);
  const age = path.join(tools, String(ageName));
  return { age, keygen: path.join(path.dirname(age), "age-keygen.exe") };
}

function bashEnv(extra: Record<string, string>): Record<string, string> {
  const tools = ensureAge();
  return {
    FAMILY_VPN_AGE: tools.age,
    FAMILY_VPN_AGE_KEYGEN: tools.keygen,
    FAMILY_VPN_PYTHON: "python",
    FAMILY_VPN_NODE: "node",
    ...extra,
  };
}

describe("panel backup and restore", () => {
  test("activation code is required on a public panel", () => {
    const activationDir = mkdtempSync(path.join(os.tmpdir(), "family-vpn-setup-"));
    process.env.FAMILY_VPN_DATA_DIR = activationDir;
    (process.env as Record<string, string>).NODE_ENV = "production";
    resetDbForTests();
    assert.throws(() => completeSetup("Ada", "correct-horse-1", ""), /кода активации/i);
    const token = randomBytes(16).toString("hex");
    writeFileSync(path.join(activationDir, "setup-token.sha256"), createHash("sha256").update("other-token").digest("hex"));
    assert.throws(() => assertSetupToken(token), /не принят/);
    assert.throws(() => completeSetup("Ada", "correct-horse-1", token), /не принят/);
    assert.equal(existsSync(path.join(activationDir, "family-vpn.sqlite")), false);
    const good = randomBytes(16).toString("hex");
    writeFileSync(path.join(activationDir, "setup-token.sha256"), createHash("sha256").update(good).digest("hex"));
    completeSetup("Ada", "correct-horse-1", good);
    assert.equal(existsSync(path.join(activationDir, "setup-token.sha256")), false);
    const row = getDb().prepare("SELECT display_name FROM admin WHERE id = 1").get();
    assert.equal(row?.display_name, "Ada");
    assert.throws(() => completeSetup("Eve", "correct-horse-2", good), /уже создан/);
    const request = readFileSync(path.join(activationDir, "backup.requested"), "utf8");
    assert.match(request, /admin/);
    assert.equal(request.includes("correct-horse-1"), false);
    resetDbForTests();
    rmSync(activationDir, { recursive: true, force: true });
  });

  test("heartbeat does not schedule a backup", () => {
    const pairing = readFileSync(path.join(normalizedRoot(), "lib/server/pairing.ts"), "utf8");
    const heartbeat = pairing.slice(
      pairing.indexOf("export function heartbeatAgent"),
      pairing.indexOf("export function revokeAgent"),
    );
    assert.equal(heartbeat.includes("requestBackup"), false);
    const jobs = readFileSync(path.join(normalizedRoot(), "lib/server/agent-jobs.ts"), "utf8");
    const stats = jobs.slice(jobs.indexOf("export function applyPeerStats"));
    assert.equal(stats.includes("requestBackup"), false);
    assert.equal(SCHEMA_VERSION, 3);
    requestBackup("config");
  });

  test("encrypted backup restores the administrator, server id, and client secret", async () => {
    mkdirSync(sourceDir, { recursive: true });
    process.env.FAMILY_VPN_DATA_DIR = sourceDir;
    (process.env as Record<string, string>).NODE_ENV = "production";
    resetDbForTests();
    const setupToken = randomBytes(16).toString("hex");
    writeFileSync(path.join(sourceDir, "setup-token.sha256"), createHash("sha256").update(setupToken).digest("hex"));
    completeSetup("Ada", "correct-horse-1", setupToken);

    const signing = run("python", [
      path.join(normalizedRoot(), "panel/s3_store.py"),
      "signing-key",
      "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      "20120215",
      "us-east-1",
      "iam",
    ], {});
    assert.equal(signing.stdout.trim(), "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d");

    getDb()
      .prepare(
        `INSERT INTO servers
          (id, name, location, endpoint, listen_port, is_default, created_at, updated_at, wg_public_key, vpn_subnet)
         VALUES (?, 'NL-01', 'Amsterdam', '203.0.113.10', 51820, 1, ?, ?, ?, '10.200.0.0/24')`,
      )
      .run(serverId, new Date().toISOString(), new Date().toISOString(), `${"A".repeat(43)}=`);
    getDb()
      .prepare(
        `INSERT INTO configs
          (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip, status, created_at, updated_at)
         VALUES (?, ?, 'phone', ?, ?, '10.200.0.2', 'active', ?, ?)`,
      )
      .run(randomUUID(), serverId, `${"B".repeat(43)}=`, encryptSecret(secretText), new Date().toISOString(), new Date().toISOString());
    const panelEnv = path.join(work, "panel.env");
    writeFileSync(panelEnv, "NODE_ENV=production\nFAMILY_VPN_PUBLIC_URL=https://203.0.113.5\n");

    const tools = ensureAge();
    const identity = path.join(work, "identity.txt");
    const generated = run(tools.keygen, ["-o", identity], {});
    assert.equal(generated.status, 0, `${generated.stdout}\n${generated.stderr}`);
    const pubkey = `${generated.stdout}\n${generated.stderr}`.match(/age1[0-9a-z]+/)?.[0];
    assert.ok(pubkey, `${generated.stdout}\n${generated.stderr}`);
    const pubFile = path.join(work, "backup.pub");
    writeFileSync(pubFile, `${pubkey}\n`);

    const port = 39123;
    const mock = spawn("python", [path.join(normalizedRoot(), "panel/s3_mock.py"), String(port)], {
      cwd: normalizedRoot(),
      stdio: "ignore",
    });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const backupEnv = path.join(work, "backup.env");
    writeFileSync(
      backupEnv,
      [
        `S3_ENDPOINT=http://127.0.0.1:${port}`,
        "S3_BUCKET=family-vpn-test",
        "S3_REGION=us-east-1",
        "S3_ACCESS_KEY_ID=AKIATEST",
        `S3_SECRET_ACCESS_KEY=${s3Secret}`,
        "S3_PREFIX=lab",
        "",
      ].join("\n"),
    );
    const backupDir = path.join(work, "backups");
    const status = path.join(work, "panel.status");
    const log = path.join(work, "panel.log");
    const common = bashEnv({
      FAMILY_VPN_PANEL_DIR: sourceDir,
      FAMILY_VPN_BACKUP_DIR: backupDir,
      FAMILY_VPN_BACKUP_PUB: pubFile,
      FAMILY_VPN_BACKUP_ENV: backupEnv,
      FAMILY_VPN_PANEL_ENV: panelEnv,
      FAMILY_VPN_BACKUP_STATUS: status,
      FAMILY_VPN_BACKUP_LOG: log,
    });
    try {
      const backup = run(bash, [path.join(normalizedRoot(), "panel/backup-panel.sh")], common);
      assert.equal(backup.status, 0, `${backup.stdout}\n${backup.stderr}`);
      assert.match(backup.stdout, /BACKUP_OK/);
      assert.match(backup.stdout, /UPLOAD_OK/);
      assert.equal(`${backup.stdout}\n${backup.stderr}\n${readFileSync(log, "utf8")}`.includes(s3Secret), false);
      assert.equal(`${backup.stdout}\n${readFileSync(status, "utf8")}`.includes(secretText), false);

      const restored = path.join(work, "restored");
      const restore = run(
        bash,
        [
          path.join(normalizedRoot(), "panel/restore-panel.sh"),
          "--archive",
          archiveName(backupDir),
          "--identity",
          identity,
          "--into",
          restored,
        ],
        common,
      );
      assert.equal(restore.status, 0, `${restore.stdout}\n${restore.stderr}`);
      assert.match(restore.stdout, /RESTORE_OK/);
      assertRecovered(restored);

      const object = readFileSync(status, "utf8").match(/UPLOAD_OK (\S+)/)?.[1];
      assert.ok(object);
      const fromS3 = path.join(work, "from-s3");
      const downloaded = run(
        bash,
        [
          path.join(normalizedRoot(), "panel/restore-panel.sh"),
          "--archive",
          `s3://family-vpn-test/${object}`,
          "--identity",
          identity,
          "--s3-env",
          backupEnv,
          "--into",
          fromS3,
        ],
        common,
      );
      assert.equal(downloaded.status, 0, `${downloaded.stdout}\n${downloaded.stderr}`);
      assertRecovered(fromS3);
      assert.equal(readFileSync(path.join(fromS3, "panel.env.previous"), "utf8").includes("203.0.113.5"), true);

      const age = run(bash, [path.join(normalizedRoot(), "panel/backup-panel.sh"), "--check-age"], common);
      assert.equal(age.status, 0, age.stdout);
      assert.match(age.stdout, /AGE_OK/);
      writeFileSync(status, "2000-01-01T00:00:00Z UPLOAD_OK panel/old.tar.age\n");
      const stale = run(bash, [path.join(normalizedRoot(), "panel/backup-panel.sh"), "--check-age"], common);
      assert.equal(stale.status, 4);
      assert.match(stale.stdout, /OFFSITE_STALE/);

      const wrongKey = path.join(work, "wrong.txt");
      assert.equal(run(tools.keygen, ["-o", wrongKey], {}).status, 0);
      const wrongDir = path.join(work, "wrong");
      const wrong = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-panel.sh"), "--archive", archiveName(backupDir), "--identity", wrongKey, "--into", wrongDir],
        common,
      );
      assert.notEqual(wrong.status, 0);
      assert.match(wrong.stderr, /DECRYPT_FAIL/);
      assert.equal(existsSync(path.join(wrongDir, "family-vpn.sqlite")), false);

      const damaged = path.join(work, "damaged.tar.age");
      const original = readFileSync(archiveName(backupDir));
      original[80] = original[80] === 65 ? 66 : 65;
      writeFileSync(damaged, original);
      const damagedDir = path.join(work, "damaged");
      const broken = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-panel.sh"), "--archive", damaged, "--identity", identity, "--into", damagedDir],
        common,
      );
      assert.notEqual(broken.status, 0);
      assert.equal(existsSync(path.join(damagedDir, "family-vpn.sqlite")), false);
      assert.equal(existsSync(path.join(damagedDir, "master.key")), false);

      const occupied = path.join(work, "occupied");
      mkdirSync(occupied);
      writeFileSync(path.join(occupied, "family-vpn.sqlite"), "keep-me");
      const clash = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-panel.sh"), "--archive", archiveName(backupDir), "--identity", identity, "--into", occupied],
        common,
      );
      assert.equal(clash.status, 3);
      assert.equal(readFileSync(path.join(occupied, "family-vpn.sqlite"), "utf8"), "keep-me");

      const rolled = path.join(work, "rolled");
      const rollback = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-panel.sh"), "--archive", archiveName(backupDir), "--identity", identity, "--into", rolled],
        { ...common, FAMILY_VPN_RESTORE_FAIL_AFTER: "sqlite" },
      );
      assert.notEqual(rollback.status, 0);
      assert.match(rollback.stderr, /RESTORE_ROLLBACK/);
      assert.equal(existsSync(path.join(rolled, "family-vpn.sqlite")), false);
      assert.equal(existsSync(path.join(rolled, "master.key")), false);

      const wgRoot = path.join(work, "wg-src");
      mkdirSync(wgRoot);
      const wgConf = path.join(wgRoot, "wg0.conf");
      const agentState = path.join(wgRoot, "agent.json");
      writeFileSync(wgConf, "[Interface]\nPrivateKey = test-server-key\n");
      writeFileSync(agentState, "{\"publicKey\":\"abc\"}\n");
      const wgBackup = path.join(work, "wg-backups");
      const wg = run(bash, [path.join(normalizedRoot(), "panel/backup-wg.sh")], bashEnv({
        FAMILY_VPN_WG_CONF: wgConf,
        FAMILY_VPN_AGENT_STATE: agentState,
        FAMILY_VPN_WG_UNIT: path.join(work, "missing.service"),
        FAMILY_VPN_WG_BACKUP_DIR: wgBackup,
        FAMILY_VPN_BACKUP_PUB: pubFile,
        FAMILY_VPN_WG_BACKUP_STATUS: path.join(work, "wg.status"),
      }));
      assert.equal(wg.status, 0, `${wg.stdout}\n${wg.stderr}`);
      assert.match(wg.stdout, /WG_BACKUP_OK/);
      const wgDest = path.join(work, "wg-restored");
      const wgRestore = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-wg.sh"), "--archive", archiveName(wgBackup), "--identity", identity, "--into", wgDest],
        bashEnv({}),
      );
      assert.equal(wgRestore.status, 0, wgRestore.stderr);
      assert.equal(readFileSync(path.join(wgDest, "wg0.conf"), "utf8"), readFileSync(wgConf, "utf8"));
      assert.equal(readFileSync(path.join(wgDest, "agent.json"), "utf8"), readFileSync(agentState, "utf8"));
      assert.equal(existsSync(path.join(wgDest, "family-vpn.sqlite")), false);
      const wgClash = run(
        bash,
        [path.join(normalizedRoot(), "panel/restore-wg.sh"), "--archive", archiveName(wgBackup), "--identity", identity, "--into", wgDest],
        bashEnv({}),
      );
      assert.notEqual(wgClash.status, 0);
      assert.match(wgClash.stderr, /DATA_EXISTS/);
    } finally {
      mock.kill();
      resetDbForTests();
      rmSync(work, { recursive: true, force: true });
    }
  });
});

function archiveName(directory: string): string {
  const names = readdirSync(directory).filter((name) => name.endsWith(".tar.age"));
  assert.equal(names.length > 0, true);
  return path.join(directory, names[0]);
}

function assertRecovered(directory: string) {
  resetDbForTests();
  process.env.FAMILY_VPN_DATA_DIR = directory;
  const admin = getDb().prepare("SELECT display_name FROM admin WHERE id = 1").get();
  assert.equal(admin?.display_name, "Ada");
  const server = getDb().prepare("SELECT id, endpoint FROM servers WHERE id = ?").get(serverId);
  assert.equal(server?.endpoint, "203.0.113.10");
  const config = getDb().prepare("SELECT client_private_key_enc FROM configs").get();
  assert.equal(decryptSecret(String(config?.client_private_key_enc)), secretText);
  const version = getDb().prepare("PRAGMA user_version").get();
  assert.equal(Number(version?.user_version), SCHEMA_VERSION);
}
