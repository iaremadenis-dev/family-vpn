# Развёртывание Family VPN

Документ описывает подготовку панели к HTTPS и публикацию артефактов агента. Автоматического запуска на серверах нет.

Панель на публичном IPv4 без домена ставится из копии репозитория: `sudo bash panel/install-panel.sh --new --email you@example.com --backup-pubkey age1...`. Восстановление расшифровывает архив на компьютере администратора и передаёт открытый tar по SSH: `panel/push-restore.sh`. Приватный ключ `age` на сервер не копируется. Точная последовательность — в README.

## Что входит в комплект

- `Dockerfile` — образ панели Next.js на Node 24
- `deploy/docker-compose.yml` — панель и Caddy
- `deploy/Caddyfile` — HTTPS и публичная раздача `/releases/*`
- `scripts/build-release.sh` — сборка Linux-агента и контрольных сумм
- `scripts/export-windows-data.ps1` / `scripts/import-panel-data.sh` — перенос SQLite

Управляющие API по-прежнему требуют сессию администратора. Публичны только вход, маршруты агента `/api/agent/*` и файлы в `/releases/*`.

## Параметры, которые нужно задать

В `deploy/.env` (образец — `deploy/.env.example`):

- `FAMILY_VPN_DOMAIN` — имя хоста без схемы, например `panel.example.com`
- `FAMILY_VPN_PUBLIC_URL` — полный HTTPS-адрес, например `https://panel.example.com`

DNS A/AAAA запись должна указывать на сервер с открытыми портами 80 и 443. Для выпуска сертификата Let’s Encrypt Caddy нужен доступ из интернета.

## Перенос локальной базы с Windows

1. Остановите локальную панель.
2. Запустите `powershell -File scripts/export-windows-data.ps1`.
3. Скопируйте каталог `export-…` на хост панели.
4. На хосте: `sudo ./scripts/import-panel-data.sh ./export-…`
5. Поднимите Compose. Учётная запись администратора сохранится.

Не коммитьте каталог `export-*` и не публикуйте файл базы.

## Запуск панели

На Linux-хосте панели:

```bash
cp deploy/.env.example deploy/.env
# заполните DOMAIN и PUBLIC_URL
cd deploy
docker compose up -d --build
```

Данные SQLite лежат в volume `panel-data`. Секреты агентов после привязки тоже там. Caddy хранит сертификаты в своих volume.

Пока Compose не запущен сознательно, удалённый агент к панели не подключится.

## Публикация агента

Предпочтительно GitHub Actions `agent-release`: на Linux выполняются `go test ./...`, сборка amd64 и загрузка artifact `family-vpn-agent-0.4.0`. Локально на Windows:

```powershell
powershell -File scripts/fetch-agent-release.ps1
```

Либо на машине с Go:

```bash
export FAMILY_VPN_PUBLIC_URL=https://panel.example.com
bash scripts/build-release.sh
```

В `releases/` появятся:

- `family-vpn-agent-linux-amd64`
- `install.sh`
- `SHA256SUMS`
- `bootstrap.sh`
- `INSTALL.txt` с командами install и `--update`

Каталог `releases/` монтируется в Caddy как `/releases/`. Бинарники в Git не коммитятся.

## Одна установочная команда

После публикации релиза команда выглядит так (хеш подставляет `build-release.sh`):

```bash
curl -fsSL https://panel.example.com/releases/install.sh -o /tmp/fvpn-install.sh \
  && echo '<sha256 install.sh>  /tmp/fvpn-install.sh' | sha256sum -c - \
  && sudo bash /tmp/fvpn-install.sh --backend https://panel.example.com
```

Установщик сам скачает агент с того же origin и сверит `SHA256SUMS`. Ручное копирование файлов и ручной подсчёт хеша агента не нужны. Существующий `/etc/wireguard/wg0.conf` не перезаписывается.

Обычный HTTP агент и установщик принимают только для `127.0.0.1` и `localhost`. Это путь проверки через SSH-туннель, описанный в `docs/vps-connect.md`. Адрес удалённой панели в production остаётся `https://`.

## Проверки до боевого VPS

```bash
npm run lint
npm run build
npm run test:pairing
bash scripts/verify-production-ready.sh
# после build-release:
(cd releases && sha256sum -c SHA256SUMS)
```

Протокол агента: `go test ./...` в каталоге `agent`.
