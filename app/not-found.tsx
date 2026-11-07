import Link from "next/link";

export default function NotFound() {
  return (
    <main className="grid min-h-dvh place-items-center px-4">
      <div className="glass w-full max-w-md p-6">
        <p className="text-xs font-medium text-accent">404</p>
        <h1 className="mt-2 text-xl font-semibold tracking-tight text-ink">
          Страница не найдена
        </h1>
        <p className="mt-2 text-sm text-muted">Такого раздела в Family VPN нет.</p>
        <Link
          href="/"
          className="mt-5 inline-flex h-10 items-center justify-center rounded-xl bg-accent px-4 text-sm font-medium text-accent-ink"
        >
          На обзор
        </Link>
      </div>
    </main>
  );
}
