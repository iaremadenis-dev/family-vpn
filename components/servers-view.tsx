"use client";

import { useRouter } from "next/navigation";
import { useId, useState, useTransition } from "react";
import {
  createServerAction,
  deleteServerAction,
  setDefaultServerAction,
  updateServerAction,
} from "@/app/actions/servers";
import { IconServer } from "@/components/icons";
import {
  Button,
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
import type { ServerInput, ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "edit"; server: ServerRecord }
  | { type: "delete"; server: ServerRecord }
  | { type: "status"; server: ServerRecord };

export function ServersView({ servers }: { servers: ServerRecord[] }) {
  const router = useRouter();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const close = () => setDialog({ type: "closed" });

  function run(action: () => Promise<{ error: string | null }>) {
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
      <PageHeader
        kicker="Инфраструктура"
        title="Серверы"
        description="Запись хранится в базе панели. Привязка VPS по коду и проверка WireGuard ещё не выполняются."
        action={
          <Button onClick={() => setDialog({ type: "create" })} disabled={pending}>
            Добавить сервер
          </Button>
        }
      />

      {message ? <p className="text-sm text-bad">{message}</p> : null}

      {servers.length === 0 ? (
        <EmptyState
          title="Серверов в базе нет"
          text="Добавьте название, расположение и адрес. Это не подключает VPS и не меняет WireGuard."
        />
      ) : (
        <div className="flex flex-col gap-2">
          {servers.map((server) => (
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
              <StatusBadge status="unchecked" />
              <div className="min-w-0">
                <p className="text-[11px] text-muted lg:hidden">Статистика</p>
                <p className="truncate text-sm text-muted">нет данных</p>
              </div>
              <div className="col-span-2 flex flex-wrap justify-end gap-1.5 lg:col-span-1">
                <Button size="sm" variant="secondary" onClick={() => setDialog({ type: "status", server })}>
                  Статус
                </Button>
                <Button size="sm" variant="secondary" onClick={() => setDialog({ type: "edit", server })}>
                  Изменить
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={server.isDefault || pending}
                  onClick={() => run(() => setDefaultServerAction(server.id))}
                >
                  Сделать по умолчанию
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  onClick={() => setDialog({ type: "delete", server })}
                >
                  Удалить
                </Button>
              </div>
            </article>
          ))}
        </div>
      )}

      <ServerFormDialog
        open={dialog.type === "create" || dialog.type === "edit"}
        server={dialog.type === "edit" ? dialog.server : undefined}
        pending={pending}
        onClose={close}
        serverError={message}
        onSubmit={(input) => {
          if (dialog.type === "edit") {
            run(() => updateServerAction(dialog.server.id, input));
            return;
          }
          run(() => createServerAction(input));
        }}
      />

      <Dialog open={dialog.type === "delete"} title="Удалить сервер" onClose={close}>
        {dialog.type === "delete" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-ink">
              Удалить «{dialog.server.name}» из базы панели? Файлы на VPS не изменяются:
              агент ещё не подключён.
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

      <Dialog open={dialog.type === "status"} title="Статус и статистика" onClose={close}>
        {dialog.type === "status" ? (
          <div className="flex flex-col gap-4">
            <p className="text-sm text-muted">
              Проверка агента и счётчики WireGuard ещё не реализованы. Статус «Не подключён»
              означает, что живых данных с VPS нет.
            </p>
            <div className="flex items-center gap-2">
              <StatusBadge status="unchecked" />
              <span className="text-sm text-muted">{dialog.server.location}</span>
            </div>
            <dl className="grid gap-2 text-sm sm:grid-cols-2">
              <Info label="Адрес в базе" value={`${dialog.server.endpoint}:${dialog.server.listenPort}`} mono />
              <Info label="Агент" value="не подключён" />
              <Info label="Трафик" value="нет данных" />
              <Info label="По умолчанию" value={dialog.server.isDefault ? "да" : "нет"} />
            </dl>
            <div className="flex justify-end">
              <Button variant="secondary" onClick={close}>
                Закрыть
              </Button>
            </div>
          </div>
        ) : null}
      </Dialog>
    </div>
  );
}

function Info({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
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
  pending,
  serverError,
  onClose,
  onSubmit,
}: {
  open: boolean;
  server?: ServerRecord;
  pending: boolean;
  serverError: string | null;
  onClose: () => void;
  onSubmit: (input: ServerInput) => void;
}) {
  return (
    <Dialog open={open} title={server ? "Изменить сервер" : "Новый сервер"} onClose={onClose}>
      {open ? (
        <ServerForm
          key={server?.id ?? "create"}
          server={server}
          pending={pending}
          serverError={serverError}
          onClose={onClose}
          onSubmit={onSubmit}
        />
      ) : null}
    </Dialog>
  );
}

function ServerForm({
  server,
  pending,
  serverError,
  onClose,
  onSubmit,
}: {
  server?: ServerRecord;
  pending: boolean;
  serverError: string | null;
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
        if (!/^\d+$/.test(port.trim())) {
          setError("Порт должен быть целым числом от 1 до 65535.");
          return;
        }
        const input = {
          name,
          location,
          endpoint,
          listenPort: Number(port.trim()),
        };
        const message = clientServerError(input);
        if (message) {
          setError(message);
          return;
        }
        setError(null);
        onSubmit(input);
      }}
    >
      <p className="text-sm text-muted">
        Панель сохранит метаданные. Код привязки, агент и сетевые настройки VPS на этом
        этапе не используются.
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
      <Field id={endpointId} label="Адрес" hint="IPv4 или домен. Схема и порт здесь не указываются.">
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
      <Field id={portId} label="Порт WireGuard">
        <input
          id={portId}
          className={inputClass}
          value={port}
          inputMode="numeric"
          autoComplete="off"
          onChange={(event) => setPort(event.target.value)}
        />
      </Field>
      {error || serverError ? <p className="text-sm text-bad">{error || serverError}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button type="submit" disabled={pending}>
          {server ? "Сохранить" : "Добавить"}
        </Button>
      </div>
    </form>
  );
}

function clientServerError(input: ServerInput): string | null {
  if (!input.name.trim()) return "Укажите название.";
  if (!input.location.trim()) return "Укажите расположение.";
  if (!input.endpoint.trim()) return "Укажите адрес.";
  if (
    !Number.isInteger(input.listenPort) ||
    input.listenPort < 1 ||
    input.listenPort > 65535
  ) {
    return "Порт должен быть целым числом от 1 до 65535.";
  }
  return null;
}
