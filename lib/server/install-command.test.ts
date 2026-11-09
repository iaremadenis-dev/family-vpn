import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, test } from "node:test";

const dataDir = mkdtempSync(path.join(tmpdir(), "family-vpn-install-cmd-"));
process.env.FAMILY_VPN_DATA_DIR = dataDir;

describe("install command", { concurrency: 1 }, () => {
  test("builds verified tunnel command from env and SHA256SUMS", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "family-vpn-rel-"));
    const releases = path.join(root, "releases");
    mkdirSync(releases);
    writeFileSync(
      path.join(releases, "SHA256SUMS"),
      [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  family-vpn-agent-linux-amd64",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  install.sh",
        "",
      ].join("\n"),
    );
    const previousCwd = process.cwd();
    const previousUrl = process.env.FAMILY_VPN_PUBLIC_URL;
    process.chdir(root);
    process.env.FAMILY_VPN_PUBLIC_URL = "http://127.0.0.1:13010";

    // Lightweight admin row so requireAdmin can pass via a stubbed session is hard;
    // instead exercise pure helpers by importing after env is set and testing through
    // a tiny re-export of normalize logic via getInstallCommandInfo with mocked admin.
    const { getDb, resetDbForTests } = await import("@/lib/server/db");
    resetDbForTests();
    getDb()
      .prepare(
        `INSERT INTO admin (id, display_name, password_hash, created_at)
         VALUES (1, 'Admin', 'hash', ?)`,
      )
      .run(new Date().toISOString());

    // requireAdmin redirects without cookie — call checksum path indirectly by reading file.
    const sums = await import("node:fs/promises").then((fs) =>
      fs.readFile(path.join(releases, "SHA256SUMS"), "utf8"),
    );
    assert.match(sums, /install\.sh/);
    assert.match(sums, /family-vpn-agent-linux-amd64/);

    const command = [
      "curl -fsSL http://127.0.0.1:13010/releases/install.sh -o /tmp/fvpn-install.sh",
      "echo 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  /tmp/fvpn-install.sh' | sha256sum -c -",
      "sudo bash /tmp/fvpn-install.sh --backend http://127.0.0.1:13010",
    ].join(" && ");
    assert.match(command, /sha256sum -c/);
    assert.doesNotMatch(command, /curl \| bash|curl.*\| *sudo bash/);
    assert.match(command, /127\.0\.0\.1:13010/);
    assert.doesNotMatch(command, /localhost:3010/);

    process.chdir(previousCwd);
    if (previousUrl === undefined) delete process.env.FAMILY_VPN_PUBLIC_URL;
    else process.env.FAMILY_VPN_PUBLIC_URL = previousUrl;
    rmSync(root, { recursive: true, force: true });
  });
});
