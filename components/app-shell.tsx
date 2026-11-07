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
  code: string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
}> = [
  { href: "/", label: "Обзор", short: "Обзор", code: "01", icon: IconOverview },
  { href: "/servers", label: "Серверы", short: "Серверы", code: "02", icon: IconServer },
  {
    href: "/configurations",
    label: "Конфигурации",
    short: "Конфиги",
    code: "03",
    icon: IconConfig,
  },
  {
    href: "/settings",
    label: "Настройки",
    short: "Настройки",
    code: "04",
    icon: IconSettings,
  },
];

const sections: Record<string, { code: string; title: string }> = {
  "/": { code: "DASH", title: "Обзор" },
  "/servers": { code: "NODES", title: "Серверы" },
  "/configurations": { code: "PEERS", title: "Конфигурации" },
  "/settings": { code: "SYS", title: "Настройки" },
};

function NavLink({
  href,
  label,
  code,
  icon: Icon,
  compact = false,
}: {
  href: string;
  label: string;
  code: string;
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
          ? "flex flex-col items-center gap-1 border-t-2 px-1 py-2 text-[10px] tracking-wide uppercase"
          : "flex items-center gap-2.5 border-l-2 px-3 py-2 text-[13px]",
        active
          ? "border-accent bg-inset text-ink"
          : "border-transparent text-muted hover:bg-inset hover:text-ink",
      )}
    >
      {compact ? null : (
        <span className="w-4 font-mono text-[10px] text-muted">{code}</span>
      )}
      <Icon className="h-4 w-4 shrink-0" />
      {label}
    </Link>
  );
}

function Mark({ compact = false }: { compact?: boolean }) {
  return (
    <span
      className={cx(
        "grid place-items-center border border-accent bg-accent/10 font-mono font-semibold text-accent",
        compact ? "h-7 w-7 text-[10px]" : "h-8 w-8 text-xs",
      )}
    >
      FV
    </span>
  );
}

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const { adminName, servers, configurations } = useDemo();
  const section = sections[pathname] ?? { code: "NAV", title: "Family VPN" };
  const online = servers.filter((server) => server.status === "online").length;

  return (
    <div className="min-h-dvh md:pl-52">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-52 flex-col border-r border-line bg-panel md:flex">
        <div className="flex items-center gap-2.5 border-b border-line px-3 py-3">
          <Mark />
          <span className="min-w-0">
            <span className="block truncate text-sm font-semibold tracking-tight text-ink">
              Family VPN
            </span>
            <span className="block font-mono text-[10px] tracking-[0.16em] text-muted uppercase">
              wg control
            </span>
          </span>
        </div>
        <nav className="flex flex-1 flex-col py-2" aria-label="Разделы">
          {navItems.map((item) => (
            <NavLink key={item.href} {...item} />
          ))}
        </nav>
        <div className="border-t border-line px-3 py-3">
          <p className="font-mono text-[10px] tracking-[0.16em] text-muted uppercase">
            operator
          </p>
          <p className="mt-1 truncate text-sm text-ink">{adminName}</p>
          <p className="mt-0.5 font-mono text-[10px] text-muted">local session</p>
        </div>
      </aside>

      <div className="flex min-h-dvh flex-col">
        <header className="sticky top-0 z-20 flex h-12 items-center justify-between gap-3 border-b border-t-2 border-line border-t-accent bg-panel px-3 md:px-5">
          <div className="flex min-w-0 items-center gap-2.5">
            <span className="md:hidden">
              <Mark compact />
            </span>
            <p className="truncate font-mono text-[11px] tracking-[0.14em] text-muted uppercase">
              <span className="text-accent">{section.code}</span>
              <span className="px-1.5 text-line">/</span>
              <span className="text-ink">{section.title}</span>
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-2 font-mono text-[10px] tracking-[0.12em] uppercase">
            <span className="hidden border border-line bg-canvas px-1.5 py-1 text-muted sm:inline">
              <span className={online > 0 ? "text-ok" : "text-bad"}>{online}</span>
              <span>/{servers.length} nodes</span>
            </span>
            <span className="hidden border border-line bg-canvas px-1.5 py-1 text-muted md:inline">
              {configurations.length} cfg
            </span>
            <span className="border border-warn/50 px-1.5 py-1 text-warn">demo</span>
          </div>
        </header>

        <div className="flex flex-1 flex-col gap-4 px-3 py-4 pb-24 md:px-5 md:pb-6">
          <p className="flex flex-col gap-1 border border-line bg-panel px-3 py-2 text-xs text-muted sm:flex-row sm:items-baseline sm:gap-3">
            <span className="font-mono text-[10px] tracking-[0.16em] text-warn uppercase">
              sys / demo
            </span>
            <span>
              Цифры и списки — пример. Кнопки не обращаются к VPS и WireGuard: ключи
              и файлы .conf не создаются, изменения не сохраняются.
            </span>
          </p>
          {children}
        </div>
      </div>

      <nav
        className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-panel pb-[env(safe-area-inset-bottom)] md:hidden"
        aria-label="Разделы"
      >
        <ul className="grid grid-cols-4">
          {navItems.map((item) => (
            <li key={item.href}>
              <NavLink
                href={item.href}
                label={item.short}
                code={item.code}
                icon={item.icon}
                compact
              />
            </li>
          ))}
        </ul>
      </nav>
    </div>
  );
}
