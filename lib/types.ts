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
};
