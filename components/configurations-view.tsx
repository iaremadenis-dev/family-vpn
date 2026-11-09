"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useState, useTransition } from "react";
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
  EmptyState,
  Field,
  PageHeader,
  RowMark,
  StatusBadge,
  configRowGrid,
  inputClass,
  itemRowClass,
} from "@/components/ui";
import { cx } from "@/lib/cx";
import { formatBytes, formatDateTime } from "@/lib/format";
import type { ConfigRecord, ServerRecord } from "@/lib/types";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "qr"; config: ConfigRecord }
  | { type: "status"; config: ConfigRecord }
  | { type: "revoke"; config: ConfigRecord }
  | { type: "delete"; config: ConfigRecord };

export function ConfigurationsView({
  configs,
  servers,
}: {
  configs: ConfigRecord[];
  servers: ServerRecord[];
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const onlineServers = servers.filter(
    (server) => server.linkStatus === "online" && server.paired && !server.agentRevoked,
  );
  const close = () => setDialog({ type: "closed" });
  const waiting = configs.some(
    (config) => config.status === "pending" || config.status === "revoking",
  );

  useEffect(() => {
    if (!waiting) return;
    const timer = window.setInterval(() => router.refresh(), 5000);
    return () => window.clearInterval(timer);
  }, [waiting, router]);

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

  function download(config: ConfigRecord) {
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
      <PageHeader
        kicker="Доступ"
        title="Конфигурации"
        description="Каждая строка — отдельное устройство: ключи, VPN-IP, peer на выбранном сервере и .conf/QR только через панель."
        action={
          <Button
            onClick={() => setDialog({ type: "create" })}
            disabled={pending || onlineServers.length === 0}
          >
            Создать конфигурацию
          </Button>
        }
      />

      {message && dialog.type === "closed" ? <p className="text-sm text-bad">{message}</p> : null}

      {onlineServers.length === 0 ? (
        <p className="text-sm text-muted">
          Для выпуска нужен сервер со статусом Online и агентом v0.4.0+.
        </p>
      ) : null}

      {configs.length === 0 ? (
        <EmptyState
          title="Конфигураций пока нет"
          text="Создайте первую запись для устройства: панель сгенерирует ключи, выделит IP и поставит peer через агент."
        />
      ) : (
        <div className="flex flex-col gap-2">
          {configs.map((config) => (
            <article key={config.id} className={cx(itemRowClass, configRowGrid)}>
              <div className="col-span-2 flex min-w-0 items-center gap-3 lg:col-span-1">
                <RowMark>
                  <DeviceIcon name={config.deviceName} className="h-4 w-4" />
                </RowMark>
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-ink">{config.deviceName}</p>
                  <p className="truncate font-mono text-xs text-muted">{config.vpnIp}</p>
                </div>
              </div>
              <div className="min-w-0">
                <p className="text-[11px] text-muted lg:hidden">Сервер</p>
                <p className="truncate text-sm text-ink">{config.serverName}</p>
              </div>
              <StatusBadge status={config.status} />
              <div className="min-w-0">
                <p className="text-[11px] text-muted lg:hidden">Трафик</p>
                <p className="truncate text-sm text-muted">
                  ↓ {formatBytes(config.rxBytes ?? 0)} · ↑ {formatBytes(config.txBytes ?? 0)}
                </p>
              </div>
              <div className="min-w-0">
                <p className="text-[11px] text-muted lg:hidden">Handshake</p>
                <p className="truncate text-sm text-muted">
                  {config.lastHandshakeAt ? formatDateTime(config.lastHandshakeAt) : "нет"}
                </p>
              </div>
              <div className="col-span-2 flex flex-wrap justify-end gap-1.5 lg:col-span-1">
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={pending || config.status === "revoked" || config.status === "revoking"}
                  onClick={() => download(config)}
                >
                  .conf
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={pending || config.status === "revoked" || config.status === "revoking"}
                  onClick={() => setDialog({ type: "qr", config })}
                >
                  QR
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  onClick={() => setDialog({ type: "status", config })}
                >
                  Статус
                </Button>
                {config.status !== "revoked" && config.status !== "revoking" ? (
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() => setDialog({ type: "revoke", config })}
                  >
                    Отозвать
                  </Button>
                ) : null}
                <Button
                  size="sm"
                  variant="danger"
                  onClick={() => setDialog({ type: "delete", config })}
                >
                  Удалить
                </Button>
              </div>
            </article>
          ))}
        </div>
      )}

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
                  : "нет данных"
              }
            />
            <Info
              label="Трафик"
              value={`RX ${formatBytes(dialog.config.rxBytes ?? 0)} · TX ${formatBytes(dialog.config.txBytes ?? 0)}`}
            />
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
