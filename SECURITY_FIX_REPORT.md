# Family VPN — отчёт об устранении уязвимостей

**Дата:** 2026-11-13  
**Файл на диске:** `C:\Projects\family-vpn\SECURITY_FIX_REPORT.md`  
**Основание:** `SECURITY_AUDIT.md`  
**Режим:** локальные правки + неразрушающие тесты. DE-01 / NL-01 **не** изменялись.  
Production release / deployment / публикация отчёта на GitHub **не** выполнялись.

---

## 1. Какие уязвимости исправлены

| ID | Уровень | Статус | Суть исправления |
|----|---------|--------|------------------|
| FV-001 | HIGH | Исправлено (локально) | Ed25519-подпись heartbeat + nonce/replay; legacy unsigned до `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1` |
| FV-002 | HIGH | Исправлено (локально) | endpoint / WG public key / subnet не переписываются heartbeat; смена только через `acceptAgentNetworkAction` |
| FV-003 | HIGH | Исправлено (локально) | `delivery_token` в AES-GCM; poll расшифровывает; plaintext не в SQLite для новых claim |
| FV-004 | HIGH | Исправлено в установщике | Новые wg0: DROP client-to-client; интернет через WAN. **На NL-01 не применено** |
| FV-016 | HIGH | Исправлено (локально) | Ed25519 detached signature + pinned fingerprint pubkey; SHA256 один недостаточен |
| FV-006 | MEDIUM | Исправлено | Security headers (Caddy + Next) |
| FV-007 | MEDIUM | Исправлено | Caddy image digest pin |
| FV-009 | MEDIUM | Исправлено | Login инвалидирует все прежние sessions |
| FV-010 | MEDIUM | Исправлено | Trusted proxy: X-Real-IP / rightmost XFF |
| FV-017 | MEDIUM | Исправлено | Logout не пишет audit без реальной сессии |
| FV-018 | MEDIUM | Исправлено | Rate limits enroll/poll/heartbeat fail; успешные HB не душатся |
| FV-019 | MEDIUM | Исправлено | Лимит JSON body 64KB + Caddy `request_body` |
| FV-021 | MEDIUM | Исправлено | AllowedIPs агента: только `/32` внутри VPN subnet |
| FV-023 | LOW | Исправлено | Битый `master.key` → ошибка, не автозамена |
| FV-024 | LOW | Исправлено | Audit на download `.conf` / QR |
| FV-005 | MEDIUM | Частично | Cookie length ≥ 32 на edge; полная валидация сессии — residual |
| FV-022 | MEDIUM | Частично | Deny-list слабых паролей; глобальный lockout не внедрялся |

---

## 2. Результаты npm и Go tests

| Проверка | Результат |
|----------|-----------|
| Go toolchain | **go1.22.12** (совпадает с `agent/go.mod`) |
| `go test ./...` (agent 0.5.0) | **PASS** — 14 тестов, включая `TestHeartbeatPayloadIsSigned` |
| Linux amd64 `go build` | **OK** — ELF 64-bit LSB executable, statically linked, stripped |
| `npm test` | **PASS** (pairing + compat + configs + install + backup + security-scripts) |
| `npm run lint` | **OK** |
| `npm run build` | **OK** |
| `npm audit --omit=dev` | **0** vulnerabilities |
| `npm audit` (dev) | 7 moderate (eslint tooling, не runtime панели) |
| `docker-bootstrap.test.sh` | **OK** |
| CI gate | Go tests (+ race) **до** сборки релиза в `agent-release.yml` |

---

## 3. Результаты тестов совместимости

| Сценарий | Результат |
|----------|-----------|
| Новая панель / старый агент 0.4 (unsigned HB) | **OK** — принимается, пока нет REQUIRE |
| Новая панель / новый агент 0.5 (signed HB) | **OK** |
| Старая панель / новый агент 0.5 | **OK по протоколу** — лишние JSON-поля игнорируются; freeze/encrypt только на новой панели → **панель обновлять раньше агента** |
| `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1` после апдейта | **OK** — unsigned отклоняется; signed проходит |
| Отрицательные: fake / replay / unsigned при REQUIRE | **OK** — отклоняются (`compat-security.test.ts`, `pairing.test.ts`) |

---

## 4. Какие проблемы остались

- **FV-008** — SSH/firewall hardening хоста: только решение владельца, автоматом не трогали.
- **FV-011** — scrypt N=16384: bump по отдельному решению.
- **FV-013** — kill switch / DNS / tunnel policy на клиентах: продуктово.
- **FV-020** — `master.key` в age-backup: смена custody не делалась без согласования.
- Изоляция клиентов (**FV-004**) на **живом NL-01** ещё не применена (`--update` wg0 не переписывает).
- Live dual-client ping / интернет / DNS / IPv6 / WebRTC на VPS **не** гонялись.
- Dev signing pubkey нужно заменить на production key + `FAMILY_VPN_RELEASE_SIGNING_KEY` в CI перед доверенным публичным релизом.
- Система **не** объявляется полностью безопасной.

---

## 5. Статус подписи релизов

- Публичный ключ: `keys/release-signing.pub` (в репозитории).
- Приватный ключ: `keys/release-signing.pem` / env `FAMILY_VPN_RELEASE_SIGNING_KEY` — **не** в git.
- Локальный `scripts/build-release.sh`: создаёт `install.sh.sig`, fingerprint в `bootstrap.sh`.
- Проверка: `scripts/verify-release-file.mjs` / `verify-signed-release-local.sh`.
- Подмена `install.sh` → **подпись отклоняется** (проверено).
- Неверный fingerprint pubkey → **отклоняется** (проверено).
- Fingerprint локальной сборки (SHA-256 pubkey): `1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259`
- Без CI secret подпись в Actions может отсутствовать (warning); для production-релиза секрет обязателен.
- **Production release в этой сессии не публиковался.**

---

## 6. Безопасный порядок обновления DE-01 и NL-01

1. Backup DE-01 (`backup-panel.sh` + проверка age decrypt offline).
2. Backup NL-01 (`/etc/wireguard/wg0.conf`, `agent.json`, agent binary backup).
3. Проверка restore на копии (не на проде).
4. Собрать/подписать артефакты 0.5.0; сверить fingerprint pubkey.
5. Обновить **только панель DE-01** (новый image/compose, schema 4). Клиентские conf не трогать.
6. Дождаться heartbeat от NL-01 (0.4 unsigned ещё допустим).
7. Обновить **агент NL-01** через `--update` (не переписывает wg0/peers).
8. Проверить signed heartbeat, jobs add/remove peer, статусы Online.
9. Опционально и отдельно: ручная изоляция FORWARD на NL-01.
10. Когда все агенты ≥ 0.5.0: `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1`.
11. Новые клиентские конфиги — только после стабилизации; существующие peers не удалять.

---

## 7. План отката без потери конфигураций

1. **DE-01:** откат Docker image/compose на предыдущий digest; при порче данных — restore из age backup. Не удалять volume SQLite без нужды.
2. **NL-01:** `--update` на предыдущий agent binary из `/var/lib/family-vpn/backups/`; `systemctl restart family-vpn-agent`.
3. **Не** включать REQUIRE до стабилизации; при проблемах — снять REQUIRE.
4. Изоляцию iptables не смешивать с откатом агента в одном шаге.
5. **Никогда** не удалять `wg0.conf` peers, клиентские `.conf` и `agent.json` при откате.
6. Клиентские VPN-конфиги на телефонах/ПК остаются валидными, пока не менялись server endpoint/key (freeze это как раз сохраняет).

---

## Production signing (2026-11-13)

- `build-release.sh` **отказывает** без private key; `bootstrap.sh` **всегда** проверяет Ed25519 до exec.
- CI `agent-release` падает без secret `FAMILY_VPN_RELEASE_SIGNING_KEY`.
- Локальные подписанные артефакты собраны в `releases/` (не опубликованы).
- Fingerprint pubkey: `1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259`
- Private key: только `keys/release-signing.pem` (gitignored) / GH secret.
- Hygiene: `scripts/check-signing-key-hygiene.sh` — pem не в git и не в `releases/`/`dist/`; pubkey = production (не ephemeral test key из unit-тестов).

## Image-based panel updater (2026-11-13)

- `panel/update-panel.sh` + `scripts/build-panel-update.sh` для установок из digest-pinned образа (не rsync/build).
- Проверки: SHA-256, Ed25519, pinned pubkey FP, schema bounds, admin row, non-empty SQLite/master.key.
- Relocate ComposeDir `/tmp/family-vpn-install` → `/opt/family-vpn/install`; данные в `/var/lib/family-vpn/panel` не удаляются.
- Pre-update backup + restore-readiness; `--rollback` образа; `FAMILY_VPN_ROLLBACK_DATA=1` для совместимого отката данных.
- Симулятор: `scripts/update-panel.test.sh` (PASS). Подписанный pack: `dist/` (не опубликован).
- Новый panel image на этой машине **не** собран (нет Docker). Для code-upgrade: `build-panel-image.sh` затем `build-panel-update.sh`.
- Rollback target: `panel-d587d590518d` / `sha256:b5a719f0…`.
- Команды: `dist/UPDATE-COMMANDS.txt`. Deployment/publish — только после отдельного согласия.

## Готовность

Код и подписанные agent-артефакты **готовы к контролируемому ручному** обновлению после:
1) вашего push/коммитов в private repo (по желанию);
2) добавления `FAMILY_VPN_RELEASE_SIGNING_KEY` в GitHub Actions;
3) ваших backup и явного запуска команд на VPS.

Production deployment / публикация release здесь **не** выполнялись.
