import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, test } from "node:test";
import { getDb, resetDbForTests } from "@/lib/server/db";
import {
  PAIRING_TTL_MS,
  claimPairingCode,
  deriveLinkStatus,
  enrollAgent,
  generatePairingCode,
  heartbeatAgent,
  pairingCodeEntropyBits,
  pollEnrollment,
  revokeAgent,
  type AgentReport,
} from "@/lib/server/pairing";

const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-pair-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

function reset() {
  resetDbForTests();
  for (const name of ["family-vpn.sqlite", "family-vpn.sqlite-wal", "family-vpn.sqlite-shm"]) {
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
  existingConfig: false,
};

function signature(message: string): string {
  return sign(null, Buffer.from(message), keys.privateKey).toString("base64url");
}

function enroll(code: string, current = report) {
  const timestamp = Math.floor(Date.now() / 1000);
  return enrollAgent(
    {
      code,
      publicKey,
      version: "0.2.0",
      timestamp,
      signature: signature(`family-vpn/v1 enroll\n${publicKey}\n${timestamp}`),
      report: current,
    },
    subject,
  );
}

function poll(enrollmentId: string, nonce: string) {
  const timestamp = Math.floor(Date.now() / 1000);
  return pollEnrollment(
    {
      enrollmentId,
      publicKey,
      nonce,
      timestamp,
      signature: signature(`family-vpn/v1 poll\n${enrollmentId}\n${nonce}\n${timestamp}`),
    },
    subject,
  );
}

describe("pairing", { concurrency: 1 }, () => {
  test("pairing codes keep high entropy", () => {
    const seen = new Set<string>();
    for (let index = 0; index < 40; index += 1) {
      const code = generatePairingCode();
      assert.equal(pairingCodeEntropyBits(code), 100);
      assert.equal(code.replace(/-/g, "").length, 20);
      assert.equal(seen.has(code), false);
      seen.add(code);
    }
  });

  test("status follows real heartbeats only", () => {
    assert.equal(deriveLinkStatus({ paired: false, revoked: false, lastSeenAt: null, wgUp: null }), "unchecked");
    assert.equal(
      deriveLinkStatus({ paired: true, revoked: false, lastSeenAt: null, wgUp: true }),
      "unchecked",
    );
    assert.equal(
      deriveLinkStatus({
        paired: true,
        revoked: false,
        lastSeenAt: new Date().toISOString(),
        wgUp: true,
      }),
      "online",
    );
    assert.equal(
      deriveLinkStatus({
        paired: true,
        revoked: false,
        lastSeenAt: new Date().toISOString(),
        wgUp: false,
      }),
      "degraded",
    );
    assert.equal(
      deriveLinkStatus({
        paired: true,
        revoked: false,
        lastSeenAt: new Date(Date.now() - 120_000).toISOString(),
        wgUp: true,
      }),
      "offline",
    );
    assert.equal(
      deriveLinkStatus({ paired: true, revoked: true, lastSeenAt: new Date().toISOString(), wgUp: true }),
      "offline",
    );
  });

  test("code pairs one server and is refused afterwards", () => {
    reset();
    const code = generatePairingCode();
    const first = enroll(code);
    const again = enroll(code);
    assert.equal(again.enrollmentId, first.enrollmentId);
    assert.equal(poll(first.enrollmentId, first.nonce).status, "pending");

    const claimed = claimPairingCode({
      name: "AMS",
      location: "Amsterdam",
      code,
      subjectHash: subject,
    });
    assert.throws(
      () => claimPairingCode({ name: "AMS", location: "Amsterdam", code, subjectHash: subject }),
      /уже использован/,
    );
    const paired = poll(first.enrollmentId, first.nonce);
    assert.equal(paired.status, "paired");
    assert.equal(typeof paired.token, "string");
    assert.ok(paired.token && paired.token.length > 20);

    heartbeatAgent(paired.token ?? "", { version: "0.2.0", report }, subject);
    const after = poll(first.enrollmentId, first.nonce);
    assert.equal(after.token, undefined);
    const row = getDb()
      .prepare("SELECT last_seen_at, wg_up, agent_version FROM servers WHERE id = ?")
      .get(claimed.serverId);
    assert.equal(Number(row?.wg_up), 1);
    assert.equal(row?.agent_version, "0.2.0");
    assert.ok(row?.last_seen_at);

    revokeAgent(claimed.serverId);
    assert.throws(
      () => heartbeatAgent(paired.token ?? "", { version: "0.2.0", report }, subject),
      /отозван/,
    );
  });

  test("rejects an unknown, expired, or badly signed code", () => {
    reset();
    assert.throws(
      () => claimPairingCode({ name: "X", location: "Y", code: "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ", subjectHash: "other" }),
      /не найден/,
    );

    const code = generatePairingCode();
    enroll(code);
    getDb()
      .prepare("UPDATE enrollments SET expires_at = ? WHERE code_hash != ''")
      .run(new Date(Date.now() - PAIRING_TTL_MS).toISOString());
    assert.throws(
      () => claimPairingCode({ name: "X", location: "Y", code, subjectHash: "expire" }),
      /истёк/,
    );

    const fresh = generatePairingCode();
    const timestamp = Math.floor(Date.now() / 1000);
    assert.throws(
      () =>
        enrollAgent(
          {
            code: fresh,
            publicKey,
            version: "0.2.0",
            timestamp,
            signature: signature("not-the-message"),
            report,
          },
          "bad-sign",
        ),
      /Подпись/,
    );
  });

  test("keeps a second server independent", () => {
    reset();
    const first = generatePairingCode();
    const second = generatePairingCode();
    enroll(first);
    enroll(second, { ...report, endpoint: "203.0.113.11", listenPort: 51821 });
    claimPairingCode({ name: "One", location: "A", code: first, subjectHash: "multi" });
    claimPairingCode({ name: "Two", location: "B", code: second, subjectHash: "multi" });
    const count = getDb().prepare("SELECT COUNT(*) AS count FROM servers").get();
    assert.equal(Number(count?.count), 2);
  });

  test("stops repeated wrong codes", () => {
    reset();
    for (let index = 0; index < 8; index += 1) {
      assert.throws(
        () =>
          claimPairingCode({
            name: "Rate",
            location: "Limit",
            code: generatePairingCode(),
            subjectHash: "rate-limit",
          }),
        /не найден/,
      );
    }
    assert.throws(
      () =>
        claimPairingCode({
          name: "Rate",
          location: "Limit",
          code: generatePairingCode(),
          subjectHash: "rate-limit",
        }),
      /Слишком много попыток/,
    );
  });
});
