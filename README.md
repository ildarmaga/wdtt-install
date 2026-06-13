# wdtt-install

Установщик WDTT VPN + Xray + веб-панель в одну строку (как [3x-ui](https://github.com/MHSanaei/3x-ui)).

VPN-протокол основан на [proxy-turn-vk-android](https://github.com/amurcanov/proxy-turn-vk-android) ([amurcanov](https://github.com/amurcanov)); сервер и панель — [ildarmaga/wdtt](https://github.com/ildarmaga/wdtt).

## Быстрая установка

```bash
SHA=$(curl -fsSL https://api.github.com/repos/ildarmaga/wdtt-install/commits/main | sed -n 's/.*"sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
bash <(curl -fsSL "https://raw.githubusercontent.com/ildarmaga/wdtt-install/${SHA}/install.sh")
```

Так обходится кэш GitHub CDN на `main/install.sh`. В шапке должно быть `installer v1.3.4` или новее.

Явно без меню (авто-режим):

```bash
SHA=$(curl -fsSL https://api.github.com/repos/ildarmaga/wdtt-install/commits/main | sed -n 's/.*"sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
bash <(curl -fsSL "https://raw.githubusercontent.com/ildarmaga/wdtt-install/${SHA}/install.sh") install --no-menu
```

или:

```bash
wdtt menu
```

`wdtt menu` / `wdtt update` всегда подтягивают **свежий** install.sh с GitHub (git clone), не локальную копию `/usr/local/wdtt/install.sh`.

**По умолчанию:**
- пароль VPN **генерируется автоматически** (показывается в конце установки);
- **xray** и **веб-панель** устанавливаются сами;
- если WDTT уже установлен — запускается **обновление** с выбором версии из GitHub Releases.

Свой пароль (опционально):

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh) install -p YOUR_PASSWORD
```

## Обновление

Повторный запуск install на уже установленном сервере:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh) install
```

Появится меню выбора версии (v1.2.4, v1.2.3, …). Или без меню:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ildarmaga/wdtt-install/main/install.sh) update --version v1.2.4
wdtt update
```

## Что устанавливается

| Компонент | Путь | Сервис |
|-----------|------|--------|
| wdtt-server | `/usr/local/bin/wdtt-server` | `wdtt.service` |
| xray routing | `/usr/local/wdtt-xray/bin/` | `wdtt-xray.service` |
| wdtt-panel | `/usr/local/bin/wdtt-panel` | `wdtt-panel.service` |
| Конфиг VPN | `/etc/wdtt/` | — |
| Конфиг Xray | `/etc/wdtt-xray/config.json` | — |

По умолчанию: **xray + panel**. Только VPN без Xray: `--direct`.

## Опции

```
install               установка (или обновление, если уже есть WDTT)
update                обновление с выбором версии
-p, --password PASS   свой пароль VPN (иначе генерируется)
--version TAG         версия для обновления (v1.2.4)
--xray                маршрутизация через xray (по умолчанию)
--direct              без xray, прямой NAT
--panel               веб-панель (по умолчанию)
--no-panel            без панели
--force               переустановка даже если WDTT уже есть
--github-user USER    ваш GitHub
status | uninstall
```

Переменные: `WDTT_GITHUB_USER`, `WDTT_VERSION`, `WDTT_DTLS_PORT`, `WDTT_WG_PORT`, `WDTT_PANEL_PORT`.

## После установки

- Панель: `http://IP:2860/wdtt/` — логин `admin`, пароль `wdtt`
- Команды: `wdtt menu` / `wdtt status` / `wdtt update` / `wdtt restart` / `wdtt log`
- Outbound (NL, warp…) настраивается в панели → **Настройки Xray**

## Репозитории

1. [wdtt](https://github.com/ildarmaga/wdtt) — сервер + панель
2. **wdtt-install** — этот репозиторий (установщик)

## Локальная установка

```bash
bash /root/wdtt-install/install.sh install
```
