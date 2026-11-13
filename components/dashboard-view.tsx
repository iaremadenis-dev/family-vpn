"use client";

import { useRouter } from "next/navigation";
import { useId, useMemo, useState, useTransition, type ReactNode } from "react";
import {
  deleteServerAction,
  revokeAgentAction,
  setDefaultServerAction,
  updateServerAction,
} from "@/app/actions/servers";
import { IconConfig, IconDevice, IconOverview, IconServer } from "@/components/icons";
import { Button, Dialog, Field, StatusBadge, inputClass } from "@/components/ui";
import { DEMO_UI_BLOCKED } from "@/lib/demo-ui";
import { formatDateTime } from "@/lib/format";
import type { ConfigRecord, ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "edit"; server: ServerRecord }
  | { type: "delete"; server: ServerRecord }
  | { type: "revoke"; server: ServerRecord };

export function DashboardView({
  servers,
  configs,
  demo = false,
}: {
  servers: ServerRecord[];
  configs: ConfigRecord[];
  demo?: boolean;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const [openAgentId, setOpenAgentId] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const close = () => setDialog({ type: "closed" });

  const configCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const config of configs) {
      counts.set(config.serverId, (counts.get(config.serverId) ?? 0) + 1);
    }
    return counts;
  }, [configs]);

  const online = servers.filter((server) => server.linkStatus === "online").length;
  const activeConfigs = configs.filter((config) => config.status === "active").length;

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
      <div className="max-w-3xl">
        <h2 className="text-lg font-semibold tracking-tight text-ink">Обзор</h2>
        {demo ? <p className="mt-1 text-xs font-medium text-warn">Демо-данные</p> : null}
        <p className="mt-1 text-sm text-muted">
          Серверы и конфигурации из базы панели. Статус связи берётся из сообщений агента.
        </p>
      </div>

      {message && dialog.type === "closed" ? <p className="text-sm text-bad">{message}</p> : null}

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

      <section className="glass overflow-hidden">
        <div className="border-b border-line px-3 py-3 md:px-4">
          <h3 className="text-sm font-medium text-ink">Серверы</h3>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1080px] border-collapse text-left text-sm">
            <thead>
              <tr className="border-b border-line text-[11px] tracking-wide text-muted uppercase">
                <th className="px-3 py-2 font-medium md:px-4">Название</th>
                <th className="px-3 py-2 font-medium">Расположение</th>
                <th className="px-3 py-2 font-medium">Публичный IP</th>
                <th className="px-3 py-2 font-medium">Статус</th>
                <th className="px-3 py-2 font-medium">Конфигурации</th>
                <th className="px-3 py-2 font-medium">Агент</th>
                <th className="px-3 py-2 font-medium">Heartbeat</th>
                <th className="px-3 py-2 font-medium">Порт</th>
                <th className="px-3 py-2 text-right font-medium md:px-4">Действия</th>
              </tr>
            </thead>
            <tbody>
              {servers.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-8 text-center text-sm text-muted">
                    Серверов в базе нет. Привязка агента остаётся на странице «Серверы».
                  </td>
                </tr>
              ) : (
                servers.map((server) => {
                  const open = openAgentId === server.id;
                  return (
                    <ServerRows
                      key={server.id}
                      server={server}
                      configCount={configCounts.get(server.id) ?? 0}
                      open={open}
                      pending={pending}
                      onToggle={() => setOpenAgentId(open ? null : server.id)}
                      onEdit={() => setDialog({ type: "edit", server })}
                      onDefault={() => run(() => setDefaultServerAction(server.id))}
                      onRevoke={() => setDialog({ type: "revoke", server })}
                      onDelete={() => setDialog({ type: "delete", server })}
                    />
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>

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
    </div>
  );
}

function ServerRows({
  server,
  configCount,
  open,
  pending,
  onToggle,
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
  onEdit: () => void;
  onDefault: () => void;
  onRevoke: () => void;
  onDelete: () => void;
}) {
  return (
    <>
      <tr className="border-b border-line/80 last:border-b-0">
        <td className="px-3 py-2 md:px-4">
          <span className="flex min-w-0 items-center gap-2">
            <span className="grid h-7 w-7 shrink-0 place-items-center rounded-lg border border-line bg-inset text-accent">
              <IconServer className="h-3.5 w-3.5" />
            </span>
            <span className="min-w-0">
              <span className="block truncate font-medium text-ink">
                {server.name}
                {server.isDefault ? (
                  <span className="ml-2 text-xs font-medium text-info">по умолчанию</span>
                ) : null}
              </span>
              <button
                type="button"
                className="text-xs text-accent hover:text-ink"
                aria-expanded={open}
                onClick={onToggle}
              >
                {open ? "Скрыть агента" : "Агент"}
              </button>
            </span>
          </span>
        </td>
        <td className="max-w-40 truncate px-3 py-2 text-ink">{shown(server.location)}</td>
        <td className="px-3 py-2 font-mono text-xs text-ink">{shown(server.endpoint)}</td>
        <td className="px-3 py-2">
          <StatusBadge status={server.linkStatus} />
        </td>
        <td className="px-3 py-2 tabular-nums text-ink">{configCount}</td>
        <td className="px-3 py-2 text-muted">{server.agentVersion ? `v${server.agentVersion}` : "Нет данных"}</td>
        <td className="px-3 py-2 text-muted">
          {server.lastSeenAt ? formatDateTime(server.lastSeenAt) : "Нет данных"}
        </td>
        <td className="px-3 py-2 font-mono text-xs text-ink">
          {Number.isFinite(server.listenPort) ? String(server.listenPort) : "Нет данных"}
        </td>
        <td className="px-3 py-2 md:px-4">
          <div className="flex flex-nowrap justify-end gap-1">
            <Button size="sm" variant="secondary" onClick={onEdit}>
              Изменить
            </Button>
            <Button size="sm" variant="secondary" disabled={server.isDefault || pending} onClick={onDefault}>
              Сделать по умолчанию
            </Button>
            {server.paired && !server.agentRevoked ? (
              <Button size="sm" variant="danger" onClick={onRevoke}>
                Отвязать
              </Button>
            ) : null}
            <Button size="sm" variant="danger" onClick={onDelete}>
              Удалить
            </Button>
          </div>
        </td>
      </tr>
      {open ? (
        <tr className="border-b border-line/80 bg-inset/40">
          <td colSpan={9} className="px-3 py-3 md:px-4">
            <dl className="grid gap-2 sm:grid-cols-2 xl:grid-cols-5">
              <AgentFact label="Версия агента" value={server.agentVersion ? `v${server.agentVersion}` : "Нет данных"} />
              <AgentFact
                label="Последняя связь"
                value={server.lastSeenAt ? formatDateTime(server.lastSeenAt) : "Нет данных"}
              />
              <AgentFact label="Привязка" value={pairingLabel(server)} />
              <AgentFact label="Агент отозван" value={server.agentRevoked ? "да" : "нет"} />
              <div className="min-w-0 rounded-xl border border-line bg-panel/40 px-3 py-2">
                <dt className="text-[11px] text-muted">Статус связи</dt>
                <dd className="mt-1">
                  <StatusBadge status={server.linkStatus} />
                </dd>
              </div>
            </dl>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function pairingLabel(server: ServerRecord) {
  if (server.agentRevoked) return "отозвана";
  if (server.paired) return "выполнена";
  return "нет агента";
}

function shown(value: string) {
  const trimmed = value.trim();
  return trimmed ? trimmed : "Нет данных";
}

function AgentFact({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0 rounded-xl border border-line bg-panel/40 px-3 py-2">
      <dt className="text-[11px] text-muted">{label}</dt>
      <dd className="mt-1 truncate text-sm text-ink">{value}</dd>
    </div>
  );
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
      {error || serverError ? <p className="text-sm text-bad">{error || serverError}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button type="submit" disabled={pending}>
          Сохранить
        </Button>
      </div>
    </form>
  );
}
