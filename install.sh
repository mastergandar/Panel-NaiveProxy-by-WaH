#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Panel NaiveProxy by RIXXX — Установщик панели управления
#  Запуск: bash <(curl -fsSL https://raw.githubusercontent.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX/main/install.sh)
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REPO_URL="https://github.com/cwash797-cmd/Panel-NaiveProxy-by-RIXXX"
PANEL_DIR="/opt/naiveproxy-panel"
SERVICE_NAME="naiveproxy-panel"
INTERNAL_PORT=3000

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  clear
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║       Panel NaiveProxy by RIXXX — Установщик        ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; exit 1; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

header

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ Запускайте скрипт от root: sudo bash install.sh${RESET}"
  exit 1
fi

# ── OS check ─────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  echo -e "${RED}❌ Поддерживается только Ubuntu/Debian${RESET}"
  exit 1
fi

SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null \
  || curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null \
  || hostname -I | awk '{print $1}')

echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}"
echo ""

# ── Security mode selection ──────────────────────────────────
echo -e "${BOLD}Выберите способ доступа к панели:${RESET}"
echo ""
echo -e "  ${CYAN}1)${RESET} Через Nginx на порту ${BOLD}8080${RESET} (рекомендуется — порт 3000 не светится)"
echo -e "  ${CYAN}2)${RESET} Напрямую на порту ${BOLD}3000${RESET} (проще, но порт виден)"
echo -e "  ${CYAN}3)${RESET} Через Nginx с доменом + HTTPS (максимальная защита)"
echo ""
read -rp "Ваш выбор [1/2/3]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"

PANEL_DOMAIN=""
if [[ "$ACCESS_MODE" == "3" ]]; then
  read -rp "Введите домен для панели (например panel.yourdomain.com): " PANEL_DOMAIN
  read -rp "Email для Let's Encrypt: " PANEL_EMAIL
fi

echo ""

# ── Step 1: System update ────────────────────────────────────
log_step "Обновление системы..."
apt-get update -y -qq   -o Dpkg::Options::="--force-confdef"   -o Dpkg::Options::="--force-confold" || true
apt-get install -y -qq curl wget git openssl ufw   -o Dpkg::Options::="--force-confdef"   -o Dpkg::Options::="--force-confold" || true
log_ok "Система обновлена"

# ── Step 2: Install Node.js ──────────────────────────────────
log_step "Установка Node.js 20..."
if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')" -lt 18 ]]; then
  log_info "Скачиваем NodeSource репозиторий..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | grep -E "^##|^Running|error" || true
  apt-get install -y -qq nodejs     -o Dpkg::Options::="--force-confdef"     -o Dpkg::Options::="--force-confold" || true
fi
NODE_VER=$(node -v 2>/dev/null || echo "не найден")
log_ok "Node.js установлен: $NODE_VER"

# ── Step 3: Install PM2 ──────────────────────────────────────
log_step "Установка PM2..."
npm install -g pm2 --silent 2>&1 | grep -v "^npm warn" | tail -3 || true
log_ok "PM2 установлен: $(pm2 -v 2>/dev/null || echo 'ok')"

# ── Step 4: Install Nginx (if needed) ───────────────────────
if [[ "$ACCESS_MODE" == "1" || "$ACCESS_MODE" == "3" ]]; then
  log_step "Установка Nginx..."
  apt-get install -y -qq nginx     -o Dpkg::Options::="--force-confdef"     -o Dpkg::Options::="--force-confold" || true
  log_ok "Nginx установлен"
fi

# ── Step 5: Clone / Update panel ────────────────────────────
log_step "Загрузка панели управления..."
if [[ -d "$PANEL_DIR/.git" ]]; then
  log_warn "Панель уже установлена. Обновляем..."
  cd "$PANEL_DIR"
  git pull --ff-only || true
else
  rm -rf "$PANEL_DIR"
  git clone "$REPO_URL" "$PANEL_DIR" || { log_err "Ошибка клонирования репозитория. Проверьте интернет."; exit 1; }
fi
log_ok "Код загружен в $PANEL_DIR"

# ── Step 6: Install dependencies ────────────────────────────
log_step "Установка зависимостей Node.js..."
cd "$PANEL_DIR/panel"
npm install --omit=dev 2>&1 | grep -v "^npm warn" | tail -3 || true
log_ok "Зависимости установлены"

# ── Step 7: Create data dir & permissions ───────────────────
log_step "Настройка директорий и прав..."
mkdir -p "$PANEL_DIR/panel/data"
chmod +x "$PANEL_DIR/panel/scripts/install_naiveproxy.sh" 2>/dev/null || true
log_ok "Директории настроены"

# ── Step 8: Configure UFW ───────────────────────────────────
log_step "Настройка файрволла..."
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

if [[ "$ACCESS_MODE" == "1" ]]; then
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  log_info "Открыт порт 8080 (Nginx proxy)"
elif [[ "$ACCESS_MODE" == "2" ]]; then
  ufw allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_info "Открыт порт ${INTERNAL_PORT} (прямой доступ)"
fi

# Deny direct access to 3000 if using nginx
if [[ "$ACCESS_MODE" == "1" || "$ACCESS_MODE" == "3" ]]; then
  ufw deny ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  log_info "Порт 3000 закрыт снаружи (проксируется через Nginx)"
fi

echo "y" | ufw enable >/dev/null 2>&1 || true
log_ok "Файрволл настроен"

# ── Step 9: Start panel with PM2 ────────────────────────────
log_step "Запуск панели через PM2..."
cd "$PANEL_DIR/panel"

# Stop existing if running
pm2 delete "$SERVICE_NAME" 2>/dev/null || true
sleep 1

pm2 start server/index.js \
  --name "$SERVICE_NAME" \
  --time \
  --restart-delay=3000

pm2 save --force >/dev/null 2>&1 || true

# Auto-start on reboot
PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>/dev/null | grep "sudo" || true)
if [[ -n "$PM2_STARTUP" ]]; then
  eval "$PM2_STARTUP" >/dev/null 2>&1 || true
fi

sleep 2

# ── Step 10: Configure Nginx ────────────────────────────────
if [[ "$ACCESS_MODE" == "1" ]]; then
  log_step "Настройка Nginx (порт 8080 → 3000)..."

  cat > /etc/nginx/sites-available/naiveproxy-panel << NGINXEOF
server {
    listen 8080;
    server_name _;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/naiveproxy-panel /etc/nginx/sites-enabled/naiveproxy-panel 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1
  log_ok "Nginx настроен (порт 8080 → 3000)"

elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  log_step "Настройка Nginx с доменом + SSL..."

  # Install certbot
  apt-get install -y -q python3-certbot-nginx 2>&1 | tail -1

  cat > /etc/nginx/sites-available/naiveproxy-panel << NGINXEOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/naiveproxy-panel /etc/nginx/sites-enabled/naiveproxy-panel 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1

  # Get SSL certificate
  certbot --nginx -d "$PANEL_DOMAIN" --email "${PANEL_EMAIL:-admin@${PANEL_DOMAIN}}" \
    --agree-tos --non-interactive 2>&1 | tail -3 || log_warn "SSL: проверьте DNS запись домена"

  log_ok "Nginx + SSL настроен"
fi

# ── Check PM2 status ─────────────────────────────────────────
sleep 1
if pm2 describe "$SERVICE_NAME" 2>/dev/null | grep -q "online"; then
  log_ok "Панель успешно запущена!"
else
  log_warn "Проверьте статус: pm2 status | pm2 logs $SERVICE_NAME"
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Panel NaiveProxy by RIXXX установлена!             ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"

if [[ "$ACCESS_MODE" == "1" ]]; then
  echo -e "${PURPLE}${BOLD}║   🌐  Панель доступна по адресу:                         ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   ➜  http://${SERVER_IP}:8080${RESET}"
  echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"
  echo -e "${PURPLE}${BOLD}║   🔒  Порт 3000 закрыт снаружи (через Nginx)            ║${RESET}"
elif [[ "$ACCESS_MODE" == "3" && -n "$PANEL_DOMAIN" ]]; then
  echo -e "${PURPLE}${BOLD}║   🌐  Панель: https://${PANEL_DOMAIN}${RESET}"
  echo -e "${PURPLE}${BOLD}║   🔒  Защищено SSL сертификатом                         ║${RESET}"
else
  echo -e "${PURPLE}${BOLD}║   🌐  Панель: http://${SERVER_IP}:${INTERNAL_PORT}${RESET}"
fi

echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   👤  Логин по умолчанию:  admin                         ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🔑  Пароль по умолчанию: admin                         ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ⚠️   Сразу смените пароль в разделе Настройки!          ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Управление:                                            ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 status                    — статус панели          ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 logs ${SERVICE_NAME}   — логи              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 restart ${SERVICE_NAME} — перезапуск       ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
