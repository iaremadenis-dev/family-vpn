"use client";

import { useId, useState, type ReactNode } from "react";
import { useDemo } from "@/components/demo-provider";
import {
  Button,
  DemoChip,
  DemoNote,
  Dialog,
  EmptyState,
  Field,
  PageHeader,
  StatusBadge,
  inputClass,
} from "@/components/ui";
import { cx } from "@/lib/cx";
import { formatBytes, formatCount, formatDateTime } from "@/lib/format";
import type { ServerInput, VpnServer } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "edit"; server: VpnServer }
  | { type: "delete"; server: VpnServer }
  | { type: "status"; server: VpnServer };

const serverGrid =
  "grid gap-3 md:grid-cols-[minmax(0,1.15fr)_minmax(0,0.9fr)_minmax(0,1.35fr)_minmax(0,0.9fr)_minmax(0,0.7fr)_minmax(0,1.25fr)] md:items-center";

export function ServersView() {
  const {
    servers,
    configurations,
    addServer,
    updateServer,
    deleteServer,
    setDefaultServer,
    notify,
  } = useDemo();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const close = () => setDialog({ type: "closed" });
  const peak = Math.max(
    ...servers.map((server) => server.rxBytes + server.txBytes),
    1,
  );

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        kicker="Инфраструктура"
        title="Серверы"
        description="Один сервер обслуживает много конфигураций. Каждая конфигурация привязана только к одному серверу."
        action={
          <Button onClick={() => setDialog({ type: "create" })}>
            Добавить сервер
            <DemoChip />
          </Button>
        }
      />

      {servers.length === 0 ? (
        <EmptyState
          title="Серверов нет"
          text="Добавьте запись в демонстрационный список. Реальный VPS при этом не создаётся."
        />
      ) : (
        <div className="glass overflow-hidden">
          <div
            className={cx(
              serverGrid,
              "hidden border-b border-line bg-inset px-4 py-3 text-xs font-medium text-muted md:grid",
            )}
          >
            <span>Узел</span>
            <span>Локация</span>
            <span>Endpoint</span>
            <span>Статус</span>
            <span>Конфиги</span>
            <span>Трафик</span>
          </div>
          {servers.map((server) => {
            const related = configurations.filter(
              (config) => config.serverId === server.id,
            );
            const active = related.filter((config) => config.status === "active");
            const total = server.rxBytes + server.txBytes;
            const share =
              total === 0 ? 0 : Math.max(4, Math.round((total / peak) * 100));
            return (
              <article key={server.id} className="border-b border-line last:border-b-0">
                <div className={cx(serverGrid, "px-4 py-3")}>
                  <Cell label="Узел">
                    <p className="truncate font-mono text-sm text-ink">{server.name}</p>
                    {server.isDefault ? (
                      <p className="mt-1 text-xs font-medium text-info">по умолчанию</p>
                    ) : null}
                  </Cell>
                  <Cell label="Локация">
                    <p className="truncate text-sm text-ink">{server.location}</p>
                  </Cell>
                  <Cell label="Endpoint">
                    <p className="truncate font-mono text-sm text-ink">
                      {server.endpoint}:{server.listenPort}
                    </p>
                  </Cell>
                  <Cell label="Статус">
                    <StatusBadge status={server.status} />
                  </Cell>
                  <Cell label="Конфиги">
                    <p className="font-mono text-sm text-ink tabular-nums">
                      {active.length}
                      <span className="text-muted">/{related.length}</span>
                    </p>
                    <p className="mt-0.5 text-[11px] text-muted">активные</p>
                  </Cell>
                  <Cell label="Трафик">
                    <p className="font-mono text-sm text-ink tabular-nums">
                      {formatBytes(total)}
                    </p>
                    <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-inset">
                      <div
                        className={cx(
                          "h-full rounded-full",
                          server.status === "offline" ? "bg-muted" : "bg-accent",
                        )}
                        style={{ width: `${share}%` }}
                      />
                    </div>
                    <p className="mt-1 font-mono text-[10px] text-muted">
                      RX {formatBytes(server.rxBytes)} · TX {formatBytes(server.txBytes)}
                    </p>
                  </Cell>
                </div>
                <div className="flex flex-col gap-2 border-t border-line bg-inset/60 px-4 py-2 sm:flex-row sm:items-center sm:justify-between">
                  <p className="font-mono text-[11px] text-muted">
                    {formatCount(active.length, [
                      "активная конфигурация",
                      "активные конфигурации",
                      "активных конфигураций",
                    ])}
                    {" · "}
                    {server.checkedAt
                      ? `пример проверки ${formatDateTime(server.checkedAt)}`
                      : "проверка не выполнялась"}
                  </p>
                  <div className="flex flex-wrap gap-1.5">
                    <Button
                      size="sm"
                      variant="secondary"
                      onClick={() => setDialog({ type: "status", server })}
                    >
                      Статус
                      <DemoChip />
                    </Button>
                    <Button
                      size="sm"
                      variant="secondary"
                      onClick={() => setDialog({ type: "edit", server })}
                    >
                      Изменить
                      <DemoChip />
                    </Button>
                    <Button
                      size="sm"
                      variant="secondary"
                      disabled={server.isDefault}
                      onClick={() => setDefaultServer(server.id)}
                    >
                      Сделать по умолчанию
                      <DemoChip />
                    </Button>
                    <Button
                      size="sm"
                      variant="danger"
                      onClick={() => setDialog({ type: "delete", server })}
                    >
                      Удалить
                      <DemoChip />
                    </Button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}

      <ServerFormDialog
        open={dialog.type === "create" || dialog.type === "edit"}
        server={dialog.type === "edit" ? dialog.server : undefined}
        onClose={close}
        onSubmit={(input) => {
          if (dialog.type === "edit") updateServer(dialog.server.id, input);
          else addServer(input);
          close();
        }}
      />

      <Dialog open={dialog.type === "delete"} title="Удалить сервер" onClose={close}>
        {dialog.type === "delete" ? (
          <DeleteServer
            server={dialog.server}
            configCount={
              configurations.filter((config) => config.serverId === dialog.server.id)
                .length
            }
            onClose={close}
            onConfirm={() => {
              deleteServer(dialog.server.id);
              close();
            }}
          />
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "status"} title="Статус и статистика" onClose={close}>
        {dialog.type === "status" ? (
          <StatusDetails
            server={dialog.server}
            activeConfigs={
              configurations.filter(
                (config) =>
                  config.serverId === dialog.server.id && config.status === "active",
              ).length
            }
            onRefresh={() =>
              notify(
                "Демонстрация: VPN-сервер не опрашивается. Показаны примерные цифры.",
              )
            }
          />
        ) : null}
      </Dialog>
    </div>
  );
}

function Cell({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <p className="text-xs text-muted md:hidden">
        {label}
      </p>
      <div className="mt-0.5 md:mt-0">{children}</div>
    </div>
  );
}

function DeleteServer({
  server,
  configCount,
  onClose,
  onConfirm,
}: {
  server: VpnServer;
  configCount: number;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      <DemoNote>
        Демонстрация. Запись исчезнет только из этого окна. VPS и WireGuard не
        затрагиваются.
      </DemoNote>
      <p className="text-sm text-ink">
        Удалить сервер «{server.name}»
        {configCount > 0
          ? ` вместе с ${formatCount(configCount, ["связанной конфигурацией", "связанными конфигурациями", "связанными конфигурациями"])}`
          : ""}
        ?
      </p>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button variant="danger" onClick={onConfirm}>
          Удалить локально
        </Button>
      </div>
    </div>
  );
}

function StatusDetails({
  server,
  activeConfigs,
  onRefresh,
}: {
  server: VpnServer;
  activeConfigs: number;
  onRefresh: () => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      <DemoNote>
        Демонстрация. Статус не запрашивается у сервера и не обновляется по сети.
      </DemoNote>
      <div className="flex items-center gap-2">
        <StatusBadge status={server.status} />
        <span className="text-sm text-muted">{server.location}</span>
      </div>
      <dl className="grid gap-px bg-line text-sm sm:grid-cols-2">
        <Info label="Адрес" value={`${server.endpoint}:${server.listenPort}`} mono />
        <Info label="Активные конфигурации" value={String(activeConfigs)} />
        <Info label="Принято" value={formatBytes(server.rxBytes)} />
        <Info label="Отправлено" value={formatBytes(server.txBytes)} />
        <Info
          label="Пример проверки"
          value={server.checkedAt ? formatDateTime(server.checkedAt) : "не выполнялась"}
        />
        <Info label="По умолчанию" value={server.isDefault ? "да" : "нет"} />
      </dl>
      <div className="flex justify-end">
        <Button variant="secondary" onClick={onRefresh}>
          Обновить статус
          <DemoChip />
        </Button>
      </div>
    </div>
  );
}

function Info({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="rounded-xl bg-inset px-3 py-2">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className={mono ? "mt-1 font-mono text-sm text-ink" : "mt-1 font-medium text-ink"}>
        {value}
      </dd>
    </div>
  );
}

function ServerFormDialog({
  open,
  server,
  onClose,
  onSubmit,
}: {
  open: boolean;
  server?: VpnServer;
  onClose: () => void;
  onSubmit: (input: ServerInput) => void;
}) {
  return (
    <Dialog
      open={open}
      title={server ? "Изменить сервер" : "Новый сервер"}
      onClose={onClose}
    >
      {open ? (
        <ServerForm
          key={server?.id ?? "create"}
          server={server}
          onClose={onClose}
          onSubmit={onSubmit}
        />
      ) : null}
    </Dialog>
  );
}

function ServerForm({
  server,
  onClose,
  onSubmit,
}: {
  server?: VpnServer;
  onClose: () => void;
  onSubmit: (input: ServerInput) => void;
}) {
  const nameId = useId();
  const locationId = useId();
  const endpointId = useId();
  const portId = useId();
  const [name, setName] = useState(server?.name ?? "");
  const [location, setLocation] = useState(server?.location ?? "");
  const [endpoint, setEndpoint] = useState(server?.endpoint ?? "");
  const [port, setPort] = useState(String(server?.listenPort ?? 51820));
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        const listenPort = Number(port);
        const input = {
          name,
          location,
          endpoint,
          listenPort,
        };
        const message = validateServer(input);
        if (message) {
          setError(message);
          return;
        }
        onSubmit(input);
      }}
    >
      <DemoNote>
        Демонстрация. Поля сохраняются только в этом окне браузера. Соединение с
        адресом не открывается.
      </DemoNote>
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
          maxLength={64}
          autoComplete="off"
          onChange={(event) => setLocation(event.target.value)}
        />
      </Field>
      <Field
        id={endpointId}
        label="Адрес"
        hint="Нужен только как подпись карточки. Для примера подойдёт адрес из документации, например 203.0.113.10."
      >
        <input
          id={endpointId}
          className={inputClass}
          value={endpoint}
          maxLength={253}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setEndpoint(event.target.value)}
        />
      </Field>
      <Field id={portId} label="Порт">
        <input
          id={portId}
          className={inputClass}
          value={port}
          inputMode="numeric"
          autoComplete="off"
          onChange={(event) => setPort(event.target.value)}
        />
      </Field>
      {error ? <p className="text-sm text-bad">{error}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button type="submit">{server ? "Сохранить локально" : "Добавить локально"}</Button>
      </div>
    </form>
  );
}

function validateServer(input: ServerInput): string | null {
  if (!input.name.trim()) return "Укажите название.";
  if (input.name.trim().length > 64) return "Название длиннее 64 символов.";
  if (!input.location.trim()) return "Укажите расположение.";
  if (!input.endpoint.trim()) return "Укажите адрес.";
  if (input.endpoint.trim().length > 253) return "Адрес слишком длинный.";
  if (
    !Number.isInteger(input.listenPort) ||
    input.listenPort < 1 ||
    input.listenPort > 65535
  ) {
    return "Порт должен быть целым числом от 1 до 65535.";
  }
  return null;
}
