# wdtt-install

Установщик WDTT VPN + Xray + веб-панель в одну строку (как [3x-ui](https://github.com/MHSanaei/3x-ui)).

## Быстрая установка

Замените `YOUR_GITHUB_USER` на ваш GitHub-логин:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/wdtt-install/main/install.sh)
```

С паролем и без интерактива:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/wdtt-install/main/install.sh) install -p YOUR_PASSWORD --xray --panel
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
install -p PASSWORD   главный пароль VPN
--xray                маршрутизация через xray (по умолчанию)
--direct              без xray, прямой NAT
--panel               веб-панель (по умолчанию)
--github-user USER    ваш GitHub (репозитории server/panel/install)
status | uninstall
```

Переменные: `WDTT_GITHUB_USER`, `WDTT_DTLS_PORT`, `WDTT_WG_PORT`, `WDTT_PANEL_PORT`.

## После установки

- Панель: `http://IP:2860/wdtt/` — логин `admin`, пароль `wdtt`
- Команда: `wdtt status` / `wdtt restart` / `wdtt log`
- Outbound (NL, warp…) настраивается в панели → **Настройки Xray**

## Репозитории

Нужны два репозитория на GitHub:

1. [wdtt](https://github.com/amurcanov/wdtt) — сервер (`server.go`) + панель (`panel/`)
2. **wdtt-install** — этот репозиторий (установщик)

Установщик клонирует `wdtt` один раз и собирает сервер и панель из одного репозитория.

## Публикация на GitHub

```bash
# 1. Создайте репозитории: wdtt, wdtt-install

# 2. wdtt (сервер + panel/)
cd /root/wdtt
git add . && git commit -m "WDTT monorepo: server + panel"
git remote add origin git@github.com:YOUR_USER/wdtt.git
git push -u origin main

# 3. wdtt-install
cd /root/wdtt-install
git add . && git commit -m "Initial installer"
git remote add origin git@github.com:YOUR_USER/wdtt-install.git
git push -u origin main

# 4. Установка одной строкой
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_USER/wdtt-install/main/install.sh) install -p secret --panel --xray
```

## Локальная установка (без GitHub)

```bash
bash /root/wdtt-install/install.sh install -p mypass --panel --xray
```

С локальными исходниками задайте пути через клон в `/usr/local/wdtt/src` или положите бинарники в `/tmp/wdtt-server` перед запуском.
