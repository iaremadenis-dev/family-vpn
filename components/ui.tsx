"use client";

import { useEffect, type ButtonHTMLAttributes, type ReactNode } from "react";
import { cx } from "@/lib/cx";

export const panelClass = "border border-line bg-panel text-ink";

export const inputClass =
  "h-9 w-full border border-line bg-canvas px-3 font-mono text-sm text-ink outline-none transition-colors placeholder:text-muted focus:border-accent";

const buttonStyles = {
  primary: "bg-accent text-accent-ink hover:brightness-110",
  secondary: "border border-line bg-panel text-ink hover:border-accent hover:text-accent",
  danger: "border border-bad/40 bg-panel text-bad hover:bg-bad/10",
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
        "inline-flex items-center justify-center gap-2 font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-45",
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
    <span className="border border-warn/50 px-1 font-mono text-[9px] tracking-[0.14em] text-warn uppercase">
      demo
    </span>
  );
}

export function DemoNote({ children }: { children: ReactNode }) {
  return (
    <p className="border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-ink">
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
    <span className="inline-flex items-center gap-1.5 border border-line bg-canvas px-1.5 py-0.5 font-mono text-[10px] tracking-[0.12em] text-ink uppercase">
      <span className={cx("h-1.5 w-1.5", ledStyles[status])} />
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
    <div className="flex flex-col gap-3 border border-line bg-panel px-4 py-3 sm:flex-row sm:items-end sm:justify-between">
      <div className="max-w-3xl">
        <p className="font-mono text-[10px] tracking-[0.18em] text-accent uppercase">
          {kicker}
        </p>
        <h1 className="mt-1 text-xl font-semibold tracking-tight text-ink">{title}</h1>
        <p className="mt-1 text-sm text-muted">{description}</p>
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
    <div className="border border-dashed border-line bg-panel px-5 py-10 text-center">
      <p className="font-mono text-xs tracking-[0.14em] text-ink uppercase">{title}</p>
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
        className="mb-1.5 block font-mono text-[10px] tracking-[0.14em] text-muted uppercase"
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
      <div className="absolute inset-0 bg-black/70" onClick={onClose} aria-hidden="true" />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="dialog-title"
        className="relative z-10 max-h-[min(90dvh,40rem)] w-full max-w-lg overflow-y-auto border border-line bg-panel p-4"
      >
        <div className="mb-4 flex items-start justify-between gap-3 border-b border-line pb-3">
          <div>
            <p className="font-mono text-[10px] tracking-[0.16em] text-accent uppercase">
              local action
            </p>
            <h2 id="dialog-title" className="mt-1 text-base font-semibold text-ink">
              {title}
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="border border-line px-2 text-lg leading-none text-muted hover:border-accent hover:text-ink"
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
