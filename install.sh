#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Panel NaiveProxy by RIXXX — Установщик панели управления
#  Запуск: bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

REPO_URL="https://github.com/cwash797-cmd/NaiveProxy-Panel-RIXXX"
PANEL_DIR="/opt/naiveproxy-panel"
SERVICE_NAME="naiveproxy-panel"
PORT=3000

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║    Panel NaiveProxy by RIXXX — Установщик       ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

header

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_err "Запускайте скрипт от root: sudo bash install.sh"
  exit 1
fi

# ── OS check ─────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  log_err "Поддерживается только Ubuntu/Debian"
  exit 1
fi

SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
log_info "Обнаружен IP сервера: ${BOLD}${SERVER_IP}${RESET}"

# ── Step 1: System update ────────────────────────────────────
log_step "Обновление системы..."
apt-get update -y -q 2>&1 | tail -1
apt-get install -y -q curl wget git openssl ufw 2>&1 | tail -1
log_ok "Система обновлена"

# ── Step 2: Install Node.js ──────────────────────────────────
log_step "Установка Node.js 20..."
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d 'v') -lt 18 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -3
  apt-get install -y -q nodejs 2>&1 | tail -1
fi
log_ok "Node.js установлен: $(node -v)"

# ── Step 3: Install PM2 ──────────────────────────────────────
log_step "Установка PM2..."
npm install -g pm2 --silent 2>&1 | tail -1
log_ok "PM2 установлен"

# ── Step 4: Clone / Update panel ────────────────────────────
log_step "Загрузка панели управления..."
if [[ -d "$PANEL_DIR" ]]; then
  log_warn "Панель уже установлена. Обновляем..."
  cd "$PANEL_DIR"
  git pull 2>&1 | tail -3
else
  git clone "$REPO_URL" "$PANEL_DIR" 2>&1
fi
log_ok "Код панели загружен в $PANEL_DIR"

# ── Step 5: Install dependencies ────────────────────────────
log_step "Установка зависимостей..."
cd "$PANEL_DIR/panel"
npm install --silent 2>&1 | tail -3
log_ok "Зависимости установлены"

# ── Step 6: Create data dir & set permissions ────────────────
log_step "Настройка директорий..."
mkdir -p "$PANEL_DIR/panel/data"
chmod +x "$PANEL_DIR/panel/scripts/install_naiveproxy.sh" 2>/dev/null || true
log_ok "Директории настроены"

# ── Step 7: Configure UFW for panel ─────────────────────────
log_step "Настройка файрволла для панели..."
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
echo "y" | ufw enable >/dev/null 2>&1 || true
log_ok "Порт ${PORT} открыт"

# ── Step 8: Start with PM2 ──────────────────────────────────
log_step "Запуск панели через PM2..."
cd "$PANEL_DIR/panel"

# Stop existing if running
pm2 delete $SERVICE_NAME 2>/dev/null || true

pm2 start server/index.js \
  --name "$SERVICE_NAME" \
  --time \
  --restart-delay=3000 \
  -- --port $PORT

# Save PM2 config and enable autostart
pm2 save
pm2 startup 2>/dev/null | tail -1 | bash 2>/dev/null || true

sleep 2

# ── Check status ─────────────────────────────────────────────
if pm2 describe $SERVICE_NAME 2>/dev/null | grep -q "online"; then
  log_ok "Панель запущена!"
else
  log_warn "Проверьте статус: pm2 status"
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║                                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Panel NaiveProxy by RIXXX установлена!         ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  Панель доступна по адресу:                     ║${RESET}"
echo -e "${PURPLE}${BOLD}║   http://${SERVER_IP}:${PORT}${RESET}"
echo -e "${PURPLE}${BOLD}║                                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   👤  Логин:  admin                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}║   🔑  Пароль: admin                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   ⚠️  Сразу смените пароль в разделе Настройки!      ║${RESET}"
echo -e "${PURPLE}${BOLD}║                                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Полезные команды:                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 status               — статус панели           ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 logs naiveproxy-panel — логи панели            ║${RESET}"
echo -e "${PURPLE}${BOLD}║   pm2 restart naiveproxy-panel — перезапуск          ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
