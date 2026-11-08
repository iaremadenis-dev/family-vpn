import type { Metadata } from "next";
import { Suspense } from "react";
import { ServersView } from "@/components/servers-view";
import { listServers } from "@/lib/server/servers";

export const metadata: Metadata = {
  title: "Серверы",
};

export default function ServersPage() {
  return (
    <Suspense fallback={<p className="text-sm text-muted">Загрузка серверов…</p>}>
      <ServersData />
    </Suspense>
  );
}

async function ServersData() {
  const servers = await listServers();
  return <ServersView servers={servers} />;
}
