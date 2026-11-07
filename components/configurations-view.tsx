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
import { formatBytes, formatDateTime } from "@/lib/format";
import type { VpnConfig } from "@/lib/types";

type Artifact = "conf" | "qr";

type DialogState =
  | { type: "closed" }
  | { type: "create" }
  | { type: "revoke"; config: VpnConfig }
  | { type: "delete"; config: VpnConfig }
  | { type: "artifact"; config: VpnConfig; artifact: Artifact };

const configGrid =
  "grid gap-3 md:grid-cols-[minmax(0,1.15fr)_minmax(0,1.15fr)_minmax(0,0.85fr)_minmax(0,1.15fr)_minmax(0,1.15fr)] md:items-center";

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
        kicker="peers"
        title="Конфигурации"
        description="Администратор создаёт конфигурации вручную. У каждой конфигурации один VPN-сервер."
        action={
          servers.length === 0 ? (
            <p className="font-mono text-xs tracking-[0.12em] text-muted uppercase">
              Сначала добавьте VPN-сервер.
            </p>
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
        <div className="border border-line bg-panel">
          <div
            className={cx(
              configGrid,
              "hidden border-b border-line bg-inset px-4 py-2 font-mono text-[10px] tracking-[0.14em] text-muted uppercase md:grid",
            )}
          >
            <span>Конфигурация</span>
            <span>Сервер</span>
            <span>Статус</span>
            <span>Трафик</span>
            <span>Создана</span>
          </div>
          {configurations.map((config) => {
            const server = servers.find((item) => item.id === config.serverId);
            const active = config.status === "active";
            return (
              <article key={config.id} className="border-b border-line last:border-b-0">
                <div className={cx(configGrid, "px-4 py-3")}>
                  <Cell label="Конфигурация">
                    <p className="truncate font-medium text-ink">{config.name}</p>
                    <p className="mt-0.5 truncate font-mono text-[10px] text-muted">
                      {config.id}
                    </p>
                  </Cell>
                  <Cell label="Сервер">
                    <p className="truncate font-mono text-sm text-ink">
                      {server ? server.name : "—"}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-muted">
                      {server ? server.location : "Сервер удалён из списка"}
                    </p>
                  </Cell>
                  <Cell label="Статус">
                    <StatusBadge status={config.status} />
                  </Cell>
                  <Cell label="Трафик">
                    <p className="font-mono text-sm text-ink tabular-nums">
                      {formatBytes(config.rxBytes + config.txBytes)}
                    </p>
                    <p className="mt-0.5 font-mono text-[10px] text-muted">
                      RX {formatBytes(config.rxBytes)} · TX {formatBytes(config.txBytes)}
                    </p>
                  </Cell>
                  <Cell label="Создана">
                    <p className="font-mono text-xs text-ink">
                      {formatDateTime(config.createdAt)}
                    </p>
                    <p className="mt-0.5 text-[11px] text-muted">
                      {config.lastHandshake
                        ? `handshake ${formatDateTime(config.lastHandshake)}`
                        : "рукопожатия нет"}
                    </p>
                  </Cell>
                </div>
                <div className="flex flex-col gap-2 border-t border-line bg-inset/60 px-4 py-2 lg:flex-row lg:items-center lg:justify-between">
                  <p className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
                    export
                  </p>
                  <div className="flex flex-wrap gap-1.5">
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
                    {active ? (
                      <Button
                        size="sm"
                        variant="danger"
                        onClick={() => setDialog({ type: "revoke", config })}
                      >
                        Отозвать
                        <DemoChip />
                      </Button>
                    ) : null}
                    <Button
                      size="sm"
                      variant="danger"
                      onClick={() => setDialog({ type: "delete", config })}
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

function Cell({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <p className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase md:hidden">
        {label}
      </p>
      <div className="mt-0.5 md:mt-0">{children}</div>
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
        <div className="mx-auto grid h-44 w-44 place-items-center border border-dashed border-line bg-canvas p-4 text-center">
          <div>
            <p className="font-mono text-[10px] tracking-[0.16em] text-accent uppercase">
              qr slot
            </p>
            <p className="mt-2 text-sm text-muted">
              QR-код появится после подключения генерации
            </p>
          </div>
        </div>
      ) : (
        <p className="border border-line bg-canvas px-3 py-2 font-mono text-sm text-muted">
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
