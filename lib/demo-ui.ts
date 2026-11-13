import type { ConfigRecord, ServerRecord } from "@/lib/types";

export const DEMO_UI_BLOCKED = "Демонстрационный режим — изменения недоступны";

/** Demo rows exist only for local UI preview. Production never enables them. */
export function demoUiEnabled(): boolean {
  return process.env.NODE_ENV === "development" && process.env.FAMILY_VPN_DEMO_UI === "1";
}

const nlId = "11111111-1111-4111-8111-111111111101";
const deId = "22222222-2222-4222-8222-222222222202";
const usId = "33333333-3333-4333-8333-333333333303";

export const demoServers: ServerRecord[] = [
  server({
    id: nlId,
    name: "NL-01",
    location: "Нидерланды",
    endpoint: "203.0.113.10",
    isDefault: true,
    linkStatus: "online",
    lastSeenAt: "2026-11-13T15:25:00.000Z",
  }),
  server({
    id: deId,
    name: "DE-02",
    location: "Германия",
    endpoint: "198.51.100.20",
    isDefault: false,
    linkStatus: "online",
    lastSeenAt: "2026-11-13T15:24:00.000Z",
  }),
  server({
    id: usId,
    name: "US-01",
    location: "США",
    endpoint: "192.0.2.30",
    isDefault: false,
    linkStatus: "offline",
    lastSeenAt: "2026-11-10T04:00:00.000Z",
  }),
];

export const demoConfigs: ConfigRecord[] = [
  config({
    id: "a1111111-1111-4111-8111-111111111101",
    serverId: nlId,
    serverName: "NL-01",
    endpoint: "203.0.113.10:51820",
    deviceName: "Денис iPhone",
    vpnIp: "10.10.0.2",
    status: "active",
    rxBytes: 1_288_490_188,
    txBytes: 83_886_080,
    lastHandshakeAt: "2026-11-13T15:20:00.000Z",
    createdAt: "2026-10-02T08:15:00.000Z",
  }),
  config({
    id: "a1111111-1111-4111-8111-111111111102",
    serverId: nlId,
    serverName: "NL-01",
    endpoint: "203.0.113.10:51820",
    deviceName: "iPhone 2",
    vpnIp: "10.10.0.3",
    status: "active",
    rxBytes: 471_859_200,
    txBytes: 41_943_040,
    lastHandshakeAt: "2026-11-13T12:04:00.000Z",
    createdAt: "2026-10-04T11:40:00.000Z",
  }),
  config({
    id: "a1111111-1111-4111-8111-111111111103",
    serverId: nlId,
    serverName: "NL-01",
    endpoint: "203.0.113.10:51820",
    deviceName: "Домашний ПК",
    vpnIp: "10.10.0.4",
    status: "pending",
    rxBytes: null,
    txBytes: null,
    lastHandshakeAt: null,
    createdAt: "2026-11-13T14:50:00.000Z",
  }),
  config({
    id: "a2222222-2222-4222-8222-222222222201",
    serverId: deId,
    serverName: "DE-02",
    endpoint: "198.51.100.20:51820",
    deviceName: "Ноутбук",
    vpnIp: "10.20.0.2",
    status: "active",
    rxBytes: 2_576_980_377,
    txBytes: 314_572_800,
    lastHandshakeAt: "2026-11-12T18:40:00.000Z",
    createdAt: "2026-09-18T16:05:00.000Z",
  }),
  config({
    id: "a2222222-2222-4222-8222-222222222202",
    serverId: deId,
    serverName: "DE-02",
    endpoint: "198.51.100.20:51820",
    deviceName: "iPad",
    vpnIp: "10.20.0.3",
    status: "revoked",
    rxBytes: 104_857_600,
    txBytes: 20_971_520,
    lastHandshakeAt: "2026-10-28T09:12:00.000Z",
    createdAt: "2026-09-20T09:00:00.000Z",
    revokedAt: "2026-11-01T10:30:00.000Z",
  }),
  config({
    id: "a2222222-2222-4222-8222-222222222203",
    serverId: deId,
    serverName: "DE-02",
    endpoint: "198.51.100.20:51820",
    deviceName: "Android",
    vpnIp: "10.20.0.4",
    status: "error",
    rxBytes: null,
    txBytes: null,
    lastHandshakeAt: null,
    lastError: "Агент не подтвердил добавление peer.",
    createdAt: "2026-11-08T13:22:00.000Z",
  }),
  config({
    id: "a3333333-3333-4333-8333-333333333301",
    serverId: usId,
    serverName: "US-01",
    endpoint: "192.0.2.30:51820",
    deviceName: "Рабочий ПК",
    vpnIp: "10.30.0.2",
    status: "active",
    rxBytes: 734_003_200,
    txBytes: 52_428_800,
    lastHandshakeAt: "2026-11-01T07:30:00.000Z",
    createdAt: "2026-10-11T07:45:00.000Z",
  }),
];

function server(input: {
  id: string;
  name: string;
  location: string;
  endpoint: string;
  isDefault: boolean;
  linkStatus: ServerRecord["linkStatus"];
  lastSeenAt: string;
}): ServerRecord {
  return {
    id: input.id,
    name: input.name,
    location: input.location,
    endpoint: input.endpoint,
    listenPort: 51820,
    isDefault: input.isDefault,
    createdAt: "2026-09-01T08:00:00.000Z",
    updatedAt: "2026-11-13T15:25:00.000Z",
    linkStatus: input.linkStatus,
    paired: true,
    agentRevoked: false,
    agentVersion: "0.4.0",
    lastSeenAt: input.lastSeenAt,
    wgPublicKey: null,
    vpnSubnet: null,
    externalInterface: null,
    cpuPercent: null,
  };
}

function config(input: {
  id: string;
  serverId: string;
  serverName: string;
  endpoint: string;
  deviceName: string;
  vpnIp: string;
  status: ConfigRecord["status"];
  rxBytes: number | null;
  txBytes: number | null;
  lastHandshakeAt: string | null;
  createdAt: string;
  revokedAt?: string | null;
  lastError?: string | null;
}): ConfigRecord {
  return {
    id: input.id,
    serverId: input.serverId,
    serverName: input.serverName,
    deviceName: input.deviceName,
    vpnIp: input.vpnIp,
    status: input.status,
    lastError: input.lastError ?? null,
    rxBytes: input.rxBytes,
    txBytes: input.txBytes,
    lastHandshakeAt: input.lastHandshakeAt,
    createdAt: input.createdAt,
    updatedAt: input.createdAt,
    revokedAt: input.revokedAt ?? null,
    clientPublicKey: `demo-not-a-key-${input.id.slice(0, 8)}`,
    endpoint: input.endpoint,
  };
}
