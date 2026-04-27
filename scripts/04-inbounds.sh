#!/usr/bin/env bash
# Phase 4 — Generate configs for the 3 inbounds and start services.
#
# Inbound 1: VLESS + XTLS-Vision + REALITY            Xray on 0.0.0.0:443/tcp
# Inbound 2: Hysteria2 + Salamander obfuscation       hysteria on 0.0.0.0:443/udp + hopping 20000-29999
# Inbound 3: VLESS + WebSocket + TLS via Cloudflare   Caddy on 0.0.0.0:2087/tcp -> Xray localhost:9100
#
# Cert strategy:
#  - REALITY: no cert needed (mimics www.tesla.com TLS handshake)
#  - Hysteria2: ACME DNS-01 via Cloudflare for hy2.charlespolart.com (CLOUDFLARE_API_TOKEN)
#  - CDN: self-signed cert for cdn.charlespolart.com; CF zone must be in "Full"
#         (NOT strict) SSL mode. CF terminates TLS, Caddy presents self-signed
#         on the origin connection. To upgrade to a real cert later, install
#         xcaddy with caddy-dns/cloudflare and switch to acme_dns directive.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${DOMAIN:?}" "${PANEL_SUBDOMAIN:?}" "${SUB_SUBDOMAIN:?}" "${HY2_SUBDOMAIN:?}" "${CDN_SUBDOMAIN:?}"
: "${VPS_IPV4:?}" "${REALITY_SNI:?}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN required for Hy2 ACME DNS-01}"

# Reasonable defaults if missing
HYSTERIA_UP_MBPS="${HYSTERIA_UP_MBPS:-200}"
HYSTERIA_DOWN_MBPS="${HYSTERIA_DOWN_MBPS:-500}"

PANEL_FQDN="${PANEL_SUBDOMAIN}.${DOMAIN}"
HY2_FQDN="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN_FQDN="${CDN_SUBDOMAIN}.${DOMAIN}"

SECRETS_DIR=/etc/bye-bye-gfw
INBOUNDS_ENV="${SECRETS_DIR}/inbounds.env"

log "Phase 4 — generate inbound configs (REALITY + Hy2 + CDN VLESS+WS)"

# --- 4.1 Read REALITY keypair from phase 3 ---------------------------------
[[ -f "$SECRETS_DIR/reality_keys.env" ]] || die "missing $SECRETS_DIR/reality_keys.env (run phase 3 first)"
# shellcheck disable=SC1090
source "$SECRETS_DIR/reality_keys.env"
[[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] || die "REALITY keys malformed"

# --- 4.2 Generate / load inbound secrets (idempotent) ----------------------
log "[4.2] inbound secrets"
if [[ ! -f "$INBOUNDS_ENV" ]]; then
  USER_UUID=$(/usr/local/bin/xray uuid)
  CDN_WS_PATH="/$(openssl rand -hex 8)"
  REALITY_SHORT_IDS="$(openssl rand -hex 4),$(openssl rand -hex 4),$(openssl rand -hex 4),$(openssl rand -hex 4)"
  HYSTERIA_AUTH_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)
  HYSTERIA_OBFS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | head -c 32)
  SUB_TOKEN=$(openssl rand -hex 16)
  cat > "$INBOUNDS_ENV" <<EOF
USER_UUID=${USER_UUID}
CDN_WS_PATH=${CDN_WS_PATH}
REALITY_SHORT_IDS=${REALITY_SHORT_IDS}
HYSTERIA_AUTH_PASSWORD=${HYSTERIA_AUTH_PASSWORD}
HYSTERIA_OBFS_PASSWORD=${HYSTERIA_OBFS_PASSWORD}
SUB_TOKEN=${SUB_TOKEN}
EOF
  chmod 600 "$INBOUNDS_ENV"
  log "  [generated] $INBOUNDS_ENV"
else
  log "  reusing existing secrets"
fi
# shellcheck disable=SC1090
source "$INBOUNDS_ENV"

# Convert REALITY_SHORT_IDS comma-list to JSON array
SHORT_IDS_JSON=$(echo "$REALITY_SHORT_IDS" | awk -F',' '{
  printf "[";
  for (i=1;i<=NF;i++) printf (i>1?",":"") "\"" $i "\"";
  printf "]"
}')

# --- 4.3 iptables NAT for Hy2 port hopping ---------------------------------
log "[4.3] iptables NAT (UDP 20000-29999 → 443)"
ensure_pkg iptables-persistent netfilter-persistent
# Idempotent rule add: check, then add
add_nat_rule() {
  local cmd="$1"
  $cmd -t nat -C PREROUTING -p udp --dport 20000:29999 -j REDIRECT --to-ports 443 2>/dev/null \
    || $cmd -t nat -A PREROUTING -p udp --dport 20000:29999 -j REDIRECT --to-ports 443
}
add_nat_rule iptables
add_nat_rule ip6tables
netfilter-persistent save >/dev/null

# --- 4.4 Xray base config (logs off, dns) ----------------------------------
log "[4.4] Xray base config (logs off, dns)"
write_file /etc/xray/configs.d/00-base.json 644 root:root <<'EOF'
{
  "log": { "loglevel": "warning", "access": "none", "error": "/var/log/xray/error.log" },
  "dns": {
    "servers": [ "1.1.1.1", "8.8.8.8", "https://1.1.1.1/dns-query" ],
    "queryStrategy": "UseIP"
  }
}
EOF

# --- 4.5 Xray REALITY inbound (443/tcp) ------------------------------------
log "[4.5] Xray VLESS+REALITY inbound (port 443/tcp, SNI ${REALITY_SNI})"
write_file /etc/xray/configs.d/10-reality.json 644 root:root <<EOF
{
  "inbounds": [{
    "tag": "in-reality",
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [
        { "id": "${USER_UUID}", "flow": "xtls-rprx-vision", "email": "user@${DOMAIN}" }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${REALITY_SNI}:443",
        "xver": 0,
        "serverNames": [ "${REALITY_SNI}" ],
        "privateKey": "${REALITY_PRIVATE_KEY}",
        "shortIds": ${SHORT_IDS_JSON}
      }
    },
    "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
  }]
}
EOF

# --- 4.6 Xray VLESS+WS inbound (loopback only — Caddy proxies) ------------
log "[4.6] Xray VLESS+WS inbound (loopback 127.0.0.1:9100)"
write_file /etc/xray/configs.d/11-vless-ws.json 644 root:root <<EOF
{
  "inbounds": [{
    "tag": "in-vless-ws",
    "listen": "127.0.0.1",
    "port": 9100,
    "protocol": "vless",
    "settings": {
      "clients": [ { "id": "${USER_UUID}", "email": "user-ws@${DOMAIN}" } ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "${CDN_WS_PATH}" }
    },
    "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] }
  }]
}
EOF

# --- 4.7 Xray outbounds (placeholder; phase 5/6 expand WARP + routing) ----
log "[4.7] Xray base outbounds (direct + block)"
write_file /etc/xray/configs.d/90-outbounds.json 644 root:root <<'EOF'
{
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block", "domain": [ "geosite:category-ads-all" ] },
      { "type": "field", "outboundTag": "direct", "ip": [ "geoip:cn" ] },
      { "type": "field", "outboundTag": "direct", "domain": [ "geosite:cn" ] }
    ]
  }
}
EOF

# Validate Xray config (loads all configs.d)
log "[4.7b] xray test"
/usr/local/bin/xray run -confdir /etc/xray/configs.d -test 2>&1 | tail -5

# --- 4.8 Hysteria2 config with Cloudflare DNS-01 ACME ----------------------
log "[4.8] Hysteria2 config (ACME DNS-01 for ${HY2_FQDN})"
install -d -m 755 /etc/hysteria
write_file /etc/hysteria/config.yaml 600 hysteria:hysteria <<EOF
listen: :443

acme:
  domains:
    - ${HY2_FQDN}
  email: admin@${DOMAIN}
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${CLOUDFLARE_API_TOKEN}

obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA_OBFS_PASSWORD}

auth:
  type: password
  password: ${HYSTERIA_AUTH_PASSWORD}

bandwidth:
  up: ${HYSTERIA_UP_MBPS} mbps
  down: ${HYSTERIA_DOWN_MBPS} mbps

ignoreClientBandwidth: false

masquerade:
  type: proxy
  proxy:
    url: https://${REALITY_SNI}/
    rewriteHost: true
EOF

# --- 4.9 Caddy: CDN VLESS+WS+TLS (self-signed for "Full" CF SSL mode) -----
log "[4.9] Caddy CDN (self-signed cert + VLESS+WS reverse proxy)"
install -d -m 755 /etc/caddy/origin
if [[ ! -f /etc/caddy/origin/cdn.crt ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/caddy/origin/cdn.key \
    -out    /etc/caddy/origin/cdn.crt \
    -days 3650 \
    -subj "/CN=${CDN_FQDN}" 2>/dev/null
  chmod 600 /etc/caddy/origin/cdn.key
  chmod 644 /etc/caddy/origin/cdn.crt
  log "  [generated] /etc/caddy/origin/cdn.{crt,key} (self-signed, valid 10 years)"
fi
chown -R caddy:caddy /etc/caddy/origin

write_file /etc/caddy/Caddyfile 644 root:root <<EOF
{
  # No automatic HTTPS — we manage TLS manually for cdn (CF Full mode),
  # and Caddy doesn't need ACME for any other vhost yet.
  auto_https off
  admin off
}

# CDN reverse proxy for VLESS+WS+TLS via Cloudflare orange-cloud.
# Listens on 2087/tcp (in CF allowed origin port list).
# CF SSL mode must be "Full" or higher (not Flexible).
${CDN_FQDN}:2087 {
  tls /etc/caddy/origin/cdn.crt /etc/caddy/origin/cdn.key

  @vlessws {
    path ${CDN_WS_PATH}
    header Connection *Upgrade*
    header Upgrade websocket
  }
  reverse_proxy @vlessws 127.0.0.1:9100

  # decoy: anything else returns a small HTML
  handle {
    respond "<!doctype html><html><body><h1>Hello.</h1></body></html>" 200
  }
}
EOF

# Test Caddy config
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -3 || die "Caddyfile invalid"

# --- 4.10 Enable + start services ------------------------------------------
log "[4.10] enable + start services"
systemctl enable --now xray
sleep 1
systemctl is-active xray >/dev/null || die "xray failed to start: $(journalctl -u xray -n 20 --no-pager)"

systemctl enable --now hysteria-server
sleep 2
systemctl is-active hysteria-server >/dev/null || die "hysteria failed to start: $(journalctl -u hysteria-server -n 20 --no-pager)"

systemctl enable --now caddy
sleep 1
systemctl is-active caddy >/dev/null || die "caddy failed to start: $(journalctl -u caddy -n 20 --no-pager)"

state_mark phase4
log "Phase 4 done."
log ""
log "  REALITY        : ${VPS_IPV4}:443/tcp  SNI=${REALITY_SNI}"
log "  Hysteria2      : ${HY2_FQDN}:443/udp + hopping 20000-29999"
log "  CDN VLESS+WS   : ${CDN_FQDN}:443 (via Cloudflare proxy) -> origin :2087"
log ""
log "  All secrets in: ${INBOUNDS_ENV}"
log ""
log "Next: phase 5 (WARP outbound for streaming) or generate sub URL with phase 7"
