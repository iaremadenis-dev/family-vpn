import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from "node:fs";
import path from "node:path";
import { dataDirectory } from "@/lib/server/db";

const KEY_FILE = "master.key";

export function getMasterKey(): Buffer {
  const directory = dataDirectory();
  mkdirSync(directory, { recursive: true });
  const file = path.join(directory, KEY_FILE);
  if (existsSync(file)) {
    const raw = readFileSync(file);
    if (raw.length === 32) return raw;
    // Refuse silent rotation: a wrong-length file would otherwise orphan encrypted secrets.
    throw new Error("master.key is present but invalid; refusing to replace it");
  }
  const key = randomBytes(32);
  writeFileSync(file, key, { mode: 0o600 });
  try {
    chmodSync(file, 0o600);
  } catch {
    // Windows may ignore chmod; file still lives only under data dir.
  }
  return key;
}

export function encryptSecret(plaintext: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", getMasterKey(), iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]).toString("base64");
}

export function decryptSecret(payload: string): string {
  const raw = Buffer.from(payload, "base64");
  if (raw.length < 28) throw new Error("encrypted payload incomplete");
  const iv = raw.subarray(0, 12);
  const tag = raw.subarray(12, 28);
  const data = raw.subarray(28);
  const decipher = createDecipheriv("aes-256-gcm", getMasterKey(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8");
}
