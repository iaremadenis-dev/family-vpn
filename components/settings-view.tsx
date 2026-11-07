"use client";

import { useId, useState } from "react";
import { useDemo } from "@/components/demo-provider";
import { useTheme } from "@/components/theme-provider";
import { Button, DemoNote, Dialog, Field, PageHeader, inputClass } from "@/components/ui";
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
    <div className="flex flex-col gap-4">
      <PageHeader
        kicker="Система"
        title="Настройки"
        description="Одна учётная запись администратора, тема оформления и общие параметры системы."
      />

      <div className="grid gap-4 xl:grid-cols-2">
        <div className="flex flex-col gap-4">
          <section className="glass overflow-hidden">
            <SectionHeading code="OP">Администратор</SectionHeading>
            <div className="px-4 py-4">
              <p className="text-sm text-muted">
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
                {error ? <p className="text-sm text-bad">{error}</p> : null}
                <div>
                  <Button type="submit">Показать в интерфейсе</Button>
                </div>
              </form>
            </div>
          </section>

          <section className="glass overflow-hidden">
            <SectionHeading code="UI">Тема</SectionHeading>
            <div className="px-4 py-4">
              <p className="text-sm text-muted">
                Светлая и тёмная темы применяются сразу и запоминаются в этом браузере.
                На сервер ничего не отправляется.
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

        <section className="glass overflow-hidden">
          <SectionHeading code="CFG">Система</SectionHeading>
          <dl>
            {systemRows.map(([label, value]) => (
              <div
                key={label}
                className="grid gap-1 border-b border-line px-4 py-3 sm:grid-cols-[11rem_minmax(0,1fr)] sm:items-baseline"
              >
                <dt className="text-sm text-muted">
                  {label}
                </dt>
                <dd className="text-sm text-ink">{value}</dd>
              </div>
            ))}
          </dl>
          <div className="px-4 py-4">
            <Button variant="secondary" onClick={() => setResetOpen(true)}>
              Вернуть примерные данные
            </Button>
            <p className="mt-2 text-xs text-muted">
              Серверы, конфигурации и имя администратора вернутся к примеру. Тема
              останется выбранной.
            </p>
          </div>
        </section>
      </div>

      <Dialog
        open={resetOpen}
        title="Вернуть примерные данные"
        onClose={() => setResetOpen(false)}
      >
        <div className="flex flex-col gap-4">
          <DemoNote>
            Демонстрация. Локальные правки списка будут заменены исходным примером.
            Серверы по сети не затрагиваются.
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

function SectionHeading({ code, children }: { code: string; children: string }) {
  return (
    <div className="flex items-center justify-between border-b border-line px-5 py-3">
      <h2 className="text-sm font-medium text-ink">{children}</h2>
      <span className="text-xs font-medium text-accent">{code}</span>
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
