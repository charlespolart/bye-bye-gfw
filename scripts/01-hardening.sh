#!/usr/bin/env bash
# Phase 1 — VPS hardening on a fresh Debian 12.
# Idempotent: re-running on a configured host is a near no-op (only fixes drift).
#
# Inputs (from config.env): SSH_PORT, DEPLOY_USER, DEPLOY_PUBKEY_FILE
# Effects:
#   - apt full-upgrade + base packages
#   - BBR + TCP tuning sysctls
#   - chrony NTP enabled (REALITY needs <60s skew)
#   - $DEPLOY_USER created with NOPASSWD sudo + your pubkey
#   - sshd: only Port $SSH_PORT, no root, no password, AllowUsers $DEPLOY_USER
#   - UFW: deny incoming except $SSH_PORT/tcp + 80/tcp + 443/tcp + 443/udp
#          + 20000-29999/udp + 2087/tcp
#   - rsyslog + fail2ban (sshd jail with ufw banaction)
#   - unattended-upgrades for security patches

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
require_root
load_env

: "${SSH_PORT:?SSH_PORT must be set in config.env}"
: "${DEPLOY_USER:?DEPLOY_USER must be set in config.env}"
: "${DEPLOY_PUBKEY_FILE:?DEPLOY_PUBKEY_FILE must be set in config.env}"

[[ -s "$DEPLOY_PUBKEY_FILE" ]] || die "DEPLOY_PUBKEY_FILE empty or missing: $DEPLOY_PUBKEY_FILE
Upload your SSH public key to the VPS (via panel or scp) and point DEPLOY_PUBKEY_FILE to it."

log "Phase 1 — hardening (port=$SSH_PORT user=$DEPLOY_USER)"

# --- 1.1 packages -----------------------------------------------------------
log "[1.1] apt update + full-upgrade + base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade >/dev/null
ensure_pkg curl wget vim htop ufw fail2ban unattended-upgrades chrony \
           ca-certificates gnupg lsb-release sudo dnsutils net-tools rsync rsyslog jq unzip

# --- 1.2 BBR + TCP tuning ---------------------------------------------------
log "[1.2] BBR + TCP sysctls"
write_file /etc/sysctl.d/99-bye-bye-gfw.conf 644 root:root <<'EOF' && sysctl --system >/dev/null || true
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
EOF
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR not active"

# --- 1.3 NTP ----------------------------------------------------------------
log "[1.3] chrony NTP"
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1

# --- 1.4 deploy user + pubkey + sudo ----------------------------------------
log "[1.4] $DEPLOY_USER user + pubkey + NOPASSWD sudo"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$DEPLOY_USER"
else
  usermod -aG sudo "$DEPLOY_USER"
fi
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_PUBKEY_FILE" "/home/${DEPLOY_USER}/.ssh/authorized_keys"

write_file "/etc/sudoers.d/${DEPLOY_USER}-nopasswd" 440 root:root <<EOF
Defaults:${DEPLOY_USER} secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL
EOF
visudo -c >/dev/null || die "sudoers syntax error after writing /etc/sudoers.d/${DEPLOY_USER}-nopasswd"

# --- 1.5 sshd ---------------------------------------------------------------
log "[1.5] sshd hardening on port $SSH_PORT"
write_file /etc/ssh/sshd_config.d/00-bye-bye-gfw.conf 644 root:root <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AllowUsers ${DEPLOY_USER}
X11Forwarding no
AllowAgentForwarding no
PrintMotd no
LogLevel VERBOSE
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
sshd -t || die "sshd config syntax error"
systemctl reload ssh

# --- 1.6 UFW ----------------------------------------------------------------
log "[1.6] UFW rules"
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp"   comment 'SSH custom port' >/dev/null
ufw allow 80/tcp              comment 'HTTP ACME'       >/dev/null
ufw allow 443/tcp             comment 'REALITY+panel'   >/dev/null
ufw allow 443/udp             comment 'Hysteria2'       >/dev/null
ufw allow 20000:29999/udp     comment 'HY2 hopping'     >/dev/null
ufw allow 2087/tcp            comment 'CDN VLESS+WS'    >/dev/null
ufw --force enable >/dev/null

# --- 1.7 rsyslog + fail2ban -------------------------------------------------
log "[1.7] rsyslog + fail2ban"
systemctl enable --now rsyslog >/dev/null 2>&1
# fail2ban needs /var/log/auth.log to exist BEFORE start (Debian 12 quirk).
[[ -f /var/log/auth.log ]] || install -m 640 -o root -g adm /dev/null /var/log/auth.log
logger -p auth.info "bye-bye-gfw: fail2ban init marker"
write_file /etc/fail2ban/jail.local 644 root:root <<EOF
[DEFAULT]
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
findtime = 10m
bantime = 1h
EOF
rm -f /etc/fail2ban/jail.d/sshd.local /etc/fail2ban/jail.d/recidive.local
systemctl restart fail2ban
sleep 2
systemctl is-active fail2ban >/dev/null || die "fail2ban failed to start — check journalctl -u fail2ban"

# --- 1.8 unattended-upgrades ------------------------------------------------
log "[1.8] unattended-upgrades (security)"
write_file /etc/apt/apt.conf.d/20auto-upgrades 644 root:root <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1

state_mark phase1
log "Phase 1 done."
log ""
log "Verify reachability from your local machine:"
log "  ssh -p ${SSH_PORT} ${DEPLOY_USER}@<this VPS IP>"
log ""
log "Next: create DNS records (Phase 2). See: scripts/02-dns-check.sh"
