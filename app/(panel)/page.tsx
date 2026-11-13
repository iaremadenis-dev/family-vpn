import type { Metadata } from "next";
import { Suspense } from "react";
import { DashboardView } from "@/components/dashboard-view";
import { demoConfigs, demoServers, demoUiEnabled } from "@/lib/demo-ui";
import { listConfigs } from "@/lib/server/configs";
import { requireAdmin } from "@/lib/server/guard";
import { listServers } from "@/lib/server/servers";

export const metadata: Metadata = {
  title: "Обзор",
};

export default function DashboardPage() {
  return (
    <Suspense fallback={<p className="text-sm text-muted">Загрузка обзора…</p>}>
      <DashboardData />
    </Suspense>
  );
}

async function DashboardData() {
  if (demoUiEnabled()) {
    await requireAdmin();
    return <DashboardView demo servers={demoServers} configs={demoConfigs} />;
  }
  const [servers, configs] = await Promise.all([listServers(), listConfigs()]);
  return <DashboardView servers={servers} configs={configs} />;
}
