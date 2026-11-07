"use client";

import {
  createContext,
  useContext,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { THEME_STORAGE_KEY, type Theme } from "@/lib/theme";

const ThemeContext = createContext<{
  theme: Theme;
  setTheme: (theme: Theme) => void;
} | null>(null);

function subscribe(onStoreChange: () => void) {
  window.addEventListener("family-vpn-theme-change", onStoreChange);
  return () =>
    window.removeEventListener("family-vpn-theme-change", onStoreChange);
}

function getSnapshot(): Theme {
  return document.documentElement.classList.contains("dark") ? "dark" : "light";
}

function getServerSnapshot(): Theme {
  return "light";
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const theme = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);

  function setTheme(next: Theme) {
    document.documentElement.classList.toggle("dark", next === "dark");
    localStorage.setItem(THEME_STORAGE_KEY, next);
    window.dispatchEvent(new Event("family-vpn-theme-change"));
  }

  return (
    <ThemeContext.Provider value={{ theme, setTheme }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error("useTheme must be used within ThemeProvider");
  }
  return context;
}
