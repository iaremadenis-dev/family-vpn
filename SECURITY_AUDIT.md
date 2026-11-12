# Family VPN — отчёт по аудиту безопасности

**Дата аудита:** 2026-11-12  
**Обновление статусов исправлений:** 2026-11-13  
**Объект:** `C:\Projects\family-vpn` (`iaremadenis-dev/family-vpn`)

**Важно:** находки ниже — результат аудита. Статусы remediation отмечены как
**локально исправлено / проверено тестами**, но **не** как проверенные на production
DE-01/NL-01. Подробности: `SECURITY_FIX_REPORT.md`.

**Архитектура:** панель Next.js + SQLite + Docker/Caddy (DE-01); WireGuard + agent
(целевой 0.5.0; на NL-01 на момент аудита был 0.4.0).

**Вердикт аудита (сохранён):** удалённого «открытого входа» в панель по коду не видно.
Подтверждённые HIGH требовали исправлений. После локальных фиксов система всё ещё
**не** объявляется полностью безопасной и **не** проверена на живых VPS.

### Статус remediation (2026-11-13)

| ID | Статус |
|----|--------|
| FV-001, FV-002, FV-003, FV-016 | локально исправлено + тесты |
| FV-004 | шаблон установщика исправлен; **не применено на NL-01** |
| FV-006, FV-007, FV-009, FV-010, FV-017–019, FV-021, FV-023, FV-024 | локально исправлено |
| FV-005, FV-022 | частично |
| FV-008, FV-011, FV-013, FV-020 | открыто / решение владельца |
| FV-012, FV-014, FV-015 | residual / принято |

---

## A. Подтверждённые уязвимости и недостатки

### FV-001 — HIGH — Агент: heartbeat без подписи, украденный Bearer управляет WireGuard

- **Компонент:** `family-vpn-agent` ↔ панель  
- **Файл:** `app/api/agent/heartbeat/route.ts` (строки 13–24), `lib/server/pairing.ts` (`heartbeatAgent`, ~295–347), `agent/protocol.go` (`Heartbeat`, ~138–159)  
- **Доказательство:** heartbeat принимает только `Authorization: Bearer`, без Ed25519-подписи (в отличие от enroll/poll). Успешный токен даёт `takeJobsForServer` → агент выполняет `wg set` add/remove peer.  
- **Сценарий:** кража `agent.json` / токена с NL-01, или утечка из панели → злоумышленник шлёт heartbeat с своим `report` и получает/подтверждает jobs, либо подставляет чужой агент.  
- **Влияние:** полный контроль peers WireGuard на скомпрометированном токене; порча метаданных сервера в панели.  
- **Исправление:** подписывать heartbeat тем же agent key; привязывать jobs к nonce/timestamp; ротация токена; короткий TTL.  
- **Минимальный diff:** да (протокол + агент + панель).  
- **Проверка:** heartbeat без подписи → 401; с подписью → 200; подделанный report без ключа → отказ.

### FV-002 — HIGH — Heartbeat может переписать endpoint и wg_public_key сервера

- **Компонент:** панель / pairing  
- **Файл:** `lib/server/pairing.ts` ~322–338  
- **Доказательство:** `UPDATE servers SET endpoint=?, listen_port=?, wg_public_key=?, vpn_subnet=?, ...` из непроверенного (кроме формата) `report` агента.  
- **Сценарий:** украденный токен или скомпрометированный агент сообщает чужой endpoint/publicKey → новые клиентские `.conf` из панели ведут на атакующего.  
- **Влияние:** перехват новых подключений (evil twin endpoint); деградация существующих до смены конфига.  
- **Исправление:** не менять `wg_public_key`/subnet после pairing без явного admin confirm; сверять report с зафиксированными при claim значениями; алерт при расхождении.  
- **Минимальный diff:** да.  
- **Проверка:** heartbeat с другим publicKey не меняет БД / требует подтверждения.

### FV-003 — HIGH — `delivery_token` хранится в SQLite открытым текстом

- **Компонент:** панель / agents  
- **Файл:** `lib/server/db.ts` (схема `agents.delivery_token`), `lib/server/pairing.ts` ~263–267, 175–177, 339–341  
- **Доказательство:** при claim пишется plaintext token в `delivery_token`; `pollEnrollment` отдаёт его агенту, пока heartbeat не обнулит поле. `token_hash` есть, но plaintext дублируется.  
- **Сценарий:** чтение volume/SQLite/расшифрованный backup до первого heartbeat → захват агента.  
- **Влияние:** то же, что FV-001.  
- **Исправление:** одноразовый encrypted delivery или out-of-band только в памяти ответа poll без записи plaintext; или encrypt-at-rest отдельным ключом с коротким TTL.  
- **Минимальный diff:** да.  
- **Проверка:** после claim в БД нет plaintext token; повторный poll не отдаёт токен после выдачи.

### FV-004 — HIGH — Нет изоляции клиентов WireGuard (client-to-client)

- **Компонент:** установщик WireGuard  
- **Файл:** `installer/install.sh` ~610–612  
- **Доказательство:** `iptables -A FORWARD -i wg0 -j ACCEPT` и `-o wg0 -j ACCEPT` без запрета forwarding между клиентами.  
- **Сценарий:** клиент A сканирует/атакует клиент B в одной `/24`.  
- **Влияние:** боковое перемещение внутри семейного VPN.  
- **Исправление:** FORWARD только wg0↔WAN; между клиентами DROP (или отдельная политика).  
- **Минимальный diff:** да (PostUp/PostDown).  
- **Проверка:** ping между двумя peers не проходит; выход в интернет есть.

### FV-005 — MEDIUM — Edge `proxy.ts` проверяет только наличие cookie, не валидность сессии

- **Компонент:** Next.js edge proxy  
- **Файл:** `proxy.ts` ~14–18  
- **Доказательство:** `request.cookies.get("family_vpn_session")` без сверки с БД.  
- **Сценарий:** произвольное значение cookie проходит matcher; защита держится на `requireAdmin`/`readSession` в RSC/API.  
- **Влияние:** ослабленная defense-in-depth; риск при будущих страницах без `requireAdmin`.  
- **Исправление:** не полагаться только на presence; документировать обязательный `requireAdmin`; опционально signed cookie.  
- **Минимальный diff:** частично (полная проверка сессии на edge без SQLite сложна).  
- **Проверка:** cookie=`x` не отдаёт данные API/RSC; покрытие всех panel routes `requireAdmin`.

### FV-006 — MEDIUM — Нет HTTP security headers (HSTS/CSP/Frame/Referrer)

- **Компонент:** Caddy  
- **Файл:** `panel/Caddyfile.https`  
- **Доказательство:** только `tls`, `encode gzip`, reverse_proxy; нет HSTS/CSP/`X-Frame-Options`/`Referrer-Policy`.  
- **Сценарий:** clickjacking UI; ослабление XSS-defense в глубину.  
- **Влияние:** повышение риска при XSS в UI; для IP-сертификатов HSTS нужно включать осторожно.  
- **Исправление:** добавить безопасный набор header в Caddy; HSTS — только после оценки IP/коротких cert.  
- **Минимальный diff:** да.  
- **Проверка:** `curl -I https://IP` показывает ожидаемые заголовки.

### FV-007 — MEDIUM — Образ Caddy в Compose закреплён тегом, не digest

- **Компонент:** supply chain / Docker  
- **Файл:** `panel/docker-compose.yml` (`image: caddy:2.10-alpine`)  
- **Доказательство:** плавающий tag; панель в image-режиме pin’ится digest’ом, Caddy — нет.  
- **Сценарий:** подмена tag в registry / компрометация upstream → на следующем pull.  
- **Влияние:** RCE в reverse proxy при злонамеренном образе.  
- **Исправление:** `caddy@sha256:…` + проверка в установщике.  
- **Минимальный diff:** да.  
- **Проверка:** compose config показывает digest; повторный install не тянет иной digest без обновления.

### FV-008 — MEDIUM — Установщики не настраивают firewall/SSH hardening хоста

- **Компонент:** install-panel / install.sh  
- **Файл:** `panel/install-panel.sh` (явные сообщения, что firewall не пишется), `installer/install.sh`  
- **Доказательство:** открытие 80/443/51820 оставлено провайдеру; SSH/root/password auth не трогаются.  
- **Сценарий:** VPS с парольным root и открытым SSH → компрометация хоста обходит приложение.  
- **Влияние:** полный захват панели/агента вне модели угроз приложения.  
- **Исправление:** чеклист hardening в docs; опциональный безопасный профиль ufw (только после согласия).  
- **Минимальный diff:** документация — да; авто-firewall — осторожно.  
- **Проверка:** read-only аудит портов/sshd на VPS (раздел G).

### FV-009 — MEDIUM — Сессии накапливаются; login не инвалидирует остальные

- **Компонент:** сессии  
- **Файл:** `lib/server/session.ts` (`createSession`), `app/actions/auth.ts` (`login`)  
- **Доказательство:** login создаёт новую сессию; старые живут до 7 суток. Смена пароля вызывает `destroyOtherSessions` — хорошо.  
- **Сценарий:** украденная старая cookie остаётся валидной после нового входа с другого устройства.  
- **Влияние:** продление кражи сессии.  
- **Исправление:** опция «выйти везде» при login; лимит активных сессий.  
- **Минимальный diff:** да.  
- **Проверка:** после login старый token → 401.

### FV-010 — MEDIUM — Rate limit / agent attempts завязаны на `X-Forwarded-For` при TRUST_PROXY

- **Компонент:** `rate-limit.ts`, `agent-route.ts`  
- **Файл:** `lib/server/rate-limit.ts` ~40–46; `lib/server/agent-route.ts` ~5–11; `Dockerfile` `FAMILY_VPN_TRUST_PROXY=1`  
- **Доказательство:** при TRUST_PROXY берётся первый XFF. Панель слушает только docker-сеть (не публикует 3000) — риск снижен.  
- **Сценарий:** прямой доступ к panel:3000 с подделанным XFF обходит лимиты.  
- **Влияние:** усиленный brute-force login/enroll.  
- **Исправление:** доверять только hop от Caddy; не публиковать 3000; сбрасывать клиентский XFF в Caddy.  
- **Минимальный diff:** да (Caddy `header_up` / проверка сети).  
- **Проверка:** с хоста docker нельзя достучаться до :3000 снаружи; лимиты с разных XFF через Caddy не сбрасываются произвольно.

### FV-011 — LOW — scrypt N=16384 на нижней границе современных рекомендаций

- **Компонент:** пароли  
- **Файл:** `lib/server/password.ts` ~3–14  
- **Доказательство:** N=16384, r=8, p=1; есть bounds и timingSafeEqual.  
- **Влияние:** при утечке hash offline brute чуть проще, чем при N≥65536.  
- **Исправление:** поднять N при создании/смене пароля с миграцией.  
- **Минимальный diff:** да.

### FV-012 — LOW — Dev-зависимости: advisory minimatch (DoS в tooling)

- **Компонент:** npm / eslint  
- **Доказательство:** `npm audit` — 8 moderate только через eslint-config-next; `npm audit --omit=dev` — 0.  
- **Влияние:** не runtime панели.  
- **Исправление:** обновить eslint-stack когда безопасно.  
- **Минимальный diff:** осторожно (breaking).

### FV-013 — LOW — Клиентский конфиг: полный туннель IPv4+IPv6, DNS 1.1.1.1, нет kill switch

- **Компонент:** выдача конфигов  
- **Файл:** `lib/server/wireguard.ts` `buildClientConfig` ~82–94  
- **Доказательство:** `AllowedIPs = 0.0.0.0/0, ::/0`, `DNS = 1.1.1.1`, нет OnDisconnected/kill switch (ограничение WG conf).  
- **Влияние:** при обрыве VPN ОС может утечь трафик; IPv6 зависит от NAT на VPS; DNS централизован на Cloudflare.  
- **Исправление:** документировать; опциональный split tunnel; проверка IPv6/NAT на NL; клиентский kill switch вне WG conf.  
- **Минимальный diff:** документация — да; продуктовые опции — шире.

### FV-014 — LOW — Публичная раздача `/releases/*` без авторизации

- **Компонент:** Caddy  
- **Файл:** `panel/Caddyfile.https` ~19–25  
- **Доказательство:** file_server для install.sh и agent binary — задумано для one-liner.  
- **Влияние:** разведка версий/бинарника; не секрет панели.  
- **Исправление:** оставить + pin SHA256 в команде (уже есть); не класть секреты в releases.

### FV-015 — LOW — Нет отдельного CSRF-токена

- **Компонент:** server actions  
- **Файл:** `lib/server/guard.ts` `assertSameOrigin`; cookie `sameSite: "lax"`  
- **Доказательство:** защита Origin + SameSite, не double-submit CSRF.  
- **Влияние:** для classic cross-site POST риск низкий; при ослаблении SameSite/Origin — выше.  
- **Исправление:** оставить Origin; при желании CSRF token.  
- **Статус:** скорее residual control gap, чем эксплуатируемая дыра.

---

## B. Потенциальные риски (не доказаны end-to-end)

| ID | Уровень | Суть | Почему potential |
|----|---------|------|------------------|
| FV-P01 | MEDIUM | Нет лимита размера JSON body в agent routes (`readJson`) | DoS через большие тела; не проверялось нагрузкой |
| FV-P02 | MEDIUM | SQLite WAL/files на volume: при ошибке umask/прав на хосте возможна утечка | Зависит от реальных прав на DE-01 |
| FV-P03 | MEDIUM | Компрометация age private key администратора → расшифровка backup с master.key и конфигами | Ключ вне VPS по дизайну; процесс хранения у человека не аудитился |
| FV-P04 | LOW | `enroll` создаёт enrollment для любого валидного кода до claim | 100 бит энтропии; rate limit 8/15м; возможен slow DB fill |
| FV-P05 | LOW | Повторная доставка jobs со статусом `delivered` | Идемпотентность add/remove обычно ок; гонки не нагрузочно тестировались |
| FV-P06 | MEDIUM | Docker escape / socket | Socket в compose не монтируется; полный runtime на VPS не смотрели |
| FV-P07 | HIGH (ops) | Слабый пароль админа / парольный SSH | Зависит от оператора |

---

## C. Успешно проверенные меры защиты

1. **Пароль:** scrypt + salt + `timingSafeEqual`; мин. 12 символов, буква+цифра (`password.ts`).  
2. **Сессии:** 32 байта random, в БД только SHA-256 hash; HttpOnly; SameSite=lax; Secure в production; logout удаляет hash (`session.ts`).  
3. **Login rate limit:** 8 / 15 мин (`rate-limit.ts`); ошибки login пишутся в audit.  
4. **Смена пароля:** проверка текущего; `destroyOtherSessions`.  
5. **Origin check** на mutating server actions (`assertSameOrigin`).  
6. **Защита API конфигов:** `readSession` + `Cache-Control: no-store` (`conf`/`qr` routes).  
7. **Активация:** hash кода на диске mode 600 uid 1001; одноразовый clear; timing-safe compare (`setup-token.ts`, install-panel).  
8. **Pairing:** ~100 бит, rejection sampling, TTL 15 мин, Ed25519 enroll/poll, code hash в БД, BEGIN IMMEDIATE на claim, subnet/endpoint conflict checks (`pairing.ts`).  
9. **Агент jobs:** только `add_peer`/`remove_peer`; валидация WG key и AllowedIPs `/32` на агенте (`peers.go`).  
10. **HTTPS-only backend** для агента (http только loopback) (`protocol.go` `normalizeBackend`).  
11. **Секреты клиентов:** AES-256-GCM + `master.key` 32 байта mode 600 (`secret.ts`).  
12. **Панель в Docker:** non-root uid 1001; 3000 не публикуется наружу; Caddy отдельным контейнером.  
13. **Restore:** отказ перезаписывать существующие sqlite/master.key; age; сканирование секретов в release pack.  
14. **SQL:** подготовленные выражения, не string-concat.  
15. **Production npm audit:** 0 известных CVE в runtime deps на момент аудита.

---

## D. Что нельзя проверить без доступа к VPS (read-only)

- Реальные `sshd_config`, firewall провайдера, listening ports  
- Права `/var/lib/family-vpn`, `agent.json`, `wg0.conf` на диске  
- Факт, что :3000 недоступен снаружи  
- TLS handshake/цепочка Let’s Encrypt shortlived на IP  
- Caddy admin только на 127.0.0.1 внутри контейнера  
- Версии пакетов ОС / наличие несвязанных сервисов  
- Корректность NAT IPv6 (если анонсируется)  

Команды — раздел **G**.

---

## E. Что нельзя проверить без клиента / браузера

- DNS leak / WebRTC leak / IPv6 leak на Windows/iOS/Keenetic  
- Kill switch при обрыве туннеля  
- Поведение split vs full tunnel на конкретных клиентах  
- Сопоставление «устройство ↔ сайт» через cookies/аккаунты (вне VPN)  

План — раздел **H**.

---

## F. План исправлений по приоритету

**P0 — до расширения числа пользователей / при любом подозрении на утечку токена**
1. FV-003 — убрать plaintext `delivery_token`  
2. FV-001 — подпись heartbeat + привязка jobs  
3. FV-002 — заморозка endpoint/wg_public_key после pairing  

**P1 — сеть VPN и хост**
4. FV-004 — запрет client-to-client  
5. FV-008 — чеклист hardening SSH/firewall (не ломая NL/DE)  
6. FV-007 — digest pin Caddy  

**P2 — web hardening**
7. FV-006 — security headers  
8. FV-005 / FV-009 — усиление сессий  
9. FV-010 — ужесточить trust proxy  

**P3 — приватность и гигиена**
10. FV-013 — документация leaks / опции DNS/AllowedIPs  
11. FV-011 / FV-012 — scrypt cost / dev audit  

Не начинать исправления без отдельного решения владельца.

---

## G. Read-only диагностика DE-01 и NL-01 (PuTTY)

Правила: не менять конфиг, не systemctl restart/stop (кроме `is-active`/`status`), не `wg syncconf`/`set`, не печатать ключи/токены/пароли.

### Общие

```bash
hostname; date -u; uname -a
. /etc/os-release; echo "$PRETTY_NAME"
ip -4 addr; ip -4 route
ss -lntu | sed -n '1,200p'
```

### DE-01 (панель)

```bash
systemctl is-active docker
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker compose --project-directory /opt/family-vpn/panel ps 2>/dev/null || true
# не выводить содержимое panel.env / master.key / sqlite
ls -la /var/lib/family-vpn/panel | sed -n '1,50p'
stat -c '%a %U %G %n' /var/lib/family-vpn/panel /var/lib/family-vpn/panel/family-vpn.sqlite /var/lib/family-vpn/panel/master.key 2>/dev/null
stat -c '%a %n' /etc/family-vpn/panel.env /etc/family-vpn/Caddyfile 2>/dev/null
ss -lntu | grep -E ':80|:443|:3000|:2019' || true
curl -sS -o /dev/null -w 'login:%{http_code}\n' https://127.0.0.1/login --resolve "$(hostname -I | awk '{print $1}'):443:127.0.0.1" 2>/dev/null || curl -sk -o /dev/null -w 'login_insecure:%{http_code}\n' https://127.0.0.1/login
# TLS без печати ключей
echo | openssl s_client -connect 127.0.0.1:443 -servername "$(hostname -I | awk '{print $1}')" 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null | head
systemctl is-active family-vpn-cert-renew.timer family-vpn-backup.timer 2>/dev/null
# убедиться что 3000 не слушает на публичном интерфейсе
ss -lnt | grep 3000 || echo 'panel_port_3000_not_listening_on_host'
```

### NL-01 (WireGuard + agent)

```bash
ip link show wg0 2>/dev/null | head
wg show wg0 2>/dev/null | sed -E 's#(peer:).*#\1 <redacted>#; s#(public key:).*#\1 <redacted>#; s#(preshared key:).*#\1 <redacted>#' | head -n 40
# НЕ: cat /etc/wireguard/wg0.conf , НЕ: cat agent.json
stat -c '%a %U %G %n' /etc/wireguard/wg0.conf /var/lib/family-vpn/agent.json 2>/dev/null
ss -lnu | grep 51820 || true
systemctl is-active family-vpn-agent 2>/dev/null; systemctl is-enabled family-vpn-agent 2>/dev/null
systemctl is-active wg-quick@wg0 2>/dev/null || true
iptables -t nat -S POSTROUTING 2>/dev/null | sed -n '1,40p'
iptables -S FORWARD 2>/dev/null | sed -n '1,80p'
sysctl net.ipv4.ip_forward
# SSH без дампа ключей
sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) ' || true
```

### Запрещено в этой диагностике

- `cat`/`jq` с выводом `master.key`, `agent.json`, private keys, setup tokens  
- `wg set`, `wg-quick down/up`, `systemctl restart|stop`  
- `iptables -F`, `ufw disable`  
- Любые «тесты» с удалением peers  

---

## H. План проверки DNS / IP / IPv6 / WebRTC

1. Подключить тестовый клиент к NL-01; запомнить public IP панели/VPN.  
2. Без VPN и с VPN открыть: `https://ifconfig.me`, `https://ipv6-test.com`, DNS leak test (например dnsleaktest.com).  
3. Браузер: WebRTC leak test; ожидание — не светить домашний IP при полном туннеле.  
4. Keenetic: проверить policy routing / kill switch на роутере отдельно — WG conf его не даёт.  
5. Оборвать интерфейс WG на клиенте и повторить ifconfig — есть ли утечка (нет kill switch в выдаваемом conf).  
6. Не использовать личные аккаунты для выводов об «анонимности».  

**Разделение угроз (честно):**
1. Содержимое трафика до сайтов — защищается WG-шифрованием до NL-01.  
2. Сокрытие домашнего IP от сайтов — при рабочем full tunnel да; при обрыве/IPv6/WebRTC — нет гарантии.  
3. Корреляция — VPS-провайдер видит объёмы и timing с NL-01.  
4. Метаданные провайдера — IP клиента до VPN, факт сессии к DE/NL.  
5. Браузерные идентификаторы — VPN не маскирует cookies/логины.

---

## Детализация по разделам запроса (кратко)

### 1. Авторизация и сессии
Сильная база (scrypt, hashed sessions, HttpOnly, Origin, rate limit). Слабые места: FV-005, FV-009, FV-015. Повторный пароль для опасных операций — только смена пароля; revoke server/config — только сессия.

### 2. API и Next.js
Agent API публичны по дизайну с крипто/токеном. Config download требует сессию. SQL injection по коду не видно. XSS зависит от React escaping (отдельного CSP нет — FV-006). Path traversal в releases — `hide .*`. IDOR между админами N/A (один admin). Prototype pollution / open redirect — явных находок нет. CORS кастомный не открыт. DoS body — FV-P01.

### 3. WireGuard-клиенты
Ключи x25519 через `generateKeyPairSync`; private в AES-GCM. Скачивание только с сессией. Revoke чистит enc поле при success. IP allocation с резервом .0/.1. AllowedIPs клиента full tunnel. Изоляция peers отсутствует (FV-004). Связь клиент↔человек: `device_name`, timestamps, handshake/rx/tx в SQLite.

### 4. Agent
Enroll/poll подписаны; heartbeat — нет (FV-001). TLS через системный trust store Go (InsecureSkipVerify не найден). HTTPS обязателен. Jobs минимальны и валидируются. Агент работает с правами, достаточными для `wg` (обычно root) — ожидаемо, residual privilege.

### 5. Pairing
Энтропия ~100 бит, TTL 15м, одноразовый claim, rate limit, race через IMMEDIATE. Код не логируется в audit как plaintext (audit — имена действий).

### 6. Docker
Нет privileged/socket в panel compose. Caddy user 0:0 ради ключей cert mode 600 — осознанный tradeoff. Panel non-root. Image pin панели — да; Caddy — FV-007.

### 7. HTTPS / Caddy
IP cert shortlived; bootstrap→https; admin 127.0.0.1:2019. Нет security headers (FV-006). Panel не должен быть на :3000 снаружи.

### 8. Установщики / supply chain
SHA256 в one-liner; digest панели; публичный releases repo; приватный source. Caddy tag float (FV-007). curl|bash — риск подмены DNS/HTTPS GitHub (классика). CI permissions в panel-image — contents:read.

### 9. SQLite / backup
master.key 600; secrets encrypted; age backups; restore не затирает чужие данные. delivery_token plaintext (FV-003). Audit log без IP клиента WG.

### 10. Сеть VPS
Установщик не hardening SSH/firewall (FV-008). NAT MASQUERADE есть; ip_forward=1. Docker может осложнять host firewall — проверить на VPS.

### 11. Приватность
Панель: audit действий админа, peer stats (handshake/bytes), имена устройств. Агент: локальный agent.json. WG: handshake timers. Провайдер видит метаданные. Абсолютной анонимности нет.

### 12. Тесты
См. шапку отчёта. Статический разбор Docker/Compose/agent выполнен вручную по файлам.

---

## Краткая сводка

| Уровень | Подтверждено | Potential |
|---------|--------------|-----------|
| CRITICAL | 0 | 0 |
| HIGH | 4 (FV-001…004) | 1 ops (FV-P07) |
| MEDIUM | 6 (FV-005…010) | 4 |
| LOW | 5 (FV-011…015) | 2 |

**Полный отчёт:** `C:\Projects\family-vpn\SECURITY_AUDIT.md`  

Исправления **не** выполнялись. DE-01 и NL-01 не изменялись. Публикация отчёта во внешний репозиторий не производилась.
