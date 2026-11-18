# telemt-web-proxy

Автоустановка **WEB-прокси для Telegram** на базе [telemt](https://github.com/telemt/telemt) — MTProxy-сервера на Rust с поддержкой транспорта `WEB` (HTTPS / WebSocket carrier ).

Скрипт разворачивает production-связку:

```
Telegram Desktop
    │  HTTPS/WSS :443
    ▼
nginx (TLS-терминация, Let's Encrypt)
    │  plain HTTP/1.1 (loopback)
    ▼
telemt WEB-listener  ──►  Telegram DC
    │
    └─ обычные запросы ──► decoy-сайт (маскировка)
```

Опционально — режим **SNI-мультиплексирования** (`--mode sni`): `nginx stream` с `ssl_preread` на 443-м порту маршрутизирует домен прокси в telemt, а весь остальной SNI-трафик — на другой бэкенд (например, Xray Reality). Так 443-й порт делят несколько сервисов.

## Что устанавливается

| Компонент | Детали |
|---|---|
| `telemt` | бинарь из GitHub Releases (x86_64 / x86_64-v3 / aarch64, glibc / musl), проверка sha256 |
| WEB-listener | `127.0.0.1:18080` — HTTPS/WebSocket carrier |
| MTProto-listener | `127.0.0.1:18443` (loopback; `--mtproxy-public` для 0.0.0.0) |
| nginx | TLS-терминация + ACME-виртхост на :80 + decoy-сайт |
| certbot | сертификат Let's Encrypt через webroot (порт 80, без даунтайма) |
| systemd | `telemt.service` под отдельным юзером `telemt` |

## Требования

- Debian / Ubuntu (apt), RHEL-подобные (dnf/yum), Arch, Alpine — на выбор
- systemd, root (или sudo)
- открытые порты **80** (выпуск сертификата) и **443**
- домен, смотрящий на сервер. Если домена нет — автоматически используется `<IP>.sslip.io` (magic-DNS, Let's Encrypt выдаёт на него сертификат)

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/sniks81984-del/telemt-web-proxy/main/install.sh -o install.sh
sudo sh install.sh
```

Со своим доменом:

```bash
sudo sh install.sh --domain proxy.example.com --email admin@example.com
```

Режим разделения 443-го порта (SNI-роутинг, как на связке с Xray):

```bash
sudo sh install.sh --mode sni --sni-fallback 127.0.0.1:7443
```

В конце скрипт печатает ссылку подключения:

```
tg://webproxy?server=<домен>&secret=dd<секрет>
```

## Основные опции

| Флаг | Описание |
|---|---|
| `--domain FQDN` | публичный домен (def `<IP>.sslip.io`) |
| `--port N` | публичный HTTPS-порт (def `443`; `tg://webproxy` требует 443) |
| `--mode direct\|sni` | `direct` — nginx держит порт сам; `sni` — ssl_preread-роутинг |
| `--sni-fallback H:P` | бэкенд для прочего SNI в режиме sni (def `127.0.0.1:7443`) |
| `--secret HEX32` | свой секрет (по умолчанию генерируется) |
| `--carrier C` | `https` (совместимость, iOS) / `https-lanes` / `websocket` / `websocket-lanes` |
| `--decoy URL` | внешний decoy-upstream вместо встроенного сайта-заглушки |
| `--cert-method M` | `webroot` (def) или `standalone` (certbot сам биндит :80) |
| `--no-firewall` | не открывать 80/443 в ufw/firewalld автоматически |
| `--mtproxy-public` | открыть MTProto-listener наружу (выдаст `tg://proxy` ссылку) |
| `--version TAG` | конкретная версия telemt (def `latest`) |
| `--uninstall` | удалить сервис и конфиги; `--purge` — также данные и бинарь |

Полный список: `sh install.sh --help`

## Управление

```bash
journalctl -u telemt -f          # логи (telemt печатает ссылки при старте)
systemctl restart telemt         # рестарт
systemctl reload nginx           # применить изменения nginx
certbot renew                    # сертификат продлевается автоматически
```

Конфиг: `/etc/telemt/config.toml` — после правки `systemctl restart telemt`.

## Сертификат не выдаётся?

Скрипт перед выпуском делает самопроверку `http://<домен>/.well-known/acme-challenge/` и при ошибке certbot печатает хвост его лога. Частые причины:

- **80-й порт закрыт снаружи** — ufw/firewalld (скрипт открывает сам, если они активны) или Security Group/фаервол у хостера — откройте в панели;
- **стоковый сайт nginx** (`sites-enabled/default`) занимал `default_server` на :80 — скрипт снимает флаг автоматически;
- **DNS** — домен не резолвится в IP сервера (скрипт предупреждает о несовпадении);
- альтернатива: `--cert-method standalone` — certbot поднимает свой :80 сам (nginx должен быть остановлен на момент выпуска и продления — хуки ставятся автоматически).

## Удаление

```bash
sudo sh install.sh --uninstall   # сервис + nginx-конфиги
sudo sh install.sh --purge       # + бинарь, /etc/telemt, юзер telemt
```

## Примечания

- WEB-режим telemt требует `plain` или `dd` секреты; `ee` (FakeTLS) не поддерживается транспортом WEB.
- Клиент: Telegram Desktop с типом прокси `WEB` (ссылка `tg://webproxy`). iOS-клиенты работают только с `--carrier https`.
- `--port` позволяет повесить прокси на другой порт, но официальные ссылки `tg://webproxy` в Telegram Desktop работают **только на 443**. Нестандартный порт имеет смысл за NAT/DNAT (внешний 443 → внутренний `--port`) или для кастомных клиентов.
- В режиме `sni` скрипт дописывает маркированный `stream {}`-блок в `nginx.conf`; если `stream {}` уже существует — установка остановится с инструкцией для ручного мержа.

---

## English (short)

One-command installer for a **Telegram WEB proxy** powered by [telemt](https://github.com/telemt/telemt): downloads the binary, writes `/etc/telemt/config.toml` (WEB + MTProto listeners on loopback), configures nginx TLS termination with a Let's Encrypt certificate (webroot on :80, defaults domain to `<IP>.sslip.io`), installs a decoy site, and creates a systemd unit. `--mode sni` adds ssl_preread SNI multiplexing so port 443 can be shared with e.g. Xray. Prints the `tg://webproxy` link at the end. See `install.sh --help` for all flags.

## License

MIT
