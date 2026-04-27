#!/usr/bin/env bash
# bye-bye-gfw — entrypoint
#
# Workflow on a fresh Debian 12 VPS:
#   ssh root@<vps>
#   apt update && apt install -y git
#   git clone <this-repo> bye-bye-gfw && cd bye-bye-gfw
#   cp config.env.example config.env && vim config.env
#   sudo ./bootstrap.sh           # runs all phases that are ready
#   sudo ./bootstrap.sh phase1    # run a single phase
#
# Phases:
#   1  hardening       (system, ssh, ufw, fail2ban) — runs as root
#   2  dns-check       (verifies DNS records exist) — needs registrar action first
#   3  hiddify         (install Hiddify Manager)    — needs phase 2 OK
#   4  inbounds        (REALITY, Hysteria2, CDN+WS+TLS)
#   5  warp            (WARP outbound for streaming)
#   6  routing         (geosite rules: cn=direct, ads=block, streaming=warp)
#   7  subscription    (verify multi-format sub URL with UA-detection)
#   9  tests           (xray tls ping, active-probing test, speedtest)
#   10 docs            (write DEPLOYMENT_NOTES.md, backup configs)
#
# (Phase 8 — monitoring — runs on a different host, not on this VPS)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
REPO_ROOT="$SCRIPT_DIR"

PHASES=(
  "1:scripts/01-hardening.sh"
  "2:scripts/02-dns-check.sh"
  "3:scripts/03-stack-install.sh"
  "4:scripts/04-inbounds.sh"
  "5:scripts/05-warp-outbound.sh"
  "6:scripts/06-routing.sh"
  "7:scripts/07-subscription-test.sh"
  "9:scripts/09-tests.sh"
  "10:scripts/10-finalize-docs.sh"
)

run_phase() {
  local label="$1"
  for entry in "${PHASES[@]}"; do
    [[ "${entry%%:*}" == "$label" ]] || continue
    local script="$SCRIPT_DIR/${entry#*:}"
    [[ -f "$script" ]] || die "phase $label not implemented yet: $script"
    log "===== phase $label ====="
    bash "$script"
    return
  done
  die "unknown phase: $label"
}

case "${1:-all}" in
  -h|--help|help)
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'
    exit 0
    ;;
  all)
    for entry in "${PHASES[@]}"; do
      label="${entry%%:*}"
      script="$SCRIPT_DIR/${entry#*:}"
      [[ -f "$script" ]] || { warn "phase $label script missing — stopping at last available"; exit 0; }
      log "===== phase $label ====="
      bash "$script" || die "phase $label failed"
    done
    log ""
    log "All available phases completed."
    ;;
  *) run_phase "$1" ;;
esac
