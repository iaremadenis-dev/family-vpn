import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, test } from "node:test";
import { getDb, resetDbForTests } from "@/lib/server/db";
import {
  claimPairingCode,
  enrollAgent,
  generatePairingCode,
  heartbeatAgent,
  heartbeatMessage,
  pollEnrollment,
  type AgentReport,
} from "@/lib/server/pairing";

const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-compat-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

function reset() {
  resetDbForTests();
  delete process.env.FAMILY_VPN_REQUIRE_HEARTBEAT_SIG;
  for (const name of [
    "family-vpn.sqlite",
    "family-vpn.sqlite-wal",
    "family-vpn.sqlite-shm",
    "master.key",
  ]) {
    rmSync(path.join(dataDir, name), { force: true });
  }
}

const subject = "compat-subject";
const keys = generateKeyPairSync("ed25519");
const spki = keys.publicKey.export({ format: "der", type: "spki" }) as Buffer;
const publicKey = spki.subarray(spki.length - 32).toString("base64url");

const report: AgentReport = {
  endpoint: "203.0.113.40",
  listenPort: 51820,
  publicKey: `${"C".repeat(43)}=`,
  subnet: "10.210.0.0/24",
  interfaceName: "wg0",
  interfaceUp: true,
  externalInterface: "eth0",
  existingConfig: false,
};

function signature(message: string): string {
  return sign(null, Buffer.from(message), keys.privateKey).toString("base64url");
}

function pair(): { token: string; serverId: string } {
  const code = generatePairingCode();
  const timestamp = Math.floor(Date.now() / 1000);
  const enrolled = enrollAgent(
    {
      code,
      publicKey,
      version: "0.5.0",
      timestamp,
      signature: signature(`family-vpn/v1 enroll\n${publicKey}\n${timestamp}`),
      report,
    },
    subject,
  );
  const claimed = claimPairingCode({
    name: "Compat",
    location: "Lab",
    code,
    subjectHash: subject,
  });
  const pollTs = Math.floor(Date.now() / 1000);
  const paired = pollEnrollment(
    {
      enrollmentId: enrolled.enrollmentId,
      publicKey,
      nonce: enrolled.nonce,
      timestamp: pollTs,
      signature: signature(
        `family-vpn/v1 poll\n${enrolled.enrollmentId}\n${enrolled.nonce}\n${pollTs}`,
      ),
    },
    subject,
  );
  return { token: String(paired.token), serverId: claimed.serverId };
}

describe("compatibility and required signatures", { concurrency: 1 }, () => {
  test("new panel accepts legacy unsigned heartbeat from old agent", () => {
    reset();
    const { token } = pair();
    const result = heartbeatAgent(token, { version: "0.4.0", report }, "compat-old-agent");
    assert.equal(result.ok, true);
    const row = getDb().prepare("SELECT agent_version FROM servers").get();
    assert.equal(row?.agent_version, "0.4.0");
  });

  test("new panel accepts signed heartbeat from new agent", () => {
    reset();
    const { token } = pair();
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = "compat-signed-nonce-1";
    const result = heartbeatAgent(
      token,
      {
        version: "0.5.0",
        report,
        timestamp,
        nonce,
        signature: signature(heartbeatMessage(publicKey, timestamp, nonce)),
      },
      "compat-new-agent",
    );
    assert.equal(result.ok, true);
  });

  test("REQUIRE flag rejects unsigned heartbeat after upgrade", () => {
    reset();
    const { token } = pair();
    process.env.FAMILY_VPN_REQUIRE_HEARTBEAT_SIG = "1";
    assert.throws(
      () => heartbeatAgent(token, { version: "0.5.0", report }, "compat-require-unsigned"),
      /Подпись heartbeat обязательна/,
    );
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = "compat-require-signed-1";
    const ok = heartbeatAgent(
      token,
      {
        version: "0.5.0",
        report,
        timestamp,
        nonce,
        signature: signature(heartbeatMessage(publicKey, timestamp, nonce)),
      },
      "compat-require-signed",
    );
    assert.equal(ok.ok, true);
  });

  test("negative: fake and replayed signed heartbeats are rejected", () => {
    reset();
    process.env.FAMILY_VPN_REQUIRE_HEARTBEAT_SIG = "1";
    const { token } = pair();
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = "compat-neg-nonce";

    assert.throws(
      () =>
        heartbeatAgent(
          token,
          {
            version: "0.5.0",
            report,
            timestamp,
            nonce,
            signature: "totally-fake-signature",
          },
          "compat-fake",
        ),
      /Подпись/,
    );

    heartbeatAgent(
      token,
      {
        version: "0.5.0",
        report,
        timestamp,
        nonce,
        signature: signature(heartbeatMessage(publicKey, timestamp, nonce)),
      },
      "compat-once",
    );

    assert.throws(
      () =>
        heartbeatAgent(
          token,
          {
            version: "0.5.0",
            report,
            timestamp,
            nonce,
            signature: signature(heartbeatMessage(publicKey, timestamp, nonce)),
          },
          "compat-replay",
        ),
      /Повтор heartbeat/,
    );
  });
});
