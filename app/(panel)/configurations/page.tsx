import type { Metadata } from "next";
import { ConfigurationsView } from "@/components/configurations-view";
import { listConfigs } from "@/lib/server/configs";
import { listServers } from "@/lib/server/servers";

export const metadata: Metadata = {
  title: "Конфигурации",
};

export default async function ConfigurationsPage() {
  const [configs, servers] = await Promise.all([listConfigs(), listServers()]);
  return <ConfigurationsView configs={configs} servers={servers} />;
}
