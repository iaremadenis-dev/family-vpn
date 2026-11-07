"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  initialAdminName,
  initialConfigurations,
  initialServers,
} from "@/lib/demo-data";
import type { ServerInput, VpnConfig, VpnServer } from "@/lib/types";

type DemoState = {
  adminName: string;
  servers: VpnServer[];
  configurations: VpnConfig[];
};

type DemoContextValue = DemoState & {
  setAdminName: (name: string) => void;
  addServer: (input: ServerInput) => void;
  updateServer: (id: string, input: ServerInput) => void;
  deleteServer: (id: string) => void;
  setDefaultServer: (id: string) => void;
  addConfiguration: (input: { name: string; serverId: string }) => void;
  revokeConfiguration: (id: string) => void;
  deleteConfiguration: (id: string) => void;
  resetDemo: () => void;
  notice: string | null;
  notify: (message: string) => void;
  dismissNotice: () => void;
};

const DemoContext = createContext<DemoContextValue | null>(null);

function createInitialState(): DemoState {
  return {
    adminName: initialAdminName,
    servers: initialServers.map((server) => ({ ...server })),
    configurations: initialConfigurations.map((config) => ({ ...config })),
  };
}

export function DemoProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<DemoState>(createInitialState);
  const [notice, setNotice] = useState<string | null>(null);

  const notify = useCallback((message: string) => {
    setNotice(message);
  }, []);

  const dismissNotice = useCallback(() => {
    setNotice(null);
  }, []);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 4200);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const setAdminName = useCallback(
    (name: string) => {
      setState((current) => ({ ...current, adminName: name.trim() }));
      notify("Имя показано только в этом окне. Учётная запись не сохраняется.");
    },
    [notify],
  );

  const addServer = useCallback(
    (input: ServerInput) => {
      const id = `srv-${crypto.randomUUID()}`;
      setState((current) => ({
        ...current,
        servers: [
          ...current.servers,
          {
            id,
            name: input.name.trim(),
            location: input.location.trim(),
            endpoint: input.endpoint.trim(),
            listenPort: input.listenPort,
            status: "offline",
            isDefault: current.servers.length === 0,
            rxBytes: 0,
            txBytes: 0,
            checkedAt: null,
          },
        ],
      }));
      notify("Сервер добавлен в демонстрационный список. Подключения не было.");
    },
    [notify],
  );

  const updateServer = useCallback(
    (id: string, input: ServerInput) => {
      setState((current) => ({
        ...current,
        servers: current.servers.map((server) =>
          server.id === id
            ? {
                ...server,
                name: input.name.trim(),
                location: input.location.trim(),
                endpoint: input.endpoint.trim(),
                listenPort: input.listenPort,
              }
            : server,
        ),
      }));
      notify("Параметры сервера изменены только на этом экране.");
    },
    [notify],
  );

  const deleteServer = useCallback(
    (id: string) => {
      setState((current) => {
        const remaining = current.servers.filter((server) => server.id !== id);
        const removedDefault = current.servers.some(
          (server) => server.id === id && server.isDefault,
        );
        return {
          ...current,
          servers: remaining.map((server, index) => ({
            ...server,
            isDefault: removedDefault ? index === 0 : server.isDefault,
          })),
          configurations: current.configurations.filter(
            (config) => config.serverId !== id,
          ),
        };
      });
      notify("Сервер удалён из демонстрационного списка.");
    },
    [notify],
  );

  const setDefaultServer = useCallback(
    (id: string) => {
      setState((current) => ({
        ...current,
        servers: current.servers.map((server) => ({
          ...server,
          isDefault: server.id === id,
        })),
      }));
      notify("Сервер по умолчанию выбран только в этом интерфейсе.");
    },
    [notify],
  );

  const addConfiguration = useCallback(
    (input: { name: string; serverId: string }) => {
      const id = `cfg-${crypto.randomUUID()}`;
      setState((current) => ({
        ...current,
        configurations: [
          {
            id,
            name: input.name.trim(),
            serverId: input.serverId,
            status: "active",
            createdAt: new Date().toISOString(),
            lastHandshake: null,
            rxBytes: 0,
            txBytes: 0,
          },
          ...current.configurations,
        ],
      }));
      notify(
        "Конфигурация добавлена в список. Ключи и файл .conf не создавались.",
      );
    },
    [notify],
  );

  const revokeConfiguration = useCallback(
    (id: string) => {
      setState((current) => ({
        ...current,
        configurations: current.configurations.map((config) =>
          config.id === id ? { ...config, status: "revoked" } : config,
        ),
      }));
      notify("Конфигурация отозвана в демонстрационном списке.");
    },
    [notify],
  );

  const deleteConfiguration = useCallback(
    (id: string) => {
      setState((current) => ({
        ...current,
        configurations: current.configurations.filter(
          (config) => config.id !== id,
        ),
      }));
      notify("Конфигурация удалена из демонстрационного списка.");
    },
    [notify],
  );

  const resetDemo = useCallback(() => {
    setState(createInitialState());
    notify("Примерные данные возвращены. Это по-прежнему только интерфейс.");
  }, [notify]);

  const value = useMemo<DemoContextValue>(
    () => ({
      ...state,
      setAdminName,
      addServer,
      updateServer,
      deleteServer,
      setDefaultServer,
      addConfiguration,
      revokeConfiguration,
      deleteConfiguration,
      resetDemo,
      notice,
      notify,
      dismissNotice,
    }),
    [
      state,
      setAdminName,
      addServer,
      updateServer,
      deleteServer,
      setDefaultServer,
      addConfiguration,
      revokeConfiguration,
      deleteConfiguration,
      resetDemo,
      notice,
      notify,
      dismissNotice,
    ],
  );

  return (
    <DemoContext.Provider value={value}>
      {children}
      {notice ? (
        <div className="pointer-events-none fixed inset-x-0 bottom-20 z-50 flex justify-center px-4 md:bottom-6">
          <div
            role="status"
            className="pointer-events-auto flex w-full max-w-md items-start gap-3 rounded-xl border border-zinc-200 bg-white px-4 py-3 text-sm text-zinc-800 shadow-lg dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
          >
            <p className="flex-1">{notice}</p>
            <button
              type="button"
              onClick={dismissNotice}
              className="rounded-md px-1 text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
              aria-label="Закрыть уведомление"
            >
              ×
            </button>
          </div>
        </div>
      ) : null}
    </DemoContext.Provider>
  );
}

export function useDemo() {
  const context = useContext(DemoContext);
  if (!context) {
    throw new Error("useDemo must be used within DemoProvider");
  }
  return context;
}
