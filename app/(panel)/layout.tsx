import { Suspense, type ReactNode } from "react";
import { AppShell } from "@/components/app-shell";
import { demoServers, demoUiEnabled } from "@/lib/demo-ui";
import { getPanelSummary } from "@/lib/server/panel";

export default function PanelLayout({ children }: { children: ReactNode }) {
  return (
    <Suspense fallback={<p className="px-6 py-10 text-sm text-muted">Загрузка панели…</p>}>
      <PanelFrame>{children}</PanelFrame>
    </Suspense>
  );
}

async function PanelFrame({ children }: { children: ReactNode }) {
  const summary = await getPanelSummary();
  const demo = demoUiEnabled();
  const shellSummary = demo
    ? {
        ...summary,
        serverCount: demoServers.length,
        onlineCount: demoServers.filter((server) => server.linkStatus === "online").length,
      }
    : summary;
  return (
    <AppShell summary={shellSummary} demo={demo}>
      {children}
    </AppShell>
  );
}
