"use client";

import { useId, useState } from "react";
import { useDemo } from "@/components/demo-provider";
import { IconServer } from "@/components/icons";
import {
  Button,
  DemoChip,
  DemoNote,
  Dialog,
  EmptyState,
  Field,
  PageHeader,
  RowMark,
  StatusBadge,
  inputClass,
  itemRowClass,
  serverRowGrid,
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
        <div className="flex flex-col gap-2">
          {servers.map((server) => {
            const related = configurations.filter(
              (config) => config.serverId === server.id,
            );
            const active = related.filter((config) => config.status === "active");
            const total = server.rxBytes + server.txBytes;
            return (
              <article key={server.id} className={cx(itemRowClass, serverRowGrid)}>
                <div className="col-span-2 flex min-w-0 items-center gap-3 lg:col-span-1">
                  <RowMark>
                    <IconServer className="h-4 w-4" />
                  </RowMark>
                  <p className="min-w-0 truncate text-sm font-medium text-ink">
                    {server.name}
                    {server.isDefault ? (
                      <span className="ml-2 text-xs font-medium text-info">по умолчанию</span>
                    ) : null}
                  </p>
                </div>
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">IP</p>
                  <p className="truncate font-mono text-sm text-ink">
                    {server.endpoint}:{server.listenPort}
                  </p>
                </div>
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">Расположение</p>
                  <p className="truncate text-sm text-ink">{server.location}</p>
                </div>
                <StatusBadge status={server.status} />
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">Статистика</p>
                  <p
                    className="truncate text-sm text-ink tabular-nums"
                    title={
                      server.checkedAt
                        ? `Пример проверки ${formatDateTime(server.checkedAt)}`
                        : "Проверка не выполнялась"
                    }
                  >
                    {active.length}/{related.length} · {formatBytes(total)}
                  </p>
                </div>
                <div className="col-span-2 flex flex-wrap justify-end gap-1.5 lg:col-span-1">
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
