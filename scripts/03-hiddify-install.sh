#!/usr/bin/env bash
# Phase 3 — Install Hiddify Manager + extract admin/sub URLs.
# Idempotent: skips if /opt/hiddify-config/current.json already exists.
#
# Approach: replicate the official common/download_install.sh flow but pre-seeded
# (MAIN_DOMAIN, USER_SECRET) and patched (allow Debian). The official script extracts
# release artifact `hiddify-config.zip` directly into /opt/hiddify-config (no wrapper),
# then runs install.sh which migrates to /opt/hiddify-manager.

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
INSTALL_DIR=/opt/hiddify-config
HIDDIFY_PIP_VER="${HIDDIFY_PIP_VER:-8.8.99}"

log "Phase 3 — Hiddify install (panel: ${PANEL_DOMAIN}, version: ${HIDDIFY_VERSION})"

# --- 3.1 Pre-flight ---------------------------------------------------------
log "[3.1] Pre-flight checks"
mem_mb=$(free -m | awk '/^Mem:/{print $2}')
(( mem_mb >= 900 )) || die "RAM too low: ${mem_mb} MB (need >= 1 GB)"
disk_g=$(df --output=avail -BG / | tail -1 | tr -d 'G ')
(( disk_g >= 5 )) || die "Disk too low: ${disk_g} GB (need >= 5 GB)"
got=$(dig +short A "$PANEL_DOMAIN" @1.1.1.1 | grep -E '^[0-9]+\.' | head -1)
[[ "$got" == "$VPS_IPV4" ]] || die "DNS: ${PANEL_DOMAIN} -> '${got:-<empty>}' (expected ${VPS_IPV4})"
log "  RAM=${mem_mb}MB disk=${disk_g}GB DNS=OK"

# --- 3.2 UFW: allow forwarding (Hysteria2 NAT port-hopping needs it) -------
log "[3.2] UFW DEFAULT_FORWARD_POLICY=ACCEPT"
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw reload >/dev/null

# --- 3.3 Install (skip if already there) -----------------------------------
if [[ -f "$INSTALL_DIR/current.json" ]]; then
  log "[3.3] ${INSTALL_DIR}/current.json present — skipping reinstall"
else
  log "[3.3] Cleanup previous attempts"
  rm -rf "$INSTALL_DIR" /tmp/Hiddify-Manager-* /tmp/hiddify-config-* /tmp/hiddify-config.zip

  log "[3.4] Download release ${HIDDIFY_VERSION} (release artifact, not source archive)"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  curl -fsSL -o hiddify-config.zip \
    "https://github.com/hiddify/hiddify-config/releases/download/${HIDDIFY_VERSION}/hiddify-config.zip"
  [[ -s hiddify-config.zip ]] || die "downloaded zip is empty — version tag wrong?"
  unzip -q -o hiddify-config.zip
  rm hiddify-config.zip
  rm -f xray/configs/*.json singbox/configs/*.json
  [[ -f install.sh && -f common/utils.sh ]] || die "extracted layout unexpected (no install.sh or common/utils.sh)"

  log "[3.5] Patch supported_distros to include Debian (best-effort)"
  # The OS gate is in download_install.sh in some versions, may also be in utils.sh.
  # In v10.5.73+ install.sh is OS-agnostic (no gate), so this patch is a no-op there.
  patched=0
  for f in "$INSTALL_DIR/common/utils.sh" "$INSTALL_DIR/common/download_install.sh"; do
    [[ -f "$f" ]] || continue
    if grep -q 'supported_distros=("Ubuntu")' "$f"; then
      sed -i 's/supported_distros=("Ubuntu")/supported_distros=("Ubuntu" "Debian")/' "$f"
      log "  [patched] $f"
      patched=1
    fi
  done
  (( patched )) || log "  (no OS gate found — this version is OS-agnostic, OK)"

  log "[3.6] Pre-seed config.env (MAIN_DOMAIN + USER_SECRET)"
  USER_SECRET="$(openssl rand -hex 16)"
  cat > "$INSTALL_DIR/config.env" <<EOF
MAIN_DOMAIN=${PANEL_DOMAIN}
USER_SECRET=${USER_SECRET}
EOF
  chmod 600 "$INSTALL_DIR/config.env"

  log "[3.7] Bootstrap Python venv + pin hiddifypanel ${HIDDIFY_PIP_VER}"
  cd "$INSTALL_DIR"
  export DEBIAN_FRONTEND=noninteractive
  export USE_VENV=true
  # shellcheck disable=SC1091
  source common/utils.sh
  install_python
  install_pypi_package pip==24.0
  pip install -U "hiddifypanel==${HIDDIFY_PIP_VER}" >/var/log/hiddify-pip.log 2>&1

  log "[3.8] Run install.sh --no-gui --no-log (5-15 min, full log: /var/log/hiddify-install.log)"
  cd "$INSTALL_DIR"
  bash install.sh --no-gui --no-log 2>&1 | tee /var/log/hiddify-install.log | \
    grep -iE '\b(fail|error|fatal|warning|installing|installed|configuring|generating|done|started|admin|panel|reality|hysteria)\b' \
    | head -200 || true
  install_rc=${PIPESTATUS[0]}
  (( install_rc == 0 )) || die "install.sh failed (rc=${install_rc}); see /var/log/hiddify-install.log"
fi

# --- 3.9 Extract URLs -------------------------------------------------------
RUNTIME_DIR=/opt/hiddify-manager
[[ -d "$RUNTIME_DIR" ]] || RUNTIME_DIR=/opt/hiddify-config
CJ="$RUNTIME_DIR/current.json"
[[ -f "$CJ" ]] || die "current.json missing at ${CJ} — install incomplete"

log "[3.9] Extract admin/sub URLs"
ADMIN_PATH=$(jq -r '.proxy_path_admin // ""' "$CJ")
CLIENT_PATH=$(jq -r '.proxy_path_client // ""' "$CJ")
OWNER_UUID=$(jq -r '[.admins[]?|select(.mode=="super_admin").uuid][0] // empty' "$CJ")

[[ -n "$ADMIN_PATH"  ]] || die "proxy_path_admin missing in current.json"
[[ -n "$OWNER_UUID"  ]] || die "owner UUID missing in current.json"

ADMIN_URL="https://${PANEL_DOMAIN}/${ADMIN_PATH}/${OWNER_UUID}/admin/"
SUB_URL="https://${PANEL_DOMAIN}/${CLIENT_PATH}/${OWNER_UUID}/sub/"

log "Phase 3 done."
log ""
log "  Panel admin: ${ADMIN_URL}"
log "  Sub URL:     ${SUB_URL}"
log ""

INFO="/home/${DEPLOY_USER}/.hiddify-info"
cat > "$INFO" <<EOF
PANEL_DOMAIN=${PANEL_DOMAIN}
ADMIN_URL=${ADMIN_URL}
SUB_URL=${SUB_URL}
OWNER_UUID=${OWNER_UUID}
PROXY_PATH_ADMIN=${ADMIN_PATH}
PROXY_PATH_CLIENT=${CLIENT_PATH}
EOF
chmod 600 "$INFO"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$INFO"
log "  credentials saved to ${INFO} (mode 600)"

state_mark phase3
log ""
log "Next: phase 4 (configure REALITY/Hysteria2/CDN inbounds via hiddify-panel-cli)"
