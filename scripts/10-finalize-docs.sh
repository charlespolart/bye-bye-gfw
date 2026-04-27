#!/usr/bin/env bash
# Phase 10 — Generate DEPLOYMENT_NOTES.md with everything you need to operate
# this VPS later: secrets, URLs, service ops, rotation procedures, calendar.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${VPS_IPV4:?}" "${VPS_IPV6:?}" "${REALITY_SNI:?}" "${DOMAIN:?}"
: "${SUB_SUBDOMAIN:?}" "${PANEL_SUBDOMAIN:?}" "${HY2_SUBDOMAIN:?}" "${CDN_SUBDOMAIN:?}"
: "${SSH_PORT:?}" "${DEPLOY_USER:?}" "${VPS_PROVIDER:?}" "${VPS_PLAN:?}" "${VPS_LOCATION:?}"
SECRETS_DIR=/etc/bye-bye-gfw
# shellcheck disable=SC1090
source "$SECRETS_DIR/inbounds.env"
# shellcheck disable=SC1090
source "$SECRETS_DIR/reality_keys.env"

SUB_FQDN="${SUB_SUBDOMAIN}.${DOMAIN}"
HY2_FQDN="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN_FQDN="${CDN_SUBDOMAIN}.${DOMAIN}"
NOTES=/root/DEPLOYMENT_NOTES.md

log "Phase 10 — generate ${NOTES}"

cat > "$NOTES" <<EOF
# bye-bye-gfw — DEPLOYMENT_NOTES

Generated: $(date -Iseconds) on \`$(hostname)\`

## Provider
- ${VPS_PROVIDER} ${VPS_PLAN} — ${VPS_LOCATION}
- IPv4: \`${VPS_IPV4}\`
- IPv6: \`${VPS_IPV6}\`

## SSH access
- Port: \`${SSH_PORT}\`
- User: \`${DEPLOY_USER}\` (key-only, NOPASSWD sudo)
- Root login: disabled, password auth: disabled

\`\`\`bash
ssh -p ${SSH_PORT} ${DEPLOY_USER}@${VPS_IPV4}
\`\`\`

## Subscription URL — paste into your client
\`\`\`
https://${SUB_FQDN}:8443/${SUB_TOKEN}/
\`\`\`
UA-detection serves Clash YAML (Clash Verge Rev / Mihomo / Stash) or v2ray base64
(Shadowrocket / Hiddify Next / sing-box / others). Force a format with
\`/clash.yaml\` or \`/v2ray.b64\` suffix.

## Inbounds at a glance
| # | Protocol            | Server                | Port      | Notes |
|---|---------------------|-----------------------|-----------|-------|
| 1 | VLESS+REALITY       | \`${VPS_IPV4}\`         | 443/tcp   | SNI=\`${REALITY_SNI}\`, flow=xtls-rprx-vision |
| 2 | Hysteria2+Salamander| \`${HY2_FQDN}\`         | 443/udp + 20000-29999/udp | Let's Encrypt cert via DNS-01 |
| 3 | VLESS+WS+TLS        | \`${CDN_FQDN}\`         | 2087/tcp via Cloudflare | self-signed origin cert; CF SSL must be "Full" |

## Outbound routing
- \`geosite:cn\` / \`geoip:cn\` → DIRECT
- \`geosite:category-ads-all\` → BLOCK
- Streaming (Netflix, Disney, HBO, Hulu, OpenAI, Anthropic) → WARP (Cloudflare)

## Secrets — DO NOT share
All secrets are in \`/etc/bye-bye-gfw/\`:
- \`reality_keys.env\` — REALITY X25519 keypair
- \`inbounds.env\` — UUID, sub token, Hy2 password, etc.
- \`/etc/wgcf/\` — WARP account/profile

\`\`\`
USER_UUID                 = ${USER_UUID}
REALITY_PUBLIC_KEY        = ${REALITY_PUBLIC_KEY}
REALITY_SHORT_IDS         = ${REALITY_SHORT_IDS}
HYSTERIA_AUTH_PASSWORD    = ${HYSTERIA_AUTH_PASSWORD}
HYSTERIA_OBFS_PASSWORD    = ${HYSTERIA_OBFS_PASSWORD}
CDN_WS_PATH               = ${CDN_WS_PATH}
SUB_TOKEN                 = ${SUB_TOKEN}
\`\`\`

## Service operations

\`\`\`bash
# Check status
sudo systemctl status xray hysteria-server caddy

# Restart one
sudo systemctl restart xray
sudo systemctl restart hysteria-server
sudo systemctl restart caddy

# Tail logs
sudo journalctl -u xray -f
sudo journalctl -u hysteria-server -f
sudo journalctl -u caddy -f

# Validate Xray config
sudo /usr/local/bin/xray run -confdir /etc/xray/configs.d -test

# Validate Caddy config
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
\`\`\`

## Re-run a phase (idempotent)

\`\`\`bash
cd /home/${DEPLOY_USER}/bye-bye-gfw
sudo ./bootstrap.sh 1   # hardening
sudo ./bootstrap.sh 2   # DNS check (uses CF token if set)
sudo ./bootstrap.sh 3   # install components
sudo ./bootstrap.sh 4   # inbound configs
sudo ./bootstrap.sh 5   # WARP outbound
sudo ./bootstrap.sh 7   # sub URL
sudo ./bootstrap.sh 9   # tests
sudo ./bootstrap.sh 10  # regenerate this doc
sudo ./bootstrap.sh all # everything in order
\`\`\`

## Backup configs (run after every change)

\`\`\`bash
sudo tar -czf /root/bye-bye-gfw-backup-\$(date +%F).tar.gz \\
  /etc/bye-bye-gfw \\
  /etc/wgcf \\
  /etc/xray/configs.d \\
  /etc/hysteria/config.yaml \\
  /etc/caddy/Caddyfile \\
  /etc/caddy/origin \\
  /etc/ssh/sshd_config.d/00-bye-bye-gfw.conf \\
  /etc/ufw \\
  /var/www/sub
\`\`\`

Pull from local Mac:
\`\`\`bash
scp -P ${SSH_PORT} ${DEPLOY_USER}@${VPS_IPV4}:/root/bye-bye-gfw-backup-*.tar.gz ~/Downloads/
\`\`\`

## IP blacklist response (if VPS IP gets blocked from China)

The GFW typically blacklists the IP, not the protocol. If REALITY/Hy2 stop
working from China but everything is fine on the VPS, the IP is burned.

1. **Quick mitigation** — toggle Cloudflare proxy on cdn.charlespolart.com:
   - The CDN inbound continues working (CF IPs aren't blocked).
2. **Real fix** — provision a new VPS, redeploy:
   \`\`\`bash
   # On new VPS
   git clone <this-repo>
   cd bye-bye-gfw
   cp config.env.example config.env  &&  vim config.env  # update VPS_IPV4/IPV6
   sudo ./bootstrap.sh all
   \`\`\`
3. Update DNS records via Cloudflare API (Phase 2 with new IP):
   \`\`\`bash
   sudo ./bootstrap.sh 2   # auto-updates A/AAAA records via API
   \`\`\`

## Sensitive periods — switch to CDN-only

The GFW tightens during these dates. If REALITY/Hy2 misbehave, switch clients
to the CDN inbound only (CF-fronted, much harder to block).

| Date         | Event                       |
|--------------|-----------------------------|
| March 5-15   | Two Sessions (NPC + CPPCC)  |
| June 4       | Tiananmen anniversary       |
| October 1    | National Day                |
| Mid-November | Plenum / Party meetings     |

In your client, just set the proxy-group to \`CDN-LAX\` only during these windows.

## Cloudflare requirements
- Zone SSL/TLS Encryption mode must be **"Full"** (not Flexible, not strict)
  for cdn.charlespolart.com (we use a self-signed origin cert).
- API token (in \`config.env\`) must have **Zone:DNS:Edit** scope, scoped to
  charlespolart.com only.

## Files locations
\`\`\`
/usr/local/bin/{xray,hysteria,caddy,wgcf}     — binaries
/etc/xray/configs.d/                           — Xray configs (one file per concern)
/etc/hysteria/config.yaml                      — Hysteria2 config
/etc/caddy/Caddyfile                           — Caddy config
/etc/caddy/origin/cdn.{crt,key}                — self-signed origin cert
/etc/wgcf/                                     — WARP account + profile
/etc/bye-bye-gfw/                              — secrets (mode 600)
/var/www/sub/${SUB_TOKEN}/                     — generated sub configs
/var/log/xray/                                 — Xray logs
/var/log/hiddify-install.log                   — (orphan, can delete)
/var/lib/bye-bye-gfw/state                     — phase state file
\`\`\`
EOF
chmod 600 "$NOTES"

state_mark phase10
log "Phase 10 done."
log ""
log "  Notes saved to: ${NOTES} (mode 600)"
log ""
log "  Pull to your local machine:"
log "    scp -P ${SSH_PORT} ${DEPLOY_USER}@${VPS_IPV4}:${NOTES} ~/Downloads/"
