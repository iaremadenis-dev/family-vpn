import { createHash, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { createAdmin, hasAdmin } from "@/lib/server/admin";
import { dataDirectory } from "@/lib/server/db";
import { UserError } from "@/lib/server/errors";

const FILE = "setup-token.sha256";

function tokenFile(): string {
  return path.join(dataDirectory(), FILE);
}

export function activationRequired(): boolean {
  return process.env.NODE_ENV === "production" || existsSync(tokenFile());
}

export function assertSetupToken(token: string) {
  if (!activationRequired()) return;
  if (!existsSync(tokenFile())) {
    throw new UserError(
      "Нет кода активации. Выпустите его на сервере командой install-panel.sh --setup-token.",
      403,
      "setup_token",
    );
  }
  const expected = Buffer.from(readFileSync(tokenFile(), "utf8").trim().toLowerCase());
  const actual = Buffer.from(createHash("sha256").update(token.trim()).digest("hex"));
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    throw new UserError("Код активации не принят.", 403, "setup_token");
  }
}

export function clearSetupToken() {
  rmSync(tokenFile(), { force: true });
}

export function completeSetup(displayName: string, password: string, token: string) {
  if (existsSync(path.join(dataDirectory(), "family-vpn.sqlite")) && hasAdmin()) {
    throw new UserError("Администратор уже создан.");
  }
  assertSetupToken(token);
  createAdmin(displayName, password);
  clearSetupToken();
}
