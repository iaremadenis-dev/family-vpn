"use client";

import { useActionState } from "react";
import { logout } from "@/app/actions/auth";
import {
  changePasswordAction,
  renameAdminAction,
  type SettingsFormState,
} from "@/app/actions/settings";
import { useTheme } from "@/components/theme-provider";
import { Button, Field, PageHeader, inputClass } from "@/components/ui";
import { cx } from "@/lib/cx";
import { formatDateTime } from "@/lib/format";
import type { Theme } from "@/lib/theme";
import type { AuditEntry } from "@/lib/types";

const idle: SettingsFormState = { error: null, saved: false };

const auditLabels: Record<string, string> = {
  "admin.setup": "Создан администратор",
  "admin.login": "Вход",
  "admin.logout": "Выход",
  "admin.login_failed": "Неудачный вход",
  "admin.rename": "Изменено имя",
  "admin.password": "Изменён пароль",
  "server.create": "Добавлен сервер",
  "server.update": "Изменён сервер",
  "server.delete": "Удалён сервер",
  "server.default": "Выбран основной сервер",
  "agent.pair": "Привязан агент",
  "agent.revoke": "Отозван агент",
};

export function SettingsView({
  adminName,
  audit,
}: {
  adminName: string;
  audit: AuditEntry[];
}) {
  const { theme, setTheme } = useTheme();
  const [nameState, saveName, namePending] = useActionState(renameAdminAction, idle);
  const [passwordState, savePassword, passwordPending] = useActionState(
    changePasswordAction,
    idle,
  );

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        kicker="Система"
        title="Настройки"
        description="Учётная запись администратора, тема и журнал действий панели."
      />

      <div className="grid gap-4 xl:grid-cols-2">
        <div className="flex flex-col gap-4">
          <section className="glass overflow-hidden">
            <SectionHeading>Администратор</SectionHeading>
            <div className="flex flex-col gap-5 px-4 py-4">
              <form key={adminName} action={saveName} className="flex max-w-md flex-col gap-4">
                <Field id="admin-name" label="Отображаемое имя">
                  <input
                    id="admin-name"
                    name="name"
                    className={inputClass}
                    defaultValue={adminName}
                    maxLength={40}
                    autoComplete="nickname"
                  />
                </Field>
                {nameState.error ? <p className="text-sm text-bad">{nameState.error}</p> : null}
                {nameState.saved ? <p className="text-sm text-ok">Имя сохранено.</p> : null}
                <div>
                  <Button type="submit" disabled={namePending}>
                    Сохранить имя
                  </Button>
                </div>
              </form>

              <form action={savePassword} className="flex max-w-md flex-col gap-4">
                <Field id="current-password" label="Текущий пароль">
                  <input
                    id="current-password"
                    name="current"
                    type="password"
                    className={inputClass}
                    autoComplete="current-password"
                  />
                </Field>
                <Field id="next-password" label="Новый пароль" hint="Не короче 12 символов, с буквой и цифрой.">
                  <input
                    id="next-password"
                    name="next"
                    type="password"
                    className={inputClass}
                    autoComplete="new-password"
                  />
                </Field>
                <Field id="confirm-password" label="Новый пароль ещё раз">
                  <input
                    id="confirm-password"
                    name="confirm"
                    type="password"
                    className={inputClass}
                    autoComplete="new-password"
                  />
                </Field>
                {passwordState.error ? (
                  <p className="text-sm text-bad">{passwordState.error}</p>
                ) : null}
                {passwordState.saved ? <p className="text-sm text-ok">Пароль изменён.</p> : null}
                <div className="flex flex-wrap gap-2">
                  <Button type="submit" disabled={passwordPending}>
                    Сменить пароль
                  </Button>
                </div>
              </form>

              <form action={logout}>
                <Button type="submit" variant="secondary">
                  Выйти
                </Button>
              </form>
            </div>
          </section>

          <section className="glass overflow-hidden">
            <SectionHeading>Тема</SectionHeading>
            <div className="px-4 py-4">
              <p className="text-sm text-muted">
                Светлая и тёмная темы запоминаются в этом браузере.
              </p>
              <div className="mt-4 grid gap-3 sm:grid-cols-2">
                <ThemeChoice
                  label="Светлая"
                  text="Светлое стекло на холодном фоне."
                  selected={theme === "light"}
                  mode="light"
                  onSelect={() => setTheme("light")}
                />
                <ThemeChoice
                  label="Тёмная"
                  text="Основной тёмный режим панели."
                  selected={theme === "dark"}
                  mode="dark"
                  onSelect={() => setTheme("dark")}
                />
              </div>
            </div>
          </section>
        </div>

        <div className="flex flex-col gap-4">
          <section className="glass overflow-hidden">
            <SectionHeading>Журнал</SectionHeading>
            {audit.length === 0 ? (
              <p className="px-4 py-4 text-sm text-muted">Записей пока нет.</p>
            ) : (
              <ul>
                {audit.map((entry) => (
                  <li
                    key={entry.id}
                    className="grid gap-1 border-b border-line px-4 py-3 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-baseline"
                  >
                    <p className="truncate text-sm text-ink">
                      {auditLabels[entry.action] ?? "Операция"}
                      {entry.target ? <span className="text-muted"> · {entry.target}</span> : null}
                    </p>
                    <p className="text-xs text-muted">{formatDateTime(entry.createdAt)}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}

function SectionHeading({ children }: { children: string }) {
  return (
    <div className="border-b border-line px-5 py-3">
      <h2 className="text-sm font-medium text-ink">{children}</h2>
    </div>
  );
}

function ThemeChoice({
  label,
  text,
  selected,
  mode,
  onSelect,
}: {
  label: string;
  text: string;
  selected: boolean;
  mode: Theme;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      className={cx(
        "rounded-2xl border p-3 text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        selected ? "border-accent/50 bg-accent/10" : "border-line bg-inset hover:border-accent/30",
      )}
    >
      <span
        className="mb-3 block h-12 rounded-xl"
        style={{
          background:
            mode === "dark"
              ? "linear-gradient(120deg, #07111c 0%, #16345a 62%, #7ec8ff 100%)"
              : "linear-gradient(120deg, #f7fbff 0%, #d5e6f5 62%, #0b78b4 100%)",
        }}
        data-theme-preview={mode}
      />
      <span className="flex items-center justify-between gap-2">
        <span className="font-medium text-ink">{label}</span>
        <span className="text-xs font-medium text-accent">{selected ? "выбрана" : ""}</span>
      </span>
      <span className="mt-1 block text-sm text-muted">{text}</span>
    </button>
  );
}
