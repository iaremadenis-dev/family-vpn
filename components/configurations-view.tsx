"use client";

import { useRouter } from "next/navigation";
import {
  useEffect,
  useId,
  useMemo,
  useState,
  useTransition,
  type ReactNode,
} from "react";
import {
  createConfigAction,
  deleteConfigAction,
  downloadConfigAction,
  revokeConfigAction,
} from "@/app/actions/configs";
import { DeviceIcon } from "@/components/icons";
import {
  Button,
  Dialog,
  Field,
  StatusBadge,
  inputClass,
} from "@/components/ui";
import { DEMO_UI_BLOCKED } from "@/lib/demo-ui";
import { cx } from "@/lib/cx";
import { formatBytes, formatDateTime } from "@/lib/format";
import type { ConfigRecord, ConfigStatus, ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "qr"; config: ConfigRecord }
  | { type: "status"; config: ConfigRecord }
  | { type: "revoke"; config: ConfigRecord }
  | { type: "delete"; config: ConfigRecord };

type StatusFilter = "all" | ConfigStatus;
type CountryCode = "NL" | "DE" | "US" | "SG";

const statusFilters: Array<{ value: StatusFilter; label: string }> = [
  { value: "all", label: "Все статусы" },
  { value: "active", label: "Активна" },
  { value: "pending", label: "Ожидает" },
  { value: "revoking", label: "Отзыв" },
  { value: "revoked", label: "Отозвана" },
  { value: "error", label: "Ошибка" },
];

export function ConfigurationsView({
  configs,
  servers,
  demo = false,
}: {
  configs: ConfigRecord[];
  servers: ServerRecord[];
  demo?: boolean;
}) {
  const router = useRouter();
  const searchId = useId();
  const statusId = useId();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const [message, setMessage] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [pending, startTransition] = useTransition();
  const onlineServers = servers.filter(
    (server) => server.linkStatus === "online" && server.paired && !server.agentRevoked,
  );
  const close = () => setDialog({ type: "closed" });
  const waiting = configs.some(
    (config) => config.status === "pending" || config.status === "revoking",
  );

  useEffect(() => {
    if (demo || !waiting) return;
    const timer = window.setInterval(() => router.refresh(), 5000);
    return () => window.clearInterval(timer);
  }, [demo, waiting, router]);

  const serversById = useMemo(() => new Map(servers.map((server) => [server.id, server])), [servers]);
  const summary = useMemo(() => summarize(configs), [configs]);
  const visible = useMemo(
    () => filterConfigs(configs, query, statusFilter),
    [configs, query, statusFilter],
  );

  function run(action: () => Promise<{ error: string | null }>) {
    if (demo) {
      setMessage(DEMO_UI_BLOCKED);
      return;
    }
    setMessage(null);
    startTransition(async () => {
      const result = await action();
      if (result.error) {
        setMessage(result.error);
        return;
      }
      close();
      router.refresh();
    });
  }

  function download(config: ConfigRecord) {
    if (demo) {
      setMessage(DEMO_UI_BLOCKED);
      return;
    }
    setMessage(null);
    startTransition(async () => {
      const result = await downloadConfigAction(config.id);
      if (result.error || !result.content || !result.fileName) {
        setMessage(result.error ?? "Не удалось скачать конфигурацию.");
        return;
      }
      const blob = new Blob([result.content], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = result.fileName;
      anchor.click();
      URL.revokeObjectURL(url);
    });
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="max-w-3xl">
          <h2 className="text-lg font-semibold tracking-tight text-ink">Конфигурации</h2>
          {demo ? <p className="mt-1 text-xs font-medium text-warn">Демо-данные</p> : null}
          <p className="mt-1 text-sm text-muted">
            Каждая строка — отдельное устройство: ключи, VPN-IP, peer на выбранном сервере и
            .conf/QR только через панель.
          </p>
          {onlineServers.length === 0 ? (
            <p className="mt-2 text-sm text-muted">
              Для выпуска нужен сервер со статусом Online и агентом v0.4.0+.
            </p>
          ) : null}
        </div>
        <Button
          onClick={() => setDialog({ type: "create" })}
          disabled={pending || onlineServers.length === 0}
        >
          Добавить конфигурацию
        </Button>
      </div>

      {message && dialog.type === "closed" ? <p className="text-sm text-bad">{message}</p> : null}

      <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Всего" value={String(summary.total)} hint="конфигураций" icon={<IconStack />} />
        <Kpi
          label="Активные"
          value={String(summary.active)}
          hint="со статусом «Активна»"
          icon={<IconPulse />}
        />
        <Kpi
          label="Рукопожатие"
          value={summary.latestHandshake ? formatDateTime(summary.latestHandshake) : "Нет данных"}
          hint="последнее от WireGuard"
          icon={<IconHandshake />}
        />
        <Kpi
          label="Трафик"
          value={summary.traffic ?? "Нет данных"}
          hint="сумма RX / TX"
          icon={<IconTraffic />}
        />
      </section>

      <section className="glass overflow-hidden">
        <div className="flex flex-col gap-3 border-b border-line px-3 py-3 sm:flex-row sm:items-end sm:justify-between md:px-4">
          <h3 className="text-sm font-medium text-ink">Конфигурации устройств</h3>
          <div className="flex flex-col gap-2 sm:flex-row">
            <div className="sm:w-64">
              <label htmlFor={searchId} className="mb-1 block text-[11px] text-muted">
                Поиск
              </label>
              <input
                id={searchId}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Устройство, IP или сервер"
                className={inputClass}
              />
            </div>
            <div className="sm:w-40">
              <label htmlFor={statusId} className="mb-1 block text-[11px] text-muted">
                Статус
              </label>
              <select
                id={statusId}
                value={statusFilter}
                onChange={(event) => setStatusFilter(event.target.value as StatusFilter)}
                className={inputClass}
              >
                {statusFilters.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </div>
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[980px] border-collapse text-left text-sm">
            <thead>
              <tr className="border-b border-line text-[11px] tracking-wide text-muted uppercase">
                <th className="px-3 py-2 font-medium md:px-4">Устройство</th>
                <th className="px-3 py-2 font-medium">Сервер</th>
                <th className="px-3 py-2 font-medium">VPN IP</th>
                <th className="px-3 py-2 font-medium">Статус</th>
                <th className="px-3 py-2 font-medium">Последнее рукопожатие</th>
                <th className="px-3 py-2 font-medium">Трафик RX/TX</th>
                <th className="px-3 py-2 text-right font-medium md:px-4">Действия</th>
              </tr>
            </thead>
            <tbody>
              {visible.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-sm text-muted">
                    {configs.length === 0
                      ? "Конфигураций пока нет. Создайте первую запись для устройства: панель сгенерирует ключи, выделит IP и поставит peer через агент."
                      : "Нет данных"}
                  </td>
                </tr>
              ) : (
                visible.map((config) => {
                  const locked = config.status === "revoked" || config.status === "revoking";
                  return (
                    <tr key={config.id} className="border-b border-line/80 last:border-b-0">
                      <td className="px-3 py-2 md:px-4">
                        <span className="flex min-w-0 items-center gap-2">
                          <span className="grid h-7 w-7 shrink-0 place-items-center rounded-lg border border-line bg-inset text-accent">
                            <DeviceIcon name={config.deviceName} className="h-3.5 w-3.5" />
                          </span>
                          <span className="truncate font-medium text-ink">{config.deviceName}</span>
                        </span>
                      </td>
                      <td className="px-3 py-2">
                        <ServerCell config={config} server={serversById.get(config.serverId)} />
                      </td>
                      <td className="px-3 py-2 font-mono text-xs text-ink">{config.vpnIp}</td>
                      <td className="px-3 py-2">
                        <StatusBadge status={config.status} />
                      </td>
                      <td className="px-3 py-2 text-muted">
                        {config.lastHandshakeAt
                          ? formatDateTime(config.lastHandshakeAt)
                          : "Нет данных"}
                      </td>
                      <td className="px-3 py-2">
                        <TrafficCell rx={config.rxBytes} tx={config.txBytes} />
                      </td>
                      <td className="px-3 py-2 md:px-4">
                        <div className="flex flex-nowrap justify-end gap-1">
                          <Button
                            size="sm"
                            variant="secondary"
                            disabled={pending || locked}
                            aria-label="Скачать .conf"
                            onClick={() => download(config)}
                          >
                            .conf
                          </Button>
                          <Button
                            size="sm"
                            variant="secondary"
                            disabled={pending || locked}
                            aria-label="Показать QR-код"
                            onClick={() => {
                              if (demo) {
                                setMessage(DEMO_UI_BLOCKED);
                                return;
                              }
                              setDialog({ type: "qr", config });
                            }}
                          >
                            QR
                          </Button>
                          <Button
                            size="sm"
                            variant="secondary"
                            aria-label="Статус"
                            onClick={() => setDialog({ type: "status", config })}
                          >
                            Статус
                          </Button>
                          {config.status !== "revoked" && config.status !== "revoking" ? (
                            <Button
                              size="sm"
                              variant="danger"
                              aria-label="Отозвать"
                              onClick={() => setDialog({ type: "revoke", config })}
                            >
                              Отозвать
                            </Button>
                          ) : null}
                          <Button
                            size="sm"
                            variant="danger"
                            aria-label="Удалить"
                            onClick={() => setDialog({ type: "delete", config })}
                          >
                            Удалить
                          </Button>
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>

      <Dialog open={dialog.type === "create"} title="Создать конфигурацию" onClose={close}>
        {dialog.type === "create" ? (
          <CreateForm
            servers={onlineServers}
            pending={pending}
            serverError={message}
            onClose={close}
            onSubmit={(input) => run(() => createConfigAction(input))}
          />
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "qr"} title="QR-код" onClose={close}>
        {dialog.type === "qr" ? (
          <div className="flex flex-col items-center gap-3">
            <p className="text-sm text-muted">
              Отсканируйте в приложении WireGuard для «{dialog.config.deviceName}».
            </p>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={`/api/configs/${dialog.config.id}/qr`}
              alt={`QR для ${dialog.config.deviceName}`}
              className="rounded-xl bg-white p-3"
              width={320}
              height={320}
            />
          </div>
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "status"} title="Статус конфигурации" onClose={close}>
        {dialog.type === "status" ? (
          <dl className="grid gap-3 text-sm">
            <Info label="Устройство" value={dialog.config.deviceName} />
            <Info label="Сервер" value={`${dialog.config.serverName} · ${dialog.config.endpoint}`} />
            <Info label="VPN-IP" value={dialog.config.vpnIp} mono />
            <Info label="Публичный ключ" value={dialog.config.clientPublicKey} mono />
            <Info label="Статус" value={dialog.config.status} />
            <Info
              label="Последний handshake"
              value={
                dialog.config.lastHandshakeAt
                  ? formatDateTime(dialog.config.lastHandshakeAt)
                  : "Нет данных"
              }
            />
            <Info label="Трафик" value={trafficLabel(dialog.config.rxBytes, dialog.config.txBytes)} />
            {dialog.config.lastError ? (
              <Info label="Ошибка" value={dialog.config.lastError} />
            ) : null}
            <Info label="Создана" value={formatDateTime(dialog.config.createdAt)} />
          </dl>
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "revoke"} title="Отозвать доступ" onClose={close}>
        {dialog.type === "revoke" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-ink">
              Удалить peer «{dialog.config.deviceName}» с сервера {dialog.config.serverName}? Файл
              конфигурации на устройстве перестанет работать после успешного отзыва.
            </p>
            {message ? <p className="text-sm text-bad">{message}</p> : null}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="secondary" onClick={close}>
                Отмена
              </Button>
              <Button
                variant="danger"
                disabled={pending}
                onClick={() => run(() => revokeConfigAction(dialog.config.id))}
              >
                Отозвать
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "delete"} title="Удалить конфигурацию" onClose={close}>
        {dialog.type === "delete" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-ink">
              {dialog.config.status === "revoked"
                ? `Удалить запись «${dialog.config.deviceName}» из базы?`
                : `Сначала peer будет отозван на сервере. После статуса «Отозвана» удалите запись повторно.`}
            </p>
            {message ? <p className="text-sm text-bad">{message}</p> : null}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="secondary" onClick={close}>
                Отмена
              </Button>
              <Button
                variant="danger"
                disabled={pending}
                onClick={() => run(() => deleteConfigAction(dialog.config.id))}
              >
                Удалить
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>
    </div>
  );
}

function ServerCell({ config, server }: { config: ConfigRecord; server: ServerRecord | undefined }) {
  const flag = countryFlag(server?.location, config.serverName);
  const ip = publicHost(server?.endpoint, config.endpoint);
  return (
    <span className="flex min-w-0 items-center gap-2">
      <CountryFlag code={flag} />
      <span className="min-w-0">
        <span className="block truncate font-medium text-ink">{config.serverName || "Нет данных"}</span>
        <span className="block truncate font-mono text-[11px] text-muted">{ip}</span>
      </span>
    </span>
  );
}

function TrafficCell({ rx, tx }: { rx: number | null; tx: number | null }) {
  if (rx == null && tx == null) {
    return <span className="text-xs text-muted/75">Нет данных</span>;
  }
  return (
    <span className="flex flex-col gap-1">
      <TrafficLine direction="rx" value={rx} />
      <TrafficLine direction="tx" value={tx} />
    </span>
  );
}

function TrafficLine({ direction, value }: { direction: "rx" | "tx"; value: number | null }) {
  const incoming = direction === "rx";
  return (
    <span className="inline-flex items-center gap-1.5 text-[11px] leading-none">
      <span
        className={cx(
          "grid h-4 w-4 place-items-center rounded-md border",
          incoming ? "border-info/30 bg-info/10 text-info" : "border-warn/30 bg-warn/10 text-warn",
        )}
      >
        <svg viewBox="0 0 12 12" className="h-2.5 w-2.5" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden>
          <path
            d={incoming ? "M6 2.5v7M3.5 7.2 6 9.5 8.5 7.2" : "M6 9.5v-7M3.5 4.8 6 2.5 8.5 4.8"}
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </span>
      <span className="w-5 text-muted">{incoming ? "RX" : "TX"}</span>
      <span className={value == null ? "text-muted/75" : "font-medium text-ink"}>
        {value == null ? "Нет данных" : formatBytes(value)}
      </span>
    </span>
  );
}

function CountryFlag({ code }: { code: CountryCode | null }) {
  const graphic =
    code === "NL" ? <FlagNl /> : code === "DE" ? <FlagDe /> : code === "US" ? <FlagUs /> : code === "SG" ? <FlagSg /> : <FlagGlobe />;
  return <span className="grid h-5 w-5 shrink-0 place-items-center">{graphic}</span>;
}

function flagFrame(children: ReactNode) {
  return (
    <svg viewBox="0 0 60 40" className="h-[18px] w-5 overflow-hidden rounded-[3px] ring-1 ring-line" aria-hidden>
      {children}
    </svg>
  );
}

function FlagNl() {
  return flagFrame(
    <>
      <rect width="60" height="13.4" fill="#AE1C28" />
      <rect y="13.3" width="60" height="13.4" fill="#FFFFFF" />
      <rect y="26.6" width="60" height="13.4" fill="#21468B" />
    </>,
  );
}

function FlagDe() {
  return flagFrame(
    <>
      <rect width="60" height="13.4" fill="#000000" />
      <rect y="13.3" width="60" height="13.4" fill="#DD0000" />
      <rect y="26.6" width="60" height="13.4" fill="#FFCE00" />
    </>,
  );
}

function FlagUs() {
  return flagFrame(
    <>
      <rect width="60" height="40" fill="#BF0A30" />
      <rect y="3.1" width="60" height="3.1" fill="#FFFFFF" />
      <rect y="9.3" width="60" height="3.1" fill="#FFFFFF" />
      <rect y="15.5" width="60" height="3.1" fill="#FFFFFF" />
      <rect y="21.7" width="60" height="3.1" fill="#FFFFFF" />
      <rect y="27.9" width="60" height="3.1" fill="#FFFFFF" />
      <rect y="34.1" width="60" height="3.1" fill="#FFFFFF" />
      <rect width="26" height="21.5" fill="#002868" />
    </>,
  );
}

function FlagSg() {
  return flagFrame(
    <>
      <rect width="60" height="20" fill="#EF3340" />
      <rect y="20" width="60" height="20" fill="#FFFFFF" />
      <circle cx="16" cy="20" r="6" fill="#FFFFFF" />
      <circle cx="18.2" cy="20" r="4.6" fill="#EF3340" />
    </>,
  );
}

function FlagGlobe() {
  return (
    <svg viewBox="0 0 20 20" className="h-5 w-5 text-accent" aria-hidden>
      <circle cx="10" cy="10" r="7.2" fill="none" stroke="currentColor" strokeWidth="1.2" />
      <ellipse cx="10" cy="10" rx="3.1" ry="7.2" fill="none" stroke="currentColor" strokeWidth="1" />
      <path d="M2.8 10h14.4M4.2 6.4h11.6M4.2 13.6h11.6" fill="none" stroke="currentColor" strokeWidth="1" />
    </svg>
  );
}

const countryFlags: Record<string, CountryCode> = {
  нидерланды: "NL",
  netherlands: "NL",
  holland: "NL",
  амстердам: "NL",
  германия: "DE",
  germany: "DE",
  франкфурт: "DE",
  сша: "US",
  usa: "US",
  "united states": "US",
  сингапур: "SG",
  singapore: "SG",
};

const prefixFlags: Record<string, CountryCode> = {
  NL: "NL",
  DE: "DE",
  US: "US",
  SG: "SG",
};

function countryFlag(location: string | undefined, serverName: string): CountryCode | null {
  const fromLocation = countryFlags[location?.trim().toLowerCase() ?? ""];
  if (fromLocation) return fromLocation;
  const prefix = /^([A-Za-z]{2})-/.exec(serverName.trim())?.[1]?.toUpperCase();
  return (prefix && prefixFlags[prefix]) || null;
}

function publicHost(serverEndpoint: string | undefined, configEndpoint: string) {
  const host = serverEndpoint?.trim() || configEndpoint.split(":")[0]?.trim() || "";
  return host || "Нет данных";
}

function summarize(configs: ConfigRecord[]) {
  const active = configs.filter((config) => config.status === "active").length;
  let latestHandshake: string | null = null;
  let latestTime = Number.NEGATIVE_INFINITY;
  let rx = 0;
  let tx = 0;
  let hasTraffic = false;
  for (const config of configs) {
    if (config.lastHandshakeAt) {
      const time = Date.parse(config.lastHandshakeAt);
      if (Number.isFinite(time) && time >= latestTime) {
        latestTime = time;
        latestHandshake = config.lastHandshakeAt;
      }
    }
    if (config.rxBytes != null || config.txBytes != null) {
      hasTraffic = true;
      rx += config.rxBytes ?? 0;
      tx += config.txBytes ?? 0;
    }
  }
  return {
    total: configs.length,
    active,
    latestHandshake,
    traffic: hasTraffic ? `RX ${formatBytes(rx)} · TX ${formatBytes(tx)}` : null,
  };
}

function filterConfigs(configs: ConfigRecord[], query: string, status: StatusFilter) {
  const needle = query.trim().toLowerCase();
  return configs.filter((config) => {
    if (status !== "all" && config.status !== status) return false;
    if (!needle) return true;
    return [config.deviceName, config.vpnIp, config.serverName]
      .join(" ")
      .toLowerCase()
      .includes(needle);
  });
}

function trafficLabel(rx: number | null, tx: number | null) {
  if (rx == null && tx == null) return "Нет данных";
  const received = rx == null ? "Нет данных" : formatBytes(rx);
  const sent = tx == null ? "Нет данных" : formatBytes(tx);
  return `RX ${received} · TX ${sent}`;
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

function IconStack() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <rect x="4" y="4" width="16" height="6" rx="1.5" />
      <rect x="4" y="14" width="16" height="6" rx="1.5" />
    </svg>
  );
}

function IconPulse() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M3 12h4l2-5 4 10 2-5h6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function IconHandshake() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <circle cx="12" cy="12" r="7" />
      <path d="M12 8v4l3 2" strokeLinecap="round" />
    </svg>
  );
}

function IconTraffic() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M7 7h10M12 7v10M9 14l3 3 3-3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function CreateForm({
  servers,
  pending,
  serverError,
  onClose,
  onSubmit,
}: {
  servers: ServerRecord[];
  pending: boolean;
  serverError: string | null;
  onClose: () => void;
  onSubmit: (input: { deviceName: string; serverId: string }) => void;
}) {
  const deviceId = useId();
  const serverId = useId();
  const defaultServer = servers.find((server) => server.isDefault) ?? servers[0];
  const [deviceName, setDeviceName] = useState("");
  const [selectedServer, setSelectedServer] = useState(defaultServer?.id ?? "");

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit({ deviceName, serverId: selectedServer });
      }}
    >
      <Field id={deviceId} label="Название устройства">
        <input
          id={deviceId}
          className={inputClass}
          value={deviceName}
          onChange={(event) => setDeviceName(event.target.value)}
          placeholder="iPhone Анны"
          maxLength={64}
          required
          autoFocus
        />
      </Field>
      <Field id={serverId} label="Сервер" hint="Только серверы Online с рабочим агентом.">
        <select
          id={serverId}
          className={inputClass}
          value={selectedServer}
          onChange={(event) => setSelectedServer(event.target.value)}
          required
        >
          {servers.map((server) => (
            <option key={server.id} value={server.id}>
              {server.name} · {server.location}
            </option>
          ))}
        </select>
      </Field>
      {serverError ? <p className="text-sm text-bad">{serverError}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" type="button" onClick={onClose}>
          Отмена
        </Button>
        <Button type="submit" disabled={pending || !selectedServer}>
          Создать
        </Button>
      </div>
    </form>
  );
}

function Info({
  label,
  value,
  mono,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className={cx("mt-1 break-all text-ink", mono && "font-mono text-xs")}>{value}</dd>
    </div>
  );
}
