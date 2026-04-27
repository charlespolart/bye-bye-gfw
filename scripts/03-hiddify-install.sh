#!/usr/bin/env bash
# Phase 3 — Install Hiddify Manager + extract admin/sub URLs.
# Idempotent: if /opt/hiddify-manager exists with current.json, skip reinstall.
#
# Notes:
# - Hiddify-Manager officially supports Ubuntu only; we patch supported_distros to add "Debian".
#   (Issue #4568, still open as of 2026-04.)
# - Hiddify takes ownership of ports 80/443 (nginx + haproxy) and runs xray, sing-box,
#   mariadb, redis, warp. Allow ~1 GB RAM and ~5 GB disk.
# - We pre-seed /opt/hiddify-manager/config.env with MAIN_DOMAIN + USER_SECRET so the
#   install runs unattended. Other settings are configured post-install via hiddify-panel-cli
#   in phase 4.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${DOMAIN:?}" "${PANEL_SUBDOMAIN:?}" "${DEPLOY_USER:?}" "${VPS_IPV4:?}"
PANEL_DOMAIN="${PANEL_SUBDOMAIN}.${DOMAIN}"
HIDDIFY_VERSION="${HIDDIFY_VERSION:-v10.5.73}"

log "Phase 3 — Hiddify install (panel: ${PANEL_DOMAIN}, version: ${HIDDIFY_VERSION})"

# --- 3.1 Pre-flight ---------------------------------------------------------
log "[3.1] Pre-flight checks"
mem_mb=$(free -m | awk '/^Mem:/{print $2}')
[[ "$mem_mb" -ge 900 ]] || die "VPS has only ${mem_mb} MB RAM, Hiddify needs >= 1 GB"
disk_g=$(df --output=avail -BG / | tail -1 | tr -d 'G ')
[[ "$disk_g" -ge 5 ]] || die "Need >= 5 GB free disk, only ${disk_g} GB available"
got=$(dig +short A "$PANEL_DOMAIN" @1.1.1.1 | grep -E '^[0-9]+\.' | head -1)
[[ "$got" == "$VPS_IPV4" ]] || die "DNS: ${PANEL_DOMAIN} -> '${got:-<empty>}' (expected ${VPS_IPV4}). Run phase 2 first."
log "  RAM=${mem_mb}MB disk=${disk_g}GB DNS=OK"

# --- 3.2 UFW: enable forwarding (required for Hysteria2 NAT) ---------------
log "[3.2] UFW DEFAULT_FORWARD_POLICY=ACCEPT"
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw reload >/dev/null

# --- 3.3 Install (skip if already there) -----------------------------------
if [[ -d /opt/hiddify-manager && -f /opt/hiddify-manager/current.json ]]; then
  log "[3.3] /opt/hiddify-manager + current.json present — skipping reinstall"
else
  log "[3.3] Downloading hiddify-config ${HIDDIFY_VERSION}"
  cd /tmp
  rm -rf hiddify-config hiddify-config.zip "hiddify-config-${HIDDIFY_VERSION#v}"
  curl -fsSL -o hiddify-config.zip \
    "https://github.com/hiddify/hiddify-config/archive/refs/tags/${HIDDIFY_VERSION}.zip"
  unzip -q hiddify-config.zip
  rm hiddify-config.zip
  rm -rf /opt/hiddify-manager
  mv "hiddify-config-${HIDDIFY_VERSION#v}" /opt/hiddify-manager
  ln -sfn /opt/hiddify-manager /opt/hiddify-config
  ln -sfn /opt/hiddify-manager /opt/hiddify-server

  log "[3.4] Patching supported_distros to include Debian"
  sed -i 's/^supported_distros=("Ubuntu")$/supported_distros=("Ubuntu" "Debian")/' \
    /opt/hiddify-manager/common/utils.sh
  # Some versions also gate in download_install.sh — patch defensively.
  if [[ -f /opt/hiddify-manager/common/download_install.sh ]]; then
    sed -i 's/^supported_distros=("Ubuntu")$/supported_distros=("Ubuntu" "Debian")/' \
      /opt/hiddify-manager/common/download_install.sh || true
  fi

  log "[3.5] Pre-seed config.env (MAIN_DOMAIN + USER_SECRET)"
  USER_SECRET="$(openssl rand -hex 16)"
  cat > /opt/hiddify-manager/config.env <<EOF
MAIN_DOMAIN=${PANEL_DOMAIN}
USER_SECRET=${USER_SECRET}
EOF
  chmod 600 /opt/hiddify-manager/config.env

  log "[3.6] Running install.sh --no-gui --no-log (5-15 min)"
  cd /opt/hiddify-manager
  export DEBIAN_FRONTEND=noninteractive
  # Pipe to tee so we get full log and live progress
  bash install.sh --no-gui --no-log 2>&1 | tee /var/log/hiddify-install.log | \
    grep -E '^(\[|---|===|Installing|Setting|Installed|Starting|Running|Configuring|Generating|Done|Error|FATAL|Warning)' \
    || true
  install_rc=${PIPESTATUS[0]}
  [[ "$install_rc" -eq 0 ]] || die "install.sh failed (rc=${install_rc}); see /var/log/hiddify-install.log"
fi

# --- 3.7 Post-install: extract URLs ----------------------------------------
log "[3.7] Extracting admin/sub URLs from current.json"
CJ=/opt/hiddify-manager/current.json
[[ -f "$CJ" ]] || die "${CJ} missing — install may have failed"

ADMIN_PATH=$(jq -r '.proxy_path_admin // ""' "$CJ")
CLIENT_PATH=$(jq -r '.proxy_path_client // ""' "$CJ")
OWNER_UUID=$(jq -r '[.admins[]?|select(.mode=="super_admin").uuid][0] // empty' "$CJ")

[[ -n "$ADMIN_PATH" ]] || die "proxy_path_admin missing in current.json"
[[ -n "$OWNER_UUID" ]] || die "owner UUID missing in current.json"

ADMIN_URL="https://${PANEL_DOMAIN}/${ADMIN_PATH}/${OWNER_UUID}/admin/"
SUB_URL="https://${PANEL_DOMAIN}/${CLIENT_PATH}/${OWNER_UUID}/sub/"

log "Phase 3 done."
log ""
log "  Panel admin: ${ADMIN_URL}"
log "  Sub URL:     ${SUB_URL}"
log ""

# Save to /home/$DEPLOY_USER/.hiddify-info (mode 600) so phase 4+ can read it
INFO=/home/${DEPLOY_USER}/.hiddify-info
cat > "$INFO" <<EOF
PANEL_DOMAIN=${PANEL_DOMAIN}
ADMIN_URL=${ADMIN_URL}
SUB_URL=${SUB_URL}
OWNER_UUID=${OWNER_UUID}
PROXY_PATH_ADMIN=${ADMIN_PATH}
PROXY_PATH_CLIENT=${CLIENT_PATH}
USER_SECRET_FILE=/opt/hiddify-manager/config.env
EOF
chmod 600 "$INFO"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$INFO"
log "  credentials saved to ${INFO} (mode 600)"

state_mark phase3
log ""
log "Next: phase 4 (REALITY + Hysteria2 + CDN inbounds)"
