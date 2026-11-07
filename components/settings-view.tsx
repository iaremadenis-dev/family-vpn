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
        kicker="system"
        title="Настройки"
        description="Одна учётная запись администратора, тема оформления и общие параметры системы."
      />

      <div className="grid gap-4 xl:grid-cols-2">
        <div className="flex flex-col gap-4">
          <section className="border border-line bg-panel">
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

          <section className="border border-line bg-panel">
            <SectionHeading code="UI">Тема</SectionHeading>
            <div className="px-4 py-4">
              <p className="text-sm text-muted">
                Светлая и тёмная темы применяются сразу и запоминаются в этом браузере.
                На сервер ничего не отправляется.
              </p>
              <div className="mt-4 grid gap-px bg-line sm:grid-cols-2">
                <ThemeChoice
                  label="Светлая"
                  text="Светлое поле, те же контуры панелей."
                  selected={theme === "light"}
                  mode="light"
                  onSelect={() => setTheme("light")}
                />
                <ThemeChoice
                  label="Тёмная"
                  text="Основной режим панели управления."
                  selected={theme === "dark"}
                  mode="dark"
                  onSelect={() => setTheme("dark")}
                />
              </div>
            </div>
          </section>
        </div>

        <section className="border border-line bg-panel">
          <SectionHeading code="CFG">Система</SectionHeading>
          <dl>
            {systemRows.map(([label, value]) => (
              <div
                key={label}
                className="grid gap-1 border-b border-line px-4 py-3 sm:grid-cols-[11rem_minmax(0,1fr)] sm:items-baseline"
              >
                <dt className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
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
    <div className="flex items-center justify-between border-b border-line px-4 py-2">
      <h2 className="font-mono text-[11px] tracking-[0.16em] text-muted uppercase">
        {children}
      </h2>
      <span className="font-mono text-[10px] text-accent">{code}</span>
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
        "bg-panel p-3 text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        selected ? "bg-inset" : "hover:bg-inset",
      )}
    >
      <span
        className="mb-3 block h-10 border border-line"
        style={{
          background:
            mode === "dark"
              ? "linear-gradient(90deg, #0e1621 0 70%, #22d3ee 70% 100%)"
              : "linear-gradient(90deg, #f5f9fb 0 70%, #0e7490 70% 100%)",
        }}
        data-theme-preview={mode}
      />
      <span className="flex items-center justify-between gap-2">
        <span className="font-medium text-ink">{label}</span>
        <span className="font-mono text-[10px] tracking-[0.14em] text-accent uppercase">
          {selected ? "active" : mode}
        </span>
      </span>
      <span className="mt-1 block text-sm text-muted">{text}</span>
    </button>
  );
}
