import { readFile } from "node:fs/promises";
import path from "node:path";
import { requireAdmin } from "@/lib/server/guard";
import type { InstallCommandInfo } from "@/lib/types";

export type { InstallCommandInfo };

/**
 * Builds the verified install one-liner for the admin UI.
 * Backend URL comes from FAMILY_VPN_PUBLIC_URL (the origin the VPS must reach).
 * For local tunnel workflows that is typically http://127.0.0.1:13010 — not Windows localhost:3010.
 */
export async function getInstallCommandInfo(): Promise<InstallCommandInfo> {
  await requireAdmin();
  const missing: string[] = [];
  const backendUrl = normalizePublicUrl(process.env.FAMILY_VPN_PUBLIC_URL);
  if (!backendUrl) missing.push("FAMILY_VPN_PUBLIC_URL");

  const sums = await readReleaseSums();
  if (!sums.installSha256) missing.push("releases/install.sh checksum");
  if (!sums.agentSha256) missing.push("releases/agent checksum");

  const ready = missing.length === 0 && Boolean(backendUrl);
  const installCommand = ready
    ? buildCommand(backendUrl!, sums.installSha256!, false)
    : null;
  const updateCommand = ready
    ? buildCommand(backendUrl!, sums.installSha256!, true)
    : null;

  return {
    backendUrl: backendUrl ?? "",
    installCommand,
    updateCommand,
    installSha256: sums.installSha256,
    agentSha256: sums.agentSha256,
    ready,
    tunnelHint: Boolean(backendUrl && isTunnelBackend(backendUrl)),
    missing,
  };
}

function buildCommand(backend: string, installSha: string, update: boolean): string {
  const suffix = update ? " --update" : "";
  return [
    `curl -fsSL ${backend}/releases/install.sh -o /tmp/fvpn-install.sh`,
    `echo '${installSha}  /tmp/fvpn-install.sh' | sha256sum -c -`,
    `sudo bash /tmp/fvpn-install.sh --backend ${backend}${suffix}`,
  ].join(" && ");
}

function normalizePublicUrl(raw: string | undefined): string | null {
  const value = raw?.trim().replace(/\/$/, "") ?? "";
  if (!value) return null;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) return null;
  if (parsed.pathname && parsed.pathname !== "/") return null;
  if (parsed.protocol === "https:") return `${parsed.protocol}//${parsed.host}`;
  if (parsed.protocol === "http:") {
    const host = parsed.hostname.toLowerCase();
    if (host === "127.0.0.1" || host === "localhost" || host === "::1") {
      return `${parsed.protocol}//${parsed.host}`;
    }
    return null;
  }
  return null;
}

function isTunnelBackend(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" && ["127.0.0.1", "localhost", "::1"].includes(parsed.hostname);
  } catch {
    return false;
  }
}

async function readReleaseSums(): Promise<{ installSha256: string | null; agentSha256: string | null }> {
  const file = path.resolve(process.cwd(), "releases", "SHA256SUMS");
  try {
    const text = await readFile(file, "utf8");
    let installSha256: string | null = null;
    let agentSha256: string | null = null;
    for (const line of text.split(/\r?\n/)) {
      const match = line.match(/^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$/);
      if (!match) continue;
      const [, hash, name] = match;
      if (name === "install.sh") installSha256 = hash!.toLowerCase();
      if (name === "family-vpn-agent-linux-amd64") agentSha256 = hash!.toLowerCase();
    }
    return { installSha256, agentSha256 };
  } catch {
    return { installSha256: null, agentSha256: null };
  }
}
