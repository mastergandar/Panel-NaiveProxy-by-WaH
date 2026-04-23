#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Hysteria2 installer
#  ENV: NAIVE_DOMAIN, HY2_PASSWORD
# ═══════════════════════════════════════════════════════
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

DOMAIN="${NAIVE_DOMAIN:-}"
HY2_PASS="${HY2_PASSWORD:-}"
CERT_DIR="/etc/ssl/traefik-certs/${DOMAIN}"

if [[ -z "$DOMAIN" || -z "$HY2_PASS" ]]; then
  echo "ОШИБКА: Не заданы NAIVE_DOMAIN, HY2_PASSWORD"
  exit 1
fi

log()  { echo "$1"; }
step() { echo "STEP:$1"; }

step hysteria
log "▶ Установка Hysteria2..."

# ── Binary ──────────────────────────────────────────────
HY2_TAG=$(curl -fsSL --connect-timeout 10 \
  'https://api.github.com/repos/apernet/hysteria/releases/latest' 2>/dev/null \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4 || echo "app/v2.5.1")
# URL-encode the slash in tag (app/v2.x.x → app%2Fv2.x.x)
HY2_TAG_URL=$(echo "$HY2_TAG" | sed 's|/|%2F|g')

log "  Загружаем Hysteria2 ${HY2_TAG}..."
wget -q --timeout=120 \
  "https://github.com/apernet/hysteria/releases/download/${HY2_TAG_URL}/hysteria-linux-amd64" \
  -O /usr/local/bin/hysteria 2>&1 || {
  log "ОШИБКА: Не удалось загрузить Hysteria2"
  exit 1
}
chmod +x /usr/local/bin/hysteria
log "✅ Hysteria2 установлен: $(/usr/local/bin/hysteria version 2>/dev/null | head -1 || echo 'ok')"

# ── Config ──────────────────────────────────────────────
step hysteriaconfig
log "▶ Создание конфигурации Hysteria2..."

mkdir -p /etc/hysteria

# Wait for cert files to exist (traefik-certs-dumper should have run already)
if [[ ! -f "${CERT_DIR}/certificate.crt" ]]; then
  log "  Ждём сертификата ${DOMAIN}..."
  for i in $(seq 1 30); do
    [[ -f "${CERT_DIR}/certificate.crt" ]] && break
    sleep 3
  done
fi

if [[ ! -f "${CERT_DIR}/certificate.crt" ]]; then
  log "⚠ Сертификат не найден в ${CERT_DIR} — Hysteria2 запустится без TLS (исправьте вручную)"
  CERT_PATH="/etc/ssl/traefik-certs/${DOMAIN}/certificate.crt"
  KEY_PATH="/etc/ssl/traefik-certs/${DOMAIN}/privatekey.key"
else
  CERT_PATH="${CERT_DIR}/certificate.crt"
  KEY_PATH="${CERT_DIR}/privatekey.key"
fi

cat > /etc/hysteria/config.yaml << CFGEOF
listen: :443

tls:
  cert: ${CERT_PATH}
  key:  ${KEY_PATH}

auth:
  type: password
  password: "${HY2_PASS}"

masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
CFGEOF

log "✅ Конфигурация Hysteria2 создана"

# ── Systemd service ─────────────────────────────────────
step hysteriaservice
log "▶ Создание systemd сервиса Hysteria2..."

systemctl stop hysteria-server 2>/dev/null || true

cat > /etc/systemd/system/hysteria-server.service << 'SVCEOF'
[Unit]
Description=Hysteria2 Proxy Server
Documentation=https://hysteria.network/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1 || true

# ── Start Hysteria2 ─────────────────────────────────────
step hysteriastart
log "▶ Запуск Hysteria2..."

systemctl start hysteria-server 2>&1 || {
  log "⚠ Ошибка запуска Hysteria2, проверьте: systemctl status hysteria-server"
  # Don't exit — cert might not be ready yet, service will retry
}

for i in $(seq 1 10); do
  if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    log "✅ Hysteria2 запущен (${i}с)"
    break
  fi
  sleep 1
  if [[ $i -eq 10 ]]; then
    log "⚠ Hysteria2 запускается медленно (ждёт сертификат?)"
    log "⚠ Проверьте: systemctl status hysteria-server"
  fi
done

step DONE
log ""
log "╔════════════════════════════════════════════════════════╗"
log "║   ✅ Hysteria2 установлен!                              ║"
log "║   Ссылка: hysteria2://${HY2_PASS}@${DOMAIN}:443        ║"
log "╚════════════════════════════════════════════════════════╝"
log ""
exit 0
