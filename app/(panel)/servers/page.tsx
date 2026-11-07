import type { Metadata } from "next";
import { ServersView } from "@/components/servers-view";

export const metadata: Metadata = {
  title: "Серверы",
};

export default function ServersPage() {
  return <ServersView />;
}
