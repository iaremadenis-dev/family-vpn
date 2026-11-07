export type ServerStatus = "online" | "degraded" | "offline";

export type ConfigStatus = "active" | "revoked";

export type VpnServer = {
  id: string;
  name: string;
  location: string;
  endpoint: string;
  listenPort: number;
  status: ServerStatus;
  isDefault: boolean;
  rxBytes: number;
  txBytes: number;
  checkedAt: string | null;
};

export type VpnConfig = {
  id: string;
  name: string;
  serverId: string;
  status: ConfigStatus;
  createdAt: string;
  lastHandshake: string | null;
  rxBytes: number;
  txBytes: number;
};

export type ServerInput = {
  name: string;
  location: string;
  endpoint: string;
  listenPort: number;
};
