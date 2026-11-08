import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { LoginForm } from "@/components/login-form";
import { hasAdmin } from "@/lib/server/admin";
import { readSession } from "@/lib/server/session";

export const metadata: Metadata = {
  title: "Вход",
};

export default function LoginPage() {
  return (
    <Suspense fallback={<p className="px-6 py-10 text-sm text-muted">Загрузка входа…</p>}>
      <LoginGate />
    </Suspense>
  );
}

async function LoginGate() {
  const session = await readSession();
  if (session) redirect("/");
  return <LoginForm mode={hasAdmin() ? "login" : "setup"} />;
}
