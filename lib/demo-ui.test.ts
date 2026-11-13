import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { demoUiEnabled } from "@/lib/demo-ui";

const source = readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "demo-ui.ts"), "utf8");

describe("demo mode", () => {
  test("production cannot enable demo data", () => {
    const env = process.env as Record<string, string | undefined>;
    const nodeEnv = env.NODE_ENV;
    const flag = env.FAMILY_VPN_DEMO_UI;
    try {
      env.NODE_ENV = "production";
      env.FAMILY_VPN_DEMO_UI = "1";
      assert.equal(demoUiEnabled(), false);
      env.NODE_ENV = "test";
      assert.equal(demoUiEnabled(), false);
      env.NODE_ENV = "development";
      env.FAMILY_VPN_DEMO_UI = "0";
      assert.equal(demoUiEnabled(), false);
      env.FAMILY_VPN_DEMO_UI = "1";
      assert.equal(demoUiEnabled(), true);
    } finally {
      if (nodeEnv === undefined) delete env.NODE_ENV;
      else env.NODE_ENV = nodeEnv;
      if (flag === undefined) delete env.FAMILY_VPN_DEMO_UI;
      else env.FAMILY_VPN_DEMO_UI = flag;
    }
    assert.equal(source.includes("getDb"), false);
    assert.equal(source.includes("family-vpn.sqlite"), false);
    assert.equal(source.includes("node:sqlite"), false);
  });
});
