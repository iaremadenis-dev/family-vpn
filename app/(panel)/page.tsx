import type { Metadata } from "next";
import { Suspense } from "react";
import { DashboardView } from "@/components/dashboard-view";
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
  const servers = await listServers();
  return <DashboardView servers={servers} />;
}
