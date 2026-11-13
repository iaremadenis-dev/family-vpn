import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { displayedCpuPercent } from "@/lib/cpu-display";
import { deriveLinkStatus } from "@/lib/server/pairing";

describe("displayed cpu", () => {
  test("shows a fresh sample and hides servers that are offline", () => {
    assert.equal(displayedCpuPercent({ linkStatus: "online", cpuPercent: 18 }), 18);
    assert.equal(displayedCpuPercent({ linkStatus: "degraded", cpuPercent: 0 }), 0);
    assert.equal(displayedCpuPercent({ linkStatus: "online", cpuPercent: null }), null);
    assert.equal(displayedCpuPercent({ linkStatus: "online", cpuPercent: 101 }), null);

    const stale = new Date(Date.now() - 120_000).toISOString();
    const linkStatus = deriveLinkStatus({
      paired: true,
      revoked: false,
      lastSeenAt: stale,
      wgUp: true,
    });
    assert.equal(linkStatus, "offline");
    assert.equal(displayedCpuPercent({ linkStatus, cpuPercent: 40 }), null);
  });
});
