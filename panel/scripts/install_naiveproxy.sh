#!/bin/bash
# ═══════════════════════════════════════════════════════
#  NaiveProxy Auto-Installer — by RIXXX
#  Используется панелью управления Panel NaiveProxy by RIXXX
#  Переменные окружения: NAIVE_DOMAIN, NAIVE_EMAIL,
#                        NAIVE_LOGIN, NAIVE_PASSWORD
# ═══════════════════════════════════════════════════════

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Параметры ──────────────────────────────────────────
DOMAIN="${NAIVE_DOMAIN:-}"
EMAIL="${NAIVE_EMAIL:-}"
LOGIN="${NAIVE_LOGIN:-}"
PASSWORD="${NAIVE_PASSWORD:-}"

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$LOGIN" || -z "$PASSWORD" ]]; then
  echo "ОШИБКА: Не заданы переменные NAIVE_DOMAIN, NAIVE_EMAIL, NAIVE_LOGIN, NAIVE_PASSWORD"
  exit 1
fi

log() { echo "$1"; }
step() { echo "STEP:$1"; }

# ══════════════════════════════════════════════════════
step 1
log "▶ Обновление системы и установка зависимостей..."
# ══════════════════════════════════════════════════════
apt-get update -y -q 2>&1 | tail -1
apt-get upgrade -y -q 2>&1 | tail -1
apt-get install -y -q curl wget git openssl ufw 2>&1 | tail -1
log "✅ Система обновлена"

# ══════════════════════════════════════════════════════
step 2
log "▶ Включение BBR..."
# ══════════════════════════════════════════════════════
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true
log "✅ BBR включён"

# ══════════════════════════════════════════════════════
step 3
log "▶ Настройка файрволла UFW..."
# ══════════════════════════════════════════════════════
ufw --force reset >/dev/null 2>&1 || true
ufw allow 22/tcp  >/dev/null 2>&1
ufw allow 80/tcp  >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1 || true
log "✅ Файрволл настроен (порты 22, 80, 443)"

# ══════════════════════════════════════════════════════
step 4
log "▶ Установка Go (может занять 1-2 минуты)..."
# ══════════════════════════════════════════════════════

# Remove old Go if present
rm -rf /usr/local/go

# Get latest Go version
GO_VERSION=$(curl -fsSL 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1)
if [[ -z "$GO_VERSION" ]]; then
  GO_VERSION="go1.22.3"
  log "⚠ Не удалось получить версию Go, используем $GO_VERSION"
fi

log "  Загружаем $GO_VERSION..."
wget -q "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

# Update PATH
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:/root/go/bin

# Persist PATH
if ! grep -q "/usr/local/go/bin" /root/.profile; then
  echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.profile
  echo 'export PATH=$PATH:/root/go/bin' >> /root/.profile
fi

GO_VER_OUT=$(/usr/local/go/bin/go version 2>/dev/null || echo "unknown")
log "✅ Go установлен: $GO_VER_OUT"

# ══════════════════════════════════════════════════════
step 5
log "▶ Сборка Caddy с naive-плагином (это займёт 3-7 минут)..."
# ══════════════════════════════════════════════════════

# Set Go environment
export GOPATH=/root/go
export GOROOT=/usr/local/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
export TMPDIR=/root/tmp
mkdir -p /root/tmp /root/go

# Install xcaddy
log "  Установка xcaddy..."
/usr/local/go/bin/go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>&1 | tail -3

# Build Caddy with naiveproxy plugin
log "  Сборка Caddy с forwardproxy naive (ждите...)..."
cd /root
/root/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
  2>&1 | while read line; do echo "  $line"; done

if [[ ! -f /root/caddy ]]; then
  log "ОШИБКА: Caddy не был собран!"
  exit 1
fi

mv /root/caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

CADDY_VER=$(/usr/bin/caddy version 2>/dev/null || echo "unknown")
log "✅ Caddy собран: $CADDY_VER"

# ══════════════════════════════════════════════════════
step 6
log "▶ Создание конфигурационных файлов..."
# ══════════════════════════════════════════════════════

# Create directories
mkdir -p /var/www/html /etc/caddy

# Create camouflage page
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Loading</title>
  <style>
    body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}
    .bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}
    .fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}
    @keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}
    .t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}
  </style>
</head>
<body>
  <div class="bar"><div class="fill"></div></div>
  <div class="t">LOADING CONTENT</div>
</body>
</html>
HTMLEOF

# Create Caddyfile with user credentials
cat > /etc/caddy/Caddyfile << CADDYEOF
{
  order forward_proxy before file_server
}

:443, ${DOMAIN} {
  tls ${EMAIL}

  forward_proxy {
    basic_auth ${LOGIN} ${PASSWORD}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
CADDYEOF

log "✅ Caddyfile создан для домена ${DOMAIN}"

# Validate config
/usr/bin/caddy validate --config /etc/caddy/Caddyfile 2>&1 || {
  log "⚠ Предупреждение при валидации конфига (не критично)"
}

# ══════════════════════════════════════════════════════
step 7
log "▶ Настройка systemd сервиса..."
# ══════════════════════════════════════════════════════

cat > /etc/systemd/system/caddy.service << 'SERVICEEOF'
[Unit]
Description=Caddy with NaiveProxy (by RIXXX)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
log "✅ Systemd сервис создан"

# ══════════════════════════════════════════════════════
step 8
log "▶ Включение и запуск Caddy..."
# ══════════════════════════════════════════════════════

systemctl enable caddy 2>&1 || true
systemctl restart caddy 2>&1 || {
  log "⚠ Не удалось запустить через systemctl, пробуем напрямую..."
  pkill -f "caddy run" 2>/dev/null || true
  nohup /usr/bin/caddy run --config /etc/caddy/Caddyfile > /var/log/caddy.log 2>&1 &
  sleep 3
}

# Wait a bit for service to start
sleep 5

# Check status
if systemctl is-active --quiet caddy; then
  log "✅ Caddy запущен и работает"
elif pgrep -x caddy > /dev/null; then
  log "✅ Caddy запущен (процесс обнаружен)"
else
  log "⚠ Caddy может ещё запускаться, проверьте: systemctl status caddy"
fi

# ══════════════════════════════════════════════════════
step DONE
# ══════════════════════════════════════════════════════

log ""
log "╔════════════════════════════════════════════════╗"
log "║   ✅ NaiveProxy успешно установлен!            ║"
log "║                                                ║"
log "║   Ссылка для подключения:                      ║"
log "║   naive+https://${LOGIN}:****@${DOMAIN}:443    ║"
log "╚════════════════════════════════════════════════╝"
log ""

exit 0
