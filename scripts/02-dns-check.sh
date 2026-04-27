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

log "Phase 2 — DNS check"

PANEL="${PANEL_SUBDOMAIN}.${DOMAIN}"
SUB="${SUB_SUBDOMAIN}.${DOMAIN}"
HY2="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN="${CDN_SUBDOMAIN}.${DOMAIN}"

# --- Cloudflare API automation (optional) -----------------------------------
# If CLOUDFLARE_API_TOKEN is set, ensure all 4 records via API before verifying.
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  command -v jq >/dev/null 2>&1 || die "jq required for API mode (apt install jq)"
  log "Cloudflare API mode — ensuring records (token detected)"

  cf_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-sS -X "$method" -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(--data "$data")
    curl "${args[@]}" "https://api.cloudflare.com/client/v4${path}"
  }

  ZONE_ID=$(cf_api GET "/zones?name=${DOMAIN}" | jq -r '.result[0].id // empty')
  [[ -n "$ZONE_ID" ]] || die "Cloudflare zone not found for ${DOMAIN}. Token scope correct?"
  log "  zone_id=${ZONE_ID}"

  cf_ensure() {
    local fqdn="$1" content="$2" type="$3" proxied="$4"
    local existing id current_content current_proxied body
    existing=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=${type}&name=${fqdn}")
    id=$(echo "$existing" | jq -r '.result[0].id // ""')
    current_content=$(echo "$existing" | jq -r '.result[0].content // ""')
    # CF returns proxied=null for DNS-only records; normalize to "false"
    current_proxied=$(echo "$existing" | jq -r 'if .result[0].proxied == true then "true" else "false" end')
    body=$(jq -nc --arg type "$type" --arg name "$fqdn" --arg content "$content" --argjson proxied "$proxied" \
      '{type:$type,name:$name,content:$content,proxied:$proxied,ttl:1}')

    if [[ -z "$id" ]]; then
      log "  [create] ${fqdn} ${type} ${content} (proxied=${proxied})"
      cf_api POST "/zones/${ZONE_ID}/dns_records" "$body" >/dev/null
    elif [[ "$current_content" != "$content" ]] || [[ "$current_proxied" != "$proxied" ]]; then
      log "  [update] ${fqdn} ${type} ${content} (was ${current_content} proxied=${current_proxied})"
      cf_api PUT "/zones/${ZONE_ID}/dns_records/${id}" "$body" >/dev/null
    else
      log "  [ok]     ${fqdn} ${type} ${content} (proxied=${proxied})"
    fi
  }

  cf_ensure "$PANEL" "$VPS_IPV4" A false
  cf_ensure "$SUB"   "$VPS_IPV4" A false
  cf_ensure "$HY2"   "$VPS_IPV4" A false
  cf_ensure "$CDN"   "$VPS_IPV4" A true
  if [[ -n "${VPS_IPV6:-}" ]]; then
    cf_ensure "$PANEL" "$VPS_IPV6" AAAA false
    cf_ensure "$SUB"   "$VPS_IPV6" AAAA false
    cf_ensure "$HY2"   "$VPS_IPV6" AAAA false
  fi
  log "  waiting 5s for propagation..."
  sleep 5
fi

# --- Verification (always runs) ---------------------------------------------
log "Verifying with @1.1.1.1"
dns_ok=true

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
