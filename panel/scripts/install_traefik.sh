#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Traefik + traefik-certs-dumper installer
#  ENV: NAIVE_DOMAIN, PANEL_DOMAIN, ADMIN_DOMAIN,
#       NAIVE_EMAIL, TRAEFIK_USER, TRAEFIK_PASS_YAML
# ═══════════════════════════════════════════════════════
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

DOMAIN="${NAIVE_DOMAIN:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-}"
EMAIL="${NAIVE_EMAIL:-}"
TR_USER="${TRAEFIK_USER:-admin}"
TR_PASS_YAML="${TRAEFIK_PASS_YAML:-}"

log()  { echo "$1"; }
step() { echo "STEP:$1"; }

# ── Traefik binary ──────────────────────────────────────
step traefik
log "▶ Установка Traefik..."

mkdir -p /etc/traefik /etc/ssl/traefik-certs
chmod 700 /etc/traefik

TRAEFIK_VERSION=$(curl -fsSL --connect-timeout 10 \
  'https://api.github.com/repos/traefik/traefik/releases/latest' 2>/dev/null \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4 || echo "v3.1.4")
TRAEFIK_VER_NUM="${TRAEFIK_VERSION#v}"

log "  Загружаем Traefik ${TRAEFIK_VERSION}..."
wget -q --timeout=120 \
  "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VER_NUM}_linux_amd64.tar.gz" \
  -O /tmp/traefik.tar.gz 2>&1 || {
  log "ОШИБКА: Не удалось загрузить Traefik"
  exit 1
}
tar -xzf /tmp/traefik.tar.gz -C /tmp traefik 2>/dev/null || \
  tar -xzf /tmp/traefik.tar.gz -C /tmp
mv /tmp/traefik /usr/local/bin/traefik
chmod +x /usr/local/bin/traefik
rm -f /tmp/traefik.tar.gz
log "✅ Traefik установлен: $(/usr/local/bin/traefik version 2>/dev/null | head -1 || echo 'ok')"

# ── traefik-certs-dumper binary ─────────────────────────
log "  Загружаем traefik-certs-dumper..."
DUMPER_VERSION=$(curl -fsSL --connect-timeout 10 \
  'https://api.github.com/repos/ldez/traefik-certs-dumper/releases/latest' 2>/dev/null \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4 || echo "v2.8.3")
DUMPER_VER_NUM="${DUMPER_VERSION#v}"

wget -q --timeout=60 \
  "https://github.com/ldez/traefik-certs-dumper/releases/download/${DUMPER_VERSION}/traefik-certs-dumper_v${DUMPER_VER_NUM}_linux_amd64.tar.gz" \
  -O /tmp/dumper.tar.gz 2>&1 || {
  log "ОШИБКА: Не удалось загрузить traefik-certs-dumper"
  exit 1
}
tar -xzf /tmp/dumper.tar.gz -C /tmp traefik-certs-dumper 2>/dev/null || \
  tar -xzf /tmp/dumper.tar.gz -C /tmp
mv /tmp/traefik-certs-dumper /usr/local/bin/traefik-certs-dumper
chmod +x /usr/local/bin/traefik-certs-dumper
rm -f /tmp/dumper.tar.gz
log "✅ traefik-certs-dumper установлен"

# ── Traefik static config ───────────────────────────────
step traefikconfig
log "▶ Создание конфигурации Traefik..."

touch /etc/traefik/acme.json
chmod 600 /etc/traefik/acme.json

cat > /etc/traefik/traefik.yaml << TEOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${EMAIL}
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web

providers:
  file:
    filename: /etc/traefik/dynamic.yaml
    watch: true

api:
  dashboard: true
  insecure: false

log:
  level: ERROR
TEOF

# ── Traefik dynamic config ──────────────────────────────
# TR_PASS_YAML has $ already doubled for YAML format
cat > /etc/traefik/dynamic.yaml << DEOF
http:
  middlewares:
    admin-auth:
      basicAuth:
        users:
          - "${TR_USER}:${TR_PASS_YAML}"

  routers:
    panel:
      rule: "Host(\`${PANEL_DOMAIN}\`)"
      entryPoints:
        - websecure
      middlewares:
        - admin-auth
      service: panel-svc
      tls:
        certResolver: letsencrypt

    traefik-dash:
      rule: "Host(\`${ADMIN_DOMAIN}\`)"
      entryPoints:
        - websecure
      middlewares:
        - admin-auth
      service: api@internal
      tls:
        certResolver: letsencrypt

    # Dummy router: triggers ACME HTTP-01 cert issuance for proxy domain.
    # TCP passthrough router (below) handles actual HTTPS traffic.
    # ACME challenge happens via port 80 (web entrypoint) — no conflict.
    naive-cert:
      rule: "Host(\`${DOMAIN}\`)"
      entryPoints:
        - websecure
      service: panel-svc
      tls:
        certResolver: letsencrypt

  services:
    panel-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:3000"

tcp:
  routers:
    naiveproxy:
      rule: "HostSNI(\`${DOMAIN}\`)"
      entryPoints:
        - websecure
      service: caddy-svc
      tls:
        passthrough: true

  services:
    caddy-svc:
      loadBalancer:
        servers:
          - address: "127.0.0.1:10443"
DEOF

log "✅ Конфигурация Traefik создана"

# ── Traefik systemd service ─────────────────────────────
step traefikservice
log "▶ Создание systemd сервиса Traefik..."

systemctl stop traefik 2>/dev/null || true

cat > /etc/systemd/system/traefik.service << 'SVCEOF'
[Unit]
Description=Traefik Reverse Proxy
Documentation=https://doc.traefik.io/traefik/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yaml
Restart=always
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

# ── traefik-certs-dumper systemd service ────────────────
cat > /etc/systemd/system/traefik-certs-dumper.service << 'SVCEOF'
[Unit]
Description=Traefik Certs Dumper
After=traefik.service
Requires=traefik.service

[Service]
Type=simple
ExecStart=/usr/local/bin/traefik-certs-dumper file \
  --source /etc/traefik/acme.json \
  --dest /etc/ssl/traefik-certs \
  --watch \
  --post-hook "systemctl reload caddy 2>/dev/null; systemctl reload hysteria-server 2>/dev/null; true"
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable traefik >/dev/null 2>&1 || true
systemctl enable traefik-certs-dumper >/dev/null 2>&1 || true
log "✅ Systemd сервисы созданы"

# ── Start Traefik ────────────────────────────────────────
step traefikstart
log "▶ Запуск Traefik..."

systemctl start traefik 2>&1 || {
  log "⚠ Ошибка запуска Traefik, проверьте: systemctl status traefik"
  exit 1
}

for i in $(seq 1 15); do
  if systemctl is-active --quiet traefik 2>/dev/null; then
    log "✅ Traefik запущен (${i}с)"
    break
  fi
  sleep 1
  if [[ $i -eq 15 ]]; then
    log "⚠ Traefik медленно запускается, проверьте: systemctl status traefik"
  fi
done

step DONE
log ""
log "╔════════════════════════════════════════════╗"
log "║   ✅ Traefik установлен и запущен!          ║"
log "║   Ждём выдачи сертификатов (~30-90с)...     ║"
log "╚════════════════════════════════════════════╝"
log ""
exit 0
