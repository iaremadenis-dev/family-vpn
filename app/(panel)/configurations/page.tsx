import type { Metadata } from "next";
import { ConfigurationsView } from "@/components/configurations-view";
import { demoConfigs, demoServers, demoUiEnabled } from "@/lib/demo-ui";
import { listConfigs } from "@/lib/server/configs";
import { requireAdmin } from "@/lib/server/guard";
import { listServers } from "@/lib/server/servers";

export const metadata: Metadata = {
  title: "Конфигурации",
};

export default async function ConfigurationsPage() {
  if (demoUiEnabled()) {
    await requireAdmin();
    return <ConfigurationsView demo configs={demoConfigs} servers={demoServers} />;
  }
  const [configs, servers] = await Promise.all([listConfigs(), listServers()]);
  return <ConfigurationsView configs={configs} servers={servers} />;
}
