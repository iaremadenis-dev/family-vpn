import { createHash, randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import { connection } from "next/server";
import { getDb } from "@/lib/server/db";

const COOKIE = "family_vpn_session";
const SESSION_MS = 7 * 24 * 60 * 60 * 1000;

export type AdminSession = {
  displayName: string;
};

export async function readSession(): Promise<AdminSession | null> {
  await connection();
  const token = (await cookies()).get(COOKIE)?.value;
  if (!token || token.length < 32) return null;

  const now = new Date().toISOString();
  const row = getDb()
    .prepare(
      `SELECT admin.display_name AS display_name
       FROM sessions
       JOIN admin ON admin.id = 1
       WHERE sessions.token_hash = ? AND sessions.expires_at > ?`,
    )
    .get(hashToken(token), now);

  if (!row) return null;
  return { displayName: String(row.display_name) };
}

export async function createSession() {
  // Single-admin panel: a new login invalidates every prior session (FV-009).
  getDb().prepare("DELETE FROM sessions").run();
  const token = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + SESSION_MS);
  getDb()
    .prepare("INSERT INTO sessions (token_hash, expires_at, created_at) VALUES (?, ?, ?)")
    .run(hashToken(token), expiresAt.toISOString(), new Date().toISOString());

  (await cookies()).set(COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    expires: expiresAt,
  });
}

export async function destroySession() {
  const token = (await cookies()).get(COOKIE)?.value;
  if (token) {
    getDb().prepare("DELETE FROM sessions WHERE token_hash = ?").run(hashToken(token));
  }
  (await cookies()).delete(COOKIE);
}

export async function destroyOtherSessions() {
  const token = (await cookies()).get(COOKIE)?.value;
  if (!token) return;
  getDb().prepare("DELETE FROM sessions WHERE token_hash != ?").run(hashToken(token));
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
