import Link from "next/link";

export default function NotFound() {
  return (
    <main className="grid min-h-dvh place-items-center bg-zinc-100 px-4 dark:bg-zinc-950">
      <div className="w-full max-w-md rounded-xl border border-zinc-200 bg-white p-6 text-center shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <p className="text-sm font-medium text-zinc-500 dark:text-zinc-400">404</p>
        <h1 className="mt-2 text-2xl font-semibold">Страница не найдена</h1>
        <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
          Такого раздела в Family VPN нет.
        </p>
        <Link
          href="/"
          className="mt-5 inline-flex h-10 items-center justify-center rounded-lg bg-teal-800 px-4 text-sm font-medium text-white dark:bg-teal-400 dark:text-teal-950"
        >
          На обзор
        </Link>
      </div>
    </main>
  );
}
