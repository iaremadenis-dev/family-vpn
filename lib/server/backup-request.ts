import { writeFileSync } from "node:fs";
import path from "node:path";
import { dataDirectory } from "@/lib/server/db";

export function requestBackup(reason: string) {
  try {
    const safe = reason.replace(/[^a-z0-9._-]/gi, "").slice(0, 40);
    writeFileSync(path.join(dataDirectory(), "backup.requested"), `${new Date().toISOString()} ${safe}\n`, {
      mode: 0o600,
    });
  } catch {
    // A panel action still succeeds when the backup request file cannot be written.
  }
}
