"use client";

import { useId, useState } from "react";
import { useDemo } from "@/components/demo-provider";
import { useTheme } from "@/components/theme-provider";
import {
  Button,
  DemoNote,
  Dialog,
  Field,
  PageHeader,
  inputClass,
  panelClass,
} from "@/components/ui";
import { cx } from "@/lib/cx";
import type { Theme } from "@/lib/theme";

const systemRows = [
  ["Режим", "Демонстрационный интерфейс"],
  ["Администраторы", "Одна учётная запись"],
  ["Учётные записи VPN", "Не используются"],
  ["Подписки и платежи", "Не используются"],
  ["Протокол", "WireGuard, управление не подключено"],
  ["Размещение", "Отдельный сервер админки планируется позже"],
] as const;

export function SettingsView() {
  const { adminName, setAdminName, resetDemo } = useDemo();
  const { theme, setTheme } = useTheme();
  const nameId = useId();
  const [draft, setDraft] = useState(adminName);
  const [error, setError] = useState<string | null>(null);
  const [resetOpen, setResetOpen] = useState(false);

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title="Настройки"
        description="Одна учётная запись администратора, тема оформления и общие параметры системы."
      />

      <section className={panelClass}>
        <h2 className="text-base font-semibold">Администратор</h2>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Вход и проверка пароля на этом этапе не подключены. Имя видно только в
          боковой панели текущего окна.
        </p>
        <form
          className="mt-4 flex max-w-md flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            if (!draft.trim()) {
              setError("Укажите имя.");
              return;
            }
            if (draft.trim().length > 40) {
              setError("Имя длиннее 40 символов.");
              return;
            }
            setError(null);
            setAdminName(draft);
          }}
        >
          <Field id={nameId} label="Отображаемое имя">
            <input
              id={nameId}
              className={inputClass}
              value={draft}
              maxLength={40}
              autoComplete="off"
              onChange={(event) => setDraft(event.target.value)}
            />
          </Field>
          {error ? (
            <p className="text-sm text-rose-700 dark:text-rose-300">{error}</p>
          ) : null}
          <div>
            <Button type="submit">
              Показать в интерфейсе
            </Button>
          </div>
        </form>
      </section>

      <section className={panelClass}>
        <h2 className="text-base font-semibold">Тема</h2>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Светлая и тёмная темы применяются сразу и запоминаются в этом браузере.
          На сервер ничего не отправляется.
        </p>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <ThemeChoice
            label="Светлая"
            text="Светлый фон и белые карточки."
            selected={theme === "light"}
            previewClass="border-zinc-200 bg-white"
            onSelect={() => setTheme("light")}
          />
          <ThemeChoice
            label="Тёмная"
            text="Тёмный фон и приглушённые карточки."
            selected={theme === "dark"}
            previewClass="border-zinc-700 bg-zinc-900"
            onSelect={() => setTheme("dark")}
          />
        </div>
      </section>

      <section className={panelClass}>
        <h2 className="text-base font-semibold">Система</h2>
        <dl className="mt-3 divide-y divide-zinc-200 dark:divide-zinc-800">
          {systemRows.map(([label, value]) => (
            <div
              key={label}
              className="flex flex-col gap-1 py-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <dt className="text-sm text-zinc-500 dark:text-zinc-400">{label}</dt>
              <dd className="text-sm font-medium sm:text-right">{value}</dd>
            </div>
          ))}
        </dl>
        <div className="mt-2 border-t border-zinc-200 pt-4 dark:border-zinc-800">
          <Button variant="secondary" onClick={() => setResetOpen(true)}>
            Вернуть примерные данные
          </Button>
          <p className="mt-2 text-xs text-zinc-500 dark:text-zinc-400">
            Серверы, конфигурации и имя администратора вернутся к примеру. Тема
            останется выбранной.
          </p>
        </div>
      </section>

      <Dialog
        open={resetOpen}
        title="Вернуть примерные данные"
        onClose={() => setResetOpen(false)}
      >
        <div className="flex flex-col gap-4">
          <DemoNote>
            Демонстрация. Локальные правки списка будут заменены исходным
            примером. Серверы по сети не затрагиваются.
          </DemoNote>
          <div className="flex flex-wrap justify-end gap-2">
            <Button variant="secondary" onClick={() => setResetOpen(false)}>
              Отмена
            </Button>
            <Button
              onClick={() => {
                resetDemo();
                setDraft("Администратор");
                setError(null);
                setResetOpen(false);
              }}
            >
              Вернуть пример
            </Button>
          </div>
        </div>
      </Dialog>
    </div>
  );
}

function ThemeChoice({
  label,
  text,
  selected,
  previewClass,
  onSelect,
}: {
  label: string;
  text: string;
  selected: boolean;
  previewClass: string;
  onSelect: () => void;
}) {
  const themeName: Theme = label === "Тёмная" ? "dark" : "light";
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      className={cx(
        "rounded-xl border p-4 text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
        selected
          ? "border-teal-700 ring-2 ring-teal-700/30 dark:border-teal-400 dark:ring-teal-400/30"
          : "border-zinc-200 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800",
      )}
    >
      <span
        className={cx("mb-3 block h-14 rounded-lg border", previewClass)}
        data-theme-preview={themeName}
      />
      <span className="block font-medium">{label}</span>
      <span className="mt-1 block text-sm text-zinc-500 dark:text-zinc-400">
        {text}
      </span>
    </button>
  );
}
