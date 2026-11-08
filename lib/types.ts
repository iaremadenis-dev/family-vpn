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
