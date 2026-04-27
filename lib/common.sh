#!/usr/bin/env bash
# Shared helpers for bye-bye-gfw deployment scripts.
# Source from phase scripts: source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# sudo on Debian strips /sbin and /usr/sbin from PATH when secure_path lacks
# them or the caller had a non-root PATH. Restore the standard root PATH so
# system tools (sysctl, ufw, sshd, ip, etc.) resolve.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Logging ----------------------------------------------------------------
_color() { local c="$1"; shift; printf '\033[%sm%s\033[0m' "$c" "$*"; }
log()  { echo "$(_color '1;32' "[$(date +%H:%M:%S)]") $*"; }
warn() { echo "$(_color '1;33' "[WARN]") $*" >&2; }
die()  { echo "$(_color '1;31' "[FATAL]") $*" >&2; exit 1; }

# --- Privilege / env --------------------------------------------------------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root (use: sudo $0)"
}

# Loads config.env from repo root. Caller must set REPO_ROOT before calling,
# or we walk up from the script's location.
load_env() {
  local root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)}"
  local env_file="${root}/config.env"
  [[ -f "$env_file" ]] || die "config.env not found at $env_file — copy config.env.example and fill in"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

# --- State tracking ---------------------------------------------------------
STATE_DIR=/var/lib/bye-bye-gfw
STATE_FILE="${STATE_DIR}/state"

state_init() {
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
}

state_done() { grep -q "^${1}=done$" "$STATE_FILE" 2>/dev/null; }
state_mark() {
  state_init
  grep -v "^${1}=" "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.new" || true
  echo "${1}=done" >> "${STATE_FILE}.new"
  mv "${STATE_FILE}.new" "$STATE_FILE"
}

# --- Idempotency helpers ----------------------------------------------------
ensure_pkg() {
  local pkgs=("$@")
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    log "installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" \
      "${missing[@]}"
  fi
}

# Write a file only if its content would change. Args: path, mode, owner:group, content-on-stdin.
# Always returns 0 (safe under set -e). Logs "[changed] <path>" to stderr when modified.
write_file() {
  local path="$1" mode="$2" owner="$3"
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp" "$path"
  rm -f "$tmp"
  echo "  [changed] $path" >&2
  return 0
}

# Append a line to a file iff not already present (anchored).
append_unique() {
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}
