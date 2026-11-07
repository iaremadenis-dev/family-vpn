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
          ? "bg-accent text-accent-ink shadow-[0_10px_24px_color-mix(in_srgb,var(--accent)_32%,transparent)]"
          : "text-muted hover:bg-inset hover:text-ink",
      )}
    >
      <Icon className="h-4 w-4 shrink-0" />
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
    <div className="relative min-h-dvh md:pl-[16.75rem]">
      <div className="scene" aria-hidden="true">
        <Mountains className="scene-mountains" />
      </div>
      <aside className="glass sidebar-glass fixed top-3 bottom-3 left-3 z-30 hidden w-56 overflow-hidden md:flex md:flex-col">
        <Mountains className="pointer-events-none absolute inset-x-0 bottom-0 h-48 w-full opacity-80" />
        <div className="relative z-10 flex min-h-0 flex-1 flex-col">
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
          <div className="relative z-10 m-3 rounded-2xl bg-canvas/75 px-3 py-3 backdrop-blur-md">
            <p className="truncate text-sm font-medium text-ink">{adminName}</p>
            <p className="mt-0.5 text-xs text-muted">Локальная сессия</p>
          </div>
        </div>
      </aside>

      <div className="relative z-10 flex flex-col gap-5 px-3 py-3 pb-28 md:px-5 md:py-4 md:pb-6">
        <header className="glass sticky top-3 z-20 flex h-12 items-center justify-between gap-3 px-3 md:px-4">
          <div className="flex min-w-0 items-center gap-2.5">
            <span className="md:hidden">
              <Mark compact />
            </span>
            <h1 className="truncate text-sm font-semibold text-ink">{title}</h1>
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

        <p className="px-1 text-xs leading-5 text-muted">
          Цифры и списки — пример. Кнопки не обращаются к VPS и WireGuard: ключи и
          файлы .conf не создаются, изменения не сохраняются.
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

function Mountains({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 800 240" preserveAspectRatio="none" aria-hidden="true">
      <path
        d="M0 168 L90 112 L150 146 L230 78 L310 138 L390 52 L470 124 L560 70 L650 132 L730 96 L800 140 L800 240 L0 240 Z"
        fill="var(--peak)"
        opacity="0.55"
      />
      <path
        d="M0 196 L120 150 L210 176 L300 124 L390 168 L500 112 L610 160 L720 130 L800 168 L800 240 L0 240 Z"
        fill="var(--peak-deep)"
        opacity="0.9"
      />
    </svg>
  );
}
