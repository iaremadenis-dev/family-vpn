"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { useDemo } from "@/components/demo-provider";
import { StatusBadge } from "@/components/ui";
import { cx } from "@/lib/cx";
import { formatBytes, formatCount } from "@/lib/format";

export function DashboardView() {
  const { servers, configurations } = useDemo();
  const online = servers.filter((server) => server.status === "online").length;
  const degraded = servers.filter((server) => server.status === "degraded").length;
  const offline = servers.filter((server) => server.status === "offline").length;
  const active = configurations.filter((config) => config.status === "active").length;
  const revoked = configurations.length - active;
  const received = servers.reduce((sum, server) => sum + server.rxBytes, 0);
  const sent = servers.reduce((sum, server) => sum + server.txBytes, 0);
  const totalTraffic = received + sent;
  const defaultServer = servers.find((server) => server.isDefault);
  const series = demoDaily(totalTraffic);

  return (
    <div className="flex flex-col gap-5">
      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat
          label="Серверы"
          value={String(servers.length)}
          wash="bg-accent/35"
          hint={
            defaultServer
              ? `По умолчанию ${defaultServer.name}`
              : "Сервер по умолчанию не выбран"
          }
        />
        <Stat
          label="Конфигурации"
          value={String(configurations.length)}
          wash="bg-info/35"
          hint={`${formatCount(active, ["активная", "активные", "активных"])} · ${formatCount(revoked, ["отозвана", "отозваны", "отозвано"])}`}
        />
        <Stat
          label="Online / offline"
          wash="bg-ok/30"
          value={
            <span>
              <span className="text-ok">{online}</span>
              <span className="text-muted"> / </span>
              <span className={offline > 0 ? "text-bad" : "text-ink"}>{offline}</span>
            </span>
          }
          hint={
            servers.length === 0
              ? "Узлов нет"
              : degraded > 0
                ? formatCount(degraded, [
                    "нестабильный узел",
                    "нестабильных узла",
                    "нестабильных узлов",
                  ])
                : offline > 0
                  ? formatCount(offline, [
                      "сервер не в сети",
                      "сервера не в сети",
                      "серверов не в сети",
                    ])
                  : "Все узлы в сети"
          }
        />
        <Stat
          label="Трафик"
          value={formatBytes(totalTraffic)}
          wash="bg-accent/25"
          hint={`RX ${formatBytes(received)} · TX ${formatBytes(sent)}`}
        />
      </section>

      <div className="grid gap-5 xl:grid-cols-5">
        <section className="glass px-5 py-5 xl:col-span-3">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-sm font-medium text-ink">Трафик за 30 дней</h2>
              <p className="mt-1 text-xs text-muted">
                Демонстрационная кривая по примерным счётчикам. Опрос не выполняется.
              </p>
            </div>
            <p className="shrink-0 text-xs text-muted">30 дней</p>
          </div>
          <TrafficChart series={series} />
        </section>

        <section className="glass px-3 py-3 xl:col-span-2">
          <SectionTitle href="/servers" action="Все серверы">
            Серверы
          </SectionTitle>
          {servers.length === 0 ? (
            <p className="px-2 py-6 text-sm text-muted">
              Серверов в демонстрационном списке нет.
            </p>
          ) : (
            <ul className="space-y-1">
              {servers.map((server) => (
                <li
                  key={server.id}
                  className="grid gap-2 rounded-xl px-2 py-2.5 sm:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)_auto] sm:items-center"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-ink">
                      {server.name}
                      {server.isDefault ? (
                        <span className="ml-2 text-xs font-medium text-info">по умолчанию</span>
                      ) : null}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-muted">{server.location}</p>
                  </div>
                  <p className="truncate font-mono text-xs text-muted">
                    {server.endpoint}:{server.listenPort}
                  </p>
                  <StatusBadge status={server.status} />
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <section className="glass px-3 py-3">
        <SectionTitle href="/configurations" action="Все конфигурации">
          Конфигурации
        </SectionTitle>
        {configurations.length === 0 ? (
          <p className="px-2 py-6 text-sm text-muted">
            Конфигураций в демонстрационном списке нет.
          </p>
        ) : (
          <ul className="space-y-1">
            {configurations.map((config) => {
              const server = servers.find((item) => item.id === config.serverId);
              return (
                <li
                  key={config.id}
                  className="grid gap-2 rounded-xl px-2 py-2.5 sm:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)_minmax(0,0.8fr)_auto] sm:items-center"
                >
                  <p className="truncate font-medium text-ink">{config.name}</p>
                  <p className="truncate text-sm text-muted">
                    {server ? server.name : "сервер удалён"}
                  </p>
                  <p className="text-sm text-muted tabular-nums">
                    {formatBytes(config.rxBytes + config.txBytes)}
                  </p>
                  <StatusBadge status={config.status} />
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}

const CHART_DAYS = 30;

function demoDaily(total: number): number[] {
  const weights = Array.from({ length: CHART_DAYS }, (_, day) => {
    const wave = 0.62 + 0.28 * Math.sin(day / 3.4 + 0.6) + 0.12 * Math.sin(day / 1.35);
    const trend = 0.72 + day / CHART_DAYS;
    return Math.max(0.18, wave * trend);
  });
  const sum = weights.reduce((acc, weight) => acc + weight, 0);
  if (total <= 0 || sum === 0) return weights.map(() => 0);
  return weights.map((weight) => (total * weight) / sum);
}

function TrafficChart({ series }: { series: number[] }) {
  const width = 640;
  const height = 180;
  const padX = 8;
  const padY = 16;
  const max = Math.max(...series, 1);
  const step = (width - padX * 2) / (series.length - 1);
  const points = series.map((value, index) => {
    const x = Math.round(padX + index * step);
    const y = Math.round(padY + (1 - value / max) * (height - padY * 2));
    return [x, y] as const;
  });
  const line = points.map(([x, y]) => `${x},${y}`).join(" ");
  const area = `${padX},${height - 6} ${line} ${width - padX},${height - 6}`;

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="mt-4 h-48 w-full"
      role="img"
      aria-label="Демонстрационный график трафика за 30 дней"
    >
      <defs>
        <linearGradient id="traffic-fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.45" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
        </linearGradient>
      </defs>
      {[0.25, 0.5, 0.75].map((mark) => (
        <line
          key={mark}
          x1={padX}
          x2={width - padX}
          y1={padY + (1 - mark) * (height - padY * 2)}
          y2={padY + (1 - mark) * (height - padY * 2)}
          stroke="var(--line)"
          strokeDasharray="3 6"
        />
      ))}
      <polygon points={area} fill="url(#traffic-fill)" />
      <polyline
        points={line}
        fill="none"
        stroke="var(--accent)"
        strokeWidth="2.5"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
}

function Stat({
  label,
  value,
  hint,
  wash,
}: {
  label: string;
  value: ReactNode;
  hint: string;
  wash: string;
}) {
  return (
    <article className="glass relative overflow-hidden px-5 py-5">
      <div
        className={cx(
          "pointer-events-none absolute -top-12 -right-8 h-32 w-32 rounded-full blur-2xl",
          wash,
        )}
      />
      <p className="relative text-sm text-muted">{label}</p>
      <p className="relative mt-3 text-4xl font-semibold tracking-tight text-ink tabular-nums">
        {value}
      </p>
      <p className="relative mt-2 text-sm text-muted">{hint}</p>
    </article>
  );
}

function SectionTitle({
  href,
  action,
  children,
}: {
  href: string;
  action: string;
  children: string;
}) {
  return (
    <div className="flex items-center justify-between gap-3 px-2 py-2">
      <h2 className="text-sm font-medium text-ink">{children}</h2>
      <Link href={href} className="text-sm font-medium text-accent hover:text-ink">
        {action}
      </Link>
    </div>
  );
}
