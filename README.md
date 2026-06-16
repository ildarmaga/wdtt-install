# wdtt-install

Установщик WDTT VPN + Xray + веб-панель в одну строку (как [3x-ui](https://github.com/MHSanaei/3x-ui)).

VPN-протокол основан на [proxy-turn-vk-android](https://github.com/amurcanov/proxy-turn-vk-android) ([amurcanov](https://github.com/amurcanov)); сервер и панель — [ildarmaga/wdtt](https://github.com/ildarmaga/wdtt).

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh)
```

или:

```bash
wdtt menu
```

`wdtt menu` / `wdtt update` всегда подтягивают **свежий** install.sh с GitHub (git clone), не локальную копию `/usr/local/wdtt/install.sh`.

В шапке установщика: **installer v1.4.36** (совпадает с линейкой релизов wdtt).

**Рекомендуется wdtt ≥ v1.4.36** (VK Creator в панели, unified, minimal systemd unit).

**По умолчанию:**
- пароль VPN **генерируется автоматически** (в `panel.db`, не в systemd);
- **xray** и **веб-панель** устанавливаются сами;
- если WDTT уже установлен — запускается **обновление** с выбором версии из GitHub Releases.

Свой пароль (опционально):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh) install -p YOUR_PASSWORD
```

## Обновление

```bash
wdtt update
```

или повторный запуск install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh) install
```

## Что устанавливается

| Компонент | Путь | Сервис |
|-----------|------|--------|
| wdtt (unified) | `/usr/local/bin/wdtt-app` | `wdtt.service` (server + panel) |
| CLI | `/usr/local/bin/wdtt` | `wdtt menu`, `wdtt status`, `wdtt purge` |
| xray routing | `/usr/local/wdtt-xray/bin/` | `wdtt-xray.service` |
| Конфиг VPN | `/etc/wdtt/panel.db` | — |
| Seed при установке | `/etc/wdtt/install-inbound.env`, `install-main-password.env` | — |
| Конфиг Xray | `/etc/wdtt-xray/config.json` | — |

**systemd unit (v1.4.9+):** `ExecStart=/usr/local/bin/wdtt-app -config-dir /etc/wdtt` — порты, DNS, лимиты только в **panel.db** (Панель → Подключения).

По умолчанию: **xray + panel**. Только VPN без Xray: `--direct`.

## Опции

```
install               установка (или обновление, если уже есть WDTT)
update                обновление с выбором версии
-p, --password PASS   свой пароль VPN (иначе генерируется)
--version TAG         версия для обновления (v1.4.9)
--xray                маршрутизация через xray (по умолчанию)
--direct              без xray, прямой NAT
--panel               веб-панель (по умолчанию)
--no-panel            без панели (-password остаётся в ExecStart)
--force               переустановка даже если WDTT уже есть
--github-user USER    ваш GitHub
status | uninstall | purge
```

**Удаление:**
- `wdtt uninstall` — сервисы и бинарники; `/etc/wdtt` сохраняется
- `wdtt purge` — **полное удаление**: `/etc/wdtt`, `/etc/wdtt-xray`, NAT, firewall, логи

Переменные: `WDTT_GITHUB_USER`, `WDTT_VERSION`, `WDTT_DTLS_PORT`, `WDTT_WG_PORT`, `WDTT_PANEL_PORT`.

## После установки

- Панель: `http://IP:2860/wdtt/` — логин `admin`, пароль `wdtt`
- Команды: `wdtt menu` · `wdtt status` · `wdtt update` · `wdtt purge` · `wdtt restart` · `wdtt log`
- Outbound (NL, warp…) настраивается в панели → **Настройки Xray**

## Репозитории

1. [wdtt](https://github.com/ildarmaga/wdtt) — сервер + панель
2. **wdtt-install** — этот репозиторий (установщик)

При изменении unified-архитектуры или `deploy.sh` в **wdtt** — синхронизировать `install.sh` здесь (unit, seed-файлы, README).

## Локальная установка

```bash
bash /root/wdtt-install/install.sh install
```
