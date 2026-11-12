# Family VPN — отчёт об устранении уязвимостей

**Дата:** 2026-11-13  
**Основание:** `SECURITY_AUDIT.md`  
**Режим:** локальные правки кода + неразрушающие тесты. DE-01 / NL-01 **не** изменялись. Релиз **не** публиковался.

---

## 1. Таблица статусов FV

| ID | Уровень | Статус | Примечание |
|----|---------|--------|------------|
| FV-001 | HIGH | **Исправлено (локально)** | Ed25519 heartbeat + nonce/replay; legacy unsigned до `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1` |
| FV-002 | HIGH | **Исправлено (локально)** | endpoint / WG key / subnet заморожены; `acceptAgentNetworkAction` для явного подтверждения |
| FV-003 | HIGH | **Исправлено (локально)** | `delivery_token` в AES-GCM; poll расшифровывает; plaintext не в SQLite для новых claim |
| FV-004 | HIGH | **Исправлено в установщике** | Новые wg0: DROP wg0→wg0; интернет через WAN. **Не применено на NL-01** |
| FV-016 | HIGH | **Исправлено (локально)** | Ed25519 detached sig + pinned pubkey fingerprint в bootstrap; SHA256 недостаточен один |
| FV-005 | MEDIUM | **Частично** | proxy требует cookie length ≥ 32; полная edge-валидация сессии — осознанный residual |
| FV-006 | MEDIUM | **Исправлено (локально)** | CSP/Frame/Referrer/HSTS в Caddy + Next headers |
| FV-007 | MEDIUM | **Исправлено (локально)** | Caddy digest pin в compose |
| FV-008 | MEDIUM | **Открыто / владелец** | SSH/firewall hardening хоста — без автоприменения |
| FV-009 | MEDIUM | **Исправлено (локально)** | Новый login очищает все sessions |
| FV-010 | MEDIUM | **Исправлено (локально)** | X-Real-IP / rightmost XFF; Caddy перезаписывает XFF |
| FV-011 | LOW | **Открыто / владелец** | scrypt N=16384 оставлен (совместимость/CPU); bump по решению |
| FV-012 | LOW | **Открыто** | eslint/minimatch moderate в dev |
| FV-013 | LOW | **Открыто / владелец** | kill switch / DNS / tunnel policy — продуктово |
| FV-014 | LOW | **Принято** | `/releases/*` публичны по дизайну |
| FV-015 | LOW | **Принято** | Origin + SameSite; отдельный CSRF token не добавлялся |
| FV-017 | MEDIUM | **Исправлено (локально)** | logout audit только при реальной сессии |
| FV-018 | MEDIUM | **Исправлено (локально)** | лимиты enroll/poll/heartbeat fail + enroll_ok; success HB не лимитятся |
| FV-019 | MEDIUM | **Исправлено (локально)** | 64KB agent body + Caddy request_body |
| FV-020 | MEDIUM | **Открыто / владелец** | master.key в age-backup — смена custody без согласования не делалась |
| FV-021 | MEDIUM | **Исправлено (локально)** | агент: только /32 внутри subnet wg0 |
| FV-022 | MEDIUM | **Частично** | deny-list слабых паролей; глобальный lockout не внедрялся |
| FV-023 | LOW | **Исправлено (локально)** | битый master.key → ошибка, не ротация |
| FV-024 | LOW | **Исправлено (локально)** | audit на conf/QR API download |

---

## 2. Что исправлено и почему

### Протокол агента (0.5.0)
- Heartbeat подписывается Ed25519: `family-vpn/v1 heartbeat\n{pub}\n{ts}\n{nonce}`.
- Панель проверяет подпись по `agents.public_key`, отклоняет replay nonce.
- Порядок обновления: **сначала панель (принимает unsigned+signed)**, затем агент 0.5.0, затем опционально `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1`.

### Identity freeze
- Heartbeat обновляет только liveness / version / external_interface / last_report_json.
- Смена endpoint/key/subnet — только `acceptAgentNetworkAction` (admin + Origin).

### Delivery token
- Хранится через `encryptSecret` (AES-GCM / master.key).
- Poll отдаёт plaintext агенту; повторы poll до первого heartbeat поддерживаются.

### WG client isolation
- В шаблоне **нового** wg0: DROP client-to-client, ACCEPT wg0→WAN, ESTABLISHED WAN→wg0.
- Существующий wg0 на NL-01 **не** переписывается `--update`.

### Supply chain
- `keys/release-signing.pub` + fingerprint в bootstrap.
- `install.sh.sig` при наличии private key / `FAMILY_VPN_RELEASE_SIGNING_KEY`.
- Приватный ключ в git не коммитится.

---

## 3. Что осталось открытым

- Применение изоляции FORWARD на **живом** NL-01 (ручной/согласованный шаг).
- Принудительный `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1` после обновления всех агентов.
- FV-008 / FV-011 / FV-013 / FV-020 — решение владельца.
- Замена dev signing pubkey на production key + GH secret.
- Live dual-client ping / internet через WG на VPS — **не выполнялось**.
- `go test` — Go toolchain на этой машине отсутствует.

---

## 4. Результаты реальных тестов

| Проверка | Результат |
|----------|-----------|
| `npm test` | OK (pairing/configs/install/backup/security-scripts) |
| `npm run lint` | OK |
| `npm run build` | OK |
| `npm audit --omit=dev` | 0 vulnerabilities |
| `npm audit` (dev) | 7 moderate (eslint tooling) |
| `bash scripts/docker-bootstrap.test.sh` | OK |
| `scripts/release-signing.test.sh` | OK (tamper rejected) |
| `installer/client-isolation.test.sh` | OK |

---

## 5. Какие тесты не выполнены

- Live ping между двумя WG-клиентами на NL-01.
- Live проверка интернет через WG / DNS / IPv6 / WebRTC.
- `go test ./...` (нет `go` в PATH на рабочей станции).
- Production deploy / compose up на DE-01.
- Чистая Ubuntu VM с полным one-liner install (только локальные script tests).

---

## 6. Риски несовместимости

1. Панель schema **4** — старый restore с `SCHEMA_MAX=3` не примет новый backup (обновлён `archive-tool.mjs` / `archive_host.py`).
2. Агент **0.4.0** продолжит работать с новой панелью (unsigned heartbeat), пока не включён REQUIRE.
3. Агент **0.5.0** на **старой** панели: лишние поля timestamp/nonce/signature игнорируются старым кодом — но jobs/heartbeat логика старой панели без freeze/encrypt. **Обновлять панель раньше агента.**
4. Caddy digest pin: `docker pull` должен тянуть точный digest; offline air-gap нужен тот же digest.
5. Изоляция клиентов появится только на **новых** wg0; старый NL-01 без ручного PostUp останется с прежним FORWARD.

---

## 7. План обновления DE-01 и NL-01

1. Backup DE-01 (`backup-panel.sh` + проверка age decrypt offline).
2. Backup NL-01 (`backup-wg.sh` / копия `/etc/wireguard/wg0.conf` + `agent.json`).
3. Проверить восстановление backup на копии (не на проде).
4. Собрать/подписать релиз 0.5.0 локально; сверить fingerprint `keys/release-signing.pub`.
5. Обновить **панель DE-01** (image/compose). Не трогать клиентские conf.
6. Дождаться heartbeat от NL-01 (unsigned ещё ок).
7. Обновить **агент NL-01** через `--update` (не переписывает wg0).
8. Проверить signed heartbeat / jobs add-remove peer / статусы.
9. Опционально: вручную добавить DROP wg0→wg0 на NL-01 (отдельное согласование).
10. После всех агентов ≥0.5.0: `FAMILY_VPN_REQUIRE_HEARTBEAT_SIG=1`.
11. Новые клиентские conf — только после проверки; существующие peers не трогать.

---

## 8. План отката

1. DE-01: откат Docker image/compose на предыдущий digest; restore panel data из age backup при порче schema.
2. NL-01: `--update` на предыдущий agent binary из `/var/lib/family-vpn/backups/`; unit restart.
3. Не включать REQUIRE flag до стабилизации.
4. Не применять изоляцию iptables одновременно с обновлением агента.
5. Клиентские `.conf` и peers WireGuard при откате не удалять.

---

## Готовность к контролируемому обновлению

**Код готов к контролируемому (ручному) обновлению staging/production после вашего решения**, при условии:

- есть свежие backup DE-01/NL-01;
- понятен порядок panel → agent;
- изоляция клиентов на NL-01 — отдельный шаг;
- production signing key заменён/загружен в CI secret.

Система **не** объявляется полностью безопасной. Production deployment в этой сессии **не** выполнялся.
