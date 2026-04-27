#!/usr/bin/env bash
# Phase 9 — Validate the deployment.
# Runs a series of read-only checks: services up, ports listening, certs valid,
# REALITY SNI camouflage healthy, NAT rules in place, sub URL accessible.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${VPS_IPV4:?}" "${REALITY_SNI:?}" "${DOMAIN:?}" "${SUB_SUBDOMAIN:?}" "${HY2_SUBDOMAIN:?}" "${CDN_SUBDOMAIN:?}"
SECRETS_DIR=/etc/bye-bye-gfw
[[ -f "$SECRETS_DIR/inbounds.env" ]] || die "missing inbounds.env (run phase 4)"
# shellcheck disable=SC1090
source "$SECRETS_DIR/inbounds.env"

SUB_FQDN="${SUB_SUBDOMAIN}.${DOMAIN}"
HY2_FQDN="${HY2_SUBDOMAIN}.${DOMAIN}"
CDN_FQDN="${CDN_SUBDOMAIN}.${DOMAIN}"

ok() { echo -e "  $(_color '1;32' '[OK]   ') $*"; }
ko() { echo -e "  $(_color '1;31' '[FAIL] ') $*"; FAIL=1; }
sk() { echo -e "  $(_color '1;33' '[WARN] ') $*"; }
FAIL=0

log "Phase 9 — validation tests"

# --- 9.1 services -----------------------------------------------------------
log "[9.1] services"
for svc in xray hysteria-server caddy ssh fail2ban chrony; do
  state=$(systemctl is-active "$svc" 2>/dev/null || echo "absent")
  [[ "$state" == "active" ]] && ok "$svc = $state" || ko "$svc = $state"
done
# UFW is a oneshot (loads netfilter rules, exits) — check via 'ufw status'
ufw_state=$(ufw status 2>/dev/null | awk 'NR==1{print $2}')
[[ "$ufw_state" == "active" ]] && ok "ufw rules active" || ko "ufw rules: $ufw_state"

# --- 9.2 listening ports ----------------------------------------------------
log "[9.2] listening ports"
declare -A expected=( ["52217:tcp"]=sshd ["443:tcp"]=xray ["443:udp"]=hysteria
                      ["2087:tcp"]=caddy ["8443:tcp"]=caddy ["80:tcp"]=caddy
                      ["9100:tcp"]=xray )
for entry in "${!expected[@]}"; do
  port=${entry%:*}; proto=${entry#*:}
  if ss -nlp -A "$proto" 2>/dev/null | grep -qE "[: ]${port}\s"; then
    ok "$proto/$port = ${expected[$entry]}"
  else
    ko "$proto/$port not listening (expected ${expected[$entry]})"
  fi
done

# --- 9.3 REALITY SNI camouflage --------------------------------------------
log "[9.3] REALITY SNI ${REALITY_SNI} TLS+H2 check"
sni_info=$(curl -sIv --max-time 10 "https://${REALITY_SNI}/" 2>&1)
if echo "$sni_info" | grep -q "TLSv1.3"; then ok "${REALITY_SNI} serves TLS 1.3"
else ko "${REALITY_SNI} not serving TLS 1.3"; fi
if echo "$sni_info" | grep -q "ALPN: server accepted h2"; then ok "${REALITY_SNI} negotiates HTTP/2"
else sk "${REALITY_SNI} HTTP/2 not confirmed (might still work)"; fi

# --- 9.4 active probing — random SNI fallback --------------------------------
log "[9.4] active probing test (raw TLS to VPS:443 with non-REALITY SNI)"
# Grabs the cert subject when probing with a wrong SNI; should be the SNI'd site,
# not anything mentioning charlespolart.com (which would leak the deployment)
probe=$(echo | openssl s_client -connect "${VPS_IPV4}:443" -servername "scanner-test.example.com" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || echo "(no cert)")
if echo "$probe" | grep -qiE 'charlespolart|hiddify|bye-bye-gfw'; then
  ko "probe leaks identity: $probe"
else
  ok "probe with wrong SNI returns: $probe (no identity leak)"
fi

# --- 9.5 Hy2 cert (LE) — check via journal, not TCP (443/tcp = Xray REALITY) -
log "[9.5] Hysteria2 ACME cert"
if journalctl -u hysteria-server --no-pager 2>/dev/null \
     | grep -qE "certificate obtained successfully.*${HY2_FQDN}"; then
  ok "Hy2 ACME got LE cert for ${HY2_FQDN}"
else
  sk "no ACME success log line for ${HY2_FQDN} (cert may have been cached from prior run)"
fi

# --- 9.6 sub URL accessible -------------------------------------------------
log "[9.6] sub URL"
sub_url="https://${SUB_FQDN}:8443/${SUB_TOKEN}/v2ray.b64"
sub_size=$(curl -ssk --max-time 10 -o /dev/null -w '%{size_download}' "$sub_url" || echo 0)
if (( sub_size > 100 )); then ok "sub URL serves ${sub_size} bytes"
else ko "sub URL returned ${sub_size} bytes (expected >100)"; fi

# --- 9.7 iptables NAT (Hy2 port hopping) ------------------------------------
log "[9.7] iptables NAT for Hy2 port hopping"
if iptables -t nat -L PREROUTING -n | grep -q '20000:29999'; then ok "v4 NAT 20000-29999/udp -> 443"
else ko "v4 NAT rule missing"; fi
if ip6tables -t nat -L PREROUTING -n | grep -q '20000:29999'; then ok "v6 NAT 20000-29999/udp -> 443"
else ko "v6 NAT rule missing"; fi

# --- 9.8 BBR + chrony -------------------------------------------------------
log "[9.8] kernel/network state"
cc=$(sysctl -n net.ipv4.tcp_congestion_control)
[[ "$cc" == "bbr" ]] && ok "BBR active" || ko "tcp_congestion_control=$cc (expected bbr)"
offset=$(chronyc tracking 2>/dev/null | awk -F': ' '/Last offset/ {print $2}' | tr -d ' s')
if [[ -n "$offset" ]]; then ok "chrony offset: ${offset}s"
else sk "chrony tracking unavailable"; fi

# --- 9.9 bandwidth (light test, may fail if speedtest server unreachable) --
log "[9.9] bandwidth (speedtest-cli, non-fatal)"
ensure_pkg speedtest-cli >/dev/null 2>&1 || true
if command -v speedtest-cli >/dev/null 2>&1; then
  speedtest-cli --simple --secure 2>&1 | head -n5 | sed 's/^/  /' || sk "speedtest-cli failed"
else
  sk "speedtest-cli not installed (skipping)"
fi

echo
if (( FAIL )); then
  die "Phase 9: some checks failed. Review [FAIL] above."
fi
state_mark phase9
log "Phase 9 done. All checks passed."
