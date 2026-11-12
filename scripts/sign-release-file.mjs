#!/usr/bin/env node
/**
 * Signs a release file with the Ed25519 release key (PEM PKCS8).
 * Usage: node scripts/sign-release-file.mjs <file> [private-key-pem-path]
 * Writes <file>.sig as raw base64url (64-byte Ed25519 signature).
 */
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const file = process.argv[2];
const defaultKey = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "keys", "release-signing.pem");
const keyPath = process.argv[3] || process.env.FAMILY_VPN_RELEASE_SIGNING_KEY_FILE || defaultKey;

if (!file) {
  console.error("usage: node scripts/sign-release-file.mjs <file> [private-key.pem]");
  process.exit(2);
}

const keyPem = process.env.FAMILY_VPN_RELEASE_SIGNING_KEY || readFileSync(keyPath);
const key = createPrivateKey(keyPem);
const data = readFileSync(file);
const signature = sign(null, data, key);
if (signature.length !== 64) {
  console.error("unexpected signature length", signature.length);
  process.exit(1);
}
writeFileSync(`${file}.sig`, signature.toString("base64url") + "\n", { mode: 0o644 });
console.log(`signed ${path.basename(file)} -> ${path.basename(file)}.sig`);
