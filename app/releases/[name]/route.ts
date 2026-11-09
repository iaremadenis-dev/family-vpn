import { connection } from "next/server";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";

const RELEASE_TYPES: Record<string, string> = {
  SHA256SUMS: "text/plain; charset=utf-8",
  "INSTALL.txt": "text/plain; charset=utf-8",
  "install.sh": "text/plain; charset=utf-8",
  "bootstrap.sh": "text/plain; charset=utf-8",
  "family-vpn-agent-linux-amd64": "application/octet-stream",
};

export async function generateStaticParams() {
  return Object.keys(RELEASE_TYPES).map((name) => ({ name }));
}

export async function GET(_request: Request, context: { params: Promise<{ name: string }> }) {
  return releaseResponse(context.params, false);
}

export async function HEAD(_request: Request, context: { params: Promise<{ name: string }> }) {
  return releaseResponse(context.params, true);
}

async function releaseResponse(params: Promise<{ name: string }>, head: boolean) {
  await connection();
  const { name } = await params;
  const type = RELEASE_TYPES[name];
  if (!type) return new Response("Not found", { status: 404 });

  const root = path.resolve(process.cwd(), "releases");
  const resolved = path.resolve(root, name);
  if (resolved !== path.resolve(root, path.basename(name))) {
    return new Response("Not found", { status: 404 });
  }

  let info: Awaited<ReturnType<typeof stat>>;
  try {
    info = await stat(resolved);
  } catch (cause) {
    if (!missingFile(cause)) throw cause;
    return new Response("Not found", { status: 404 });
  }
  if (!info.isFile()) return new Response("Not found", { status: 404 });

  const headers = {
    "Content-Type": type,
    "Content-Length": String(info.size),
    "Cache-Control": "no-cache",
    "X-Content-Type-Options": "nosniff",
  };
  if (head) return new Response(null, { status: 200, headers });

  let body: Buffer;
  try {
    body = await readFile(resolved);
  } catch (cause) {
    if (!missingFile(cause)) throw cause;
    return new Response("Not found", { status: 404 });
  }
  return new Response(new Uint8Array(body), { status: 200, headers });
}

function missingFile(cause: unknown): boolean {
  if (typeof cause !== "object" || cause === null || !("code" in cause)) return false;
  return (cause as { code?: unknown }).code === "ENOENT";
}
