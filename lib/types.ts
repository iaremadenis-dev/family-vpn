export type LinkStatus = "unchecked" | "online" | "degraded" | "offline";

export type ServerInput = {
  name: string;
  location: string;
  endpoint: string;
  listenPort: number;
};

export type ServerRecord = ServerInput & {
  id: string;
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
  linkStatus: LinkStatus;
  paired: boolean;
  agentRevoked: boolean;
  agentVersion: string | null;
  lastSeenAt: string | null;
  wgPublicKey: string | null;
  vpnSubnet: string | null;
  externalInterface: string | null;
};

export type AuditEntry = {
  id: number;
  action: string;
  target: string | null;
  createdAt: string;
};

export type PanelSummary = {
  adminName: string;
  serverCount: number;
  onlineCount: number;
};

export type ConfigStatus = "pending" | "active" | "revoking" | "revoked" | "error";

export type ConfigRecord = {
  id: string;
  serverId: string;
  serverName: string;
  deviceName: string;
  vpnIp: string;
  status: ConfigStatus;
  lastError: string | null;
  rxBytes: number | null;
  txBytes: number | null;
  lastHandshakeAt: string | null;
  createdAt: string;
  updatedAt: string;
  revokedAt: string | null;
  clientPublicKey: string;
  endpoint: string;
};

export type InstallCommandInfo = {
  backendUrl: string;
  installCommand: string | null;
  updateCommand: string | null;
  installSha256: string | null;
  agentSha256: string | null;
  ready: boolean;
  tunnelHint: boolean;
  missing: string[];
};

export type ClaimedServerSummary = {
  serverId: string;
  name: string;
  location: string;
  endpoint: string;
  listenPort: number;
  vpnSubnet: string | null;
  wgPublicKey: string | null;
  externalInterface: string | null;
  agentVersion: string | null;
  wgUp: boolean;
  readyForConfigs: boolean;
};
