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

## Панель на Ubuntu 24.04

Новая панель ставится на свой VPS и получает HTTPS-сертификат Let's Encrypt на публичный IPv4. Сертификат профиля `shortlived` действует около 160 часов. Certbot 5.4 обновляет его сам, затем перезагружает только Caddy.

Репозиторий приватный. Токен и пароль в установщик не записываются. С машины, где уже есть доступ к GitHub, копируйте свежий clone. Рабочий каталог Windows не копируйте: в нём лежит локальная база.

```bash
git clone git@github.com:iaremadenis-dev/family-vpn.git
scp -r family-vpn root@PANEL_IP:/opt/family-vpn/app
ssh root@PANEL_IP bash /opt/family-vpn/app/panel/install-panel.sh --new --email you@example.com
```

Если публичный адрес не совпадает с адресом на интерфейсе, добавьте `--ip A.B.C.D`. Пароль администратора в команду не передаётся. После установки откройте `https://A.B.C.D/login` и создайте администратора в браузере.

Повторный запуск, если в `/var/lib/family-vpn/panel` уже есть база или `master.key`, останавливается и ничего не стирает. Режим `--restore` зарезервирован и пока ничего не меняет.

Установщик не останавливает `wg0`, не правит `wg0.conf` и не переписывает firewall. TCP 80 и 443 должны быть доступны для выпуска сертификата.

Продление проверяется таймером `family-vpn-cert-renew.timer` дважды в сутки и выпускает новый сертификат, когда до конца срока остаётся меньше двух суток. Ошибка пишется в журнал службы и в `/var/lib/family-vpn/cert-renew.status`.

На чистой машине для проверки без доверенного сертификата можно добавить `--staging`. Такой сертификат агенты не примут. На рабочий VPN-сервер эту команду запускать не нужно.

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
