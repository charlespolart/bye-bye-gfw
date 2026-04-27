#!/usr/bin/env bash
# Phase 2 — Verify DNS records resolve as expected.
# Action requise côté user : créer les records chez ton registrar.
# Ce script vérifie seulement ; il ne crée rien.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
load_env

: "${DOMAIN:?DOMAIN must be set in config.env}"
: "${PANEL_SUBDOMAIN:?}"; : "${SUB_SUBDOMAIN:?}"; : "${HY2_SUBDOMAIN:?}"; : "${CDN_SUBDOMAIN:?}"
: "${VPS_IPV4:?VPS_IPV4 must be set in config.env}"

log "Phase 2 — DNS check (resolver: 1.1.1.1, expecting fresh records)"

dns_ok=true
PANEL="${PANEL_SUBDOMAIN}.${DOMAIN}"
SUB="${SUB_SUBDOMAIN}.${DOMAIN}"
HY2="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN="${CDN_SUBDOMAIN}.${DOMAIN}"

check_direct() {
  local name="$1"
  local got; got=$(dig +short +time=4 +tries=2 A "$name" @1.1.1.1 | grep -E '^[0-9]+\.' | head -1)
  if [[ "$got" == "$VPS_IPV4" ]]; then
    log "  [OK]   $name -> $got (direct, as expected)"
  else
    warn "  [FAIL] $name -> '${got:-<empty>}' (expected $VPS_IPV4, DNS-only A record)"
    dns_ok=false
  fi
}

check_proxied() {
  local name="$1"
  local got; got=$(dig +short +time=4 +tries=2 A "$name" @1.1.1.1 | grep -E '^[0-9]+\.' | head -1)
  if [[ -z "$got" ]]; then
    warn "  [FAIL] $name -> <empty> (record missing)"
    dns_ok=false
  elif [[ "$got" == "$VPS_IPV4" ]]; then
    warn "  [FAIL] $name -> $got (must be Cloudflare-proxied, orange-cloud OFF detected)"
    dns_ok=false
  elif [[ "$got" =~ ^(104\.|172\.6[67]\.|162\.159\.|188\.114\.|131\.0\.72\.|141\.101\.|108\.162\.) ]]; then
    log "  [OK]   $name -> $got (Cloudflare proxy, as expected)"
  else
    warn "  [WARN] $name -> $got (resolved, but IP doesn't look like Cloudflare; check orange-cloud)"
  fi
}

check_direct "$PANEL"
check_direct "$SUB"
check_direct "$HY2"
check_proxied "$CDN"

if $dns_ok; then
  state_mark phase2
  log "Phase 2 done. All 4 DNS records resolve correctly."
else
  cat >&2 <<EOF

Phase 2 incomplete. Create these records at your registrar / DNS provider:

  ${PANEL}    A    ${VPS_IPV4}    DNS-only (proxy OFF)
  ${SUB}      A    ${VPS_IPV4}    DNS-only (proxy OFF)
  ${HY2}      A    ${VPS_IPV4}    DNS-only (proxy OFF)
  ${CDN}      A    ${VPS_IPV4}    Cloudflare orange-cloud ON

Notes:
  - panel/sub/hy2 MUST be DNS-only — REALITY needs the direct VPS IP, ACME HTTP-01 too.
  - cdn MUST be Cloudflare-proxied — that's the whole point of the CDN fallback inbound.
  - If your domain is on Cloudflare DNS, all are orange-cloud-eligible by default;
    toggle the cloud icon to grey for the first three.

Wait 1-5 min for DNS propagation, then re-run:
  sudo ./bootstrap.sh 2
EOF
  exit 1
fi
