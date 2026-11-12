import { createHash } from "node:crypto";
import { headers } from "next/headers";
import { clientAddressFromHeaders } from "@/lib/server/client-ip";
import { getDb } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";

const WINDOW_MS = 15 * 60 * 1000;
const MAX_ATTEMPTS = 8;

export async function assertLoginAllowed() {
  const subject = await subjectHash();
  prune();
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const row = getDb()
    .prepare(
      "SELECT COUNT(*) AS count FROM login_attempts WHERE subject_hash = ? AND created_at >= ?",
    )
    .get(subject, since);
  if (Number(row?.count ?? 0) >= MAX_ATTEMPTS) {
    throw new UserError("Слишком много попыток. Повторите через несколько минут.");
  }
}

export async function recordLoginFailure() {
  const subject = await subjectHash();
  getDb()
    .prepare("INSERT INTO login_attempts (subject_hash, created_at) VALUES (?, ?)")
    .run(subject, new Date().toISOString());
}

export async function clearLoginFailures() {
  const subject = await subjectHash();
  getDb().prepare("DELETE FROM login_attempts WHERE subject_hash = ?").run(subject);
}

function prune() {
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  getDb().prepare("DELETE FROM login_attempts WHERE created_at < ?").run(since);
}

async function subjectHash(): Promise<string> {
  const headerList = await headers();
  const subject = clientAddressFromHeaders(headerList) ?? "direct";
  return createHash("sha256").update(subject).digest("hex");
}
