#!/usr/bin/env bash
# Phase 7 — Subscription URL endpoint with User-Agent based format selection.
#
# Generates 2 static config files from the 3 inbounds:
#   - clash.yaml         (Clash Verge Rev, Mihomo, Stash)
#   - v2ray.b64          (Shadowrocket, Hiddify Next, sing-box, others)
#
# Serves via Caddy at https://sub.charlespolart.com/<SUB_TOKEN>/
# Caddy auto-issues a Let's Encrypt cert via HTTP-01 (sub.charlespolart.com
# is DNS-only, port 80 free). Token-protected; UA picks the format.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${DOMAIN:?}" "${SUB_SUBDOMAIN:?}" "${CDN_SUBDOMAIN:?}" "${VPS_IPV4:?}" "${REALITY_SNI:?}" "${HY2_SUBDOMAIN:?}"
SECRETS_DIR=/etc/bye-bye-gfw
[[ -f "$SECRETS_DIR/inbounds.env"     ]] || die "missing inbounds.env (run phase 4 first)"
[[ -f "$SECRETS_DIR/reality_keys.env" ]] || die "missing reality_keys.env (run phase 3 first)"
# shellcheck disable=SC1090
source "$SECRETS_DIR/inbounds.env"
# shellcheck disable=SC1090
source "$SECRETS_DIR/reality_keys.env"

SUB_FQDN="${SUB_SUBDOMAIN}.${DOMAIN}"
HY2_FQDN="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN_FQDN="${CDN_SUBDOMAIN}.${DOMAIN}"
SUB_DIR="/var/www/sub/${SUB_TOKEN}"
SUB_PORT=8443  # Caddy can't take 443 (Xray REALITY); 8443 is CF-supported HTTPS port

log "Phase 7 — subscription endpoint at https://${SUB_FQDN}:${SUB_PORT}/${SUB_TOKEN}/"

# Open port 8443/tcp in UFW (idempotent)
ufw allow ${SUB_PORT}/tcp comment "sub URL HTTPS (Caddy)" >/dev/null 2>&1 || true

# --- 7.1 generate config files ---------------------------------------------
log "[7.1] generate config files"
install -d -m 755 "$SUB_DIR"

SID0="${REALITY_SHORT_IDS%%,*}"
PATH_ENC="${CDN_WS_PATH//\//%2F}"

# v2ray plain (newline-separated VLESS/HY2 URLs)
V2RAY_PLAIN=$(cat <<EOF
vless://${USER_UUID}@${VPS_IPV4}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SID0}&type=tcp#REALITY-LAX
hysteria2://${HYSTERIA_AUTH_PASSWORD}@${HY2_FQDN}:443?mport=20000-29999&obfs=salamander&obfs-password=${HYSTERIA_OBFS_PASSWORD}#Hy2-LAX
vless://${USER_UUID}@${CDN_FQDN}:2087?encryption=none&security=tls&sni=${CDN_FQDN}&type=ws&host=${CDN_FQDN}&path=${PATH_ENC}&fp=chrome#CDN-LAX
EOF
)
# v2ray base64 (no wrap)
echo -n "$V2RAY_PLAIN" | base64 -w0 > "$SUB_DIR/v2ray.b64"

# Clash YAML (Mihomo / Verge Rev compatible)
cat > "$SUB_DIR/clash.yaml" <<EOF
# bye-bye-gfw subscription — generated $(date -Iseconds)
mixed-port: 7890
mode: rule
log-level: info
allow-lan: true

dns:
  enable: true
  ipv6: false
  default-nameserver: [1.1.1.1, 8.8.8.8]
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: [https://1.1.1.1/dns-query, https://8.8.8.8/dns-query]
  fallback: [tls://1.1.1.1:853, tls://8.8.8.8:853]
  fake-ip-filter:
    - "*.lan"
    - "+.local"
    - "+.cn"

proxies:
  - name: REALITY-LAX
    type: vless
    server: ${VPS_IPV4}
    port: 443
    uuid: ${USER_UUID}
    network: tcp
    flow: xtls-rprx-vision
    tls: true
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SID0}

  - name: Hy2-LAX
    type: hysteria2
    server: ${HY2_FQDN}
    port: 443
    ports: 20000-29999
    password: ${HYSTERIA_AUTH_PASSWORD}
    obfs: salamander
    obfs-password: ${HYSTERIA_OBFS_PASSWORD}
    sni: ${HY2_FQDN}

  - name: CDN-LAX
    type: vless
    server: ${CDN_FQDN}
    port: 2087
    uuid: ${USER_UUID}
    network: ws
    tls: true
    servername: ${CDN_FQDN}
    client-fingerprint: chrome
    ws-opts:
      path: ${CDN_WS_PATH}
      headers:
        Host: ${CDN_FQDN}

proxy-groups:
  - name: PROXY
    type: select
    proxies: [AUTO, REALITY-LAX, Hy2-LAX, CDN-LAX, DIRECT]
  - name: AUTO
    type: url-test
    proxies: [REALITY-LAX, Hy2-LAX, CDN-LAX]
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50

rule-providers:
  reject:
    type: http
    behavior: domain
    url: https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt
    path: ./ruleset/reject.yaml
    interval: 86400
  cn-domain:
    type: http
    behavior: domain
    url: https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt
    path: ./ruleset/cn-domain.yaml
    interval: 86400
  proxy:
    type: http
    behavior: domain
    url: https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt
    path: ./ruleset/proxy.yaml
    interval: 86400
  cn-ip:
    type: http
    behavior: ipcidr
    url: https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt
    path: ./ruleset/cn-ip.yaml
    interval: 86400

rules:
  - RULE-SET,reject,REJECT
  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,proxy,PROXY
  - RULE-SET,cn-ip,DIRECT
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

chmod 644 "$SUB_DIR"/{v2ray.b64,clash.yaml}
log "  [generated] $SUB_DIR/{v2ray.b64,clash.yaml}"

# --- 7.2 update Caddyfile to serve sub URL with UA-routing ----------------
log "[7.2] Caddyfile: add ${SUB_FQDN} vhost"
write_file /etc/caddy/Caddyfile 644 root:root <<EOF
{
  admin off
  email admin@${DOMAIN}
}

# CDN — Cloudflare orange-cloud, Caddy on 2087 with self-signed (CF SSL "Full")
${CDN_FQDN}:2087 {
  tls /etc/caddy/origin/cdn.crt /etc/caddy/origin/cdn.key

  @vlessws path ${CDN_WS_PATH}
  handle @vlessws {
    reverse_proxy 127.0.0.1:9100
  }
  handle {
    respond "<!doctype html><html><body><h1>Hello.</h1></body></html>" 200
  }
}

# Subscription endpoint — Let's Encrypt ACME via HTTP-01 (port 80)
# Listens on 8443 (port 443 is taken by Xray REALITY)
${SUB_FQDN}:${SUB_PORT} {
  encode gzip

  @clash    header_regexp User-Agent (?i)(clash|mihomo|stash|verge)
  @rocket   header_regexp User-Agent (?i)(shadowrocket|quantumult|surge|loon)
  @singbox  header_regexp User-Agent (?i)(sing-box|hiddify)

  handle_path /${SUB_TOKEN}/clash.yaml {
    rewrite * /${SUB_TOKEN}/clash.yaml
    root * /var/www/sub
    file_server
  }
  handle_path /${SUB_TOKEN}/v2ray.b64 {
    rewrite * /${SUB_TOKEN}/v2ray.b64
    root * /var/www/sub
    file_server
  }

  @sub_root path /${SUB_TOKEN} /${SUB_TOKEN}/
  handle @sub_root {
    root * /var/www/sub
    handle @clash {
      rewrite * /${SUB_TOKEN}/clash.yaml
      file_server
    }
    handle @rocket {
      rewrite * /${SUB_TOKEN}/v2ray.b64
      file_server
    }
    handle @singbox {
      rewrite * /${SUB_TOKEN}/v2ray.b64
      file_server
    }
    handle {
      rewrite * /${SUB_TOKEN}/v2ray.b64
      file_server
    }
  }

  handle {
    respond "Not found." 404
  }
}
EOF

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -3 || die "Caddyfile invalid"
# admin endpoint is disabled (security), so use restart not reload
systemctl restart caddy
sleep 2
systemctl is-active caddy >/dev/null || die "caddy failed: $(journalctl -u caddy -n 20 --no-pager)"

state_mark phase7
log "Phase 7 done."
log ""
log "  Subscription URL (UA-detected):"
log "    https://${SUB_FQDN}:${SUB_PORT}/${SUB_TOKEN}/"
log ""
log "  Direct paths (if you want to force a format):"
log "    https://${SUB_FQDN}:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
log "    https://${SUB_FQDN}:${SUB_PORT}/${SUB_TOKEN}/v2ray.b64"
log ""
log "Paste the first URL into Shadowrocket (Subscribe) / Clash Verge Rev (Profiles + URL)"
log "/ Hiddify Next (Add profile from URL). UA detection serves the right format."
log ""
log "ACME may take 5-30s on first request — Caddy issues LE cert via HTTP-01."
