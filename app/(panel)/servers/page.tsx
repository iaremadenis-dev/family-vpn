import type { Metadata } from "next";
import { Suspense } from "react";
import { ServersView } from "@/components/servers-view";
import { getInstallCommandInfo } from "@/lib/server/install-command";
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
  const [servers, install] = await Promise.all([listServers(), getInstallCommandInfo()]);
  return <ServersView servers={servers} install={install} />;
}
