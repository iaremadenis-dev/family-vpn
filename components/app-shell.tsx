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
        "rounded-lg text-sm font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700",
        compact
          ? "flex flex-col items-center gap-1 px-1 py-2 text-[11px]"
          : "flex items-center gap-3 px-3 py-2",
        active
          ? "bg-teal-50 text-teal-900 dark:bg-teal-950/60 dark:text-teal-100"
          : "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800",
      )}
    >
      <Icon className="h-5 w-5 shrink-0" />
      {label}
    </Link>
  );
}

export function AppShell({ children }: { children: React.ReactNode }) {
  const { adminName } = useDemo();

  return (
    <div className="min-h-dvh md:pl-60">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-60 flex-col border-r border-zinc-200 bg-white md:flex dark:border-zinc-800 dark:bg-zinc-900">
        <div className="flex items-center gap-3 px-4 py-5">
          <span className="grid h-9 w-9 place-items-center rounded-lg bg-teal-800 text-sm font-semibold text-white dark:bg-teal-400 dark:text-teal-950">
            VC
          </span>
          <span>
            <span className="block text-sm font-semibold">Family VPN</span>
            <span className="block text-xs text-zinc-500 dark:text-zinc-400">
              WireGuard
            </span>
          </span>
        </div>
        <nav className="flex flex-1 flex-col gap-1 px-3" aria-label="Разделы">
          {navItems.map((item) => (
            <NavLink key={item.href} {...item} />
          ))}
        </nav>
        <div className="border-t border-zinc-200 p-4 dark:border-zinc-800">
          <p className="truncate text-sm font-medium">{adminName}</p>
          <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
            Один администратор · демо
          </p>
        </div>
      </aside>

      <header className="sticky top-0 z-20 flex h-14 items-center justify-between border-b border-zinc-200 bg-white/90 px-4 backdrop-blur md:hidden dark:border-zinc-800 dark:bg-zinc-900/90">
        <span className="flex items-center gap-2">
          <span className="grid h-8 w-8 place-items-center rounded-lg bg-teal-800 text-xs font-semibold text-white dark:bg-teal-400 dark:text-teal-950">
            VC
          </span>
          <span className="text-sm font-semibold">Family VPN</span>
        </span>
        <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900 dark:bg-amber-900/60 dark:text-amber-100">
          Демо
        </span>
      </header>

      <div className="px-4 py-5 pb-24 md:px-8 md:py-8 md:pb-8">
        <div className="mx-auto flex max-w-6xl flex-col gap-5">
          <p className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-100">
            <span className="font-medium">Демонстрационный режим.</span> Цифры и
            списки — пример. Кнопки не обращаются к VPS и WireGuard: ключи и
            файлы .conf не создаются, изменения не сохраняются.
          </p>
          {children}
        </div>
      </div>

      <nav
        className="fixed inset-x-0 bottom-0 z-30 border-t border-zinc-200 bg-white pb-[env(safe-area-inset-bottom)] md:hidden dark:border-zinc-800 dark:bg-zinc-900"
        aria-label="Разделы"
      >
        <ul className="grid grid-cols-4">
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
