# Family VPN

Family VPN — админ-панель одного администратора для нескольких VPN-серверов WireGuard.

Получатели VPN не регистрируются. Подписок и платежей нет. Конфигурации позже создаёт сам администратор.

## Стек

- Next.js 16
- TypeScript
- App Router
- Tailwind CSS
- SQLite через встроенный `node:sqlite` (Node.js 24)
- Go-агент
- Docker Compose + Caddy для HTTPS

## Этот этап

Работают локальная база, вход администратора, привязка агента и подготовка production-развёртывания.

Ещё не подключены трафик, handshake, выпуск `.conf` и QR-код. Удалённый VPS автоматически не меняется.

Развёртывание панели: [docs/deploy.md](docs/deploy.md).  
Подключение уже настроенного VPS: [docs/vps-connect.md](docs/vps-connect.md).  
Архитектура: [docs/architecture.md](docs/architecture.md).

После публикации релиза одна установочная команда печатается в `releases/INSTALL.txt`. Установщик сверяет контрольные суммы и не перезаписывает существующий `wg0`.

## Запуск локально

```bash
npm install
npm run dev
```

База — каталог `data/` или `FAMILY_VPN_DATA_DIR`. За прокси: `FAMILY_VPN_TRUST_PROXY=1`.

## Проверки

```bash
npm run lint
npm run build
npm run test:pairing
bash scripts/verify-production-ready.sh
```

Протокол агента: `go test ./...` в каталоге `agent`.  
Сборка релиза агента: `FAMILY_VPN_PUBLIC_URL=https://panel.example.com bash scripts/build-release.sh`.
