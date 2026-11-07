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
  const peak = Math.max(
    ...servers.map((server) => server.rxBytes + server.txBytes),
    1,
  );
  const rxShare = totalTraffic === 0 ? 0 : Math.round((received / totalTraffic) * 100);

  return (
    <div className="flex flex-col gap-4">
      <div className="border border-line bg-panel px-4 py-3">
        <p className="font-mono text-[10px] tracking-[0.18em] text-accent uppercase">
          dashboard
        </p>
        <h1 className="mt-1 text-xl font-semibold tracking-tight text-ink">Обзор</h1>
        <p className="mt-1 text-sm text-muted">
          Сводка по узлам WireGuard, конфигурациям и примерному трафику.
        </p>
      </div>

      <section className="grid grid-cols-1 gap-px border border-line bg-line sm:grid-cols-2 xl:grid-cols-4">
        <Stat
          index="01"
          label="Серверы"
          value={String(servers.length)}
          hint={
            defaultServer
              ? `По умолчанию ${defaultServer.name}`
              : "Сервер по умолчанию не выбран"
          }
        />
        <Stat
          index="02"
          label="Конфигурации"
          value={String(configurations.length)}
          hint={`${formatCount(active, ["активная", "активные", "активных"])} · ${formatCount(revoked, ["отозвана", "отозваны", "отозвано"])}`}
        />
        <Stat
          index="03"
          label="Online / offline"
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
          index="04"
          label="Трафик"
          value={formatBytes(totalTraffic)}
          hint={`RX ${formatBytes(received)} · TX ${formatBytes(sent)}`}
          meter={rxShare}
        />
      </section>

      <div className="grid gap-4 xl:grid-cols-5">
        <section className="border border-line bg-panel xl:col-span-3">
          <SectionTitle href="/servers" action="Все серверы">
            Узлы
          </SectionTitle>
          {servers.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">
              Серверов в демонстрационном списке нет.
            </p>
          ) : (
            <ul>
              {servers.map((server) => (
                <li
                  key={server.id}
                  className="grid gap-2 border-b border-line px-4 py-3 last:border-b-0 sm:grid-cols-[minmax(0,1.2fr)_minmax(0,1.1fr)_auto] sm:items-center"
                >
                  <div className="min-w-0">
                    <p className="truncate font-mono text-sm text-ink">
                      {server.name}
                      {server.isDefault ? (
                        <span className="ml-2 text-[10px] tracking-[0.12em] text-info uppercase">
                          default
                        </span>
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
          <dl className="grid grid-cols-3 border-t border-line">
            <Count label="В сети" value={online} tone="ok" />
            <Count label="Нестабильны" value={degraded} tone="warn" />
            <Count label="Не в сети" value={offline} tone="bad" />
          </dl>
        </section>

        <section className="border border-line bg-panel xl:col-span-2">
          <div className="border-b border-line px-4 py-2">
            <h2 className="font-mono text-[11px] tracking-[0.16em] text-muted uppercase">
              Трафик узлов
            </h2>
          </div>
          <div className="px-4 py-3">
            <p className="text-sm text-muted">
              Сумма примерных счётчиков. Опрос серверов не выполняется.
            </p>
            <dl className="mt-3 grid grid-cols-2 gap-px bg-line">
              <Mini label="RX" value={formatBytes(received)} />
              <Mini label="TX" value={formatBytes(sent)} />
            </dl>
            {servers.length === 0 ? (
              <p className="mt-4 text-sm text-muted">Нет данных для сравнения.</p>
            ) : (
              <ul className="mt-4 space-y-3">
                {servers.map((server) => {
                  const total = server.rxBytes + server.txBytes;
                  const width =
                    total === 0 ? 0 : Math.max(4, Math.round((total / peak) * 100));
                  return (
                    <li key={server.id}>
                      <div className="mb-1 flex items-center justify-between gap-3 font-mono text-xs">
                        <span className="truncate text-ink">{server.name}</span>
                        <span className="shrink-0 text-muted tabular-nums">
                          {formatBytes(total)}
                        </span>
                      </div>
                      <div className="h-1.5 bg-inset">
                        <div
                          className={cx(
                            "h-full",
                            server.status === "online"
                              ? "bg-accent"
                              : server.status === "degraded"
                                ? "bg-warn"
                                : "bg-muted",
                          )}
                          style={{ width: `${width}%` }}
                        />
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </section>
      </div>

      <section className="border border-line bg-panel">
        <SectionTitle href="/configurations" action="Все конфигурации">
          Конфигурации
        </SectionTitle>
        {configurations.length === 0 ? (
          <p className="px-4 py-6 text-sm text-muted">
            Конфигураций в демонстрационном списке нет.
          </p>
        ) : (
          <ul>
            {configurations.map((config) => {
              const server = servers.find((item) => item.id === config.serverId);
              return (
                <li
                  key={config.id}
                  className="grid gap-2 border-b border-line px-4 py-3 last:border-b-0 sm:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)_minmax(0,0.8fr)_auto] sm:items-center"
                >
                  <p className="truncate font-medium text-ink">{config.name}</p>
                  <p className="truncate font-mono text-xs text-muted">
                    {server ? server.name : "сервер удалён"}
                  </p>
                  <p className="font-mono text-xs text-muted tabular-nums">
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

function Stat({
  index,
  label,
  value,
  hint,
  tone = "ink",
  meter,
}: {
  index: string;
  label: string;
  value: ReactNode;
  hint: string;
  tone?: "ink" | "ok" | "warn" | "bad";
  meter?: number;
}) {
  const toneClass = {
    ink: "text-ink",
    ok: "text-ok",
    warn: "text-warn",
    bad: "text-bad",
  }[tone];

  return (
    <article className="bg-panel px-4 py-3">
      <div className="flex items-center justify-between gap-3">
        <p className="font-mono text-[10px] tracking-[0.16em] text-muted uppercase">
          {label}
        </p>
        <span className="font-mono text-[10px] text-accent">{index}</span>
      </div>
      <p className={cx("mt-2 font-mono text-2xl text-ink tabular-nums", toneClass)}>
        {value}
      </p>
      <p className="mt-1 text-xs text-muted">{hint}</p>
      {meter !== undefined ? (
        <div className="mt-2 flex h-1 bg-inset">
          <div className="bg-accent" style={{ width: `${meter}%` }} />
          <div className="bg-info" style={{ width: `${100 - meter}%` }} />
        </div>
      ) : null}
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
    <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-2">
      <h2 className="font-mono text-[11px] tracking-[0.16em] text-muted uppercase">
        {children}
      </h2>
      <Link
        href={href}
        className="font-mono text-[11px] tracking-[0.12em] text-accent uppercase hover:text-ink"
      >
        {action}
      </Link>
    </div>
  );
}

function Count({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: "ok" | "warn" | "bad";
}) {
  const toneClass = {
    ok: "text-ok",
    warn: "text-warn",
    bad: "text-bad",
  }[tone];

  return (
    <div className="border-r border-line px-4 py-3 last:border-r-0">
      <dt className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
        {label}
      </dt>
      <dd className={cx("mt-1 font-mono text-lg tabular-nums", toneClass)}>{value}</dd>
    </div>
  );
}

function Mini({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-inset px-3 py-2">
      <dt className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
        {label}
      </dt>
      <dd className="mt-1 font-mono text-sm text-ink tabular-nums">{value}</dd>
    </div>
  );
}
