import type { Metadata } from "next";
import { ConfigurationsView } from "@/components/configurations-view";

export const metadata: Metadata = {
  title: "Конфигурации",
};

export default function ConfigurationsPage() {
  return <ConfigurationsView />;
}
