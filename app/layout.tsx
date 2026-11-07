import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { DemoProvider } from "@/components/demo-provider";
import { ThemeProvider } from "@/components/theme-provider";
import { THEME_STORAGE_KEY } from "@/lib/theme";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin", "cyrillic"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin", "cyrillic"],
});

const themeScript = `(function(){try{if(localStorage.getItem(${JSON.stringify(THEME_STORAGE_KEY)})==="dark"){document.documentElement.classList.add("dark")}}catch(e){}})();`;

export const metadata: Metadata = {
  title: {
    default: "Family VPN",
    template: "%s · Family VPN",
  },
  description:
    "Family VPN — админ-панель для управления VPN-серверами WireGuard. Демонстрационный интерфейс без подключения к серверам.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="ru"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <body className="min-h-full bg-zinc-100 font-sans text-zinc-950 dark:bg-zinc-950 dark:text-zinc-50">
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
        <ThemeProvider>
          <DemoProvider>{children}</DemoProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
