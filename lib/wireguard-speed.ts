/**
 * Speed from the latest WireGuard counters already stored on each configuration.
 * The interval is the gap between two peer-stat writes (`configs.updated_at`),
 * not the time at which the overview happened to refresh.
 *
 * A server heartbeat updates `servers.last_seen_at` even when `wg show` returned
 * no peers. Those counters stay fresh only while `updated_at` still belongs to
 * that same heartbeat. `applyPeerStats` is the only writer that moves `updated_at`
 * without changing the configuration status, so a status-only write is not a sample.
 */

/** Peer stats are written just after last_seen in the same heartbeat request. */
export const STATS_MATCH_MS = 5_000;
export const MEGABIT = 1_000_000;

export type SpeedConfig = {
  id: string;
  serverId: string;
  status: string;
  rxBytes: number | null;
  txBytes: number | null;
  updatedAt: string;
};

export type SpeedServer = {
  id: string;
  name: string;
  linkStatus: string;
  lastSeenAt: string | null;
  paired: boolean;
  agentRevoked: boolean;
};

export type PeerBaseline = {
  rx: number;
  tx: number;
  at: number;
  status: string;
};

export type SpeedBaseline = {
  peers: Record<string, PeerBaseline>;
};

export type SpeedPoint = {
  at: number;
  rxMbps: number;
  txMbps: number;
};

export type SpeedPhase = "empty" | "waiting" | "ready";

export type SpeedStep = {
  baseline: SpeedBaseline;
  rates: SpeedPoint[];
  phase: SpeedPhase;
};

const EMPTY_BASELINE: SpeedBaseline = { peers: {} };

export function stepWireguardSpeed(
  previous: SpeedBaseline | null,
  rates: SpeedPoint[],
  configs: SpeedConfig[],
  servers: SpeedServer[],
): SpeedStep {
  const prior = previous ?? EMPTY_BASELINE;
  const eligible = configs.filter((config) => isFreshSample(config, servers));
  if (eligible.length === 0) {
    return { baseline: EMPTY_BASELINE, rates: [], phase: "empty" };
  }

  const nextPeers: Record<string, PeerBaseline> = {};
  let rxMbps = 0;
  let txMbps = 0;
  let contributed = false;
  let reset = false;
  let sampleAt = 0;

  for (const config of eligible) {
    const at = Date.parse(config.updatedAt);
    const rx = config.rxBytes as number;
    const tx = config.txBytes as number;
    const seen = prior.peers[config.id];
    if (!seen) {
      nextPeers[config.id] = { rx, tx, at, status: config.status };
      continue;
    }
    if (config.status !== seen.status && rx === seen.rx && tx === seen.tx) {
      nextPeers[config.id] = { rx, tx, at, status: config.status };
      continue;
    }
    if (at === seen.at) {
      nextPeers[config.id] = seen;
      continue;
    }
    if (at < seen.at) {
      nextPeers[config.id] = seen;
      continue;
    }
    if (rx < seen.rx || tx < seen.tx) {
      reset = true;
      nextPeers[config.id] = { rx, tx, at, status: config.status };
      continue;
    }
    const seconds = (at - seen.at) / 1000;
    if (seconds < 1) {
      nextPeers[config.id] = seen;
      continue;
    }
    nextPeers[config.id] = { rx, tx, at, status: config.status };
    rxMbps += ((rx - seen.rx) * 8) / seconds / MEGABIT;
    txMbps += ((tx - seen.tx) * 8) / seconds / MEGABIT;
    contributed = true;
    if (at > sampleAt) sampleAt = at;
  }

  const baseline = { peers: nextPeers };
  if (!contributed) {
    if (reset) return { baseline, rates: [], phase: "waiting" };
    return {
      baseline,
      rates,
      phase: rates.length > 0 ? "ready" : "waiting",
    };
  }
  const point: SpeedPoint = { at: sampleAt, rxMbps, txMbps };
  return {
    baseline,
    rates: [...rates, point].slice(-24),
    phase: "ready",
  };
}

function isFreshSample(config: SpeedConfig, servers: SpeedServer[]): boolean {
  if (config.status === "revoked") return false;
  if (config.rxBytes == null || config.txBytes == null) return false;
  if (!Number.isFinite(config.rxBytes) || !Number.isFinite(config.txBytes)) return false;
  if (config.rxBytes < 0 || config.txBytes < 0) return false;
  const server = servers.find((item) => item.id === config.serverId);
  if (!server || !server.paired || server.agentRevoked) return false;
  if (server.name.trim().toUpperCase() === "DE-01") return false;
  if (server.linkStatus !== "online" && server.linkStatus !== "degraded") return false;
  const at = Date.parse(config.updatedAt);
  const seen = Date.parse(server.lastSeenAt ?? "");
  if (!Number.isFinite(at) || !Number.isFinite(seen)) return false;
  if (seen - at > STATS_MATCH_MS) return false;
  if (at - seen > STATS_MATCH_MS) return false;
  return true;
}
