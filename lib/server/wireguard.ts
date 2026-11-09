import { generateKeyPairSync } from "node:crypto";
import { UserError } from "@/lib/server/errors";

const WG_KEY = /^[A-Za-z0-9+/]{42,44}={0,2}$/;
const IPV4 =
  /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;

export type WireGuardKeyPair = {
  privateKey: string;
  publicKey: string;
};

export function generateWireGuardKeyPair(): WireGuardKeyPair {
  const { privateKey, publicKey } = generateKeyPairSync("x25519");
  const privDer = privateKey.export({ type: "pkcs8", format: "der" }) as Buffer;
  const pubDer = publicKey.export({ type: "spki", format: "der" }) as Buffer;
  return {
    privateKey: privDer.subarray(privDer.length - 32).toString("base64"),
    publicKey: pubDer.subarray(pubDer.length - 32).toString("base64"),
  };
}

export function assertWireGuardKey(value: string, label = "Ключ WireGuard"): string {
  const key = value.trim();
  if (!WG_KEY.test(key)) throw new UserError(`${label} не принят.`);
  const raw = Buffer.from(key, "base64");
  if (raw.length !== 32) throw new UserError(`${label} не принят.`);
  return raw.toString("base64");
}

export function parseSubnet(cidr: string): { network: number; prefix: number; size: number } {
  const [ip, prefixRaw] = cidr.split("/");
  const prefix = Number(prefixRaw);
  if (!ip || !IPV4.test(ip) || !Number.isInteger(prefix) || prefix < 8 || prefix > 30) {
    throw new UserError("Подсеть сервера не задана или не поддерживается.");
  }
  const network = ipToInt(ip) & prefixMask(prefix);
  const size = 2 ** (32 - prefix);
  return { network, prefix, size };
}

export function allocateVpnIp(subnet: string, used: Iterable<string>): string {
  const { network, size } = parseSubnet(subnet);
  const taken = new Set<number>();
  for (const value of used) {
    const ip = value.trim().split("/")[0]!;
    if (!IPV4.test(ip)) continue;
    taken.add(ipToInt(ip));
  }
  // .0 network address and typically .1 server address stay reserved.
  for (let offset = 2; offset < size - 1; offset += 1) {
    const candidate = network + offset;
    if (!taken.has(candidate)) {
      return `${intToIp(candidate)}`;
    }
  }
  throw new UserError("В подсети сервера не осталось свободных VPN-IP.");
}

export function hostAllowedIps(vpnIp: string): string {
  if (!IPV4.test(vpnIp)) throw new UserError("VPN-IP не принят.");
  return `${vpnIp}/32`;
}

export function buildClientConfig(input: {
  privateKey: string;
  address: string;
  serverPublicKey: string;
  endpoint: string;
  listenPort: number;
}): string {
  const privateKey = assertWireGuardKey(input.privateKey, "Приватный ключ");
  const serverPublicKey = assertWireGuardKey(input.serverPublicKey, "Публичный ключ сервера");
  if (!IPV4.test(input.address)) throw new UserError("VPN-IP не принят.");
  if (!Number.isInteger(input.listenPort) || input.listenPort < 1 || input.listenPort > 65535) {
    throw new UserError("Порт сервера не принят.");
  }
  const endpoint = input.endpoint.trim();
  if (!endpoint || endpoint.includes("/") || endpoint.includes(" ")) {
    throw new UserError("Адрес сервера не принят.");
  }
  return [
    "[Interface]",
    `PrivateKey = ${privateKey}`,
    `Address = ${input.address}/32`,
    "DNS = 1.1.1.1",
    "",
    "[Peer]",
    `PublicKey = ${serverPublicKey}`,
    `Endpoint = ${endpoint}:${input.listenPort}`,
    "AllowedIPs = 0.0.0.0/0, ::/0",
    "PersistentKeepalive = 25",
    "",
  ].join("\n");
}

export function collectUsedIps(values: Array<string | null | undefined>): string[] {
  const out: string[] = [];
  for (const value of values) {
    if (!value) continue;
    for (const part of value.split(",")) {
      const host = part.trim().split("/")[0];
      if (host && IPV4.test(host)) out.push(host);
    }
  }
  return out;
}

function ipToInt(ip: string): number {
  return ip.split(".").reduce((acc, octet) => (acc << 8) + Number(octet), 0) >>> 0;
}

function intToIp(value: number): string {
  return [
    (value >>> 24) & 255,
    (value >>> 16) & 255,
    (value >>> 8) & 255,
    value & 255,
  ].join(".");
}

function prefixMask(prefix: number): number {
  if (prefix === 0) return 0;
  return (0xffffffff << (32 - prefix)) >>> 0;
}

export function parseUsedIpsJson(raw: string | null | undefined): string[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === "string" && IPV4.test(item));
  } catch {
    return [];
  }
}
