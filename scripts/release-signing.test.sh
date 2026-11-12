#!/bin/bash
# Signs install.sh with a temp key, verifies, then rejects a tampered copy.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

node <<'NODE'
const { generateKeyPairSync, createHash } = require("crypto");
const { mkdtempSync, writeFileSync, readFileSync, rmSync } = require("fs");
const { tmpdir } = require("os");
const { join } = require("path");
const { spawnSync } = require("child_process");

const root = process.cwd();
const dir = mkdtempSync(join(tmpdir(), "fvpn-sign-"));
try {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const keyPath = join(dir, "key.pem");
  const pubPath = join(dir, "pub.pem");
  const filePath = join(dir, "install.sh");
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }));
  writeFileSync(pubPath, publicKey.export({ type: "spki", format: "pem" }));
  writeFileSync(filePath, "trusted installer body\n");

  const sign = spawnSync(process.execPath, [join(root, "scripts/sign-release-file.mjs"), filePath, keyPath], {
    encoding: "utf8",
  });
  if (sign.status !== 0) {
    console.error(sign.stdout, sign.stderr);
    process.exit(1);
  }
  const fp = createHash("sha256").update(readFileSync(pubPath)).digest("hex");
  const verify = spawnSync(
    process.execPath,
    [join(root, "scripts/verify-release-file.mjs"), filePath, `${filePath}.sig`, pubPath, fp],
    { encoding: "utf8" },
  );
  if (verify.status !== 0) {
    console.error(verify.stdout, verify.stderr);
    process.exit(1);
  }

  writeFileSync(filePath, "trusted installer body\nTAMPER\n");
  const bad = spawnSync(
    process.execPath,
    [join(root, "scripts/verify-release-file.mjs"), filePath, `${filePath}.sig`, pubPath, fp],
    { encoding: "utf8" },
  );
  if (bad.status === 0) {
    console.error("tampered install.sh was accepted");
    process.exit(1);
  }
  console.log("release-signing ok");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
NODE
