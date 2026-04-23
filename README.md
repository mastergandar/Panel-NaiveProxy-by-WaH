# Panel NaiveProxy + Hysteria2

> Веб-панель управления для быстрой установки и управления NaiveProxy (TCP 443) + Hysteria2 (UDP 443) на VPS.
> Traefik как единый ACME-клиент и edge-прокси, Caddy — NaiveProxy на внутреннем порту.

---

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mastergandar/Panel-NaiveProxy-by-WaH/main/install.sh)
```

Скрипт запросит:
- `NAIVE_DOMAIN` — домен для NaiveProxy (proxy.example.com)
- `PANEL_DOMAIN` — домен для веб-панели (panel.example.com)
- `ADMIN_DOMAIN` — домен для дашборда Traefik (admin.example.com)
- `NAIVE_EMAIL` — email для Let's Encrypt
- `TRAEFIK_USER` — логин для basicAuth (панель + Traefik dashboard)
- Пароли генерируются автоматически и выводятся в конце установки

---

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11 / 12
- 3 поддомена с A-записями на IP сервера
- Открытые порты: 22, 80, 443/tcp, 443/udp
- Минимум 1 GB RAM (сборка Caddy требует ~512 MB временно)

---

## Архитектура

```
Internet
  ├── TCP 80   → Traefik (HTTP→HTTPS redirect + ACME HTTP-01)
  ├── TCP 443  → Traefik (SNI routing)
  │              ├── SNI=proxy.domain  → TCP passthrough → Caddy:10443 (NaiveProxy)
  │              ├── SNI=panel.domain  → basicAuth → Node.js:3000
  │              └── SNI=admin.domain  → basicAuth → Traefik dashboard
  └── UDP 443  → Hysteria2 (QUIC, мимо Traefik)

traefik-certs-dumper: /etc/traefik/acme.json → /etc/ssl/traefik-certs/<domain>/
Caddy и Hysteria2 читают сертификаты из файлов (не делают ACME самостоятельно)
```

---

## Возможности панели

| Функция | Описание |
|---------|----------|
| **Установка в 1 клик** | Домен + email → панель поднимает весь стек автоматически |
| **Управление пользователями** | Добавление/удаление прокси-пользователей с авто-обновлением Caddyfile |
| **Дашборд** | Статус Caddy и Hysteria2, IP сервера, домен, кол-во пользователей |
| **Ссылки подключения** | `naive+https://...` и `hysteria2://...` ссылки для всех клиентов |
| **Управление сервисом** | Старт / стоп / рестарт Caddy и Hysteria2 из браузера |
| **Смена пароля панели** | Мин. 12 символов |

---

## Процесс установки (автоматически)

1. Обновление системы и зависимостей
2. Включение BBR
3. Настройка UFW (22, 80, 443/tcp, 443/udp)
4. Установка Traefik + traefik-certs-dumper, systemd сервисы
5. Ожидание выдачи ACME-сертификатов Traefik
6. Первый дамп сертификатов в файлы
7. Установка Go
8. Сборка Caddy с naive-плагином, порт 127.0.0.1:10443
9. Node.js + PM2, веб-панель на 127.0.0.1:3000
10. Установка Hysteria2, порт UDP 443

---

## Клиенты для подключения

**NaiveProxy:**

| Платформа | Приложение |
|-----------|-----------|
| iOS | [Karing](https://apps.apple.com/app/karing/id6472431552) |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| Windows | [Hiddify](https://github.com/hiddify/hiddify-app/releases) |
| Windows | [NekoRay](https://github.com/MatsuriDayo/nekoray/releases) |

```
naive+https://LOGIN:PASSWORD@proxy.example.com:443
```

**Hysteria2:**

| Платформа | Приложение |
|-----------|-----------|
| iOS / Android / Windows / macOS | [Hiddify](https://github.com/hiddify/hiddify-app/releases) |
| Windows / Linux | [Hysteria2 CLI](https://github.com/apernet/hysteria/releases) |

```
hysteria2://PASSWORD@proxy.example.com:443
```

---

## Управление панелью

```bash
pm2 status                      # Статус
pm2 logs naiveproxy-panel       # Логи
pm2 restart naiveproxy-panel    # Перезапуск
pm2 stop naiveproxy-panel       # Остановка
```

```bash
systemctl status traefik            # Traefik
systemctl status caddy              # NaiveProxy (Caddy)
systemctl status hysteria-server    # Hysteria2
systemctl status traefik-certs-dumper
```

---

## Безопасность

- basicAuth (bcrypt) на веб-панели и Traefik dashboard
- Пароли панели и Hysteria2 генерируются случайно при установке
- Rate limiting на /api/login (10 попыток / 15 мин)
- WebSocket требует аутентификации
- Caddyfile и конфиги защищены от инъекций
- Сессии с HttpOnly + SameSite=strict cookie
- Мин. длина пароля панели — 12 символов
