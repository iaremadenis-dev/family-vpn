import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";

const SCRYPT_N = 16384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const KEY_LENGTH = 32;

export function hashPassword(password: string): string {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, KEY_LENGTH, {
    N: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
    maxmem: 64 * 1024 * 1024,
  });
  return [
    "scrypt",
    SCRYPT_N,
    SCRYPT_R,
    SCRYPT_P,
    salt.toString("base64url"),
    hash.toString("base64url"),
  ].join("$");
}

export function verifyPassword(password: string, stored: string): boolean {
  const [scheme, nRaw, rRaw, pRaw, saltRaw, hashRaw] = stored.split("$");
  if (scheme !== "scrypt" || !saltRaw || !hashRaw) return false;
  const costN = Number(nRaw);
  const costR = Number(rRaw);
  const costP = Number(pRaw);
  if (!Number.isInteger(costN) || !Number.isInteger(costR) || !Number.isInteger(costP)) {
    return false;
  }
  if (costN < 16384 || costN > 262144 || costR < 8 || costR > 16 || costP < 1 || costP > 4) {
    return false;
  }

  const salt = Buffer.from(saltRaw, "base64url");
  const expected = Buffer.from(hashRaw, "base64url");
  if (salt.length < 16 || expected.length !== KEY_LENGTH) return false;

  const actual = scryptSync(password, salt, expected.length, {
    N: costN,
    r: costR,
    p: costP,
    maxmem: 64 * 1024 * 1024,
  });
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function validatePassword(password: string): string | null {
  if (password.length < 12) return "Пароль должен быть не короче 12 символов.";
  if (password.length > 128) return "Пароль длиннее 128 символов.";
  if (!/[a-zA-Zа-яА-Я]/.test(password) || !/\d/.test(password)) {
    return "Пароль должен содержать букву и цифру.";
  }
  return null;
}
