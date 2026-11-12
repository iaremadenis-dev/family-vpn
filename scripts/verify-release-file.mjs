#!/usr/bin/env node
/**
 * Verifies a Family VPN release signature.
 * Usage: node scripts/verify-release-file.mjs <file> <file.sig> <public.pem> [expected-pub-sha256]
 */
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

const [file, sigFile, pubFile, expectedFp] = process.argv.slice(2);
if (!file || !sigFile || !pubFile) {
  console.error("usage: node scripts/verify-release-file.mjs <file> <sig> <pub.pem> [sha256]");
  process.exit(2);
}

const pubPem = readFileSync(pubFile);
const fp = createHash("sha256").update(pubPem).digest("hex");
if (expectedFp && fp !== expectedFp.toLowerCase()) {
  console.error("release public key fingerprint mismatch");
  process.exit(1);
}

const key = createPublicKey(pubPem);
const data = readFileSync(file);
const sigRaw = readFileSync(sigFile, "utf8").trim();
const signature = Buffer.from(sigRaw, "base64url");
if (signature.length !== 64 || !verify(null, data, key, signature)) {
  console.error("signature verification failed");
  process.exit(1);
}
console.log("ok");
