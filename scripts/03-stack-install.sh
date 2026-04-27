#!/usr/bin/env bash
# Phase 3 — Install Xray-core + Hysteria2 + Caddy on Ubuntu 22.04.
# No Hiddify panel. Configs are written by phase 4.
#
# Components after this phase:
#   - /usr/local/bin/xray         (XTLS/Xray-core)
#   - /usr/local/bin/hysteria     (apernet/hysteria v2)
#   - /usr/bin/caddy              (caddyserver/caddy from cloudsmith apt repo)
# Systemd units installed but disabled (started by phase 4 once configs exist).
# REALITY X25519 keypair generated once and stored in /etc/bye-bye-gfw/reality_keys.env.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

XRAY_VERSION="${XRAY_VERSION:-v25.10.0}"
SECRETS_DIR=/etc/bye-bye-gfw

log "Phase 3 — Install Xray ${XRAY_VERSION} + Hysteria2 + Caddy"

# --- 3.1 secrets dir --------------------------------------------------------
log "[3.1] Secrets dir"
install -d -m 700 -o root -g root "$SECRETS_DIR"

# --- 3.2 Caddy from official apt repo --------------------------------------
log "[3.2] Caddy"
if ! command -v caddy >/dev/null 2>&1; then
  install -d -m 755 /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
  # Don't run with default config — we'll configure in phase 4.
  systemctl stop caddy >/dev/null 2>&1 || true
  systemctl disable caddy >/dev/null 2>&1 || true
fi
caddy version 2>&1 | head -1

# --- 3.3 Xray-core (binary) ------------------------------------------------
log "[3.3] Xray ${XRAY_VERSION}"
need_install=1
if command -v xray >/dev/null 2>&1; then
  if /usr/local/bin/xray version 2>/dev/null | grep -q "Xray ${XRAY_VERSION#v}"; then
    need_install=0
  fi
fi
if (( need_install )); then
  cd /tmp
  rm -rf xray.zip xray-extracted
  curl -fsSL -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
  install -d -m 755 xray-extracted
  unzip -q -o xray.zip -d xray-extracted
  install -m 755 xray-extracted/xray /usr/local/bin/xray
  install -d -m 755 /usr/local/share/xray
  install -m 644 xray-extracted/geoip.dat /usr/local/share/xray/geoip.dat
  install -m 644 xray-extracted/geosite.dat /usr/local/share/xray/geosite.dat
  rm -rf xray.zip xray-extracted
fi
/usr/local/bin/xray version 2>&1 | head -1

# Xray systemd unit + config dir
install -d -m 755 /etc/xray /etc/xray/configs.d /var/log/xray
write_file /etc/systemd/system/xray.service 644 root:root <<'EOF'
[Unit]
Description=Xray Service (manual stack)
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -confdir /etc/xray/configs.d
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# --- 3.4 Hysteria2 ---------------------------------------------------------
log "[3.4] Hysteria2"
if ! command -v hysteria >/dev/null 2>&1; then
  curl -fsSL https://get.hy2.sh/ | bash </dev/null
fi
hysteria version 2>&1 | head -1
# Get-hy2 already creates /etc/systemd/system/hysteria-server.service and a
# /etc/hysteria user. We override the config in phase 4.

# --- 3.5 REALITY X25519 keypair --------------------------------------------
log "[3.5] REALITY keypair"
if [[ ! -f "$SECRETS_DIR/reality_keys.env" ]]; then
  keys=$(/usr/local/bin/xray x25519)
  priv=$(echo "$keys" | awk -F': ' '/[Pp]rivate key/{print $2}')
  pub=$(echo  "$keys" | awk -F': ' '/[Pp]ublic key/{print $2}')
  [[ -n "$priv" && -n "$pub" ]] || die "x25519 keypair generation failed"
  cat > "$SECRETS_DIR/reality_keys.env" <<EOF
REALITY_PRIVATE_KEY=${priv}
REALITY_PUBLIC_KEY=${pub}
EOF
  chmod 600 "$SECRETS_DIR/reality_keys.env"
  log "  [generated] $SECRETS_DIR/reality_keys.env"
else
  log "  keypair already exists, keeping"
fi

# --- 3.6 Daemon reload + summary -------------------------------------------
systemctl daemon-reload
state_mark phase3
log "Phase 3 done."
log ""
log "  xray:     $(/usr/local/bin/xray version 2>&1 | head -1)"
log "  hysteria: $(hysteria version 2>&1 | grep Version | head -1 || hysteria version 2>&1 | head -1)"
log "  caddy:    $(caddy version 2>&1 | head -1)"
log ""
log "Services installed but DISABLED — phase 4 generates configs and starts them."
log ""
log "Next: bootstrap.sh 4"
