import type { ServerRecord } from "@/lib/types";

/** Same 45 second limit as deriveLinkStatus. Offline already means the heartbeat is older than that. */
export function displayedCpuPercent(server: Pick<ServerRecord, "linkStatus" | "cpuPercent">): number | null {
  if (server.linkStatus !== "online" && server.linkStatus !== "degraded") return null;
  const value = server.cpuPercent;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 100) return null;
  return value;
}
