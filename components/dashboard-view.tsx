import Link from "next/link";
import { DeviceIcon, IconServer } from "@/components/icons";
import { EmptyState, RowMark, StatusBadge } from "@/components/ui";
import { formatBytes } from "@/lib/format";
import type { ConfigRecord, ServerRecord } from "@/lib/types";

export function DashboardView({
  servers,
  configs,
}: {
  servers: ServerRecord[];
  configs: ConfigRecord[];
}) {
  const defaultServer = servers.find((server) => server.isDefault);
  const online = servers.filter((server) => server.linkStatus === "online").length;
  const paired = servers.some((server) => server.paired);
  const activeConfigs = configs.filter((config) => config.status === "active").length;
  const totalRx = configs.reduce((sum, config) => sum + (config.rxBytes ?? 0), 0);
  const totalTx = configs.reduce((sum, config) => sum + (config.txBytes ?? 0), 0);
  const recent = configs.slice(0, 5);

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
          value={String(configs.length)}
          wash="bg-info/35"
          hint={
            configs.length === 0
              ? "Выпуск WireGuard через панель"
              : `Активных: ${activeConfigs}`
          }
        />
        <Stat
          label="Агенты"
          value={String(online)}
          wash="bg-ok/30"
          hint={
            paired
              ? "На связи те, от кого сообщение пришло за последние 45 секунд"
              : "Привязанных агентов нет"
          }
        />
        <Stat
          label="Трафик"
          value={configs.length === 0 ? "—" : formatBytes(totalRx + totalTx)}
          wash="bg-accent/25"
          hint={
            configs.length === 0
              ? "Счётчики появятся после peer-статистики"
              : `RX ${formatBytes(totalRx)} · TX ${formatBytes(totalTx)}`
          }
        />
      </section>

      <div className="grid gap-5 xl:grid-cols-5">
        <section className="glass px-5 py-5 xl:col-span-3">
          <h2 className="text-sm font-medium text-ink">Трафик</h2>
          <p className="mt-2 text-sm text-muted">
            Суммарный RX/TX берётся из heartbeat агента по известным peer. Неизвестные peer
            (например, созданные вручную до панели) не удаляются и в эту сумму не входят.
          </p>
          <p className="mt-4 text-3xl font-semibold tabular-nums text-ink">
            {configs.length === 0 ? "—" : formatBytes(totalRx + totalTx)}
          </p>
        </section>

        <section className="xl:col-span-2">
          <SectionTitle href="/servers" action="Все серверы">
            Серверы
          </SectionTitle>
          {servers.length === 0 ? (
            <EmptyState title="Серверов нет" text="В базе панели пока нет ни одной записи." />
          ) : (
            <ul className="flex flex-col gap-2">
              {servers.map((server) => (
                <li key={server.id} className="glass flex min-h-16 items-center gap-3 px-3 py-2.5">
                  <RowMark>
                    <IconServer className="h-4 w-4" />
                  </RowMark>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-ink">
                      {server.name}
                      {server.isDefault ? (
                        <span className="ml-2 text-xs font-medium text-info">по умолчанию</span>
                      ) : null}
                    </p>
                    <p className="truncate text-xs text-muted">
                      {server.location} · {server.endpoint}:{server.listenPort}
                    </p>
                  </div>
                  <StatusBadge status={server.linkStatus} />
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <section>
        <SectionTitle href="/configurations" action="Все конфигурации">
          Конфигурации
        </SectionTitle>
        {recent.length === 0 ? (
          <EmptyState
            title="Конфигураций нет"
            text="Создайте первую в разделе «Конфигурации»: ключи, VPN-IP и peer регистрируются через агент."
          />
        ) : (
          <ul className="flex flex-col gap-2">
            {recent.map((config) => (
              <li key={config.id} className="glass flex min-h-16 items-center gap-3 px-3 py-2.5">
                <RowMark>
                  <DeviceIcon name={config.deviceName} className="h-4 w-4" />
                </RowMark>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-ink">{config.deviceName}</p>
                  <p className="truncate text-xs text-muted">
                    {config.serverName} · {config.vpnIp}
                  </p>
                </div>
                <StatusBadge status={config.status} />
              </li>
            ))}
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
  wash,
}: {
  label: string;
  value: string;
  hint: string;
  wash: string;
}) {
  return (
    <article className="glass relative overflow-hidden px-5 py-5">
      <div className={`pointer-events-none absolute -top-12 -right-8 h-32 w-32 rounded-full blur-2xl ${wash}`} />
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
