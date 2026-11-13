import type { Metadata } from "next";
import { Suspense } from "react";
import { ServersView } from "@/components/servers-view";
import { demoConfigs, demoServers, demoUiEnabled } from "@/lib/demo-ui";
import { listConfigs } from "@/lib/server/configs";
import { requireAdmin } from "@/lib/server/guard";
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
  if (demoUiEnabled()) {
    await requireAdmin();
    const install = await getInstallCommandInfo();
    return <ServersView demo servers={demoServers} configs={demoConfigs} install={install} />;
  }
  const [servers, configs, install] = await Promise.all([
    listServers(),
    listConfigs(),
    getInstallCommandInfo(),
  ]);
  return <ServersView servers={servers} configs={configs} install={install} />;
}
