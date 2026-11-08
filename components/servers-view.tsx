"use client";

import { useRouter } from "next/navigation";
import { useId, useState, useTransition } from "react";
import {
  claimServerAction,
  deleteServerAction,
  revokeAgentAction,
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
import { formatDateTime } from "@/lib/format";
import type { ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "pair" }
  | { type: "edit"; server: ServerRecord }
  | { type: "delete"; server: ServerRecord }
  | { type: "revoke"; server: ServerRecord }
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
        description="Сервер появляется после одноразового кода. Статус берётся из сообщений агента, а не из примера."
        action={
          <Button onClick={() => setDialog({ type: "pair" })} disabled={pending}>
            Добавить сервер
          </Button>
        }
      />

      {message && dialog.type === "closed" ? <p className="text-sm text-bad">{message}</p> : null}

      {servers.length === 0 ? (
        <EmptyState
          title="Серверов в базе нет"
          text="Запустите установщик на VPS, затем введите здесь название и код привязки. Панель сама на сервер по SSH не заходит."
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
              <StatusBadge status={server.linkStatus} />
              <div className="min-w-0">
                <p className="text-[11px] text-muted lg:hidden">Агент</p>
                <p className="truncate text-sm text-muted" title={seenTitle(server)}>
                  {server.agentRevoked
                    ? "доступ отозван"
                    : server.agentVersion
                      ? `v${server.agentVersion}`
                      : "нет данных"}
                </p>
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
                {server.paired && !server.agentRevoked ? (
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() => setDialog({ type: "revoke", server })}
                  >
                    Отвязать
                  </Button>
                ) : null}
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

      <Dialog open={dialog.type === "pair"} title="Добавить сервер" onClose={close}>
        {dialog.type === "pair" ? (
          <PairForm
            pending={pending}
            serverError={message}
            onClose={close}
            onSubmit={(input) => run(() => claimServerAction(input))}
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

function seenTitle(server: ServerRecord): string {
  if (!server.lastSeenAt) return "Сообщений агента ещё не было";
  return `Последняя связь ${formatDateTime(server.lastSeenAt)}`;
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

function PairForm({
  pending,
  serverError,
  onClose,
  onSubmit,
}: {
  pending: boolean;
  serverError: string | null;
  onClose: () => void;
  onSubmit: (input: { name: string; location: string; code: string }) => void;
}) {
  const nameId = useId();
  const locationId = useId();
  const codeId = useId();
  const [name, setName] = useState("");
  const [location, setLocation] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        if (!name.trim() || !location.trim() || !code.trim()) {
          setError("Укажите название, расположение и код.");
          return;
        }
        setError(null);
        onSubmit({ name, location, code });
      }}
    >
      <p className="text-sm text-muted">
        Код показывает установщик на VPS. Он действует 15 минут и принимается один раз.
      </p>
      <Field id={nameId} label="Название">
        <input id={nameId} className={inputClass} value={name} maxLength={64} autoComplete="off" onChange={(event) => setName(event.target.value)} />
      </Field>
      <Field id={locationId} label="Расположение">
        <input id={locationId} className={inputClass} value={location} maxLength={80} autoComplete="off" onChange={(event) => setLocation(event.target.value)} />
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
        <Button variant="secondary" onClick={onClose}>Отмена</Button>
        <Button type="submit" disabled={pending}>Привязать</Button>
      </div>
    </form>
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
