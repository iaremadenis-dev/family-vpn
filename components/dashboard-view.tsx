"use client";

import Link from "next/link";
import { useDemo } from "@/components/demo-provider";
import { panelClass, StatusBadge } from "@/components/ui";
import { formatBytes, formatCount } from "@/lib/format";

export function DashboardView() {
  const { servers, configurations } = useDemo();
  const online = servers.filter((server) => server.status === "online").length;
  const degraded = servers.filter((server) => server.status === "degraded").length;
  const offline = servers.filter((server) => server.status === "offline").length;
  const active = configurations.filter((config) => config.status === "active").length;
  const received = servers.reduce((sum, server) => sum + server.rxBytes, 0);
  const sent = servers.reduce((sum, server) => sum + server.txBytes, 0);
  const defaultServer = servers.find((server) => server.isDefault);
  const peak = Math.max(
    ...servers.map((server) => server.rxBytes + server.txBytes),
    1,
  );

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Обзор</h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Сводка по серверам, конфигурациям и примерному трафику.
        </p>
      </div>

      <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat
          label="Серверы"
          value={String(servers.length)}
          hint={
            defaultServer
              ? `По умолчанию ${defaultServer.name}`
              : "Сервер по умолчанию не выбран"
          }
        />
        <Stat
          label="Конфигурации"
          value={String(configurations.length)}
          hint={`${active} активных`}
        />
        <Stat
          label="В сети"
          value={String(online)}
          hint={
            offline > 0
              ? `${formatCount(offline, ["сервер не в сети", "сервера не в сети", "серверов не в сети"])}`
              : "Нет серверов вне сети"
          }
        />
        <Stat
          label="Трафик"
          value={formatBytes(received + sent)}
          hint={`Принято ${formatBytes(received)} · отправлено ${formatBytes(sent)}`}
        />
      </section>

      <div className="grid gap-4 lg:grid-cols-2">
        <section className={panelClass}>
          <SectionTitle href="/servers" action="Все серверы">
            Состояние VPN-серверов
          </SectionTitle>
          {servers.length === 0 ? (
            <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
              Серверов в демонстрационном списке нет.
            </p>
          ) : (
            <ul className="mt-4 divide-y divide-zinc-200 dark:divide-zinc-800">
              {servers.map((server) => (
                <li
                  key={server.id}
                  className="flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
                >
                  <div className="min-w-0">
                    <p className="truncate font-medium">
                      {server.name}
                      <span className="font-normal text-zinc-500 dark:text-zinc-400">
                        {" "}
                        · {server.location}
                      </span>
                    </p>
                    <p className="mt-0.5 font-mono text-xs text-zinc-500 dark:text-zinc-400">
                      {server.endpoint}:{server.listenPort}
                    </p>
                  </div>
                  <StatusBadge status={server.status} />
                </li>
              ))}
            </ul>
          )}
          <dl className="mt-4 grid grid-cols-3 gap-3 border-t border-zinc-200 pt-4 text-sm dark:border-zinc-800">
            <Count label="В сети" value={online} />
            <Count label="Нестабильны" value={degraded} />
            <Count label="Не в сети" value={offline} />
          </dl>
        </section>

        <section className={panelClass}>
          <h2 className="text-sm font-semibold">Общая статистика трафика</h2>
          <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Сумма примерных счётчиков. Опрос серверов не выполняется.
          </p>
          <dl className="mt-4 grid grid-cols-2 gap-3">
            <Mini label="Принято" value={formatBytes(received)} />
            <Mini label="Отправлено" value={formatBytes(sent)} />
          </dl>
          {servers.length === 0 ? (
            <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
              Нет данных для сравнения.
            </p>
          ) : (
            <ul className="mt-5 space-y-3">
              {servers.map((server) => {
                const total = server.rxBytes + server.txBytes;
                const width =
                  total === 0 ? 0 : Math.max(4, Math.round((total / peak) * 100));
                return (
                  <li key={server.id}>
                    <div className="mb-1 flex items-center justify-between gap-3 text-sm">
                      <span className="truncate">{server.name}</span>
                      <span className="shrink-0 tabular-nums text-zinc-500 dark:text-zinc-400">
                        {formatBytes(total)}
                      </span>
                    </div>
                    <div className="h-1.5 overflow-hidden rounded-full bg-zinc-100 dark:bg-zinc-800">
                      <div
                        className="h-full rounded-full bg-teal-700 dark:bg-teal-400"
                        style={{ width: `${width}%` }}
                      />
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </section>
      </div>

      <section className={panelClass}>
        <SectionTitle href="/configurations" action="Все конфигурации">
          Конфигурации
        </SectionTitle>
        {configurations.length === 0 ? (
          <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
            Конфигураций в демонстрационном списке нет.
          </p>
        ) : (
          <ul className="mt-2 divide-y divide-zinc-200 dark:divide-zinc-800">
            {configurations.map((config) => {
              const server = servers.find((item) => item.id === config.serverId);
              return (
                <li
                  key={config.id}
                  className="flex items-center justify-between gap-3 py-3"
                >
                  <div className="min-w-0">
                    <p className="truncate font-medium">{config.name}</p>
                    <p className="mt-0.5 truncate text-sm text-zinc-500 dark:text-zinc-400">
                      {server ? server.name : "Сервер удалён"} ·{" "}
                      {formatBytes(config.rxBytes + config.txBytes)}
                    </p>
                  </div>
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
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint: string;
}) {
  return (
    <article className={panelClass}>
      <p className="text-sm text-zinc-500 dark:text-zinc-400">{label}</p>
      <p className="mt-2 text-3xl font-semibold tracking-tight tabular-nums">
        {value}
      </p>
      <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">{hint}</p>
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
    <div className="flex items-center justify-between gap-3">
      <h2 className="text-sm font-semibold">{children}</h2>
      <Link
        href={href}
        className="text-sm font-medium text-teal-800 hover:underline dark:text-teal-300"
      >
        {action}
      </Link>
    </div>
  );
}

function Count({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt className="text-zinc-500 dark:text-zinc-400">{label}</dt>
      <dd className="mt-1 text-lg font-semibold tabular-nums">{value}</dd>
    </div>
  );
}

function Mini({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg bg-zinc-50 px-3 py-2 dark:bg-zinc-950">
      <dt className="text-xs text-zinc-500 dark:text-zinc-400">{label}</dt>
      <dd className="mt-1 font-medium tabular-nums">{value}</dd>
    </div>
  );
}
