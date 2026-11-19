#!/usr/bin/env bash
#
# caddy.sh — Caddy front (80 + 443) · Wildcard SSL (Cloudflare DNS) · 3x-ui / Xray backends
#
#   :80  ─► redirect to https (or plain HTTP catch-all when enabled)
#   :443 ─► Caddy terminates TLS (wildcard cert) and routes by subdomain or path:
#            ws / httpupgrade ─► http://127.0.0.1:PORT   (Upgrade handled automatically)
#            grpc / xhttp     ─► h2c://127.0.0.1:PORT    (HTTP/2 cleartext, no buffering)
#            panel / sub      ─► http://127.0.0.1:PORT
#            reality          ─► caddy-l4 routes the chosen SNI(s) to a REALITY inbound
#            browsers         ─► camouflage website
#
#   v5.3.0: any custom SNI / Host from clients is accepted (fallback_sni + catch-all site)
#   v5.4.0: real client IP forwarded to backends (X-Real-IP + X-Forwarded-For)
#   v5.5.0: optional VLESS REALITY on :443 — caddy-l4 routes the chosen SNI(s) to a REALITY inbound
#   v5.6.0: Cloudflare token pre-flight check, port collision checks, plain HTTP catch-all,
#           live backend/SSL health check, CLI subcommands, auto-swap & Go cache cleanup,
#           backup restore, and clean uninstall
#   v5.7.0: review pass —
#           · removed the file logger (root-run `caddy validate` created root-owned log files that
#             could stop Caddy from starting, and journalctl lost Caddy's logs); journald rotates
#           · restore now brings back the matching settings, not only the Caddyfile
#           · full reconfigure no longer reports false port conflicts from the old setup
#           · fixed errexit bugs in the xcaddy/swap cleanup path
#           · Cloudflare token is masked; systemd drop-in tolerates a missing env file
#           · safer self-update (syntax check, never downgrades), single-instance lock,
#             dependency check, apt lock wait, SSL days-left, live health in the final summary
#

set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "bash 4.4 or newer is required." >&2
  exit 1
fi

readonly VERSION="5.7.0"
readonly REPO_RAW="https://raw.githubusercontent.com/Kabut27/caddy/main"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDY_ENV="/etc/caddy/caddy.env"
readonly STATE_DIR="/etc/caddy-deploy"
readonly CONF_FILE="${STATE_DIR}/config.env"
readonly LOC_FILE="${STATE_DIR}/locations.tsv"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LOCK_FILE="/run/caddy-sh.lock"
readonly BUILD_SWAP="/swapfile.caddy-build"
TS="$(date +%Y%m%d-%H%M%S)"
readonly TS

# ───────────────────────────── UI helpers ─────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; D=""; R=""; G=""; Y=""; C=""; N=""
fi

step() { printf '\n%s▸ %s%s\n' "$B$C" "$1" "$N"; }
info() { printf '  %s•%s %s\n' "$C" "$N" "$1"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1" >&2; }
err()  { printf '  %s✘%s %s\n' "$R" "$N" "$1" >&2; }
die()  { err "$1"; exit 1; }

trap 'err "Unexpected error on line ${LINENO}. Check the message above."' ERR

banner() {
  printf '\n%s' "$B"
  cat <<'EOF'
  ┌──────────────────────────────────────────────────────────┐
  │   Caddy Front (80/443) + Wildcard SSL · 3x-ui / Xray     │
  └──────────────────────────────────────────────────────────┘
EOF
  printf '%s  %sv%s%s\n' "$N" "$D" "$VERSION" "$N"
}

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "  ${prompt} ${D}[${default}]${N}: " ans
    printf '%s' "${ans:-$default}"
  else
    read -r -p "  ${prompt}: " ans
    printf '%s' "$ans"
  fi
}

# Like ask, but the typed value is hidden and the current value is shown masked.
ask_secret() {
  local prompt="$1" cur="${2:-}" ans hint=""
  if [[ -n "$cur" ]]; then
    if (( ${#cur} > 8 )); then hint=" ${D}[Enter = keep ${cur:0:4}…${cur: -4}]${N}"; else hint=" ${D}[Enter = keep current]${N}"; fi
  fi
  read -r -s -p "  ${prompt}${hint}: " ans
  echo >&2
  printf '%s' "${ans:-$cur}"
}

confirm() {
  local def="${2:-y}" hint ans
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "  $1 ${D}[${hint}]${N}: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ───────────────────────────── Validation ─────────────────────────────
valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_host()  { [[ "$1" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,}|xn--[a-z0-9-]+)$ ]]; }
valid_path()  { [[ "$1" =~ ^/[A-Za-z0-9._~/@:+-]+$ ]]; }
valid_email() { [[ -z "$1" || "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

normalize_path() {
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  while [[ ${#p} -gt 1 && "$p" == */ ]]; do p="${p%/}"; done
  printf '%s' "$p"
}

# ───────────────────────────── State ─────────────────────────────
declare -a HOSTS=() LOC_KEYS=() LOC_PORTS=() LOC_TYPES=()
DOMAINS=""
EMAIL=""
DEFAULT_PORT="10000"        # main backend at "/" (WS/HTTPUpgrade); empty = none
ENABLE_FALLBACK="true"
FALLBACK_DIR="/var/www/fallback"
USE_WILDCARD="false"
CF_API_TOKEN=""
PLAIN_HTTP="false"          # also serve the same routes over plain HTTP on :80 (no TLS)
NEED_RESTART="false"
ENABLE_MIXED_L4="false"     # SOCKS5 / HTTP / Mixed proxy on :443 via caddy-l4
MIXED_PORT="10808"          # 3x-ui mixed/socks/http inbound (127.0.0.1)
CADDY_HTTPS_PORT="8443"     # internal loopback HTTPS port, used whenever caddy-l4 fronts :443
ENABLE_REALITY="false"      # VLESS REALITY on :443 via caddy-l4 (SNI based)
REALITY_PORT="10443"        # 3x-ui REALITY inbound (127.0.0.1)
REALITY_SNIS=""             # SNI(s) = REALITY dest/serverNames, space separated
REALITY_PROXY_PROTO="false" # send PROXY protocol v2 to the REALITY inbound (real client IP)

save_state() {
  local i
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  {
    printf 'DOMAINS=%q\n' "$DOMAINS"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'DEFAULT_PORT=%q\n' "$DEFAULT_PORT"
    printf 'ENABLE_FALLBACK=%q\n' "$ENABLE_FALLBACK"
    printf 'FALLBACK_DIR=%q\n' "$FALLBACK_DIR"
    printf 'USE_WILDCARD=%q\n' "$USE_WILDCARD"
    printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
    printf 'PLAIN_HTTP=%q\n' "$PLAIN_HTTP"
    printf 'ENABLE_MIXED_L4=%q\n' "$ENABLE_MIXED_L4"
    printf 'MIXED_PORT=%q\n' "$MIXED_PORT"
    printf 'CADDY_HTTPS_PORT=%q\n' "$CADDY_HTTPS_PORT"
    printf 'ENABLE_REALITY=%q\n' "$ENABLE_REALITY"
    printf 'REALITY_PORT=%q\n' "$REALITY_PORT"
    printf 'REALITY_SNIS=%q\n' "$REALITY_SNIS"
    printf 'REALITY_PROXY_PROTO=%q\n' "$REALITY_PROXY_PROTO"
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  : > "$LOC_FILE"
  for i in "${!LOC_KEYS[@]}"; do
    printf '%s\t%s\t%s\n' "${LOC_KEYS[$i]}" "${LOC_PORTS[$i]}" "${LOC_TYPES[$i]}" >> "$LOC_FILE"
  done
}

load_state() {
  local k q t
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  read -ra HOSTS <<< "$DOMAINS"
  LOC_KEYS=(); LOC_PORTS=(); LOC_TYPES=()
  if [[ -f "$LOC_FILE" ]]; then
    while IFS=$'\t' read -r k q t; do
      if [[ -n "$k" && -n "$q" ]]; then LOC_KEYS+=("$k"); LOC_PORTS+=("$q"); LOC_TYPES+=("${t:-ws}"); fi
    done < "$LOC_FILE"
  fi
}

# Read the Cloudflare token from the env file (used by validate/reload without loading full state).
load_cf_env() {
  [[ -f "$CADDY_ENV" ]] || return 0
  CF_API_TOKEN="$(sed -n 's/^CF_API_TOKEN=//p' "$CADDY_ENV" | head -n1)"
  export CF_API_TOKEN
}

base_domain() { printf '%s' "${HOSTS[0]#\*.}"; }

# caddy-l4 fronts :443 when SOCKS/HTTP/Mixed and/or REALITY is enabled.
use_l4() { [[ "$ENABLE_MIXED_L4" == "true" || "$ENABLE_REALITY" == "true" ]]; }

# Check if a port is already assigned to another role in our config.
# $1 = port, $2 = role to ignore (default|mixed|https|reality|loc:<key>)
port_conflict() {
  local p="$1" ignore="${2:-}" i
  if [[ "$p" == "80" || "$p" == "443" ]]; then printf 'reserved (80/443)'; return 0; fi
  if [[ "$ignore" != "default" && -n "$DEFAULT_PORT" && "$p" == "$DEFAULT_PORT" ]]; then
    printf 'main backend (/)'; return 0
  fi
  if [[ "$ignore" != "mixed" && "$ENABLE_MIXED_L4" == "true" && "$p" == "$MIXED_PORT" ]]; then
    printf 'Mixed/SOCKS inbound'; return 0
  fi
  if [[ "$ignore" != "https" ]] && use_l4 && [[ "$p" == "$CADDY_HTTPS_PORT" ]]; then
    printf 'Caddy internal HTTPS'; return 0
  fi
  if [[ "$ignore" != "reality" && "$ENABLE_REALITY" == "true" && "$p" == "$REALITY_PORT" ]]; then
    printf 'REALITY inbound'; return 0
  fi
  for i in "${!LOC_KEYS[@]}"; do
    if [[ "$ignore" != "loc:${LOC_KEYS[$i]}" && "$p" == "${LOC_PORTS[$i]}" ]]; then
      printf 'route %s' "${LOC_KEYS[$i]}"; return 0
    fi
  done
  return 1
}

# ───────────────────────────── Routes (path or subdomain) ─────────────────────────────
normalize_key() {
  local k="$1" base
  base="$(base_domain)"
  if [[ "$k" == /* ]]; then normalize_path "$k"; return 0; fi
  k="${k,,}"; k="${k%.}"
  [[ "$k" == *.* ]] || k="${k}.${base}"
  printf '%s' "$k"
}

valid_key() {
  local k="$1" base
  base="$(base_domain)"
  if [[ "$k" == /* ]]; then valid_path "$k"; return; fi
  valid_host "$k" && [[ "$k" != \*.* && "$k" == *".${base}" ]]
}

ask_type() {
  local c
  {
    printf '    %s1)%s WebSocket (ws)\n' "$B" "$N"
    printf '    %s2)%s HTTPUpgrade\n' "$B" "$N"
    printf '    %s3)%s gRPC            %s(h2c upstream)%s\n' "$B" "$N" "$D" "$N"
    printf '    %s4)%s XHTTP / SplitHTTP %s(h2c upstream, no buffering)%s\n' "$B" "$N" "$D" "$N"
    printf '    %s5)%s 3x-ui Panel / Subscription / other HTTP\n' "$B" "$N"
  } >&2
  while true; do
    c="$(ask "Transport type" "1")"
    case "$c" in
      1) printf 'ws'; return 0 ;;
      2) printf 'httpupgrade'; return 0 ;;
      3) printf 'grpc'; return 0 ;;
      4) printf 'xhttp'; return 0 ;;
      5) printf 'http'; return 0 ;;
      *) err "Pick 1-5." ;;
    esac
  done
}

add_location() {
  local key="$1" port="$2" type="$3" i
  for i in "${!LOC_KEYS[@]}"; do
    if [[ "${LOC_KEYS[$i]}" == "$key" ]]; then
      LOC_PORTS[$i]="$port"; LOC_TYPES[$i]="$type"
      info "${key} updated → [${type}] 127.0.0.1:${port}"
      return 0
    fi
  done
  LOC_KEYS+=("$key"); LOC_PORTS+=("$port"); LOC_TYPES+=("$type")
  ok "Added ${key} → [${type}] 127.0.0.1:${port}"
}

prompt_locations() {
  local k t q def base conflict
  base="$(base_domain)"
  info "Add routes: a path (/ws, /panel) or a subdomain (panel → panel.${base})."
  info "Leave it empty when you are done."
  while true; do
    echo
    k="$(ask "Path or subdomain" "")"
    if [[ -z "$k" ]]; then break; fi
    k="$(normalize_key "$k")"
    if ! valid_key "$k"; then err "Invalid path/subdomain (host must end with .${base})."; continue; fi
    t="$(ask_type)"
    case "$t" in http) def="2053" ;; *) def="10000" ;; esac
    q="$(ask "Backend port for ${k} (127.0.0.1)" "$def")"
    if ! valid_port "$q"; then err "Invalid port."; continue; fi
    if conflict="$(port_conflict "$q" "loc:${k}")"; then
      warn "Port ${q} is already used by: ${conflict}."
      confirm "Use port ${q} anyway?" "n" || continue
    fi
    add_location "$k" "$q" "$t"
  done
}

remove_location() {
  local i n
  if (( ${#LOC_KEYS[@]} == 0 )); then warn "No extra routes to remove."; return 0; fi
  for i in "${!LOC_KEYS[@]}"; do
    printf '    %s%d)%s %s → [%s] 127.0.0.1:%s\n' "$B" "$((i + 1))" "$N" "${LOC_KEYS[$i]}" "${LOC_TYPES[$i]}" "${LOC_PORTS[$i]}"
  done
  n="$(ask "Number to remove (blank to cancel)" "")"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#LOC_KEYS[@]} )); then
    n=$((n - 1))
    ok "Removed ${LOC_KEYS[$n]}"
    unset 'LOC_KEYS[n]' 'LOC_PORTS[n]' 'LOC_TYPES[n]'
    LOC_KEYS=("${LOC_KEYS[@]}"); LOC_PORTS=("${LOC_PORTS[@]}"); LOC_TYPES=("${LOC_TYPES[@]}")
  fi
}

# ───────────────────────────── Questions ─────────────────────────────
verify_cf_token() {
  local res
  res="$(curl -fsS --max-time 8 -H "Authorization: Bearer ${1}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null || true)"
  grep -q '"status":"active"' <<< "$res"
}

ask_domains() {
  local input host good base_dom
  while true; do
    input="$(ask "Base Domain (e.g. example.com)" "${1:-example.com}")"
    input="${input//,/ }"; input="${input,,}"
    read -ra HOSTS <<< "$input"
    good=true
    (( ${#HOSTS[@]} > 0 )) || good=false
    for host in "${HOSTS[@]}"; do
      if ! valid_host "$host"; then err "\"${host}\" is not a valid domain."; good=false; fi
    done
    if [[ "$good" == "true" ]]; then break; fi
  done

  if confirm "Enable Wildcard Certificate (*.${HOSTS[0]#\*.}) via Cloudflare DNS API?" "y"; then
    USE_WILDCARD="true"
    base_dom="${HOSTS[0]#\*.}"
    HOSTS=("$base_dom" "*.${base_dom}")
    while true; do
      CF_API_TOKEN="$(ask_secret "Cloudflare API Token (Zone:DNS:Edit)" "$CF_API_TOKEN")"
      if [[ -z "$CF_API_TOKEN" ]]; then
        err "Cloudflare API Token is required for wildcard certificates."
        continue
      fi
      info "Verifying Cloudflare API Token…"
      if verify_cf_token "$CF_API_TOKEN"; then
        ok "Cloudflare API Token is active."
        break
      else
        warn "Could not verify the token (wrong/expired, or an account-owned token, which this check cannot read)."
        if confirm "Continue with this token anyway?" "n"; then break; fi
      fi
    done
  else
    USE_WILDCARD="false"
    CF_API_TOKEN=""
  fi
  DOMAINS="${HOSTS[*]}"
}

ask_email() {
  local e
  while true; do
    e="$(ask "Email for certificate notices (optional)" "${1:-}")"
    if valid_email "$e"; then EMAIL="$e"; break; fi
    err "That does not look like an email."
  done
}

# $1 = previous on/off value used for the default answer (defaults to the current setting)
configure_mixed() {
  local ans def="n" conflict prev="${1:-$ENABLE_MIXED_L4}"
  [[ "$prev" == "true" ]] && def="y"
  info "Caddy (caddy-l4) can also accept SOCKS5 / HTTP / Mixed proxy clients on port 443, detected by protocol."
  info "The website then moves to an internal loopback port. Note: SOCKS5/HTTP auth is NOT encrypted"
  info "and the SOCKS5 handshake is easy for DPI to recognise — prefer REALITY / TLS routes."
  if confirm "Enable SOCKS5 / HTTP / Mixed on port 443?" "$def"; then
    ENABLE_MIXED_L4="true"
    while true; do
      ans="$(ask "3x-ui Mixed/SOCKS/HTTP inbound port (127.0.0.1)" "$MIXED_PORT")"
      if ! valid_port "$ans"; then err "Invalid port."; continue; fi
      if conflict="$(port_conflict "$ans" "mixed")"; then err "Port ${ans} conflicts with: ${conflict}."; continue; fi
      MIXED_PORT="$ans"; break
    done
    while true; do
      ans="$(ask "Caddy internal HTTPS port (127.0.0.1 only)" "$CADDY_HTTPS_PORT")"
      if ! valid_port "$ans"; then err "Invalid port."; continue; fi
      if conflict="$(port_conflict "$ans" "https")"; then err "Port ${ans} conflicts with: ${conflict}."; continue; fi
      CADDY_HTTPS_PORT="$ans"; break
    done
  else
    ENABLE_MIXED_L4="false"
  fi
  NEED_RESTART="true"
}

# $1 = previous on/off value used for the default answer (defaults to the current setting)
configure_reality() {
  local ans def="n" pp_def="n" s base good conflict prev="${1:-$ENABLE_REALITY}"
  local -a list=()
  base="$(base_domain)"
  [[ "$prev" == "true" ]] && def="y"
  [[ "$REALITY_PROXY_PROTO" == "true" ]] && pp_def="y"
  info "REALITY (VLESS + Vision) on port 443: connections whose SNI matches your chosen site(s) go to a REALITY inbound."
  info "Everything else (your website, WS routes, custom SNI) keeps working as now."
  info "Pick a real, popular HTTPS site (TLS 1.3 + h2) as SNI/dest — NOT your own domain."
  if confirm "Enable REALITY on port 443?" "$def"; then
    ENABLE_REALITY="true"
    while true; do
      ans="$(ask "3x-ui REALITY inbound port (127.0.0.1)" "$REALITY_PORT")"
      if ! valid_port "$ans"; then err "Invalid port."; continue; fi
      if conflict="$(port_conflict "$ans" "reality")"; then err "Port ${ans} conflicts with: ${conflict}."; continue; fi
      REALITY_PORT="$ans"; break
    done
    while true; do
      ans="$(ask "REALITY SNI / dest site(s), space separated (e.g. www.example.com)" "$REALITY_SNIS")"
      ans="${ans//,/ }"; ans="${ans,,}"
      read -ra list <<< "$ans"
      good=true
      (( ${#list[@]} > 0 )) || good=false
      for s in "${list[@]}"; do
        if [[ "$s" == \*.* ]]; then err "\"${s}\" cannot be a wildcard — use an exact hostname."; good=false
        elif ! valid_host "$s"; then err "\"${s}\" is not a valid domain."; good=false
        elif [[ "$s" == "$base" || "$s" == *".${base}" ]]; then err "\"${s}\" belongs to your own domain — use another site."; good=false; fi
      done
      if [[ "$good" == "true" ]]; then REALITY_SNIS="${list[*]}"; break; fi
    done
    info "If you answer yes below, enable 'Proxy Protocol' (sockopt acceptProxyProtocol) on that inbound in 3x-ui, otherwise it will not connect."
    if confirm "Send PROXY protocol (real client IP) to the REALITY inbound?" "$pp_def"; then
      REALITY_PROXY_PROTO="true"
    else
      REALITY_PROXY_PROTO="false"
    fi
  else
    ENABLE_REALITY="false"
  fi
  NEED_RESTART="true"
}

gather_full() {
  local ans conflict keep_mixed keep_reality

  # Start from a clean slate so ports of the OLD setup never raise false conflicts.
  # (Previous on/off answers are still offered as the defaults below.)
  keep_mixed="$ENABLE_MIXED_L4"; keep_reality="$ENABLE_REALITY"
  ENABLE_MIXED_L4="false"; ENABLE_REALITY="false"
  LOC_KEYS=(); LOC_PORTS=(); LOC_TYPES=()

  step "1/4  Domain & Wildcard SSL"
  ask_domains "${HOSTS[0]:-example.com}"
  ask_email "$EMAIL"

  step "2/4  Main backend at /  (WebSocket / HTTPUpgrade)"
  info "Requests with an Upgrade header on any other path go to this inbound. 0 = none."
  while true; do
    ans="$(ask "Main backend port (127.0.0.1)" "${DEFAULT_PORT:-0}")"
    if [[ "$ans" == "0" ]]; then DEFAULT_PORT=""; break; fi
    if ! valid_port "$ans"; then err "Invalid port."; continue; fi
    if conflict="$(port_conflict "$ans" "default")"; then err "Port ${ans} conflicts with: ${conflict}."; continue; fi
    DEFAULT_PORT="$ans"; break
  done

  if confirm "Also accept plain HTTP on port 80 for proxy clients (no TLS)?" "$([[ "$PLAIN_HTTP" == "true" ]] && echo y || echo n)"; then
    PLAIN_HTTP="true"
  else
    PLAIN_HTTP="false"
  fi
  configure_mixed "$keep_mixed"
  configure_reality "$keep_reality"

  step "3/4  Routes (ws · httpupgrade · grpc · xhttp · panel · sub)"
  prompt_locations

  step "4/4  Camouflage Website"
  if confirm "Enable the camouflage website for normal browsers?" "$([[ "$ENABLE_FALLBACK" == "true" ]] && echo y || echo n)"; then
    ENABLE_FALLBACK="true"
    FALLBACK_DIR="$(ask "Directory to serve it from" "$FALLBACK_DIR")"
  else
    ENABLE_FALLBACK="false"
  fi
}

# ───────────────────────────── System preparation ─────────────────────────────
require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root:  sudo bash caddy.sh"; }
require_apt()  { command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu (apt) only."; }

# Only one interactive instance at a time (two runs would overwrite each other's config).
acquire_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another caddy.sh instance is already running."
}

ensure_deps() {
  local -a missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  if (( ${#missing[@]} > 0 )); then
    info "Installing dependencies: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq "${missing[@]}" >/dev/null
  fi
}

free_ports() {
  local busy
  if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "nginx is running on 80/443."
    if confirm "Stop and disable nginx now?" "y"; then
      systemctl disable --now nginx >/dev/null 2>&1 || true
      ok "nginx stopped and disabled."
    fi
  fi
  busy="$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy"' || true)"
  if [[ -n "$busy" ]]; then
    err "Ports 80/443 are currently in use by another program:"
    printf '%s\n' "$busy" | sed 's/^/      /' >&2
    die "Move that inbound in 3x-ui to Listen 127.0.0.1 + a local port (Security: none), restart x-ui, then re-run."
  fi
}

needed_plugins() {
  local out=""
  if [[ "$USE_WILDCARD" == "true" ]]; then out+=" github.com/caddy-dns/cloudflare"; fi
  if use_l4; then out+=" github.com/mholt/caddy-l4"; fi
  printf '%s' "$out"
}

binary_has_plugins() {
  local mods
  mods="$("$1" list-modules 2>/dev/null || true)"
  [[ "$USE_WILDCARD" != "true" ]] || grep -q 'dns.providers.cloudflare' <<< "$mods" || return 1
  ! use_l4 || grep -q 'layer4' <<< "$mods" || return 1
  return 0
}

fetch_custom_caddy() {
  local arch pkgs="" p url tmp code
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) return 1 ;;
  esac
  for p in $(needed_plugins); do pkgs+="&p=${p}"; done
  [[ -n "$pkgs" ]] || return 1
  url="https://caddyserver.com/api/download?os=linux&arch=${arch}${pkgs}"
  tmp="$(mktemp)"
  code="$(curl -sSL --max-time 180 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ "$code" == "200" ]] && chmod +x "$tmp" && binary_has_plugins "$tmp"; then
    install_custom_binary "$tmp"
    rm -f "$tmp"
    return 0
  fi
  warn "Caddy's download service could not build the plugins (HTTP ${code:-?})."
  rm -f "$tmp"
  return 1
}

install_custom_binary() {
  local bin="$1"
  systemctl stop caddy 2>/dev/null || true
  if [[ -z "$(dpkg-divert --list /usr/bin/caddy 2>/dev/null)" ]]; then
    dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy >/dev/null
  fi
  install -m 755 "$bin" /usr/bin/caddy.custom
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null
  update-alternatives --set caddy /usr/bin/caddy.custom >/dev/null
}

ensure_go() {
  local arch gover
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported CPU for the Go toolchain: $(uname -m)" ;;
  esac
  if [[ ! -x /usr/local/go/bin/go ]]; then
    info "Installing a current Go toolchain (needed to build Caddy)…"
    gover="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
    [[ "$gover" == go* ]] || die "Could not determine the latest Go version."
    curl -fsSL "https://go.dev/dl/${gover}.linux-${arch}.tar.gz" | tar -C /usr/local -xz
  fi
  export PATH="/usr/local/go/bin:${PATH}"
}

build_with_xcaddy() {
  local tmp_bin="" tmp_swap="" p total_mb
  local -a args=()
  for p in $(needed_plugins); do args+=(--with "$p"); done
  (( ${#args[@]} > 0 )) || return 0

  # Leftover from an interrupted earlier build.
  if [[ -f "$BUILD_SWAP" ]]; then swapoff "$BUILD_SWAP" 2>/dev/null || true; rm -f "$BUILD_SWAP"; fi

  total_mb="$(free -m | awk '/^(Mem|Swap):/{sum+=$2} END{print sum+0}')"
  if (( total_mb < 1500 )); then
    warn "Low memory detected (${total_mb} MB RAM+Swap). xcaddy build may be killed by OOM."
    if confirm "Create a temporary 1 GB swapfile during the build?" "y"; then
      if { fallocate -l 1G "$BUILD_SWAP" 2>/dev/null || dd if=/dev/zero of="$BUILD_SWAP" bs=1M count=1024 status=none; } \
         && chmod 600 "$BUILD_SWAP" && mkswap "$BUILD_SWAP" >/dev/null 2>&1 && swapon "$BUILD_SWAP" 2>/dev/null; then
        tmp_swap="$BUILD_SWAP"
        ok "Temporary 1 GB swap enabled."
      else
        warn "Could not enable a temporary swapfile — continuing without it."
        swapoff "$BUILD_SWAP" 2>/dev/null || true
        rm -f "$BUILD_SWAP"
      fi
    fi
  fi

  cleanup_build() {
    if [[ -n "$tmp_swap" && -f "$tmp_swap" ]]; then
      swapoff "$tmp_swap" 2>/dev/null || true
      rm -f "$tmp_swap"
      info "Temporary swapfile removed."
    fi
    if [[ -n "$tmp_bin" && -d "$tmp_bin" ]]; then rm -rf "$tmp_bin"; fi
    return 0
  }
  trap 'cleanup_build; exit 130' INT TERM

  warn "Building Caddy with xcaddy — this takes a few minutes…"
  ensure_go
  export HOME="${HOME:-/root}" GOPATH="${GOPATH:-/root/go}"
  if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest; then
    cleanup_build; trap - INT TERM; die "Could not install xcaddy."
  fi
  tmp_bin="$(mktemp -d)"
  if ! ( cd "$tmp_bin" && "$(go env GOPATH)/bin/xcaddy" build "${args[@]}" ); then
    cleanup_build; trap - INT TERM; die "xcaddy build failed."
  fi
  if ! binary_has_plugins "${tmp_bin}/caddy"; then
    cleanup_build; trap - INT TERM; die "xcaddy built a binary without the required plugins."
  fi
  install_custom_binary "${tmp_bin}/caddy"
  cleanup_build
  trap - INT TERM

  info "Cleaning Go build & module caches to free disk space…"
  go clean -cache -modcache 2>/dev/null || true
}

install_caddy() {
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v caddy >/dev/null 2>&1; then
    info "Installing official Caddy package & systemd service…"
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq apt-transport-https ca-certificates curl gpg debian-keyring debian-archive-keyring >/dev/null
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      -o /etc/apt/sources.list.d/caddy-stable.list
    chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq caddy >/dev/null
  fi

  local need_build=false
  if [[ "$USE_WILDCARD" == "true" ]] && ! caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then need_build=true; fi
  if use_l4 && ! caddy list-modules 2>/dev/null | grep -q 'layer4'; then need_build=true; fi
  if [[ "$need_build" == "true" ]]; then
    info "Getting Caddy with required plugins ($(needed_plugins | xargs))…"
    if ! fetch_custom_caddy; then build_with_xcaddy; fi
    ok "Caddy ready with required modules."
  else
    ok "Caddy binary ready ($(caddy version | awk '{print $1}'))."
  fi
}

check_dns() {
  local host srv_ip dns_ip mismatch=false
  srv_ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  for host in "${HOSTS[@]}"; do
    if [[ "$host" == \*.* ]]; then continue; fi
    dns_ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [[ -z "$dns_ip" ]]; then
      warn "${host} has no A record yet."; mismatch=true
    elif [[ -n "$srv_ip" && "$dns_ip" != "$srv_ip" ]]; then
      warn "${host} → ${dns_ip}, but this server is ${srv_ip} (fine only if behind a proxy/CDN)."; mismatch=true
    else
      ok "DNS looks good: ${host} → ${dns_ip}"
    fi
  done
  if [[ "$USE_WILDCARD" == "true" ]]; then
    info "Wildcard cert needs no A record, but subdomain routes do (add an A record for *.$(base_domain) → this server)."
  fi
  if [[ "$mismatch" == "true" ]]; then
    confirm "Certificate issuance / access may fail. Continue anyway?" "n" || die "Fix DNS and re-run."
  fi
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp  >/dev/null
    ufw allow 443/tcp >/dev/null
    if ! use_l4; then ufw allow 443/udp >/dev/null; fi
    ok "ufw: opened 80/tcp, 443/tcp$(use_l4 || echo ", 443/udp")."
  fi
}

setup_caddy_env() {
  [[ "$USE_WILDCARD" == "true" ]] || return 0
  local new="CF_API_TOKEN=${CF_API_TOKEN}"
  local dir="/etc/systemd/system/caddy.service.d"
  local unit="${dir}/10-env.conf"
  local want=$'[Service]\nEnvironmentFile=-/etc/caddy/caddy.env'
  mkdir -p /etc/caddy "$dir"
  if [[ ! -f "$CADDY_ENV" || "$(cat "$CADDY_ENV")" != "$new" ]]; then
    ( umask 077; printf '%s\n' "$new" > "$CADDY_ENV" )
    chmod 600 "$CADDY_ENV"
    NEED_RESTART="true"
  fi
  # The leading "-" makes systemd tolerate a missing env file instead of refusing to start Caddy.
  if [[ ! -f "$unit" || "$(cat "$unit")" != "$want" ]]; then
    printf '%s\n' "$want" > "$unit"
    systemctl daemon-reload
    NEED_RESTART="true"
  fi
}

setup_boot_order() {
  local svc dir found=false
  for svc in x-ui xray; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
      dir="/etc/systemd/system/${svc}.service.d"
      mkdir -p "$dir"
      cat > "${dir}/10-after-caddy.conf" <<'UNIT'
[Unit]
After=caddy.service
Wants=caddy.service
UNIT
      ok "${svc}.service will now start after caddy.service."
      found=true
    fi
  done
  if [[ "$found" == "true" ]]; then systemctl daemon-reload; else info "x-ui/xray service not found — boot order skipped."; fi
}

setup_fallback() {
  [[ "$ENABLE_FALLBACK" == "true" ]] || return 0
  mkdir -p "$FALLBACK_DIR"
  if [[ -s "${FALLBACK_DIR}/index.html" ]]; then
    info "Camouflage site already present in ${FALLBACK_DIR}."
  elif curl -fsSL --max-time 15 "${REPO_RAW}/index.html" -o "${FALLBACK_DIR}/index.html" \
       && grep -qi '<html' "${FALLBACK_DIR}/index.html"; then
    ok "Camouflage site downloaded to ${FALLBACK_DIR}."
  else
    cat > "${FALLBACK_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Kabuti Grid</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#060e16;color:#e7f3f1;font-family:system-ui,sans-serif}
main{text-align:center;padding:24px}h1{font-weight:600}p{color:#6f8894}</style></head>
<body><main><h1>Kabuti Grid</h1><p>Network infrastructure monitoring. All systems operational.</p></main></body></html>
HTML
    ok "Wrote a minimal camouflage page to ${FALLBACK_DIR}."
  fi
  chmod -R a+rX "$FALLBACK_DIR"
}

# ───────────────────────────── Caddyfile ─────────────────────────────
site_hosts() {
  local k h seen
  local -a out=("${HOSTS[@]}")
  if [[ "$USE_WILDCARD" != "true" ]]; then
    for k in "${LOC_KEYS[@]}"; do
      if [[ "$k" == /* ]]; then continue; fi
      seen=false
      for h in "${out[@]}"; do
        if [[ "$h" == "$k" ]]; then seen=true; fi
      done
      if [[ "$seen" == "false" ]]; then out+=("$k"); fi
    done
  fi
  printf '%s\n' "${out[@]}"
}

emit_proxy() {   # $1 upstream · $2 flush(true|false)
  echo "        reverse_proxy $1 {"
  if [[ "$2" == "true" ]]; then echo "            flush_interval -1"; fi
  echo "            header_up X-Real-IP {remote_host}"
  echo "        }"
}

emit_fallback() {
  echo "        header X-Content-Type-Options \"nosniff\""
  echo "        header Referrer-Policy \"no-referrer\""
  echo "        root * ${FALLBACK_DIR}"
  echo "        rewrite * /index.html"
  echo "        file_server"
}

render_caddyfile() {
  local h https="" http="" i key port type upstream flush
  local -a sites=()
  mapfile -t sites < <(site_hosts)
  for h in "${sites[@]}"; do
    https+="${https:+, }${h}"
    http+="${http:+, }http://${h}"
  done

  printf '# Generated by caddy.sh v%s on %s\n' "$VERSION" "$(date '+%F %T')"
  printf '# Manual edits are overwritten — re-run the script to change settings.\n\n'

  # Caddy logs go to journald (stderr). No access log is enabled, so client traffic is not stored.
  echo "{"
  if [[ -n "$EMAIL" ]]; then echo "    email ${EMAIL}"; fi
  echo "    default_sni $(base_domain)"
  echo "    fallback_sni $(base_domain)"
  if [[ "$PLAIN_HTTP" == "true" ]] || use_l4; then echo "    auto_https disable_redirects"; fi
  if use_l4; then
    echo "    http_port 80"
    echo "    https_port ${CADDY_HTTPS_PORT}"
    echo "    servers 127.0.0.1:${CADDY_HTTPS_PORT} {"
    echo "        protocols h1 h2"
    echo "        listener_wrappers {"
    echo "            proxy_protocol {"
    echo "                timeout 5s"
    echo "                allow 127.0.0.1/32"
    echo "            }"
    echo "            tls"
    echo "        }"
    echo "    }"
    echo "    layer4 {"
    echo "        :443 {"
    if [[ "$ENABLE_MIXED_L4" == "true" ]]; then
      echo "            @socks5 socks5"
      echo "            route @socks5 {"
      echo "                proxy 127.0.0.1:${MIXED_PORT}"
      echo "            }"
      echo "            @http_proxy http"
      echo "            route @http_proxy {"
      echo "                proxy 127.0.0.1:${MIXED_PORT}"
      echo "            }"
    fi
    if [[ "$ENABLE_REALITY" == "true" ]]; then
      echo "            @reality tls sni ${REALITY_SNIS}"
      echo "            route @reality {"
      if [[ "$REALITY_PROXY_PROTO" == "true" ]]; then
        echo "                proxy {"
        echo "                    upstream 127.0.0.1:${REALITY_PORT}"
        echo "                    proxy_protocol v2"
        echo "                }"
      else
        echo "                proxy 127.0.0.1:${REALITY_PORT}"
      fi
      echo "            }"
    fi
    echo "            route {"
    echo "                proxy {"
    echo "                    upstream 127.0.0.1:${CADDY_HTTPS_PORT}"
    echo "                    proxy_protocol v1"
    echo "                }"
    echo "            }"
    echo "        }"
    echo "    }"
  fi
  echo "}"
  echo

  echo "(proxy) {"
  echo "    header -Server"
  echo

  for i in "${!LOC_KEYS[@]}"; do
    key="${LOC_KEYS[$i]}"; port="${LOC_PORTS[$i]}"; type="${LOC_TYPES[$i]}"
    case "$type" in
      grpc|xhttp)      upstream="h2c://127.0.0.1:${port}"; flush="true" ;;
      ws|httpupgrade)  upstream="127.0.0.1:${port}";       flush="true" ;;
      *)               upstream="127.0.0.1:${port}";       flush="false" ;;
    esac
    if [[ "$key" == /* ]]; then
      echo "    @r${i} path ${key} ${key}/*"
    else
      echo "    @r${i} host ${key}"
    fi
    echo "    handle @r${i} {"
    emit_proxy "$upstream" "$flush"
    echo "    }"
    echo
  done

  if [[ "$ENABLE_FALLBACK" == "true" && -n "$DEFAULT_PORT" ]]; then
    echo "    @browser {"
    echo "        not header Upgrade *"
    echo "    }"
    echo "    handle @browser {"
    emit_fallback
    echo "    }"
    echo "    handle {"
    echo "        rewrite * /"
    emit_proxy "127.0.0.1:${DEFAULT_PORT}" "true"
    echo "    }"
  elif [[ "$ENABLE_FALLBACK" == "true" ]]; then
    echo "    handle {"
    emit_fallback
    echo "    }"
  elif [[ -n "$DEFAULT_PORT" ]]; then
    echo "    handle {"
    echo "        rewrite * /"
    emit_proxy "127.0.0.1:${DEFAULT_PORT}" "true"
    echo "    }"
  else
    echo "    handle {"
    echo "        respond 404"
    echo "    }"
  fi
  echo "}"
  echo

  echo "${https} {"
  if use_l4; then echo "    bind 127.0.0.1"; fi
  if [[ "$USE_WILDCARD" == "true" ]]; then
    echo "    tls {"
    echo "        dns cloudflare {env.CF_API_TOKEN}"
    echo "        resolvers 1.1.1.1 8.8.8.8"
    echo "    }"
  fi
  echo "    import proxy"
  echo "}"

  echo
  echo "# Catch-all: any other Host header uses the same routes"
  if use_l4; then
    echo ":${CADDY_HTTPS_PORT} {"
    echo "    bind 127.0.0.1"
  else
    echo ":443 {"
  fi
  echo "    import proxy"
  echo "}"

  if [[ "$PLAIN_HTTP" == "true" ]]; then
    echo
    echo "# Plain HTTP catch-all (accepts your domain and any custom Host header)"
    echo ":80 {"
    echo "    import proxy"
    echo "}"
  elif use_l4; then
    echo
    echo "# https_port is internal, so redirects are written by hand and point to 443"
    echo "${http} {"
    echo "    redir https://{host}{uri} permanent"
    echo "}"
  fi
}

# Keep the 10 newest of each backup kind.
prune_backups() {
  local pat
  for pat in 'Caddyfile.*.bak' 'config.*.env.bak' 'locations.*.tsv.bak'; do
    find "$BACKUP_DIR" -name "$pat" -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f -- || true
  done
}

apply_config() {
  local tmp backup=""
  tmp="$(mktemp)"
  render_caddyfile > "$tmp"
  caddy fmt --overwrite "$tmp" >/dev/null 2>&1 || true

  if [[ "$USE_WILDCARD" == "true" ]]; then export CF_API_TOKEN; fi
  if ! caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>"${tmp}.err"; then
    err "Caddy rejected the generated config:"
    sed 's/^/      /' "${tmp}.err" >&2
    rm -f "$tmp" "${tmp}.err"
    return 1
  fi

  mkdir -p /etc/caddy "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if [[ -f "$CADDYFILE" ]]; then
    # Snapshot the Caddyfile together with the settings that produced it,
    # so a restore brings back a consistent setup.
    backup="${BACKUP_DIR}/Caddyfile.${TS}.bak"
    cp "$CADDYFILE" "$backup"
    if [[ -f "$CONF_FILE" ]]; then
      cp "$CONF_FILE" "${BACKUP_DIR}/config.${TS}.env.bak"; chmod 600 "${BACKUP_DIR}/config.${TS}.env.bak"
    fi
    if [[ -f "$LOC_FILE" ]]; then
      cp "$LOC_FILE" "${BACKUP_DIR}/locations.${TS}.tsv.bak"; chmod 600 "${BACKUP_DIR}/locations.${TS}.tsv.bak"
    fi
  fi
  install -m 600 "$tmp" "$CADDYFILE"
  chown caddy:caddy "$CADDYFILE" 2>/dev/null || true
  rm -f "$tmp" "${tmp}.err"

  setup_caddy_env
  systemctl enable caddy >/dev/null 2>&1 || true
  if systemctl is-active --quiet caddy; then
    if [[ "$NEED_RESTART" == "true" ]]; then
      systemctl restart caddy || { rollback "$backup"; return 1; }
    else
      systemctl reload caddy || systemctl restart caddy || { rollback "$backup"; return 1; }
    fi
  else
    systemctl start caddy || { rollback "$backup"; return 1; }
  fi
  NEED_RESTART="false"
  ok "Caddy configuration applied."
  prune_backups
}

rollback() {
  err "Caddy failed to load the new config — rolling back."
  if [[ -n "${1:-}" && -f "$1" ]]; then
    cp "$1" "$CADDYFILE"
    systemctl restart caddy >/dev/null 2>&1 || true
    warn "Previous config restored."
  fi
  journalctl -u caddy -n 10 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
}

verify_https() {
  local host tries=0
  host="$(base_domain)"
  info "Waiting for the certificate for ${host} (up to ~60s)…"
  while (( tries < 12 )); do
    if curl -sS -o /dev/null --max-time 8 "https://${host}/" 2>/dev/null; then
      ok "HTTPS is live → https://${host}"
      return 0
    fi
    tries=$((tries + 1)); sleep 5
  done
  warn "Could not confirm HTTPS yet. Usually DNS or ports 80/443 are not reachable."
  info "Recent Caddy log:"
  journalctl -u caddy -n 15 --no-pager 2>/dev/null | sed 's/^/      /' || true
}

# ───────────────────────────── Views & Health Checks ─────────────────────────────
port_badge() {
  if ss -H -ltn "( sport = :${1} )" 2>/dev/null | grep -q .; then
    printf ' %s● UP%s' "$G" "$N"
  else
    printf ' %s● DOWN%s' "$R" "$N"
  fi
}

ssl_expiry() {
  local host="$1" exp ts days
  command -v openssl >/dev/null 2>&1 || { printf 'unavailable (openssl missing)'; return 0; }
  exp="$(echo | timeout 5 openssl s_client -servername "$host" -connect 127.0.0.1:443 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [[ -z "$exp" ]]; then printf 'unavailable'; return 0; fi
  ts="$(date -d "$exp" +%s 2>/dev/null || true)"
  if [[ -n "$ts" ]]; then
    days=$(( (ts - $(date +%s)) / 86400 ))
    printf '%s (%s days left)' "$exp" "$days"
  else
    printf '%s' "$exp"
  fi
}

show_routes() {
  local live="${1:-}" i badge=""
  if [[ "$PLAIN_HTTP" == "true" ]]; then
    printf '\n  %sPort 80 :%s same routes over plain HTTP (catch-all, no TLS)\n' "$B" "$N"
  else
    printf '\n  %sPort 80 :%s redirect → https\n' "$B" "$N"
  fi
  if use_l4; then
    printf '  %sPort 443:%s Caddy Layer 4 (by protocol / SNI)\n' "$B" "$N"
    if [[ "$ENABLE_MIXED_L4" == "true" ]]; then
      if [[ "$live" == "live" ]]; then badge="$(port_badge "$MIXED_PORT")"; fi
      printf '    %-28s → 127.0.0.1:%-5s%s %s(Mixed/SOCKS/HTTP)%s\n' "SOCKS5 / HTTP proxy" "$MIXED_PORT" "$badge" "$D" "$N"
    fi
    if [[ "$ENABLE_REALITY" == "true" ]]; then
      if [[ "$live" == "live" ]]; then badge="$(port_badge "$REALITY_PORT")"; fi
      printf '    %-28s → 127.0.0.1:%-5s%s %s(REALITY%s)%s\n' "SNI: ${REALITY_SNIS}" "$REALITY_PORT" "$badge" "$D" "$([[ "$REALITY_PROXY_PROTO" == "true" ]] && echo ", PROXY v2")" "$N"
    fi
    if [[ "$live" == "live" ]]; then badge="$(port_badge "$CADDY_HTTPS_PORT")"; fi
    printf '    %-28s → 127.0.0.1:%-5s%s %s(Caddy HTTPS, %s)%s\n' "TLS / website / routes" "$CADDY_HTTPS_PORT" "$badge" "$D" "$([[ "$USE_WILDCARD" == "true" ]] && echo "wildcard" || echo "per-host")" "$N"
  else
    printf '  %sPort 443:%s Caddy (TLS %s)\n' "$B" "$N" "$([[ "$USE_WILDCARD" == "true" ]] && echo "wildcard" || echo "per-host")"
  fi
  printf '    %-28s → %s\n' "any other SNI / Host" "served with the $(base_domain) certificate"
  for i in "${!LOC_KEYS[@]}"; do
    if [[ "$live" == "live" ]]; then badge="$(port_badge "${LOC_PORTS[$i]}")"; fi
    printf '    %-28s → [%-11s] 127.0.0.1:%-5s%s\n' "${LOC_KEYS[$i]}" "${LOC_TYPES[$i]}" "${LOC_PORTS[$i]}" "$badge"
  done
  if [[ -n "$DEFAULT_PORT" ]]; then
    if [[ "$live" == "live" ]]; then badge="$(port_badge "$DEFAULT_PORT")"; fi
    printf '    %-28s → [ws/upgrade ] 127.0.0.1:%-5s%s  %s(Upgrade requests)%s\n' "/" "$DEFAULT_PORT" "$badge" "$D" "$N"
  fi
  if [[ "$ENABLE_FALLBACK" == "true" ]]; then
    printf '    %-28s → camouflage site %s(%s)%s\n' "browsers" "$D" "$FALLBACK_DIR" "$N"
  fi
  if [[ "$live" == "live" ]]; then
    printf '\n  %sDOWN%s = nothing is listening on that port yet (inbound not created or not running in 3x-ui).\n' "$R" "$N"
  fi
}

show_xui_hint() {
  printf '\n  %s3x-ui reminders:%s\n' "$B" "$N"
  printf '    Inbounds : Listen 127.0.0.1 · Security none · transport = route type\n'
  printf '    Clients  : TLS on · port 443 · address = your domain · path as listed\n'
  printf '    Real IP  : Caddy sends X-Forwarded-For + X-Real-IP; if your 3x-ui has sockopt trustedXForwardedFor, add X-Forwarded-For\n'
  printf '    Custom SNI: any SNI works (cert is for %s, so enable allowInsecure / pin the cert)\n' "$(base_domain)"
  if [[ "$ENABLE_REALITY" == "true" ]]; then
    printf '    REALITY  : inbound Listen 127.0.0.1 · port %s · TCP (RAW) · Security reality · dest = <SNI>:443 · serverNames = %s\n' "$REALITY_PORT" "$REALITY_SNIS"
    printf '               flow xtls-rprx-vision · client: port 443, address = your domain or server IP, sni = one of the SNIs, fp chrome, publicKey + shortId\n'
    if [[ "$REALITY_PROXY_PROTO" == "true" ]]; then
      printf '               enable Proxy Protocol (sockopt acceptProxyProtocol) on that inbound\n'
    fi
  fi
  if [[ "$ENABLE_MIXED_L4" == "true" ]]; then
    printf '    Mixed    : inbound Listen 127.0.0.1, port %s (SOCKS+HTTP), set user/password; clients use server:443\n' "$MIXED_PORT"
  fi
  printf '    gRPC     : serviceName = path without the leading "/"\n'
  printf '    Panel/Sub: panel without its own cert; its URI path must equal the route path\n'
}

summary() {
  printf '\n%s━━━ Done ━━━%s\n' "$B$G" "$N"
  printf '  Domain(s):   %s\n' "$DOMAINS"
  printf '  Wildcard:    %s\n' "$USE_WILDCARD"
  show_routes "live"
  show_xui_hint
  printf '\n  %sConfig:%s %s\n\n' "$B" "$N" "$CADDYFILE"
}

show_status() {
  local svc_state ver host
  svc_state="$(systemctl is-active caddy 2>/dev/null || echo inactive)"
  ver="$(caddy version 2>/dev/null | awk '{print $1}' || echo unknown)"
  host="$(base_domain)"
  step "Status & Live Health Check"
  printf '  Caddy:       %s%s%s (%s)\n' "$([[ "$svc_state" == "active" ]] && echo "$G" || echo "$R")" "$svc_state" "$N" "$ver"
  printf '  Domain(s):   %s\n' "$DOMAINS"
  printf '  SSL Expires: %s\n' "$(ssl_expiry "$host")"
  show_routes "live"
  echo
}

# ───────────────────────────── Maintenance ─────────────────────────────
restore_backup() {
  local -a files=()
  local i n chosen stamp pretty errfile
  mapfile -t files < <(find "$BACKUP_DIR" -name 'Caddyfile.*.bak' -type f 2>/dev/null | sort -r)
  if (( ${#files[@]} == 0 )); then warn "No backups found in ${BACKUP_DIR}."; return 0; fi
  step "Restore Backup"
  for i in "${!files[@]}"; do
    stamp="$(basename "${files[$i]}" .bak)"; stamp="${stamp#Caddyfile.}"
    pretty="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
    printf '    %s%d)%s %s\n' "$B" "$((i + 1))" "$N" "$pretty"
  done
  n="$(ask "Backup number to restore (blank to cancel)" "")"
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#files[@]} )); then return 0; fi
  chosen="${files[$((n - 1))]}"
  stamp="$(basename "$chosen" .bak)"; stamp="${stamp#Caddyfile.}"

  load_cf_env
  errfile="$(mktemp)"
  if ! caddy validate --config "$chosen" --adapter caddyfile >/dev/null 2>"$errfile"; then
    err "Backup failed validation:"
    sed 's/^/      /' "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"

  cp "$chosen" "$CADDYFILE"
  chown caddy:caddy "$CADDYFILE" 2>/dev/null || true

  # Bring back the matching settings so the next menu action does not silently undo the restore.
  if [[ -f "${BACKUP_DIR}/config.${stamp}.env.bak" && -f "${BACKUP_DIR}/locations.${stamp}.tsv.bak" ]]; then
    cp "${BACKUP_DIR}/config.${stamp}.env.bak" "$CONF_FILE"; chmod 600 "$CONF_FILE"
    cp "${BACKUP_DIR}/locations.${stamp}.tsv.bak" "$LOC_FILE"; chmod 600 "$LOC_FILE"
    load_state
    setup_caddy_env
    ok "Settings restored together with the Caddyfile."
  else
    warn "This backup has no matching settings snapshot: the Caddyfile is restored,"
    warn "but the next 'Add route / REALITY / reconfigure' will regenerate it from the current settings."
  fi

  if systemctl restart caddy; then
    ok "Restored ${stamp} and restarted Caddy."
  else
    err "Caddy failed to start with the restored config."
    journalctl -u caddy -n 10 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
    return 1
  fi
}

uninstall_caddy() {
  local svc
  step "Uninstall"
  warn "This will stop Caddy and remove caddy-deploy settings, backups, systemd drop-ins and the custom binary override."
  warn "Your 3x-ui inbounds listen on 127.0.0.1 — after uninstalling, set them back to a public Listen/port"
  warn "(or install another front), otherwise nothing is reachable from outside."
  confirm "Are you sure you want to continue?" "n" || return 0

  systemctl disable --now caddy >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/caddy.service.d/10-env.conf "$CADDY_ENV"
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
  for svc in x-ui xray; do
    rm -f "/etc/systemd/system/${svc}.service.d/10-after-caddy.conf"
    rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
  done
  systemctl daemon-reload

  if [[ -f /usr/bin/caddy.custom ]]; then
    update-alternatives --remove caddy /usr/bin/caddy.custom >/dev/null 2>&1 || true
    rm -f /usr/bin/caddy.custom
  fi
  if [[ -n "$(dpkg-divert --list /usr/bin/caddy 2>/dev/null)" ]]; then
    dpkg-divert --remove --rename /usr/bin/caddy >/dev/null 2>&1 || true
  fi
  if [[ -f "$BUILD_SWAP" ]]; then swapoff "$BUILD_SWAP" 2>/dev/null || true; rm -f "$BUILD_SWAP"; fi

  rm -rf "$STATE_DIR"
  ok "Removed caddy-deploy settings and overrides."

  if confirm "Also purge the Caddy apt package and /etc/caddy?" "n"; then
    apt-get purge -y -qq caddy >/dev/null 2>&1 || true
    rm -rf /etc/caddy
    ok "Caddy package and /etc/caddy removed."
  fi
  exit 0
}

update_script() {
  local tmp remote_ver newest
  if [[ ! -f "$0" || ! -w "$0" ]]; then
    die "Cannot self-update when run via pipe. Run: curl -fsSL ${REPO_RAW}/caddy.sh -o caddy.sh"
  fi
  tmp="$(mktemp)"
  info "Checking ${REPO_RAW}/caddy.sh…"
  curl -fsSL --max-time 15 "${REPO_RAW}/caddy.sh" -o "$tmp" || { rm -f "$tmp"; die "Download failed."; }
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; die "Downloaded file has syntax errors — not installing it."; }
  remote_ver="$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2 || true)"
  [[ -n "$remote_ver" ]] || { rm -f "$tmp"; die "Downloaded file does not look like caddy.sh."; }
  newest="$(printf '%s\n%s\n' "$VERSION" "$remote_ver" | sort -V | tail -n1)"
  if [[ "$remote_ver" == "$VERSION" ]]; then
    rm -f "$tmp"
    ok "Already up to date (v${VERSION})."
  elif [[ "$newest" == "$VERSION" ]]; then
    rm -f "$tmp"
    info "This copy (v${VERSION}) is newer than the repository (v${remote_ver}) — not overwriting."
  else
    install -m 755 "$tmp" "$0"
    rm -f "$tmp"
    ok "Updated caddy.sh: v${VERSION} → v${remote_ver}. Run it again to use the new version."
  fi
}

reload_caddy_cli() {
  local errfile
  [[ -f "$CADDYFILE" ]] || die "No Caddyfile found at ${CADDYFILE}."
  load_cf_env
  errfile="$(mktemp)"
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>"$errfile"; then
    err "Validation failed:"
    sed 's/^/      /' "$errfile" >&2
    rm -f "$errfile"
    exit 1
  fi
  rm -f "$errfile"
  systemctl reload caddy || systemctl restart caddy
  ok "Caddy validated and reloaded."
}

# ───────────────────────────── Flows & Menu ─────────────────────────────
deploy() {
  step "Preparing the server"
  ensure_deps
  check_dns
  free_ports
  install_caddy
  open_firewall
  setup_fallback
  setup_boot_order
  step "Applying configuration"
  apply_config || die "Deployment aborted."
  save_state
  verify_https
  summary
}

reapply() {
  step "Applying configuration"
  ensure_deps
  install_caddy
  open_firewall
  setup_fallback
  apply_config || die "Aborted. Previous configuration is still active."
  save_state
  summary
}

menu() {
  local choice
  while true; do
    printf '\n  %s1)%s Add / Update route\n' "$B" "$N"
    printf '  %s2)%s Remove route\n' "$B" "$N"
    printf '  %s3)%s SOCKS5 / HTTP / Mixed on port 443 (on/off)\n' "$B" "$N"
    printf '  %s4)%s REALITY on port 443 (on/off)\n' "$B" "$N"
    printf '  %s5)%s Full reconfigure\n' "$B" "$N"
    printf '  %s6)%s Show status & health check\n' "$B" "$N"
    printf '  %s7)%s Restore backup\n' "$B" "$N"
    printf '  %s8)%s Uninstall\n' "$B" "$N"
    printf '  %s9)%s Quit\n\n' "$B" "$N"
    choice="$(ask "Choose" "1")"
    case "$choice" in
      1) step "Add route"; show_routes; echo; prompt_locations; reapply; return 0 ;;
      2) step "Remove route"; remove_location; reapply; return 0 ;;
      3) step "SOCKS5 / HTTP / Mixed on 443"; configure_mixed; reapply; return 0 ;;
      4) step "REALITY on 443"; configure_reality; reapply; return 0 ;;
      5) step "Full reconfigure"; gather_full; deploy; return 0 ;;
      6) show_status ;;
      7) restore_backup ;;
      8) uninstall_caddy ;;
      9|q|Q) exit 0 ;;
      *) err "Pick 1-9." ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: sudo bash caddy.sh [command]

Commands:
  (none)    Launch interactive installer / management menu
  status    Show Caddy status, SSL expiry, and live backend port checks
  logs      Follow live Caddy systemd logs
  reload    Validate Caddyfile and reload Caddy
  update    Self-update caddy.sh from GitHub
  version   Print the script version
  help      Show this help message
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    version|-v|--version) echo "caddy.sh v${VERSION}"; exit 0 ;;
    logs)           require_root; exec journalctl -u caddy -n 50 -f ;;
    reload)         require_root; reload_caddy_cli; exit 0 ;;
    update)         update_script; exit 0 ;;
    status)
      require_root
      [[ -f "$CONF_FILE" ]] || die "No existing setup found in ${CONF_FILE}."
      load_state
      show_status
      exit 0
      ;;
    "") ;;
    *) err "Unknown command: $1"; usage; exit 1 ;;
  esac

  require_root
  require_apt
  acquire_lock
  if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then exec < /dev/tty; else die "This script needs an interactive terminal."; fi
  fi
  banner

  if [[ -f "$CONF_FILE" ]]; then
    load_state
    info "Existing setup found for: ${DOMAINS}"
    menu
    return 0
  fi

  gather_full
  deploy
}

main "$@"
