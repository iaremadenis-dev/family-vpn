"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useMemo, useState, useTransition, type ReactNode } from "react";
import {
  claimServerAction,
  deleteServerAction,
  refreshServerAction,
  revokeAgentAction,
  setDefaultServerAction,
  updateServerAction,
} from "@/app/actions/servers";
import { IconServer } from "@/components/icons";
import { Button, Dialog, Field, StatusBadge, inputClass } from "@/components/ui";
import { DEMO_UI_BLOCKED } from "@/lib/demo-ui";
import { cx } from "@/lib/cx";
import { formatDateTime } from "@/lib/format";
import type { ClaimedServerSummary, ConfigRecord, InstallCommandInfo, LinkStatus, ServerRecord } from "@/lib/types";

type StatusFilter = "all" | LinkStatus;
type CountryCode = "NL" | "DE" | "US" | "SG";

const statusFilters: Array<{ value: StatusFilter; label: string }> = [
  { value: "all", label: "Все статусы" },
  { value: "online", label: "В сети" },
  { value: "degraded", label: "Нестабилен" },
  { value: "offline", label: "Не в сети" },
  { value: "unchecked", label: "Не подключён" },
];

type DialogState =
  | { type: "closed" }
  | { type: "pair" }
  | { type: "edit"; server: ServerRecord }
  | { type: "delete"; server: ServerRecord }
  | { type: "revoke"; server: ServerRecord }
  | { type: "status"; server: ServerRecord };

export function ServersView({
  servers,
  configs,
  install,
  demo = false,
}: {
  servers: ServerRecord[];
  configs: ConfigRecord[];
  install: InstallCommandInfo;
  demo?: boolean;
}) {
  const router = useRouter();
  const searchId = useId();
  const statusId = useId();
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [openId, setOpenId] = useState<string | null>(null);
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const close = () => setDialog({ type: "closed" });
  const configCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const config of configs) counts.set(config.serverId, (counts.get(config.serverId) ?? 0) + 1);
    return counts;
  }, [configs]);
  const visible = useMemo(
    () => filterServers(servers, query, statusFilter),
    [servers, query, statusFilter],
  );
  const online = servers.filter((server) => server.linkStatus === "online").length;
  const offline = servers.filter((server) => server.linkStatus === "offline").length;
  const paired = servers.filter((server) => server.paired && !server.agentRevoked).length;

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

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="max-w-3xl">
          <h2 className="text-lg font-semibold tracking-tight text-ink">Серверы</h2>
          {demo ? <p className="mt-1 text-xs font-medium text-warn">Демо-данные</p> : null}
          <p className="mt-1 text-sm text-muted">
            Одна команда на чистом VPS, затем код привязки в панели. Статус берётся только из сообщений агента.
          </p>
        </div>
        <Button onClick={() => setDialog({ type: "pair" })} disabled={pending}>
          Добавить сервер
        </Button>
      </div>

      {message && dialog.type === "closed" ? <p className="text-sm text-bad">{message}</p> : null}

      <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi label="Всего VPN-серверов" value={String(servers.length)} hint="в панели" icon={<IconServer className="h-5 w-5" />} />
        <Kpi label="Серверы в сети" value={String(online)} hint="статус «В сети»" icon={<IconPulse />} />
        <Kpi label="Серверы не в сети" value={String(offline)} hint="статус «Не в сети»" icon={<IconOffline />} />
        <Kpi label="Привязанные агенты" value={String(paired)} hint="доступ не отозван" icon={<IconLink />} />
      </section>

      <section className="glass overflow-hidden">
        <div className="flex flex-col gap-3 border-b border-line px-3 py-3 sm:flex-row sm:items-end sm:justify-between md:px-4">
          <h3 className="text-sm font-medium text-ink">VPN-серверы</h3>
          <div className="flex flex-col gap-2 sm:flex-row">
            <div className="sm:w-64">
              <label htmlFor={searchId} className="mb-1 block text-[11px] text-muted">
                Поиск
              </label>
              <input
                id={searchId}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Название, страна или IP"
                className={inputClass}
              />
            </div>
            <div className="sm:w-44">
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
          <table className="w-full border-collapse text-left text-sm">
            <thead>
              <tr className="border-b border-line text-[11px] tracking-wide text-muted uppercase">
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">Сервер</th>
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">Публичный IP</th>
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">Статус</th>
                <th className="px-2.5 py-2 text-center font-medium whitespace-nowrap">Конфигурации</th>
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">Версия агента</th>
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">Последняя связь</th>
                <th className="px-2.5 py-2 font-medium whitespace-nowrap">WireGuard-порт</th>
                <th className="px-2.5 py-2 text-right font-medium whitespace-nowrap">Действия</th>
              </tr>
            </thead>
            <tbody>
              {visible.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-4 py-8 text-center text-sm text-muted">
                    {servers.length === 0
                      ? "Серверов в базе нет. Запустите установщик на VPS, затем введите название и код привязки. Панель сама на сервер по SSH не заходит."
                      : "Нет данных"}
                  </td>
                </tr>
              ) : (
                visible.map((server) => (
                  <ServerRows
                    key={server.id}
                    server={server}
                    configCount={configCounts.get(server.id) ?? 0}
                    open={openId === server.id}
                    pending={pending}
                    onToggle={() => setOpenId(openId === server.id ? null : server.id)}
                    onStatus={() => setDialog({ type: "status", server })}
                    onEdit={() => setDialog({ type: "edit", server })}
                    onDefault={() => run(() => setDefaultServerAction(server.id))}
                    onRevoke={() => setDialog({ type: "revoke", server })}
                    onDelete={() => setDialog({ type: "delete", server })}
                  />
                ))
              )}
            </tbody>
          </table>
        </div>
      </section>

      <Dialog open={dialog.type === "pair"} title="Добавить сервер" onClose={close}>
        {dialog.type === "pair" ? (
          <AddServerWizard
            install={install}
            pending={pending}
            serverError={message}
            onClose={close}
            onClaim={(input) =>
              new Promise((resolve) => {
                if (demo) {
                  setMessage(DEMO_UI_BLOCKED);
                  resolve({ error: DEMO_UI_BLOCKED });
                  return;
                }
                setMessage(null);
                startTransition(async () => {
                  const result = await claimServerAction(input);
                  if (result.error) {
                    setMessage(result.error);
                    resolve({ error: result.error });
                    return;
                  }
                  router.refresh();
                  resolve({ error: null, claimed: result.claimed });
                });
              })
            }
            onFinished={() => {
              close();
              router.refresh();
            }}
          />
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "edit"} title="Изменить сервер" onClose={close}>
        {dialog.type === "edit" ? (
          <EditForm
            key={dialog.server.id}
            server={dialog.server}
            pending={pending}
            serverError={message}
            onClose={close}
            onSubmit={(input) => run(() => updateServerAction(dialog.server.id, input))}
          />
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "revoke"} title="Отвязать агента" onClose={close}>
        {dialog.type === "revoke" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-ink">
              Отозвать доступ агента «{dialog.server.name}»? Сервер останется в панели, но
              следующие сообщения этого агента будут отклонены. Файлы WireGuard на VPS не
              изменяются.
            </p>
            {message ? <p className="text-sm text-bad">{message}</p> : null}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="secondary" onClick={close}>
                Отмена
              </Button>
              <Button
                variant="danger"
                disabled={pending}
                onClick={() => run(() => revokeAgentAction(dialog.server.id))}
              >
                Отозвать доступ
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "delete"} title="Удалить сервер" onClose={close}>
        {dialog.type === "delete" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-ink">
              Удалить «{dialog.server.name}» из базы панели? Доступ агента тоже будет
              закрыт. Файлы на VPS не изменяются.
            </p>
            {message ? <p className="text-sm text-bad">{message}</p> : null}
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="secondary" onClick={close}>
                Отмена
              </Button>
              <Button
                variant="danger"
                disabled={pending}
                onClick={() => run(() => deleteServerAction(dialog.server.id))}
              >
                Удалить из панели
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "status"} title="Состояние агента" onClose={close}>
        {dialog.type === "status" ? <StatusDetails server={dialog.server} onClose={close} /> : null}
      </Dialog>
    </div>
  );
}

function ServerRows({
  server,
  configCount,
  open,
  pending,
  onToggle,
  onStatus,
  onEdit,
  onDefault,
  onRevoke,
  onDelete,
}: {
  server: ServerRecord;
  configCount: number;
  open: boolean;
  pending: boolean;
  onToggle: () => void;
  onStatus: () => void;
  onEdit: () => void;
  onDefault: () => void;
  onRevoke: () => void;
  onDelete: () => void;
}) {
  return (
    <>
      <tr className="border-b border-line/80 last:border-b-0">
        <td className="px-2.5 py-2.5">
          <span className="flex items-start gap-2.5">
            <span className="mt-0.5">
              <CountryFlag code={countryFlag(server.location, server.name)} />
            </span>
            <span>
              <span className="block font-medium whitespace-nowrap text-ink">{server.name || "Нет данных"}</span>
              <span className="mt-0.5 block text-[11px] whitespace-nowrap text-muted">
                {server.location.trim() || "Нет данных"}
              </span>
              {server.isDefault ? (
                <span className="mt-1 inline-flex rounded-full bg-info/15 px-1.5 py-0.5 text-[10px] font-medium whitespace-nowrap text-info">
                  по умолчанию
                </span>
              ) : null}
              <button
                type="button"
                className="mt-0.5 block text-xs whitespace-nowrap text-accent hover:text-ink"
                aria-expanded={open}
                onClick={onToggle}
              >
                {open ? "Скрыть" : "Подробнее"}
              </button>
            </span>
          </span>
        </td>
        <td className="px-2.5 py-2.5 font-mono text-xs whitespace-nowrap tabular-nums text-ink">{shown(server.endpoint)}</td>
        <td className="px-2.5 py-2.5 whitespace-nowrap">
          <StatusBadge status={server.linkStatus} />
        </td>
        <td className="px-2.5 py-2.5 text-center font-medium tabular-nums text-ink">{configCount}</td>
        <td className="px-2.5 py-2.5 whitespace-nowrap tabular-nums text-muted">{agentVersionLabel(server)}</td>
        <td className="px-2.5 py-2.5 whitespace-nowrap tabular-nums text-muted">
          {server.lastSeenAt ? formatDateTime(server.lastSeenAt) : "Нет данных"}
        </td>
        <td className="px-2.5 py-2.5 font-mono text-xs whitespace-nowrap tabular-nums text-ink">
          {Number.isFinite(server.listenPort) ? `${server.listenPort} UDP` : "Нет данных"}
        </td>
        <td className="py-2.5 pr-2 pl-2.5 whitespace-nowrap">
          <div className="flex flex-nowrap items-center justify-end gap-1">
            <Button size="sm" variant="secondary" className="shrink-0 whitespace-nowrap" onClick={onStatus}>
              Статус
            </Button>
            <Button size="sm" variant="secondary" className="shrink-0 whitespace-nowrap" onClick={onEdit}>
              Изменить
            </Button>
            <Button
              size="sm"
              variant="secondary"
              className="shrink-0 whitespace-nowrap"
              title="Сделать сервером по умолчанию"
              disabled={server.isDefault || pending}
              onClick={onDefault}
            >
              Основной
            </Button>
            {server.paired && !server.agentRevoked ? (
              <Button size="sm" variant="danger" className="shrink-0 whitespace-nowrap" onClick={onRevoke}>
                Отвязать
              </Button>
            ) : null}
            <Button size="sm" variant="danger" className="shrink-0 whitespace-nowrap" onClick={onDelete}>
              Удалить
            </Button>
          </div>
        </td>
      </tr>
      {open ? (
        <tr className="border-b border-line/80">
          <td colSpan={8} className="px-3 py-3 md:px-4">
            <dl className="grid gap-2 rounded-2xl border border-line bg-panel/70 p-3 sm:grid-cols-2 xl:grid-cols-4">
              <Fact label="Название" value={shown(server.name)} />
              <Fact label="Расположение" value={shown(server.location)} />
              <Fact label="Endpoint" value={shown(server.endpoint)} mono />
              <Fact label="WireGuard-порт" value={Number.isFinite(server.listenPort) ? `${server.listenPort} UDP` : "Нет данных"} mono />
              <Fact label="VPN-подсеть" value={shown(server.vpnSubnet)} mono />
              <Fact label="Версия агента" value={agentVersionLabel(server)} />
              <Fact label="Последняя связь" value={server.lastSeenAt ? formatDateTime(server.lastSeenAt) : "Нет данных"} />
              <Fact label="Агент привязан" value={server.paired ? "да" : "нет"} />
              <Fact label="Агент отозван" value={server.agentRevoked ? "да" : "нет"} />
              <Fact label="Внешний интерфейс" value={shown(server.externalInterface)} mono />
              <Fact label="Публичный ключ WireGuard" value={shown(server.wgPublicKey)} mono />
            </dl>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function Fact({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0 rounded-xl bg-inset px-3 py-2">
      <dt className="text-[11px] text-muted">{label}</dt>
      <dd className={mono ? "mt-1 font-mono text-sm break-all text-ink" : "mt-1 text-sm break-words text-ink"}>{value}</dd>
    </div>
  );
}

function agentVersionLabel(server: ServerRecord) {
  if (!server.paired) return "Не привязан";
  return server.agentVersion?.trim() || "Нет данных";
}

function shown(value: string | null | undefined) {
  const trimmed = value?.trim() ?? "";
  return trimmed ? trimmed : "Нет данных";
}

function filterServers(servers: ServerRecord[], query: string, status: StatusFilter) {
  const needle = query.trim().toLowerCase();
  return servers.filter((server) => {
    if (status !== "all" && server.linkStatus !== status) return false;
    if (!needle) return true;
    return [server.name, server.location, server.endpoint].join(" ").toLowerCase().includes(needle);
  });
}

function Kpi({ label, value, hint, icon }: { label: string; value: string; hint: string; icon: ReactNode }) {
  return (
    <article className="glass flex items-start gap-3 px-4 py-3.5 dark:shadow-[0_16px_36px_rgba(2,8,22,0.28),0_0_28px_color-mix(in_srgb,var(--accent)_18%,transparent)]">
      <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-line bg-accent/10 text-accent">
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block text-xs text-muted">{label}</span>
        <span className="mt-1 block text-2xl font-semibold tracking-tight tabular-nums text-ink">{value}</span>
        <span className="mt-1 block text-[11px] text-muted">{hint}</span>
      </span>
    </article>
  );
}

function IconPulse() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M3 12h4l2-5 4 10 2-5h6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function IconOffline() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <circle cx="12" cy="12" r="7" />
      <path d="M8 12h8" strokeLinecap="round" />
    </svg>
  );
}

function IconLink() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      <path d="M9 12h6M8 8H7a4 4 0 0 0 0 8h1M16 8h1a4 4 0 0 1 0 8h-1" strokeLinecap="round" />
    </svg>
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

const prefixFlags: Record<string, CountryCode> = { NL: "NL", DE: "DE", US: "US", SG: "SG" };

function countryFlag(location: string | undefined, serverName: string): CountryCode | null {
  const fromLocation = countryFlags[location?.trim().toLowerCase() ?? ""];
  if (fromLocation) return fromLocation;
  const prefix = /^([A-Za-z]{2})-/.exec(serverName.trim())?.[1]?.toUpperCase();
  return (prefix && prefixFlags[prefix]) || null;
}

function StatusDetails({ server, onClose }: { server: ServerRecord; onClose: () => void }) {
  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted">
        Показано последнее сообщение агента. Панель не открывает SSH и не подставляет
        статус, если сообщения не было.
      </p>
      <div className="flex items-center gap-2">
        <StatusBadge status={server.linkStatus} />
        <span className="text-sm text-muted">{server.location}</span>
      </div>
      <dl className="grid gap-2 text-sm sm:grid-cols-2">
        <Info label="Адрес" value={`${server.endpoint}:${server.listenPort}`} mono />
        <Info label="Версия агента" value={server.agentVersion ? `v${server.agentVersion}` : "нет данных"} />
        <Info
          label="Последняя связь"
          value={server.lastSeenAt ? formatDateTime(server.lastSeenAt) : "сообщений не было"}
        />
        <Info
          label="Привязка"
          value={server.agentRevoked ? "отозвана" : server.paired ? "выполнена" : "нет агента"}
        />
        <Info label="Ключ WireGuard" value={server.wgPublicKey ?? "нет данных"} mono />
        <Info label="Подсеть" value={server.vpnSubnet ?? "нет данных"} mono />
        <Info label="Внешний интерфейс" value={server.externalInterface ?? "нет данных"} mono />
        <Info label="По умолчанию" value={server.isDefault ? "да" : "нет"} />
      </dl>
      <div className="flex justify-end">
        <Button variant="secondary" onClick={onClose}>
          Закрыть
        </Button>
      </div>
    </div>
  );
}

function Info({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0 rounded-xl bg-inset px-3 py-2">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className={mono ? "mt-1 truncate font-mono text-sm text-ink" : "mt-1 font-medium text-ink"}>
        {value}
      </dd>
    </div>
  );
}

function AddServerWizard({
  install,
  pending,
  serverError,
  onClose,
  onClaim,
  onFinished,
}: {
  install: InstallCommandInfo;
  pending: boolean;
  serverError: string | null;
  onClose: () => void;
  onClaim: (input: {
    name: string;
    location: string;
    code: string;
  }) => Promise<{ error: string | null; claimed?: ClaimedServerSummary }>;
  onFinished: () => void;
}) {
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [copied, setCopied] = useState(false);
  const [name, setName] = useState("");
  const [location, setLocation] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [claimed, setClaimed] = useState<ClaimedServerSummary | null>(null);
  const [live, setLive] = useState<ServerRecord | null>(null);
  const nameId = useId();
  const locationId = useId();
  const codeId = useId();

  useEffect(() => {
    if (step !== 3 || !claimed) return;
    let cancelled = false;
    let attempts = 0;
    const tick = async () => {
      attempts += 1;
      const result = await refreshServerAction(claimed.serverId);
      if (cancelled) return;
      if (result.server) setLive(result.server);
      if (result.server?.linkStatus === "online" || attempts >= 12) return;
      window.setTimeout(() => {
        void tick();
      }, 2500);
    };
    void tick();
    return () => {
      cancelled = true;
    };
  }, [step, claimed]);

  async function copyCommand() {
    if (!install.installCommand) return;
    try {
      await navigator.clipboard.writeText(install.installCommand);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setError("Не удалось скопировать команду. Выделите её вручную.");
    }
  }

  const checks = buildChecks(claimed, live);

  return (
    <div className="flex flex-col gap-4">
      <ol className="grid grid-cols-3 gap-2 text-center text-xs">
        {[
          { n: 1, label: "Установка" },
          { n: 2, label: "Код" },
          { n: 3, label: "Проверка" },
        ].map((item) => (
          <li
            key={item.n}
            className={cx(
              "rounded-xl px-2 py-2",
              step === item.n ? "bg-accent/15 text-accent" : "bg-inset text-muted",
            )}
          >
            {item.n}. {item.label}
          </li>
        ))}
      </ol>

      {step === 1 ? (
        <div className="flex flex-col gap-3">
          <p className="text-sm text-muted">
            На чистом Ubuntu 24.04 выполните одну команду. Она скачает install.sh, сверит SHA-256 и
            только потом запустит установку. WireGuard, NAT и агент настраиваются автоматически.
          </p>
          {install.tunnelHint ? (
            <p className="rounded-xl bg-info/10 px-3 py-2 text-sm text-ink">
              Backend для VPS: <span className="font-mono">{install.backendUrl}</span>. Это адрес
              SSH-туннеля на самом VPS, а не Windows <span className="font-mono">localhost:3010</span>.
              Туннель должен быть поднят до запуска команды.
            </p>
          ) : null}
          {!install.ready ? (
            <p className="text-sm text-bad">
              Команда ещё не готова: {install.missing.join(", ") || "нет данных релиза"}.
              Задайте FAMILY_VPN_PUBLIC_URL и положите артефакты в releases/.
            </p>
          ) : (
            <>
              <pre className="overflow-x-auto rounded-xl bg-inset p-3 font-mono text-xs leading-relaxed text-ink whitespace-pre-wrap break-all">
                {install.installCommand}
              </pre>
              <div className="flex flex-wrap gap-2">
                <Button type="button" onClick={() => void copyCommand()}>
                  {copied ? "Скопировано" : "Копировать команду"}
                </Button>
              </div>
            </>
          )}
          {error ? <p className="text-sm text-bad">{error}</p> : null}
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="secondary" onClick={onClose}>
              Отмена
            </Button>
            <Button type="button" disabled={!install.ready} onClick={() => setStep(2)}>
              Далее
            </Button>
          </div>
        </div>
      ) : null}

      {step === 2 ? (
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            if (!name.trim() || !location.trim() || !code.trim()) {
              setError("Укажите название, расположение и код.");
              return;
            }
            setError(null);
            void onClaim({ name, location, code }).then((result) => {
              if (result.error || !result.claimed) {
                setError(result.error ?? "Привязка не выполнена.");
                return;
              }
              setClaimed(result.claimed);
              setStep(3);
            });
          }}
        >
          <p className="text-sm text-muted">
            Код печатает установщик на VPS. Он действует 15 минут и принимается один раз.
          </p>
          <Field id={nameId} label="Название">
            <input
              id={nameId}
              className={inputClass}
              value={name}
              maxLength={64}
              autoComplete="off"
              onChange={(event) => setName(event.target.value)}
            />
          </Field>
          <Field id={locationId} label="Расположение">
            <input
              id={locationId}
              className={inputClass}
              value={location}
              maxLength={80}
              autoComplete="off"
              onChange={(event) => setLocation(event.target.value)}
            />
          </Field>
          <Field id={codeId} label="Код привязки">
            <input
              id={codeId}
              className={`${inputClass} font-mono`}
              value={code}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => setCode(event.target.value)}
            />
          </Field>
          {error || serverError ? <p className="text-sm text-bad">{error || serverError}</p> : null}
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="secondary" type="button" onClick={() => setStep(1)}>
              Назад
            </Button>
            <Button type="submit" disabled={pending}>
              Привязать
            </Button>
          </div>
        </form>
      ) : null}

      {step === 3 && claimed ? (
        <div className="flex flex-col gap-4">
          <p className="text-sm text-muted">
            Успех показывается только после фактических проверок. Онлайн-статус появится после
            первого heartbeat агента.
          </p>
          <ul className="flex flex-col gap-2">
            {checks.map((check) => (
              <li
                key={check.label}
                className="flex items-start justify-between gap-3 rounded-xl bg-inset px-3 py-2 text-sm"
              >
                <span className="text-ink">{check.label}</span>
                <span className={check.ok ? "text-ok" : "text-warn"}>{check.value}</span>
              </li>
            ))}
          </ul>
          {checks.every((check) => check.ok) ? (
            <p className="text-sm text-ok">Сервер готов к выпуску конфигураций.</p>
          ) : (
            <p className="text-sm text-warn">
              Привязка записана, но не все проверки зелёные. Дождитесь Online или откройте «Статус».
            </p>
          )}
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="secondary" onClick={onFinished}>
              Закрыть
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function buildChecks(claimed: ClaimedServerSummary | null, live: ServerRecord | null) {
  if (!claimed) return [];
  const online = live?.linkStatus === "online";
  const wgUp = live ? live.linkStatus === "online" : claimed.wgUp;
  const version = live?.agentVersion ?? claimed.agentVersion;
  const subnet = live?.vpnSubnet ?? claimed.vpnSubnet;
  const endpoint = live ? `${live.endpoint}:${live.listenPort}` : `${claimed.endpoint}:${claimed.listenPort}`;
  const ready =
    online &&
    Boolean(subnet) &&
    Boolean(live?.wgPublicKey ?? claimed.wgPublicKey) &&
    Boolean(version);
  return [
    {
      label: "Соединение с агентом",
      value: online ? "Online" : live ? live.linkStatus : "ожидание heartbeat",
      ok: online,
    },
    {
      label: "WireGuard",
      value: wgUp ? "поднят" : "нет подтверждения",
      ok: wgUp,
    },
    {
      label: "Публичный IP / порт",
      value: endpoint,
      ok: Boolean(claimed.endpoint && claimed.listenPort),
    },
    {
      label: "VPN-подсеть",
      value: subnet ?? "нет данных",
      ok: Boolean(subnet),
    },
    {
      label: "Версия агента",
      value: version ? `v${version}` : "нет данных",
      ok: Boolean(version),
    },
    {
      label: "Готовность к конфигурациям",
      value: ready ? "да" : "ещё нет",
      ok: ready,
    },
  ];
}

function EditForm({
  server,
  pending,
  serverError,
  onClose,
  onSubmit,
}: {
  server: ServerRecord;
  pending: boolean;
  serverError: string | null;
  onClose: () => void;
  onSubmit: (input: { name: string; location: string }) => void;
}) {
  const nameId = useId();
  const locationId = useId();
  const [name, setName] = useState(server.name);
  const [location, setLocation] = useState(server.location);
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        if (!name.trim() || !location.trim()) {
          setError("Укажите название и расположение.");
          return;
        }
        setError(null);
        onSubmit({ name, location });
      }}
    >
      <p className="text-sm text-muted">
        Адрес и порт приходят от агента. Здесь меняются только название и расположение.
      </p>
      <Field id={nameId} label="Название">
        <input id={nameId} className={inputClass} value={name} maxLength={64} autoComplete="off" onChange={(event) => setName(event.target.value)} />
      </Field>
      <Field id={locationId} label="Расположение">
        <input id={locationId} className={inputClass} value={location} maxLength={80} autoComplete="off" onChange={(event) => setLocation(event.target.value)} />
      </Field>
      {error || serverError ? <p className="text-sm text-bad">{error || serverError}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>Отмена</Button>
        <Button type="submit" disabled={pending}>Сохранить</Button>
      </div>
    </form>
  );
}
