"use client";

import { useId, useState } from "react";
import { useDemo } from "@/components/demo-provider";
import { DeviceIcon } from "@/components/icons";
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
  configRowGrid,
  inputClass,
  itemRowClass,
} from "@/components/ui";
import { cx } from "@/lib/cx";
import { formatBytes, formatDateTime } from "@/lib/format";
import type { VpnConfig } from "@/lib/types";

type Artifact = "conf" | "qr";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "revoke"; config: VpnConfig }
  | { type: "delete"; config: VpnConfig }
  | { type: "artifact"; config: VpnConfig; artifact: Artifact };

export function ConfigurationsView() {
  const {
    servers,
    configurations,
    addConfiguration,
    revokeConfiguration,
    deleteConfiguration,
  } = useDemo();
  const [dialog, setDialog] = useState<DialogState>({ type: "closed" });
  const close = () => setDialog({ type: "closed" });

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        kicker="Доступ"
        title="Конфигурации"
        description="Администратор создаёт конфигурации вручную. У каждой конфигурации один VPN-сервер."
        action={
          servers.length === 0 ? (
            <p className="text-sm text-muted">Сначала добавьте VPN-сервер.</p>
          ) : (
            <Button onClick={() => setDialog({ type: "create" })}>
              Создать конфигурацию
              <DemoChip />
            </Button>
          )
        }
      />

      {configurations.length === 0 ? (
        <EmptyState
          title="Конфигураций нет"
          text="Новая запись появится только в этом списке. Файл .conf и QR-код не формируются."
        />
      ) : (
        <div className="flex flex-col gap-2">
          {configurations.map((config) => {
            const server = servers.find((item) => item.id === config.serverId);
            const active = config.status === "active";
            return (
              <article key={config.id} className={cx(itemRowClass, configRowGrid)}>
                <div className="col-span-2 flex min-w-0 items-center gap-3 lg:col-span-1">
                  <RowMark>
                    <DeviceIcon name={config.name} className="h-4 w-4" />
                  </RowMark>
                  <p className="truncate text-sm font-medium text-ink">{config.name}</p>
                </div>
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">Сервер</p>
                  <p className="truncate text-sm text-ink">
                    {server ? server.name : "Сервер удалён"}
                  </p>
                </div>
                <StatusBadge status={config.status} />
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">Трафик</p>
                  <p className="truncate text-sm text-ink tabular-nums">
                    {formatBytes(config.rxBytes + config.txBytes)}
                  </p>
                </div>
                <div className="min-w-0">
                  <p className="text-[11px] text-muted lg:hidden">Создана</p>
                  <p
                    className="truncate text-sm text-ink"
                    title={
                      config.lastHandshake
                        ? `Рукопожатие ${formatDateTime(config.lastHandshake)}`
                        : "Рукопожатия нет"
                    }
                  >
                    {formatDateTime(config.createdAt)}
                  </p>
                </div>
                <div className="col-span-2 flex flex-wrap justify-end gap-1.5 lg:col-span-1">
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={!active}
                    onClick={() =>
                      setDialog({ type: "artifact", config, artifact: "conf" })
                    }
                  >
                    .conf
                    <DemoChip />
                  </Button>
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={!active}
                    onClick={() =>
                      setDialog({ type: "artifact", config, artifact: "qr" })
                    }
                  >
                    QR
                    <DemoChip />
                  </Button>
                  <Button
                    size="sm"
                    variant="danger"
                    disabled={!active}
                    onClick={() => setDialog({ type: "revoke", config })}
                  >
                    Отозвать
                    <DemoChip />
                  </Button>
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() => setDialog({ type: "delete", config })}
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

      <Dialog open={dialog.type === "create"} title="Новая конфигурация" onClose={close}>
        {dialog.type === "create" ? (
          <CreateConfigForm
            servers={servers.map((server) => ({
              id: server.id,
              label: `${server.name} · ${server.location}`,
            }))}
            onClose={close}
            onSubmit={(input) => {
              addConfiguration(input);
              close();
            }}
          />
        ) : null}
      </Dialog>

      <Dialog
        open={dialog.type === "revoke"}
        title="Отозвать конфигурацию"
        onClose={close}
      >
        {dialog.type === "revoke" ? (
          <Confirm
            note="Демонстрация. Статус сменится только в этом списке. Устройство не отключается, потому что сервер не вызывается."
            text={`Отозвать конфигурацию «${dialog.config.name}»?`}
            confirm="Отозвать локально"
            onClose={close}
            onConfirm={() => {
              revokeConfiguration(dialog.config.id);
              close();
            }}
          />
        ) : null}
      </Dialog>

      <Dialog open={dialog.type === "delete"} title="Удалить конфигурацию" onClose={close}>
        {dialog.type === "delete" ? (
          <Confirm
            note="Демонстрация. Запись исчезнет только из этого окна."
            text={`Удалить конфигурацию «${dialog.config.name}» из списка?`}
            confirm="Удалить локально"
            onClose={close}
            onConfirm={() => {
              deleteConfiguration(dialog.config.id);
              close();
            }}
          />
        ) : null}
      </Dialog>

      <Dialog
        open={dialog.type === "artifact"}
        title={
          dialog.type === "artifact" && dialog.artifact === "qr"
            ? "QR-код не создаётся"
            : "Файл .conf не создаётся"
        }
        onClose={close}
      >
        {dialog.type === "artifact" ? (
          <ArtifactNotice
            name={dialog.config.name}
            artifact={dialog.artifact}
            onClose={close}
          />
        ) : null}
      </Dialog>
    </div>
  );
}

function Confirm({
  note,
  text,
  confirm,
  onClose,
  onConfirm,
}: {
  note: string;
  text: string;
  confirm: string;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      <DemoNote>{note}</DemoNote>
      <p className="text-sm text-ink">{text}</p>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button variant="danger" onClick={onConfirm}>
          {confirm}
        </Button>
      </div>
    </div>
  );
}

function ArtifactNotice({
  name,
  artifact,
  onClose,
}: {
  name: string;
  artifact: Artifact;
  onClose: () => void;
}) {
  return (
    <div className="flex flex-col gap-4">
      <DemoNote>
        Демонстрация. Ключи WireGuard не генерируются, файл не скачивается, QR-код
        не строится.
      </DemoNote>
      {artifact === "qr" ? (
        <div className="mx-auto grid h-44 w-44 place-items-center rounded-2xl border border-dashed border-line bg-inset p-4 text-center">
          <div>
            <p className="text-xs font-medium text-accent">QR</p>
            <p className="mt-2 text-sm text-muted">
              QR-код появится после подключения генерации
            </p>
          </div>
        </div>
      ) : (
        <p className="rounded-xl bg-inset px-3 py-2 font-mono text-sm text-muted">
          {name}.conf — файл не создан
        </p>
      )}
      <p className="text-sm text-muted">
        {artifact === "qr"
          ? `Для «${name}» нечего сканировать: в код не записываются адрес, ключи и настройки интерфейса.`
          : `Для «${name}» содержимое конфигурации не формируется и не отдаётся браузеру.`}
      </p>
      <div className="flex justify-end">
        <Button onClick={onClose}>Понятно</Button>
      </div>
    </div>
  );
}

function CreateConfigForm({
  servers,
  onClose,
  onSubmit,
}: {
  servers: Array<{ id: string; label: string }>;
  onClose: () => void;
  onSubmit: (input: { name: string; serverId: string }) => void;
}) {
  const nameId = useId();
  const serverId = useId();
  const [name, setName] = useState("");
  const [selectedServer, setSelectedServer] = useState(servers[0]?.id ?? "");
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        if (!name.trim()) {
          setError("Укажите название.");
          return;
        }
        if (name.trim().length > 64) {
          setError("Название длиннее 64 символов.");
          return;
        }
        if (!selectedServer) {
          setError("Выберите VPN-сервер.");
          return;
        }
        onSubmit({ name, serverId: selectedServer });
      }}
    >
      <DemoNote>
        Демонстрация. В список попадёт только название и выбранный сервер. Ключи,
        адрес клиента и файл .conf не создаются.
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
      <Field id={serverId} label="VPN-сервер">
        <select
          id={serverId}
          className={inputClass}
          value={selectedServer}
          onChange={(event) => setSelectedServer(event.target.value)}
        >
          {servers.map((server) => (
            <option key={server.id} value={server.id}>
              {server.label}
            </option>
          ))}
        </select>
      </Field>
      {error ? <p className="text-sm text-bad">{error}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Отмена
        </Button>
        <Button type="submit">Добавить локально</Button>
      </div>
    </form>
  );
}
