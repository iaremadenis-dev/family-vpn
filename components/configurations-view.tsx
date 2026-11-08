import { EmptyState, PageHeader } from "@/components/ui";

export function ConfigurationsView() {
  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        kicker="Доступ"
        title="Конфигурации"
        description="Выпуск, отзыв и скачивание WireGuard-конфигураций ещё не реализованы."
      />
      <EmptyState
        title="Нет выпуска конфигураций"
        text="Панель не создаёт ключи, peer, файл .conf и QR-код. Раздел заработает после подключения агента к конкретному серверу."
      />
    </div>
  );
}
