import type { VpnConfig, VpnServer } from "@/lib/types";

const GiB = 1024 ** 3;
const MiB = 1024 ** 2;

function bytes(amount: number, unit: number) {
  return Math.round(amount * unit);
}

/**
 * Sample records for the interface.
 * Endpoints use the documentation ranges from RFC 5737 and are not real hosts.
 */
export const initialServers: VpnServer[] = [
  {
    id: "srv-ams",
    name: "AMS-1",
    location: "Амстердам",
    endpoint: "203.0.113.10",
    listenPort: 51820,
    status: "online",
    isDefault: true,
    rxBytes: bytes(48.2, GiB),
    txBytes: bytes(6.1, GiB),
    checkedAt: "2026-11-07T19:10:00.000Z",
  },
  {
    id: "srv-hel",
    name: "HEL-1",
    location: "Хельсинки",
    endpoint: "198.51.100.21",
    listenPort: 51820,
    status: "online",
    isDefault: false,
    rxBytes: bytes(12.4, GiB),
    txBytes: bytes(1.8, GiB),
    checkedAt: "2026-11-07T19:10:00.000Z",
  },
  {
    id: "srv-sgp",
    name: "SGP-1",
    location: "Сингапур",
    endpoint: "192.0.2.44",
    listenPort: 51820,
    status: "offline",
    isDefault: false,
    rxBytes: bytes(420, MiB),
    txBytes: bytes(51, MiB),
    checkedAt: "2026-11-07T11:40:00.000Z",
  },
];

export const initialConfigurations: VpnConfig[] = [
  {
    id: "cfg-laptop",
    name: "Ноутбук",
    serverId: "srv-ams",
    status: "active",
    createdAt: "2026-09-12T03:00:00.000Z",
    lastHandshake: "2026-11-07T19:05:00.000Z",
    rxBytes: bytes(30, GiB),
    txBytes: bytes(4, GiB),
  },
  {
    id: "cfg-phone",
    name: "Телефон",
    serverId: "srv-ams",
    status: "active",
    createdAt: "2026-10-02T03:20:00.000Z",
    lastHandshake: "2026-11-07T18:58:00.000Z",
    rxBytes: bytes(18, GiB),
    txBytes: bytes(2, GiB),
  },
  {
    id: "cfg-tablet",
    name: "Планшет",
    serverId: "srv-hel",
    status: "active",
    createdAt: "2026-10-18T04:00:00.000Z",
    lastHandshake: "2026-11-07T16:12:00.000Z",
    rxBytes: bytes(12, GiB),
    txBytes: bytes(1.7, GiB),
  },
  {
    id: "cfg-guest",
    name: "Гостевой",
    serverId: "srv-sgp",
    status: "revoked",
    createdAt: "2026-08-01T02:00:00.000Z",
    lastHandshake: null,
    rxBytes: bytes(400, MiB),
    txBytes: bytes(40, MiB),
  },
];

export const initialAdminName = "Администратор";
