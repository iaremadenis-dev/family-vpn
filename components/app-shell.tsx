"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ComponentType, SVGProps } from "react";
import { useDemo } from "@/components/demo-provider";
import {
  IconConfig,
  IconOverview,
  IconServer,
  IconSettings,
} from "@/components/icons";
import { cx } from "@/lib/cx";

const navItems: Array<{
  href: string;
  label: string;
  short: string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
}> = [
  { href: "/", label: "Обзор", short: "Обзор", icon: IconOverview },
  { href: "/servers", label: "Серверы", short: "Серверы", icon: IconServer },
  {
    href: "/configurations",
    label: "Конфигурации",
    short: "Конфиги",
    icon: IconConfig,
  },
  {
    href: "/settings",
    label: "Настройки",
    short: "Настройки",
    icon: IconSettings,
  },
];

const sections: Record<string, string> = {
  "/": "Обзор",
  "/servers": "Серверы",
  "/configurations": "Конфигурации",
  "/settings": "Настройки",
};

function NavLink({
  href,
  label,
  icon: Icon,
  compact = false,
}: {
  href: string;
  label: string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
  compact?: boolean;
}) {
  const pathname = usePathname();
  const active = pathname === href;

  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={cx(
        "transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        compact
          ? "flex flex-col items-center gap-1 rounded-xl px-1 py-2 text-[10px]"
          : "flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm",
        active
          ? "bg-accent/15 text-ink shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--accent)_45%,transparent)]"
          : "text-muted hover:bg-inset hover:text-ink",
      )}
    >
      <Icon className={cx("h-4 w-4 shrink-0", active && "text-accent")} />
      {label}
    </Link>
  );
}

function Mark({ compact = false }: { compact?: boolean }) {
  return (
    <span
      className={cx(
        "grid place-items-center rounded-xl bg-accent font-semibold text-accent-ink shadow-[0_8px_22px_color-mix(in_srgb,var(--accent)_35%,transparent)]",
        compact ? "h-8 w-8 text-[11px]" : "h-9 w-9 text-xs",
      )}
    >
      FV
    </span>
  );
}

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const { adminName, servers, configurations } = useDemo();
  const title = sections[pathname] ?? "Family VPN";
  const online = servers.filter((server) => server.status === "online").length;
  const allOnline = servers.length > 0 && online === servers.length;

  return (
    <div className="min-h-dvh md:pl-[16.75rem]">
      <aside className="glass fixed top-3 bottom-3 left-3 z-30 hidden w-56 flex-col md:flex">
        <div className="flex items-center gap-2.5 px-4 pt-4 pb-3">
          <Mark />
          <span className="min-w-0">
            <span className="block truncate text-sm font-semibold tracking-tight text-ink">
              Family VPN
            </span>
            <span className="block text-xs text-muted">WireGuard</span>
          </span>
        </div>
        <nav className="flex flex-1 flex-col gap-1 px-2" aria-label="Разделы">
          {navItems.map((item) => (
            <NavLink key={item.href} {...item} />
          ))}
        </nav>
        <div className="m-2 rounded-2xl bg-inset px-3 py-3">
          <p className="truncate text-sm font-medium text-ink">{adminName}</p>
          <p className="mt-0.5 text-xs text-muted">Локальная сессия</p>
        </div>
      </aside>

      <div className="flex flex-col gap-4 px-3 py-3 pb-28 md:px-5 md:py-4 md:pb-6">
        <header className="glass sticky top-3 z-20 flex h-14 items-center justify-between gap-3 px-3 md:px-4">
          <div className="flex min-w-0 items-center gap-2.5">
            <span className="md:hidden">
              <Mark compact />
            </span>
            <p className="truncate text-sm font-semibold text-ink">{title}</p>
          </div>
          <div className="flex shrink-0 items-center gap-2 text-xs">
            <span
              className={cx(
                "hidden rounded-full px-2.5 py-1 sm:inline",
                allOnline ? "bg-ok/15 text-ok" : "bg-inset text-muted",
              )}
            >
              <span className={online > 0 ? "text-ok" : "text-bad"}>{online}</span>
              <span> из {servers.length} в сети</span>
            </span>
            <span className="hidden rounded-full bg-inset px-2.5 py-1 text-muted md:inline">
              {configurations.length} конфиг.
            </span>
            <span className="rounded-full bg-warn/15 px-2.5 py-1 font-medium text-warn">
              Демо
            </span>
          </div>
        </header>

        <p className="glass flex flex-col gap-1 px-4 py-3 text-sm text-muted sm:flex-row sm:items-baseline sm:gap-3">
          <span className="text-xs font-medium text-warn">Демонстрация</span>
          <span>
            Цифры и списки — пример. Кнопки не обращаются к VPS и WireGuard: ключи и
            файлы .conf не создаются, изменения не сохраняются.
          </span>
        </p>
        {children}
      </div>

      <nav
        className="glass fixed inset-x-3 bottom-3 z-30 pb-[env(safe-area-inset-bottom)] md:hidden"
        aria-label="Разделы"
      >
        <ul className="grid grid-cols-4 px-1 py-1">
          {navItems.map((item) => (
            <li key={item.href}>
              <NavLink href={item.href} label={item.short} icon={item.icon} compact />
            </li>
          ))}
        </ul>
      </nav>
    </div>
  );
}
