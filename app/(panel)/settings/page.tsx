import type { Metadata } from "next";
import { Suspense } from "react";
import { SettingsView } from "@/components/settings-view";
import { listAudit } from "@/lib/server/audit";
import { requireAdmin } from "@/lib/server/guard";

export const metadata: Metadata = {
  title: "Настройки",
};

export default function SettingsPage() {
  return (
    <Suspense fallback={<p className="text-sm text-muted">Загрузка настроек…</p>}>
      <SettingsData />
    </Suspense>
  );
}

async function SettingsData() {
  const session = await requireAdmin();
  const audit = await listAudit();
  return <SettingsView adminName={session.displayName} audit={audit} />;
}
