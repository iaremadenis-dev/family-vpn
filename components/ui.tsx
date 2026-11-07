"use client";

import { useEffect, type ButtonHTMLAttributes, type ReactNode } from "react";
import { cx } from "@/lib/cx";

export const panelClass = "glass text-ink";

export const inputClass =
  "h-10 w-full rounded-xl border border-line bg-inset px-3 text-sm text-ink outline-none transition-colors placeholder:text-muted focus:border-accent";

const buttonStyles = {
  primary:
    "bg-accent text-accent-ink shadow-[0_8px_24px_color-mix(in_srgb,var(--accent)_32%,transparent)] hover:brightness-110",
  secondary: "border border-line bg-inset text-ink hover:border-accent/60 hover:text-accent",
  danger: "border border-bad/30 bg-bad/10 text-bad hover:bg-bad/15",
  ghost: "text-muted hover:bg-inset hover:text-ink",
} as const;

const buttonSizes = {
  md: "h-9 px-3 text-sm",
  sm: "h-7 px-2 text-xs",
} as const;

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: keyof typeof buttonStyles;
  size?: keyof typeof buttonSizes;
};

export function Button({
  variant = "primary",
  size = "md",
  className,
  type = "button",
  ...props
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cx(
        "inline-flex items-center justify-center gap-2 rounded-xl font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-45",
        buttonSizes[size],
        buttonStyles[variant],
        className,
      )}
      {...props}
    />
  );
}

export function DemoChip() {
  return (
    <span className="rounded-full bg-warn/15 px-1.5 py-0.5 text-[10px] font-medium text-warn">
      демо
    </span>
  );
}

export function DemoNote({ children }: { children: ReactNode }) {
  return (
    <p className="rounded-xl bg-warn/10 px-3 py-2 text-sm text-ink">
      {children}
    </p>
  );
}

const ledStyles = {
  online: "bg-ok",
  degraded: "bg-warn",
  offline: "bg-muted",
  active: "bg-ok",
  revoked: "bg-bad",
} as const;

const badgeStyles = {
  online: "bg-ok/15 text-ok",
  degraded: "bg-warn/15 text-warn",
  offline: "bg-inset text-muted",
  active: "bg-ok/15 text-ok",
  revoked: "bg-bad/15 text-bad",
} as const;

const badgeLabels = {
  online: "В сети",
  degraded: "Нестабилен",
  offline: "Не в сети",
  active: "Активна",
  revoked: "Отозвана",
} as const;

export function StatusBadge({
  status,
}: {
  status: keyof typeof ledStyles;
}) {
  return (
    <span
      className={cx(
        "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
        badgeStyles[status],
      )}
    >
      <span className={cx("h-1.5 w-1.5 rounded-full", ledStyles[status])} />
      {badgeLabels[status]}
    </span>
  );
}

export function PageHeader({
  kicker,
  title,
  description,
  action,
}: {
  kicker: string;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="max-w-3xl">
        <p className="text-xs font-medium text-accent">{kicker}</p>
        <h2 className="sr-only">{title}</h2>
        <p className="text-sm text-muted">{description}</p>
      </div>
      {action ? (
        <div className="sm:shrink-0 [&>button]:w-full sm:[&>button]:w-auto">{action}</div>
      ) : null}
    </div>
  );
}

export function EmptyState({
  title,
  text,
}: {
  title: string;
  text: string;
}) {
  return (
    <div className="glass border-dashed px-5 py-10 text-center">
      <p className="font-medium text-ink">{title}</p>
      <p className="mt-2 text-sm text-muted">{text}</p>
    </div>
  );
}

export function Field({
  id,
  label,
  hint,
  children,
}: {
  id: string;
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <div>
      <label
        htmlFor={id}
        className="mb-1.5 block text-sm font-medium text-ink"
      >
        {label}
      </label>
      {children}
      {hint ? <p className="mt-1.5 text-xs text-muted">{hint}</p> : null}
    </div>
  );
}

export function Dialog({
  open,
  title,
  onClose,
  children,
}: {
  open: boolean;
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    document.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = previous;
      document.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center p-4 sm:items-center">
      <div className="absolute inset-0 bg-[#04101c]/70 backdrop-blur-sm" onClick={onClose} aria-hidden="true" />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="dialog-title"
        className="glass relative z-10 max-h-[min(90dvh,40rem)] w-full max-w-lg overflow-y-auto p-5"
      >
        <div className="mb-4 flex items-start justify-between gap-3">
          <h2 id="dialog-title" className="text-lg font-semibold text-ink">
            {title}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="grid h-8 w-8 place-items-center rounded-full bg-inset text-lg leading-none text-muted hover:text-ink"
            aria-label="Закрыть"
          >
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
