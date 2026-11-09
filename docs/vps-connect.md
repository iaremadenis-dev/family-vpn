# Подключение уже настроенного VPS

Сценарий для Ubuntu 24.04, где WireGuard `wg0` уже работает. Этот документ не запускает установку сам. Изменения на VPS — только после отдельного подтверждения.

## Цель

Поставить Family VPN Agent рядом с существующим `wg0`, получить одноразовый код и привязать сервер в панели. Ключи сервера, peers и сетевые правила не меняются.

## Предварительные условия

1. Для production панель доступна агенту по HTTPS (`docs/deploy.md`).
2. В `releases/` опубликован бинарник и `SHA256SUMS`.
3. Локально известна однострочная команда из `releases/INSTALL.txt`.
4. Есть SSH-доступ администратора к VPS.

`http://localhost` на компьютере с панелью VPS не видит. Исключение — обратный SSH-туннель: на VPS панель открывается как `http://127.0.0.1:13010`, если туннель направлен на локальный порт `3010`. Агент и установщик принимают такой HTTP только для `127.0.0.1` и `localhost`. Адрес вида `http://203.0.113.5` отклоняется. Удалённая панель без туннеля остаётся на HTTPS.

Сборка Linux-агента и `go test ./...` выполняются в GitHub Actions (`.github/workflows/agent-release.yml`). На Windows Go не нужен.

После успешного workflow в PowerShell из каталога проекта:

```powershell
winget install --id GitHub.cli -e --accept-package-agreements --accept-source-agreements
gh auth login
powershell -File scripts/fetch-agent-release.ps1
```

Скрипт кладёт артефакты в `releases/` для `http://localhost:3010/releases/*` и туннеля `http://127.0.0.1:13010/releases/*`.

Готовая команда для Ubuntu — в `releases/INSTALL.txt`. Для уже привязанного VPS используйте строку с `--update` (без повторного enroll). Её выполняют на VPS, не в Windows.

## Шаг 1. Только чтение

Скопируйте на VPS `scripts/vps-preflight.sh` и выполните:

```bash
sudo bash vps-preflight.sh --backend https://panel.example.com
```

Скрипт показывает ОС, наличие `wg0.conf` без приватных ключей, состояние интерфейса, UDP 51820 и доступность `/releases/SHA256SUMS`. Ничего не устанавливает.

Ожидаемо для уже настроенного сервера:

- Ubuntu 24.04
- `wg0.conf` present
- `wg0` up
- listen port 51820

## Шаг 2. Резервная копия

До установки:

```bash
sudo cp -a /etc/wireguard /root/wireguard-backup-$(date -u +%Y%m%dT%H%M%SZ)
```

Установщик дополнительно сохранит копию в `/var/lib/family-vpn/backups/`.

## Шаг 3. Проверка установщика без изменений системы

Скачайте и проверьте `install.sh` по команде из `INSTALL.txt`, затем:

```bash
sudo bash /tmp/fvpn-install.sh --backend https://panel.example.com --check
sudo bash /tmp/fvpn-install.sh --backend https://panel.example.com --preflight
```

`--check` сверяет бинарник. `--preflight` подтверждает ОС и что существующий `wg0` будет оставлен.

## Шаг 4. Установка агента (только после подтверждения)

```bash
# точная однострочная команда — из releases/INSTALL.txt вашего релиза
```

Установщик:

- не удаляет и не перезаписывает `/etc/wireguard/wg0.conf`
- не трогает peers
- не меняет SSH
- ставит агент и systemd-службу
- печатает `PAIRING CODE`

## Шаг 5. Привязка в панели

1. Family VPN → Серверы → Добавить сервер
2. Название, расположение, код
3. Дождитесь статуса по heartbeat: Online только если агент пишет и `wg0` поднят

## Шаг 6. Проверки после привязки

На VPS:

```bash
sudo systemctl status family-vpn-agent --no-pager
sudo wg show wg0
sudo diff -u /root/wireguard-backup-*/wg0.conf /etc/wireguard/wg0.conf
```

`diff` должен быть пустым относительно сохранённого `wg0.conf`.

В панели:

- статус Online при живом агенте
- Offline после `systemctl stop family-vpn-agent`
- Online снова после `systemctl start family-vpn-agent`
- после «Отвязать» агент получает отказ и не должен крутиться в бесконечном рестарте с тем же токеном

## Восстановление

Если агент мешает:

```bash
sudo systemctl disable --now family-vpn-agent
```

Конфиг WireGuard восстанавливается из `/root/wireguard-backup-…` или `/var/lib/family-vpn/backups/`. Сам установщик при ошибке на уже существующем `wg0` этот файл не удаляет.

## Что здесь намеренно не делается

- нет автоматического SSH к VPS из репозитория
- нет выпуска клиентских `.conf`
- нет изменения firewall/SSH
- адрес конкретного VPS в Git не записывается
