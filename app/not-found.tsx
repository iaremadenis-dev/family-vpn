import Link from "next/link";

export default function NotFound() {
  return (
    <main className="grid min-h-dvh place-items-center px-4">
      <div className="w-full max-w-md border border-line bg-panel p-6">
        <p className="font-mono text-[11px] tracking-[0.18em] text-accent uppercase">
          404 · route
        </p>
        <h1 className="mt-2 text-xl font-semibold tracking-tight text-ink">
          Страница не найдена
        </h1>
        <p className="mt-2 text-sm text-muted">Такого раздела в Family VPN нет.</p>
        <Link
          href="/"
          className="mt-5 inline-flex h-9 items-center justify-center bg-accent px-3 text-sm font-medium text-accent-ink"
        >
          На обзор
        </Link>
      </div>
    </main>
  );
}
