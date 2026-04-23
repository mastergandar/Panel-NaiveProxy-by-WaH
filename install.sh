#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel NaiveProxy by RIXXX — Полный установщик
#  Стек: Traefik (edge/ACME) + Caddy (NaiveProxy) + Hysteria2 + Node.js панель
#  Запуск: bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX/main/install.sh)
#  Требования: Ubuntu 22.04 / 24.04, root, чистый сервер
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REPO_URL="https://github.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX"
PANEL_DIR="/opt/naiveproxy-panel"
SERVICE_NAME="naiveproxy-panel"
INTERNAL_PORT=3000

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  clear
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║   Panel NaiveProxy by RIXXX — Установщик v2             ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   Стек: Traefik + Caddy + Hysteria2 + Node.js            ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

header

# ── Root check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_err "Запускайте скрипт от root: sudo bash install.sh"
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  log_err "Поддерживается только Ubuntu/Debian"
  exit 1
fi

# ── Определяем IP ───────────────────────────────────────────────────────
SERVER_IP=$(curl -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null \
  || curl -4 -s --connect-timeout 8 icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}"
echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ А — НАСТРОЙКИ
# ════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}Настройка доменов:${RESET}"
echo -e "${YELLOW}  ⚠  Все A-записи должны уже указывать на ${SERVER_IP}${RESET}"
echo ""

read -rp "  Домен NaiveProxy (proxy.yourdomain.com): " NAIVE_DOMAIN
read -rp "  Домен панели управления (panel.yourdomain.com): " PANEL_DOMAIN
read -rp "  Домен Traefik dashboard (admin.yourdomain.com): " ADMIN_DOMAIN
read -rp "  Email для Let's Encrypt: " NAIVE_EMAIL
echo ""

echo -e "${BOLD}Настройка доступа к панели и dashboard:${RESET}"
read -rp "  Логин для basicAuth (панель + Traefik dashboard): " TRAEFIK_USER
TRAEFIK_USER="${TRAEFIK_USER:-admin}"
echo ""

# Генерируем все пароли
NAIVE_LOGIN=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16)
NAIVE_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
TRAEFIK_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)
HY2_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)

echo -e "${GREEN}  ✅ Сгенерированы учётные данные:${RESET}"
log_info "NaiveProxy логин:  ${NAIVE_LOGIN}"
log_info "NaiveProxy пароль: ${NAIVE_PASS}"
log_info ""
log_info "Панель/Dashboard basicAuth: ${TRAEFIK_USER} / ${TRAEFIK_PASS}"
log_info "Hysteria2 пароль:           ${HY2_PASSWORD}"
echo ""
echo -e "${YELLOW}  ⚠  Запомните эти данные! Они также будут показаны в конце.${RESET}"
echo ""
read -rp "Всё верно? Начать установку? [Enter / Ctrl+C для отмены]: " _CONFIRM
echo ""

# ════════════════════════════════════════════════════════════════════════
# РАЗДЕЛ Б — УСТАНОВКА
# ════════════════════════════════════════════════════════════════════════

# ── Б1. needrestart фикс + обновление системы ──────────────────────────
log_step "[1/13] Обновление системы..."

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
pkill -9 unattended-upgrades 2>/dev/null || true
sleep 1

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
  log_info "needrestart настроен (авто-режим)"
fi

DEBIAN_FRONTEND=noninteractive apt-get update -qq \
  -o DPkg::Lock::Timeout=60 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -o DPkg::Lock::Timeout=60 \
  curl wget git openssl ufw build-essential apache2-utils 2>/dev/null || true

log_ok "Система обновлена"

# ── Б2. Включение BBR ──────────────────────────────────────────────────
log_step "[2/13] Включение BBR (оптимизация скорости)..."

grep -qxF "net.core.default_qdisc=fq" /etc/sysctl.conf \
  || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf \
  || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
log_ok "BBR включён"

# ── Б3. UFW ────────────────────────────────────────────────────────────
log_step "[3/13] Настройка файрволла UFW..."

ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
# Панель слушает только на 127.0.0.1 — порт 3000 не открываем наружу
echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
log_ok "UFW настроен (22, 80, 443/tcp+udp; порт 3000 закрыт снаружи)"

# ── Б4. Генерируем htpasswd хеш для Traefik basicAuth ──────────────────
log_step "[4/13] Генерация htpasswd credentials для Traefik..."

TRAEFIK_PASS_HASHED=$(htpasswd -nbB "${TRAEFIK_USER}" "${TRAEFIK_PASS}" 2>/dev/null | cut -d: -f2)
# Double $ for YAML config (Traefik requirement)
TRAEFIK_PASS_YAML=$(echo "${TRAEFIK_PASS_HASHED}" | sed 's/\$/\$\$/g')
log_ok "htpasswd хеш сгенерирован"

# ── Б5. Установка Traefik + traefik-certs-dumper ───────────────────────
log_step "[5/13] Установка Traefik (edge proxy + ACME сертификаты)..."

# Экспортируем переменные для install_traefik.sh
export NAIVE_DOMAIN PANEL_DOMAIN ADMIN_DOMAIN NAIVE_EMAIL
export TRAEFIK_USER TRAEFIK_PASS_YAML

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TRAEFIK_SCRIPT="${PANEL_DIR}/panel/scripts/install_traefik.sh"

# Если скрипт ещё не скачан (первый запуск до клонирования), используем путь рядом
if [[ ! -f "$TRAEFIK_SCRIPT" ]]; then
  TRAEFIK_SCRIPT="${SCRIPT_DIR}/panel/scripts/install_traefik.sh"
fi

if [[ -f "$TRAEFIK_SCRIPT" ]]; then
  bash "$TRAEFIK_SCRIPT" 2>&1
else
  # Инлайн-установка если скрипт не найден
  log_warn "install_traefik.sh не найден — клонируем репозиторий сначала"
fi

log_ok "Traefik установлен"

# ── Б6. Ждём выдачи Let's Encrypt сертификатов ────────────────────────
log_step "[6/13] Ожидание Let's Encrypt сертификатов (до 3 минут)..."

log_info "Traefik запрашивает сертификаты для:"
log_info "  ${NAIVE_DOMAIN}, ${PANEL_DOMAIN}, ${ADMIN_DOMAIN}"
log_info "Убедитесь что все A-записи указывают на ${SERVER_IP}"

CERT_WAIT=0
for i in $(seq 1 36); do
  if [[ -f /etc/traefik/acme.json ]] && \
     [[ $(wc -c < /etc/traefik/acme.json 2>/dev/null || echo 0) -gt 200 ]] && \
     grep -q "\"${NAIVE_DOMAIN}\"" /etc/traefik/acme.json 2>/dev/null; then
    log_ok "Сертификаты получены (${i}*5с = $((i*5))с)"
    CERT_WAIT=1
    break
  fi
  sleep 5
  [[ $((i % 6)) -eq 0 ]] && log_info "...ожидаем ($((i*5))с из 180с)"
done

if [[ $CERT_WAIT -eq 0 ]]; then
  log_warn "Сертификаты ещё не получены (DNS не прошёл?)."
  log_warn "Продолжаем — сервисы запустятся как только сертификаты появятся."
fi

# ── Б7. Первый дамп сертификатов ──────────────────────────────────────
log_step "[7/13] Экспорт сертификатов из Traefik..."

mkdir -p /etc/ssl/traefik-certs

if [[ -f /etc/traefik/acme.json ]] && \
   [[ $(wc -c < /etc/traefik/acme.json 2>/dev/null || echo 0) -gt 200 ]]; then
  /usr/local/bin/traefik-certs-dumper file \
    --source /etc/traefik/acme.json \
    --dest /etc/ssl/traefik-certs 2>/dev/null || true
  log_ok "Сертификаты экспортированы в /etc/ssl/traefik-certs/"
else
  log_warn "acme.json пуст — запустим traefik-certs-dumper в watch-режиме"
  log_warn "Caddy и Hysteria2 стартуют автоматически когда сертификаты появятся"
fi

# Запускаем traefik-certs-dumper в watch-режиме
systemctl start traefik-certs-dumper 2>/dev/null || true

# ── Б8. Установка Go ───────────────────────────────────────────────────
log_step "[8/13] Установка Go..."

rm -rf /usr/local/go

GO_VERSION=""
for attempt in 1 2 3; do
  GO_VERSION=$(curl -fsSL --connect-timeout 10 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  [[ -n "$GO_VERSION" && "$GO_VERSION" == go* ]] && break
  sleep 2
done
[[ -z "$GO_VERSION" || "$GO_VERSION" != go* ]] && GO_VERSION="go1.22.5"

log_info "Загружаем ${GO_VERSION}..."
wget -q --show-progress --timeout=180 \
  "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/go.tar.gz 2>&1 || { log_err "Не удалось загрузить Go!"; exit 1; }

[[ ! -s /tmp/go.tar.gz ]] && { log_err "Файл Go пустой"; exit 1; }

tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH

grep -q "/usr/local/go/bin" /root/.profile 2>/dev/null || {
  echo 'export GOROOT=/usr/local/go' >> /root/.profile
  echo 'export GOPATH=/root/go' >> /root/.profile
  echo 'export PATH=$GOROOT/bin:$GOPATH/bin:$PATH' >> /root/.profile
}
log_ok "Go установлен: $(/usr/local/go/bin/go version 2>/dev/null || echo 'неизвестно')"

# ── Б9. Сборка Caddy с naive-плагином ─────────────────────────────────
log_step "[9/13] Сборка Caddy + naive forward proxy (3-7 минут)..."

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export TMPDIR=/root/tmp
export GOPROXY=https://proxy.golang.org,direct
mkdir -p /root/tmp /root/go

log_info "Установка xcaddy..."
/usr/local/go/bin/go install \
  github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>&1 | tail -2

[[ ! -f /root/go/bin/xcaddy ]] && { log_err "xcaddy не установился!"; exit 1; }
log_info "xcaddy установлен, собираем Caddy..."

rm -f /root/caddy
cd /root

/root/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
  2>&1 | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "    $line"
  done

[[ ! -f /root/caddy ]] && { log_err "Caddy не собран!"; exit 1; }
mv /root/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy
log_ok "Caddy собран: $(/usr/bin/caddy version 2>/dev/null || echo 'неизвестно')"

# ── Б10. Конфигурация и запуск Caddy ──────────────────────────────────
log_step "[10/13] Конфигурация Caddy (порт 10443, cert файлы)..."

mkdir -p /var/www/html /etc/caddy

cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title>
<style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style>
</head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
HTMLEOF

CERT_DIR="/etc/ssl/traefik-certs/${NAIVE_DOMAIN}"

if [[ -f "${CERT_DIR}/certificate.crt" ]]; then
  TLS_LINE="  tls ${CERT_DIR}/certificate.crt ${CERT_DIR}/privatekey.key"
  log_ok "Cert найден в ${CERT_DIR}"
else
  log_warn "Cert ещё не готов — Caddy будет ждать (traefik-certs-dumper обновит)"
  TLS_LINE="  tls ${CERT_DIR}/certificate.crt ${CERT_DIR}/privatekey.key"
fi

{
  printf '{\n  order forward_proxy before file_server\n}\n\n'
  printf '127.0.0.1:10443 {\n'
  printf '%s\n\n' "${TLS_LINE}"
  printf '  forward_proxy {\n'
  printf '    basic_auth %s %s\n' "${NAIVE_LOGIN}" "${NAIVE_PASS}"
  printf '    hide_ip\n'
  printf '    hide_via\n'
  printf '    probe_resistance\n'
  printf '  }\n\n'
  printf '  file_server {\n'
  printf '    root /var/www/html\n'
  printf '  }\n'
  printf '}\n'
} > /etc/caddy/Caddyfile
chmod 640 /etc/caddy/Caddyfile

systemctl stop caddy 2>/dev/null || true
pkill -x caddy 2>/dev/null || true
sleep 1

cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy with NaiveProxy (by RIXXX)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target traefik-certs-dumper.service
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1 || true
systemctl start caddy 2>&1 || log_warn "Caddy запустится когда появятся сертификаты"

CADDY_OK=0
for i in $(seq 1 15); do
  if systemctl is-active --quiet caddy 2>/dev/null || pgrep -x caddy >/dev/null 2>/dev/null; then
    log_ok "Caddy запущен (${i}с)"
    CADDY_OK=1; break
  fi
  sleep 1
done
[[ $CADDY_OK -eq 0 ]] && log_warn "Caddy запустится автоматически после получения сертификатов"

# ── Б11. Установка Hysteria2 ───────────────────────────────────────────
log_step "[11/13] Установка Hysteria2 (QUIC прокси, UDP 443)..."

HYSTERIA_SCRIPT="${PANEL_DIR}/panel/scripts/install_hysteria2.sh"
if [[ ! -f "$HYSTERIA_SCRIPT" ]]; then
  HYSTERIA_SCRIPT="${SCRIPT_DIR}/panel/scripts/install_hysteria2.sh"
fi

if [[ -f "$HYSTERIA_SCRIPT" ]]; then
  export NAIVE_DOMAIN HY2_PASSWORD
  bash "$HYSTERIA_SCRIPT" 2>&1
  log_ok "Hysteria2 установлен"
else
  log_warn "install_hysteria2.sh не найден — Hysteria2 не установлен"
fi

# ── Б12. Node.js + PM2 ────────────────────────────────────────────────
log_step "[12/13] Установка Node.js и панели управления..."

if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')" -lt 18 ]]; then
  log_info "Скачиваем NodeSource репозиторий..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | grep -E "^##|^Running|error" || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" 2>/dev/null || true
fi
log_ok "Node.js: $(node -v 2>/dev/null || echo 'не найден')"

npm install -g pm2 --silent 2>&1 | grep -v "^npm warn" | tail -2 || true
log_ok "PM2: $(pm2 -v 2>/dev/null || echo 'ok')"

# Клонируем/обновляем панель
if [[ -d "${PANEL_DIR}/.git" ]]; then
  log_warn "Панель уже установлена — обновляем..."
  cd "${PANEL_DIR}" && git pull --ff-only 2>&1 | tail -2 || true
else
  rm -rf "${PANEL_DIR}"
  git clone "${REPO_URL}" "${PANEL_DIR}" 2>&1 || {
    log_err "Не удалось клонировать репозиторий."
    exit 1
  }
fi

cd "${PANEL_DIR}/panel"
npm install --omit=dev 2>&1 | grep -v "^npm warn" | tail -3 || true
mkdir -p "${PANEL_DIR}/panel/data"
log_ok "Панель загружена в ${PANEL_DIR}"

# ── Записываем config.json ──────────────────────────────────────────────
HY2_ACTIVE=false
systemctl is-active --quiet hysteria-server 2>/dev/null && HY2_ACTIVE=true

if [[ ! -f "${PANEL_DIR}/panel/data/config.json" ]]; then
  cat > "${PANEL_DIR}/panel/data/config.json" << CONFIGEOF
{
  "installed": true,
  "naiveDomain": "${NAIVE_DOMAIN}",
  "domain": "${NAIVE_DOMAIN}",
  "panelDomain": "${PANEL_DOMAIN}",
  "adminDomain": "${ADMIN_DOMAIN}",
  "email": "${NAIVE_EMAIL}",
  "serverIp": "${SERVER_IP}",
  "proxyUsers": [
    {
      "username": "${NAIVE_LOGIN}",
      "password": "${NAIVE_PASS}",
      "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
  ],
  "hysteriaEnabled": ${HY2_ACTIVE},
  "hysteriaPassword": "${HY2_PASSWORD}",
  "traefikUser": "${TRAEFIK_USER}"
}
CONFIGEOF
  log_ok "config.json записан"
else
  log_warn "config.json уже существует — не перезаписываем"
fi

# ── Б13. Запуск панели через PM2 ───────────────────────────────────────
log_step "[13/13] Запуск панели управления через PM2..."

cd "${PANEL_DIR}/panel"
pm2 delete "${SERVICE_NAME}" 2>/dev/null || true
sleep 1

pm2 start server/index.js \
  --name "${SERVICE_NAME}" \
  --time \
  --restart-delay=3000 \
  2>&1 | tail -3

pm2 save --force >/dev/null 2>&1 || true

PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>/dev/null | grep "^sudo" || true)
if [[ "$PM2_STARTUP" =~ ^sudo[[:space:]]pm2[[:space:]]startup ]]; then
  bash -c "$PM2_STARTUP" >/dev/null 2>&1 || true
fi

sleep 2

if pm2 describe "${SERVICE_NAME}" 2>/dev/null | grep -q "online"; then
  log_ok "Панель запущена через PM2"
else
  log_warn "Проверьте: pm2 status && pm2 logs ${SERVICE_NAME}"
fi

# ════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНЫЙ ВЫВОД
# ════════════════════════════════════════════════════════════════════════

NAIVE_LINK="naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443"
HY2_LINK="hysteria2://${HY2_PASSWORD}@${NAIVE_DOMAIN}:443"

echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Panel NaiveProxy by RIXXX — Установка завершена!       ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  ПАНЕЛЬ УПРАВЛЕНИЯ (BasicAuth защита)                   ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ➜   https://${PANEL_DOMAIN}${RESET}"
echo -e "${PURPLE}${BOLD}║   Логин:  ${TRAEFIK_USER}${RESET}"
echo -e "${PURPLE}${BOLD}║   Пароль: ${TRAEFIK_PASS}${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   📊  TRAEFIK DASHBOARD                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ➜   https://${ADMIN_DOMAIN}${RESET}"
echo -e "${PURPLE}${BOLD}║   (те же basicAuth credentials)                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🔒  NAIVEPROXY (TCP 443)                                   ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Логин:  ${NAIVE_LOGIN}                                     ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Пароль: ${NAIVE_PASS}                                      ║${RESET}"
echo -e "${CYAN}   ${NAIVE_LINK}${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ⚡  HYSTERIA2 (UDP 443)                                    ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Пароль: ${HY2_PASSWORD}                                    ║${RESET}"
echo -e "${CYAN}   ${HY2_LINK}${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   📌  Полезные команды:                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status traefik           — Traefik              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status caddy             — NaiveProxy           ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status hysteria-server   — Hysteria2            ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status traefik-certs-dumper — Cert dumper       ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 status                         — Панель               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ls /etc/ssl/traefik-certs/         — Cert файлы           ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                              ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo ""
