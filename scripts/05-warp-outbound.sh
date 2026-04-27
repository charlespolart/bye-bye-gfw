#!/usr/bin/env bash
# Phase 5 — Cloudflare WARP outbound for geo-restricted streaming.
#
# Why: Netflix/Disney/HBO/OpenAI/Anthropic block known datacenter IPs (DMIT LAX
# is on a Cogent block that's blocked by these services). Routing via Cloudflare
# WARP makes outbound traffic look like a residential CF connection, bypassing
# the blocks while keeping our REALITY/Hy2 inbounds intact.
#
# Layout:
#  - wgcf binary at /usr/local/bin/wgcf
#  - WARP account/profile in /etc/wgcf/ (persists across re-runs)
#  - Xray outbound: /etc/xray/configs.d/50-warp.json
#  - Xray routing: /etc/xray/configs.d/70-routing-streaming.json
#    (loaded BEFORE 90-outbounds.json so streaming rules win)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

[[ "${WARP_ENABLE:-yes}" == "yes" ]] || { log "WARP_ENABLE=no, skipping phase 5"; state_mark phase5; exit 0; }

WGCF_VERSION="${WGCF_VERSION:-v2.2.30}"
WGCF_DIR=/etc/wgcf

log "Phase 5 — Cloudflare WARP outbound (wgcf ${WGCF_VERSION})"

# --- 5.1 install wgcf -------------------------------------------------------
log "[5.1] wgcf binary"
if [[ ! -x /usr/local/bin/wgcf ]]; then
  curl -fsSL -o /usr/local/bin/wgcf \
    "https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_amd64"
  chmod +x /usr/local/bin/wgcf
fi
/usr/local/bin/wgcf --version 2>&1 | head -n1 || true

# --- 5.2 register + generate profile ---------------------------------------
log "[5.2] WARP account + profile (idempotent — reuses existing)"
install -d -m 700 -o root -g root "$WGCF_DIR"
cd "$WGCF_DIR"
if [[ ! -f wgcf-account.toml ]]; then
  /usr/local/bin/wgcf register --accept-tos
  log "  [generated] $WGCF_DIR/wgcf-account.toml"
fi
if [[ ! -f wgcf-profile.conf ]]; then
  /usr/local/bin/wgcf generate
  log "  [generated] $WGCF_DIR/wgcf-profile.conf"
fi
chmod 600 wgcf-account.toml wgcf-profile.conf

# --- 5.3 parse profile -> Xray WireGuard outbound --------------------------
log "[5.3] parse WARP profile -> Xray outbound"
WG_PRIV=$(awk -F ' = ' '/^PrivateKey/{print $2}'  wgcf-profile.conf)
WG_PUB=$(awk  -F ' = ' '/^PublicKey/{print $2}'   wgcf-profile.conf)
WG_ADDR=$(awk -F ' = ' '/^Address/{print $2}'     wgcf-profile.conf)
WG_ENDP=$(awk -F ' = ' '/^Endpoint/{print $2}'    wgcf-profile.conf)
# wgcf >= 2.2.30 puts v4 + v6 on a single comma-separated line. Split.
WG_ADDR4=$(echo "$WG_ADDR" | tr ',' '\n' | awk '/\./{gsub(/^ +| +$/,""); print; exit}')
WG_ADDR6=$(echo "$WG_ADDR" | tr ',' '\n' | awk '/:/{gsub(/^ +| +$/,""); print; exit}')
[[ -n "$WG_PRIV" && -n "$WG_PUB" && -n "$WG_ADDR4" && -n "$WG_ADDR6" && -n "$WG_ENDP" ]] \
  || die "failed to parse wgcf-profile.conf (priv=${WG_PRIV:0:5}.. addr4=$WG_ADDR4 addr6=$WG_ADDR6 endp=$WG_ENDP)"

write_file /etc/xray/configs.d/50-warp.json 644 root:root <<EOF
{
  "outbounds": [{
    "tag": "warp-out",
    "protocol": "wireguard",
    "settings": {
      "secretKey": "${WG_PRIV}",
      "address": ["${WG_ADDR4}", "${WG_ADDR6}"],
      "peers": [{
        "publicKey": "${WG_PUB}",
        "endpoint": "${WG_ENDP}",
        "allowedIPs": ["0.0.0.0/0", "::/0"]
      }],
      "mtu": 1280,
      "kernelMode": false
    }
  }]
}
EOF

# --- 5.4 streaming routing rules -------------------------------------------
log "[5.4] routing rules: streaming -> warp-out"
write_file /etc/xray/configs.d/70-routing-streaming.json 644 root:root <<'EOF'
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "warp-out",
        "domain": [
          "geosite:netflix",
          "geosite:disney",
          "geosite:hbo",
          "geosite:hulu",
          "geosite:openai",
          "domain:anthropic.com",
          "domain:claude.ai",
          "domain:console.anthropic.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "ip": [ "geoip:cn" ]
      }
    ]
  }
}
EOF

# --- 5.5 reload Xray --------------------------------------------------------
log "[5.5] reload Xray"
/usr/local/bin/xray run -confdir /etc/xray/configs.d -test 2>&1 | tail -n3
systemctl restart xray
sleep 1
systemctl is-active xray >/dev/null || die "xray failed to restart"

state_mark phase5
log "Phase 5 done."
log "  WARP outbound active. Streaming domains route via Cloudflare WARP:"
log "  Netflix, Disney, HBO, Hulu, OpenAI, Anthropic (anthropic.com, claude.ai)"
log "  geoip:cn is BLOCKED on outbound (anti-reflection)"
log ""
log "Test from a connected client:"
log "  curl https://www.netflix.com/title/80057281        (should hit warp egress)"
log "  curl https://api.openai.com/v1/models               (should not return CF block)"
