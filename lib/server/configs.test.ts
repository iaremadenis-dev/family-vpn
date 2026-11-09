import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, test } from "node:test";
import { applyJobResults, takeJobsForServer } from "@/lib/server/agent-jobs";
import { getDb, resetDbForTests } from "@/lib/server/db";
import {
  claimPairingCode,
  enrollAgent,
  generatePairingCode,
  heartbeatAgent,
  type AgentReport,
} from "@/lib/server/pairing";
import { decryptSecret, encryptSecret } from "@/lib/server/secret";
import { allocateVpnIp } from "@/lib/server/wireguard";

const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-cfg-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

function reset() {
  resetDbForTests();
  for (const name of [
    "family-vpn.sqlite",
    "family-vpn.sqlite-wal",
    "family-vpn.sqlite-shm",
    "master.key",
  ]) {
    rmSync(path.join(dataDir, name), { force: true });
  }
}

const subject = "test-subject";
const keys = generateKeyPairSync("ed25519");
const spki = keys.publicKey.export({ format: "der", type: "spki" }) as Buffer;
const publicKey = spki.subarray(spki.length - 32).toString("base64url");

const report: AgentReport = {
  endpoint: "203.0.113.10",
  listenPort: 51820,
  publicKey: `${"A".repeat(43)}=`,
  subnet: "10.200.0.0/24",
  interfaceName: "wg0",
  interfaceUp: true,
  externalInterface: "eth0",
  existingConfig: true,
};

function signature(message: string): string {
  return sign(null, Buffer.from(message), keys.privateKey).toString("base64url");
}

function pairServer() {
  const pairing = generatePairingCode();
  const timestamp = Math.floor(Date.now() / 1000);
  enrollAgent(
    {
      code: pairing,
      publicKey,
      version: "0.4.0",
      timestamp,
      signature: signature(`family-vpn/v1 enroll\n${publicKey}\n${timestamp}`),
      report,
    },
    subject,
  );
  const claimed = claimPairingCode({
    name: "NL-01",
    location: "Amsterdam",
    code: pairing,
    subjectHash: subject,
  });
  const agent = getDb()
    .prepare("SELECT delivery_token FROM agents WHERE server_id = ?")
    .get(claimed.serverId);
  const token = String(agent?.delivery_token);
  heartbeatAgent(token, { version: "0.4.0", report }, subject);
  return { serverId: claimed.serverId, token };
}

describe("configs", { concurrency: 1 }, () => {
  test("encrypts private keys at rest", () => {
    reset();
    const sealed = encryptSecret("unit-test-secret");
    assert.notEqual(sealed, "unit-test-secret");
    assert.equal(decryptSecret(sealed), "unit-test-secret");
  });

  test("add_peer job activates config and records peer stats", () => {
    reset();
    getDb()
      .prepare(
        `INSERT INTO admin (id, display_name, password_hash, created_at)
         VALUES (1, 'Admin', 'hash', ?)`,
      )
      .run(new Date().toISOString());
    const paired = pairServer();
    const now = new Date().toISOString();
    const configId = "11111111-1111-4111-8111-111111111111";
    const jobId = "22222222-2222-4222-8222-222222222222";
    const clientPub = `${"C".repeat(43)}=`;

    getDb()
      .prepare(
        `INSERT INTO configs
          (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip,
           status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)`,
      )
      .run(
        configId,
        paired.serverId,
        "iPhone",
        clientPub,
        encryptSecret(`${"p".repeat(43)}=`),
        "10.200.0.3",
        now,
        now,
      );
    getDb()
      .prepare(
        `INSERT INTO agent_jobs
          (id, server_id, config_id, type, public_key, allowed_ips, status, attempts, created_at, updated_at)
         VALUES (?, ?, ?, 'add_peer', ?, '10.200.0.3/32', 'queued', 0, ?, ?)`,
      )
      .run(jobId, paired.serverId, configId, clientPub, now, now);

    const jobs = takeJobsForServer(paired.serverId);
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0]?.type, "add_peer");
    applyJobResults(paired.serverId, [{ id: jobs[0]!.id, ok: true }]);
    assert.equal(getDb().prepare("SELECT status FROM configs WHERE id = ?").get(configId)?.status, "active");

    heartbeatAgent(
      paired.token,
      {
        version: "0.4.0",
        report,
        peers: [
          {
            publicKey: clientPub,
            allowedIps: "10.200.0.3/32",
            rxBytes: 1000,
            txBytes: 2000,
            lastHandshake: Math.floor(Date.now() / 1000),
          },
        ],
      },
      subject,
    );
    const stats = getDb()
      .prepare("SELECT rx_bytes, tx_bytes, last_handshake_at FROM configs WHERE id = ?")
      .get(configId);
    assert.equal(Number(stats?.rx_bytes), 1000);
    assert.equal(Number(stats?.tx_bytes), 2000);
    assert.ok(stats?.last_handshake_at);
  });

  test("does not reassign an occupied vpn ip", () => {
    reset();
    const paired = pairServer();
    const now = new Date().toISOString();
    getDb()
      .prepare(
        `INSERT INTO configs
          (id, server_id, device_name, client_public_key, client_private_key_enc, vpn_ip,
           status, created_at, updated_at)
         VALUES (?, ?, 'A', ?, 'enc', '10.200.0.3', 'active', ?, ?)`,
      )
      .run(
        "33333333-3333-4333-8333-333333333333",
        paired.serverId,
        `${"D".repeat(43)}=`,
        now,
        now,
      );
    const rows = getDb()
      .prepare("SELECT vpn_ip FROM configs WHERE server_id = ?")
      .all(paired.serverId);
    const next = allocateVpnIp(
      "10.200.0.0/24",
      rows.map((row) => String(row.vpn_ip)).concat(["10.200.0.1", "10.200.0.2"]),
    );
    assert.equal(next, "10.200.0.4");
  });
});
