"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useState, useTransition } from "react";
import {
  claimServerAction,
  deleteServerAction,
  refreshServerAction,
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
import type { ClaimedServerSummary, InstallCommandInfo, ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "pair" }
  | { type: "edit"; server: ServerRecord }
  | { type: "delete"; server: ServerRecord }
  | { type: "revoke"; server: ServerRecord }
  | { type: "status"; server: ServerRecord };

export function ServersView({
  servers,
  install,
}: {
  servers: ServerRecord[];
  install: InstallCommandInfo;
}) {
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
        description="Одна команда на чистом VPS, затем код привязки в панели. Статус берётся только из сообщений агента."
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
          <AddServerWizard
            install={install}
            pending={pending}
            serverError={message}
            onClose={close}
            onClaim={(input) =>
              new Promise((resolve) => {
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
