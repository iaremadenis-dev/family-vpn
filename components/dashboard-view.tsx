"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { IconConfig, IconDevice, IconOverview, IconServer } from "@/components/icons";
import { displayedCpuPercent } from "@/lib/cpu-display";
import type { ConfigRecord, ServerRecord } from "@/lib/types";
import { stepWireguardSpeed, type SpeedBaseline, type SpeedPhase, type SpeedPoint } from "@/lib/wireguard-speed";

export function DashboardView({
  servers,
  configs,
  demo = false,
}: {
  servers: ServerRecord[];
  configs: ConfigRecord[];
  demo?: boolean;
}) {
  const online = servers.filter((server) => server.linkStatus === "online").length;
  const activeConfigs = configs.filter((config) => config.status === "active").length;

  return (
    <div className="flex flex-col gap-4">
      <div className="max-w-3xl">
        <h2 className="text-lg font-semibold tracking-tight text-ink">Обзор</h2>
        {demo ? <p className="mt-1 text-xs font-medium text-warn">Демо-данные</p> : null}
        <p className="mt-1 text-sm text-muted">
          Серверы и конфигурации из базы панели. Статус связи берётся из сообщений агента.
        </p>
      </div>

      <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Всего VPN-серверов" value={String(servers.length)} hint="в панели" icon={<IconServer className="h-4 w-4" />} />
        <Kpi label="Серверы в сети" value={String(online)} hint="статус Online" icon={<IconOverview className="h-4 w-4" />} />
        <Kpi label="Всего конфигураций" value={String(configs.length)} hint="все статусы" icon={<IconConfig className="h-4 w-4" />} />
        <Kpi
          label="Активные конфигурации"
          value={String(activeConfigs)}
          hint="со статусом «Активна»"
          icon={<IconDevice className="h-4 w-4" />}
        />
      </section>

      <OverviewMeters configs={configs} servers={servers} demo={demo} />
    </div>
  );
}

const SAMPLE_MS = 20_000;

type RatePoint = SpeedPoint;

function OverviewMeters({
  configs,
  servers,
  demo,
}: {
  configs: ConfigRecord[];
  servers: ServerRecord[];
  demo: boolean;
}) {
  const router = useRouter();
  const [openLoad, setOpenLoad] = useState(false);
  const [rates, setRates] = useState<RatePoint[]>([]);
  const [speedPhase, setSpeedPhase] = useState<SpeedPhase>("empty");
  const [cpuById, setCpuById] = useState<Record<string, number | null>>({});
  const baseline = useRef<SpeedBaseline | null>(null);
  const loadServers = useMemo(
    () =>
      servers.filter(
        (server) => server.paired && !server.agentRevoked && server.name.trim().toUpperCase() !== "DE-01",
      ),
    [servers],
  );

  useEffect(() => {
    if (demo) return;
    const timer = window.setInterval(() => router.refresh(), SAMPLE_MS);
    return () => window.clearInterval(timer);
  }, [demo, router]);

  useEffect(() => {
    if (!demo) return;
    const tick = () => {
      const now = Date.now();
      setRates(demoRates(now));
      setCpuById(Object.fromEntries(loadServers.map((server) => [server.id, demoCpu(server, now)])));
    };
    const first = window.setTimeout(tick, 0);
    const timer = window.setInterval(tick, 3000);
    return () => {
      window.clearTimeout(first);
      window.clearInterval(timer);
    };
  }, [demo, loadServers]);

  useEffect(() => {
    if (demo) return;
    const timer = window.setTimeout(() => {
      const step = stepWireguardSpeed(baseline.current, rates, configs, servers);
      baseline.current = step.baseline;
      setRates(step.rates);
      setSpeedPhase(step.phase);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [configs, demo, rates, servers]);

  const speedState = demo ? (rates.length > 0 ? "ready" : "waiting") : speedPhase;

  const latest = rates.at(-1);
  const cpuValues = loadServers.map((server) => (demo ? (cpuById[server.id] ?? null) : displayedCpuPercent(server)));
  const knownCpu = cpuValues.filter((value): value is number => value != null);
  const averageCpu = knownCpu.length ? Math.round(knownCpu.reduce((sum, value) => sum + value, 0) / knownCpu.length) : null;

  return (
    <section className="grid gap-3 lg:grid-cols-2">
      <article className="glass px-4 py-3.5">
        <div className="flex items-start justify-between gap-3">
          <h3 className="text-sm font-medium text-ink">Текущая скорость</h3>
          {demo ? <span className="text-[11px] font-medium text-warn">Демо-данные</span> : null}
        </div>
        {speedState === "ready" && latest ? (
          <div className="mt-3 grid grid-cols-3 gap-2">
            <SpeedValue label="RX" value={latest.rxMbps} tone="text-info" />
            <SpeedValue label="TX" value={latest.txMbps} tone="text-warn" />
            <SpeedValue label="Всего" value={latest.rxMbps + latest.txMbps} tone="text-ink" />
          </div>
        ) : (
          <p className="mt-3 text-lg font-semibold text-ink">
            {speedState === "empty" ? "Нет данных" : "Ожидание измерений"}
          </p>
        )}
        <p className="mt-1 text-[11px] text-muted">Среднее за интервал измерения, Мбит/с</p>
        {speedState === "ready" && rates.length >= 2 ? <SpeedChart points={rates} /> : null}
      </article>

      <article className="glass px-4 py-3.5">
        <div className="flex items-start justify-between gap-3">
          <h3 className="text-sm font-medium text-ink">Загрузка серверов</h3>
          {demo ? <span className="text-[11px] font-medium text-warn">Демо-данные</span> : null}
        </div>
        <p className="mt-3 text-2xl font-semibold tracking-tight tabular-nums text-ink">
          {averageCpu == null ? "Нет данных" : `${averageCpu}%`}
        </p>
        <p className="mt-1 text-[11px] text-muted">CPU</p>
        {averageCpu == null ? null : (
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-inset">
            <div className="h-full rounded-full bg-accent" style={{ width: `${averageCpu}%` }} />
          </div>
        )}
        {loadServers.length > 0 ? (
          <button
            type="button"
            className="mt-3 text-xs text-accent hover:text-ink"
            aria-expanded={openLoad}
            onClick={() => setOpenLoad((open) => !open)}
          >
            {openLoad ? "Скрыть серверы" : "По серверам"}
          </button>
        ) : null}
        {openLoad ? (
          <ul className="mt-2 flex flex-col gap-1.5">
            {loadServers.map((server, index) => (
              <li key={server.id} className="flex items-center justify-between gap-3 text-sm">
                <span className="truncate text-ink">{server.name}</span>
                <span className="shrink-0 tabular-nums text-muted">
                  {cpuValues[index] == null ? "Нет данных" : `${cpuValues[index]}%`}
                </span>
              </li>
            ))}
          </ul>
        ) : null}
      </article>
    </section>
  );
}

function SpeedValue({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <p className="min-w-0">
      <span className={`block text-[11px] ${tone}`}>{label}</span>
      <span className="mt-0.5 block truncate text-xl font-semibold tabular-nums text-ink">
        {formatMbps(value)} <span className="text-xs font-medium text-muted">Мбит/с</span>
      </span>
    </p>
  );
}

function SpeedChart({ points }: { points: RatePoint[] }) {
  const width = 240;
  const height = 48;
  const max = Math.max(...points.flatMap((point) => [point.rxMbps, point.txMbps]), 0.1);
  const x = (index: number) => (index / (points.length - 1)) * width;
  const y = (value: number) => height - 2 - (value / max) * (height - 6);
  const path = (key: "rxMbps" | "txMbps") => points.map((point, index) => `${x(index)},${y(point[key])}`).join(" ");
  return (
    <svg viewBox={`0 0 ${width} ${height}`} className="mt-3 h-12 w-full" role="img" aria-label="График скорости RX и TX">
      <polyline points={path("rxMbps")} fill="none" stroke="currentColor" strokeWidth="2" className="text-info" />
      <polyline points={path("txMbps")} fill="none" stroke="currentColor" strokeWidth="2" className="text-warn" />
    </svg>
  );
}

function demoRates(now: number): RatePoint[] {
  const points: RatePoint[] = [];
  for (let index = 11; index >= 0; index -= 1) {
    const at = now - index * 5000;
    const wave = at / 1000;
    points.push({
      at,
      rxMbps: 14 + Math.sin(wave / 3.5) * 4,
      txMbps: 3.2 + Math.cos(wave / 4) * 1.1,
    });
  }
  return points;
}

function demoCpu(server: ServerRecord, now: number): number | null {
  if (server.linkStatus !== "online") return null;
  const seed = [...server.name].reduce((sum, char) => sum + char.charCodeAt(0), 0);
  return Math.round(18 + ((Math.sin(now / 9000 + seed) + 1) / 2) * 28);
}

function formatMbps(value: number) {
  if (!Number.isFinite(value) || value < 0) return "Нет данных";
  if (value >= 100) return value.toFixed(0);
  if (value >= 10) return value.toFixed(1);
  return value.toFixed(2);
}

function Kpi({
  label,
  value,
  hint,
  icon,
}: {
  label: string;
  value: string;
  hint: string;
  icon: ReactNode;
}) {
  return (
    <article className="glass flex items-start gap-3 px-3 py-3">
      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-xl border border-line bg-accent/10 text-accent">
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block text-[11px] text-muted">{label}</span>
        <span className="mt-0.5 block truncate text-sm font-semibold text-ink">{value}</span>
        <span className="mt-0.5 block truncate text-[11px] text-muted">{hint}</span>
      </span>
    </article>
  );
}
