import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { stepWireguardSpeed, type SpeedBaseline, type SpeedConfig, type SpeedServer } from "@/lib/wireguard-speed";

const server: SpeedServer = {
  id: "nl",
  name: "NL-01",
  linkStatus: "online",
  lastSeenAt: "2026-11-14T00:00:15.000Z",
  paired: true,
  agentRevoked: false,
};

function peer(partial: Partial<SpeedConfig> & Pick<SpeedConfig, "rxBytes" | "txBytes" | "updatedAt">): SpeedConfig {
  return {
    id: "a",
    serverId: "nl",
    status: "active",
    ...partial,
  };
}

describe("wireguard speed", () => {
  test("ordinary RX and TX growth uses the stat interval", () => {
    const first = stepWireguardSpeed(null, [], [peer({ rxBytes: 1_000, txBytes: 100, updatedAt: "2026-11-14T00:00:00.000Z" })], [
      { ...server, lastSeenAt: "2026-11-14T00:00:00.000Z" },
    ]);
    assert.equal(first.phase, "waiting");
    assert.equal(first.rates.length, 0);

    const second = stepWireguardSpeed(
      first.baseline,
      first.rates,
      [peer({ rxBytes: 1_000 + 1_875_000, txBytes: 100 + 375_000, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(second.phase, "ready");
    assert.equal(second.rates.length, 1);
    assert.ok(Math.abs(second.rates[0]!.rxMbps - 1) < 1e-9);
    assert.ok(Math.abs(second.rates[0]!.txMbps - 0.2) < 1e-9);
  });

  test("a new peer does not add its accumulated bytes to the rate", () => {
    const first = stepWireguardSpeed(null, [], [peer({ rxBytes: 1_000, txBytes: 0, updatedAt: "2026-11-14T00:00:00.000Z" })], [
      { ...server, lastSeenAt: "2026-11-14T00:00:00.000Z" },
    ]);
    const second = stepWireguardSpeed(
      first.baseline,
      [],
      [
        peer({ rxBytes: 1_000 + 1_875_000, txBytes: 0, updatedAt: "2026-11-14T00:00:15.000Z" }),
        peer({ id: "b", rxBytes: 9_000_000_000, txBytes: 9_000_000_000, updatedAt: "2026-11-14T00:00:15.000Z" }),
      ],
      [server],
    );
    assert.equal(second.rates.length, 1);
    assert.ok(Math.abs(second.rates[0]!.rxMbps - 1) < 1e-9);
    assert.equal(second.rates[0]!.txMbps, 0);
  });

  test("removing a peer does not create a negative rate", () => {
    const seeded = stepWireguardSpeed(
      {
        peers: {
          a: { rx: 5_000_000, tx: 1_000_000, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" },
          b: { rx: 8_000_000, tx: 2_000_000, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" },
        },
      },
      [],
      [peer({ id: "b", rxBytes: 8_000_000 + 1_875_000, txBytes: 2_000_000, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(seeded.rates.length, 1);
    assert.ok(seeded.rates[0]!.rxMbps > 0);
    assert.ok(seeded.rates[0]!.txMbps >= 0);
    assert.equal(seeded.baseline.peers.a, undefined);
  });

  test("a counter reset waits instead of reporting a negative or zero rate", () => {
    const step = stepWireguardSpeed(
      { peers: { a: { rx: 50_000_000, tx: 10_000_000, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" } } },
      [{ at: 1, rxMbps: 4, txMbps: 1 }],
      [peer({ rxBytes: 100, txBytes: 10, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(step.phase, "waiting");
    assert.equal(step.rates.length, 0);
    assert.equal(step.baseline.peers.a?.rx, 100);
  });

  test("reading the same stored counters again does not invent a sample", () => {
    const baseline: SpeedBaseline = {
      peers: { a: { rx: 1_000, tx: 100, at: Date.parse("2026-11-14T00:00:15.000Z"), status: "active" } },
    };
    const rates = [{ at: Date.parse("2026-11-14T00:00:15.000Z"), rxMbps: 1.5, txMbps: 0.4 }];
    const step = stepWireguardSpeed(
      baseline,
      rates,
      [peer({ rxBytes: 1_000, txBytes: 100, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(step.phase, "ready");
    assert.equal(step.rates.length, 1);
    assert.equal(step.rates[0]!.rxMbps, 1.5);
  });

  test("an offline server drops the previous speed", () => {
    const step = stepWireguardSpeed(
      { peers: { a: { rx: 1_000, tx: 100, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" } } },
      [{ at: 1, rxMbps: 2, txMbps: 1 }],
      [peer({ rxBytes: 9_000_000, txBytes: 9_000_000, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [{ ...server, linkStatus: "offline" }],
    );
    assert.equal(step.phase, "empty");
    assert.equal(step.rates.length, 0);
  });

  test("a fresh heartbeat without new peer stats is not zero megabits", () => {
    const step = stepWireguardSpeed(
      { peers: { a: { rx: 1_000, tx: 100, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" } } },
      [{ at: 1, rxMbps: 2, txMbps: 1 }],
      [peer({ rxBytes: 1_000, txBytes: 100, updatedAt: "2026-11-14T00:00:00.000Z" })],
      [server],
    );
    assert.equal(step.phase, "empty");
    assert.equal(step.rates.length, 0);
  });

  test("fresh counters with no new bytes are zero megabits", () => {
    const step = stepWireguardSpeed(
      { peers: { a: { rx: 1_000, tx: 100, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" } } },
      [],
      [peer({ rxBytes: 1_000, txBytes: 100, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(step.phase, "ready");
    assert.equal(step.rates[0]!.rxMbps, 0);
    assert.equal(step.rates[0]!.txMbps, 0);
  });

  test("missing counters and a revoked configuration are ignored", () => {
    const step = stepWireguardSpeed(
      null,
      [],
      [
        peer({ rxBytes: null, txBytes: null, updatedAt: "2026-11-14T00:00:15.000Z" }),
        peer({ id: "gone", status: "revoked", rxBytes: 100, txBytes: 100, updatedAt: "2026-11-14T00:00:15.000Z" }),
      ],
      [server],
    );
    assert.equal(step.phase, "empty");
  });

  test("a status change alone is not a measurement", () => {
    const step = stepWireguardSpeed(
      { peers: { a: { rx: 4_000, tx: 500, at: Date.parse("2026-11-14T00:00:00.000Z"), status: "active" } } },
      [{ at: 1, rxMbps: 1, txMbps: 1 }],
      [peer({ status: "revoking", rxBytes: 4_000, txBytes: 500, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(step.phase, "ready");
    assert.equal(step.rates.length, 1);
    assert.equal(step.rates[0]!.rxMbps, 1);
    assert.equal(step.baseline.peers.a?.status, "revoking");
    const again = stepWireguardSpeed(
      step.baseline,
      step.rates,
      [peer({ status: "revoking", rxBytes: 4_000, txBytes: 500, updatedAt: "2026-11-14T00:00:15.000Z" })],
      [server],
    );
    assert.equal(again.rates.length, 1);
    assert.equal(again.rates[0]!.rxMbps, 1);
  });
});
