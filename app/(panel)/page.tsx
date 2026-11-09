import type { Metadata } from "next";
import { Suspense } from "react";
import { DashboardView } from "@/components/dashboard-view";
import { listConfigs } from "@/lib/server/configs";
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
  const [servers, configs] = await Promise.all([listServers(), listConfigs()]);
  return <DashboardView servers={servers} configs={configs} />;
}
