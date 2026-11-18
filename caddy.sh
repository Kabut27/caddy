#!/usr/bin/env bash
#
# caddy.sh — Caddy front (80 + 443) · Wildcard SSL (Cloudflare DNS) · 3x-ui / Xray backends
#
#   :80  ─► redirect to https (+ ACME HTTP-01 when no wildcard)
#   :443 ─► Caddy terminates TLS (wildcard cert) and routes by subdomain or path:
#            ws / httpupgrade ─► http://127.0.0.1:PORT   (Upgrade handled automatically)
#            grpc / xhttp     ─► h2c://127.0.0.1:PORT    (HTTP/2 cleartext, no buffering)
#            panel / sub      ─► http://127.0.0.1:PORT
#            browsers         ─► camouflage website
#

set -Eeuo pipefail

readonly VERSION="5.2.1"
readonly REPO_RAW="https://raw.githubusercontent.com/Kabut27/caddy/main"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDY_ENV="/etc/caddy/caddy.env"
readonly STATE_DIR="/etc/caddy-deploy"
readonly CONF_FILE="${STATE_DIR}/config.env"
readonly LOC_FILE="${STATE_DIR}/locations.tsv"
readonly BACKUP_DIR="${STATE_DIR}/backups"
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

confirm() {
  local def="${2:-y}" hint ans
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "  $1 ${D}[${hint}]${N}: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ───────────────────────────── Validation ─────────────────────────────
valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_host()  { [[ "$1" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
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
CADDY_HTTPS_PORT="8443"     # internal loopback HTTPS port, used only when ENABLE_MIXED_L4=true

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

base_domain() { printf '%s' "${HOSTS[0]#\*.}"; }

# ───────────────────────────── Routes (path or subdomain) ─────────────────────────────
# A route key is either a path (/ws) or a full host (panel.example.com).
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
  local k t q def base
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
      CF_API_TOKEN="$(ask "Cloudflare API Token (Zone:DNS:Edit)" "$CF_API_TOKEN")"
      if [[ -n "$CF_API_TOKEN" ]]; then break; fi
      err "Cloudflare API Token is required for wildcard certificates."
    done
  else
    USE_WILDCARD="false"
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

configure_mixed() {
  local ans def="n"
  [[ "$ENABLE_MIXED_L4" == "true" ]] && def="y"
  info "Caddy (caddy-l4) can also accept SOCKS5 / HTTP / Mixed proxy clients on port 443, detected by protocol."
  info "The website then moves to an internal loopback port. Note: SOCKS5/HTTP auth is NOT encrypted."
  if confirm "Enable SOCKS5 / HTTP / Mixed on port 443?" "$def"; then
    ENABLE_MIXED_L4="true"
    while true; do
      ans="$(ask "3x-ui Mixed/SOCKS/HTTP inbound port (127.0.0.1)" "$MIXED_PORT")"
      if valid_port "$ans" && [[ "$ans" != "80" && "$ans" != "443" ]]; then MIXED_PORT="$ans"; break; fi
      err "Invalid port (not 80/443)."
    done
    while true; do
      ans="$(ask "Caddy internal HTTPS port (127.0.0.1 only)" "$CADDY_HTTPS_PORT")"
      if valid_port "$ans" && [[ "$ans" != "80" && "$ans" != "443" && "$ans" != "$MIXED_PORT" ]]; then CADDY_HTTPS_PORT="$ans"; break; fi
      err "Invalid port (not 80/443, and different from ${MIXED_PORT})."
    done
  else
    ENABLE_MIXED_L4="false"
  fi
  NEED_RESTART="true"   # listeners change → restart instead of reload
}

gather_full() {
  local ans

  step "1/4  Domain & Wildcard SSL"
  ask_domains "${HOSTS[0]:-example.com}"
  ask_email "$EMAIL"

  step "2/4  Main backend at /  (WebSocket / HTTPUpgrade)"
  info "Requests with an Upgrade header on any other path go to this inbound. 0 = none."
  while true; do
    ans="$(ask "Main backend port (127.0.0.1)" "$DEFAULT_PORT")"
    if [[ "$ans" == "0" ]]; then DEFAULT_PORT=""; break; fi
    if valid_port "$ans"; then DEFAULT_PORT="$ans"; break; fi
    err "Invalid port."
  done

  if confirm "Also accept plain HTTP on port 80 for proxy clients (no TLS)?" "n"; then PLAIN_HTTP="true"; else PLAIN_HTTP="false"; fi
  configure_mixed

  step "3/4  Routes (ws · httpupgrade · grpc · xhttp · panel · sub)"
  LOC_KEYS=(); LOC_PORTS=(); LOC_TYPES=()
  prompt_locations

  step "4/4  Camouflage Website"
  if confirm "Enable the camouflage website for normal browsers?" "y"; then
    ENABLE_FALLBACK="true"
    FALLBACK_DIR="$(ask "Directory to serve it from" "$FALLBACK_DIR")"
  else
    ENABLE_FALLBACK="false"
  fi
}

# ───────────────────────────── System preparation ─────────────────────────────
require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root:  sudo bash caddy.sh"; }
require_apt()  { command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu (apt) only."; }

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

# Plugins this setup actually needs (Go module paths).
needed_plugins() {
  local out=""
  if [[ "$USE_WILDCARD" == "true" ]]; then out+=" github.com/caddy-dns/cloudflare"; fi
  if [[ "$ENABLE_MIXED_L4" == "true" ]]; then out+=" github.com/mholt/caddy-l4"; fi
  printf '%s' "$out"
}

# Does binary $1 contain every plugin we need?
binary_has_plugins() {
  local mods
  mods="$("$1" list-modules 2>/dev/null || true)"
  [[ "$USE_WILDCARD" != "true" ]] || grep -q 'dns.providers.cloudflare' <<< "$mods" || return 1
  [[ "$ENABLE_MIXED_L4" != "true" ]] || grep -q 'layer4' <<< "$mods" || return 1
  return 0
}

# 1) Try Caddy's prebuilt download service (fast, but its build server sometimes
#    answers HTTP 400 for plugin combinations it cannot compile).
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

# Keep the custom binary safe from `apt upgrade` overwriting it.
install_custom_binary() {
  local bin="$1"
  systemctl stop caddy 2>/dev/null || true
  if [[ -z "$(dpkg-divert --list /usr/bin/caddy 2>/dev/null)" ]]; then
    dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy >/dev/null
  fi
  install -m 755 "$bin" /usr/bin/caddy.custom
  update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null
}

# apt's golang-go is far too old for current Caddy → install the official Go.
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

# 2) Fallback: compile it ourselves with xcaddy (takes a few minutes, ~1 GB RAM).
build_with_xcaddy() {
  local tmp_bin p
  local -a args=()
  for p in $(needed_plugins); do args+=(--with "$p"); done
  (( ${#args[@]} > 0 )) || return 0
  warn "Building Caddy with xcaddy — this takes a few minutes. If it ends with 'signal: killed', add swap (low RAM)."
  ensure_go
  export HOME="${HOME:-/root}" GOPATH="${GOPATH:-/root/go}"
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || die "Could not install xcaddy."
  tmp_bin="$(mktemp -d)"
  ( cd "$tmp_bin" && "$(go env GOPATH)/bin/xcaddy" build "${args[@]}" ) || die "xcaddy build failed."
  binary_has_plugins "${tmp_bin}/caddy" || die "xcaddy built a binary without the required plugins."
  install_custom_binary "${tmp_bin}/caddy"
  rm -rf "$tmp_bin"
}

install_caddy() {
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v caddy >/dev/null 2>&1; then
    info "Installing official Caddy package & systemd service…"
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl gpg debian-keyring debian-archive-keyring >/dev/null
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      -o /etc/apt/sources.list.d/caddy-stable.list
    chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
  fi

  local need_build=false
  if [[ "$USE_WILDCARD" == "true" ]] && ! caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then need_build=true; fi
  if [[ "$ENABLE_MIXED_L4" == "true" ]] && ! caddy list-modules 2>/dev/null | grep -q 'layer4'; then need_build=true; fi
  if [[ "$need_build" == "true" ]]; then
    info "Getting Caddy with cloudflare-dns + caddy-l4 plugins…"
    if ! fetch_custom_caddy; then build_with_xcaddy; fi
    ok "Caddy ready with Cloudflare DNS + Layer4 modules."
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
    if [[ "$ENABLE_MIXED_L4" != "true" ]]; then ufw allow 443/udp >/dev/null; fi   # HTTP/3 (QUIC)
    ok "ufw: opened 80/tcp, 443/tcp$([[ "$ENABLE_MIXED_L4" != "true" ]] && echo ", 443/udp")."
  fi
}

# Cloudflare token lives in an env file (not in the Caddyfile).
setup_caddy_env() {
  [[ "$USE_WILDCARD" == "true" ]] || return 0
  local new="CF_API_TOKEN=${CF_API_TOKEN}" unit="/etc/systemd/system/caddy.service.d/10-env.conf"
  mkdir -p /etc/caddy /etc/systemd/system/caddy.service.d
  if [[ ! -f "$CADDY_ENV" || "$(cat "$CADDY_ENV")" != "$new" ]]; then
    ( umask 077; printf '%s\n' "$new" > "$CADDY_ENV" )
    chmod 600 "$CADDY_ENV"
    NEED_RESTART="true"
  fi
  if [[ ! -f "$unit" ]]; then
    cat > "$unit" <<'UNIT'
[Service]
EnvironmentFile=/etc/caddy/caddy.env
UNIT
    systemctl daemon-reload
    NEED_RESTART="true"
  fi
}

# Make sure Caddy starts before Xray / 3x-ui at boot.
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
# Hosts Caddy must serve. Without a wildcard, every subdomain route gets its own cert.
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
  if [[ "$2" == "true" ]]; then
    echo "        reverse_proxy $1 {"
    echo "            flush_interval -1"
    echo "        }"
  else
    echo "        reverse_proxy $1"
  fi
}

emit_fallback() {
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

  if [[ -n "$EMAIL" || "$PLAIN_HTTP" == "true" || "$ENABLE_MIXED_L4" == "true" ]]; then
    echo "{"
    if [[ -n "$EMAIL" ]]; then echo "    email ${EMAIL}"; fi
    if [[ "$PLAIN_HTTP" == "true" || "$ENABLE_MIXED_L4" == "true" ]]; then echo "    auto_https disable_redirects"; fi
    if [[ "$ENABLE_MIXED_L4" == "true" ]]; then
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
      echo "            @socks5 socks5"
      echo "            route @socks5 {"
      echo "                proxy 127.0.0.1:${MIXED_PORT}"
      echo "            }"
      echo "            @http_proxy http"
      echo "            route @http_proxy {"
      echo "                proxy 127.0.0.1:${MIXED_PORT}"
      echo "            }"
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
  fi

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
  if [[ "$ENABLE_MIXED_L4" == "true" ]]; then echo "    bind 127.0.0.1"; fi
  if [[ "$USE_WILDCARD" == "true" ]]; then
    echo "    tls {"
    echo "        dns cloudflare {env.CF_API_TOKEN}"
    echo "        resolvers 1.1.1.1 8.8.8.8"
    echo "    }"
  fi
  echo "    import proxy"
  echo "}"

  if [[ "$PLAIN_HTTP" == "true" ]]; then
    echo
    echo "${http} {"
    echo "    import proxy"
    echo "}"
  elif [[ "$ENABLE_MIXED_L4" == "true" ]]; then
    echo
    echo "# https_port is internal, so redirects are written by hand and point to 443"
    echo "${http} {"
    echo "    redir https://{host}{uri} permanent"
    echo "}"
  fi
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
  if [[ -f "$CADDYFILE" ]]; then
    backup="${BACKUP_DIR}/Caddyfile.${TS}.bak"
    cp "$CADDYFILE" "$backup"
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
  ok "Caddy configuration applied."
  # keep only the 10 most recent backups
  find "$BACKUP_DIR" -name 'Caddyfile.*.bak' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f -- || true
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
  local host
  host="$(base_domain)"
  local tries=0
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

# ───────────────────────────── Views ─────────────────────────────
show_routes() {
  local i
  if [[ "$PLAIN_HTTP" == "true" ]]; then
    printf '\n  %sPort 80 :%s same routes over plain HTTP (no TLS)\n' "$B" "$N"
  else
    printf '\n  %sPort 80 :%s redirect → https\n' "$B" "$N"
  fi
  if [[ "$ENABLE_MIXED_L4" == "true" ]]; then
    printf '  %sPort 443:%s Caddy Layer 4 (by protocol)\n' "$B" "$N"
    printf '    %-28s → 127.0.0.1:%s %s(Mixed/SOCKS/HTTP inbound)%s\n' "SOCKS5 / HTTP proxy" "$MIXED_PORT" "$D" "$N"
    printf '    %-28s → 127.0.0.1:%s %s(Caddy HTTPS, %s)%s\n' "TLS / website / routes" "$CADDY_HTTPS_PORT" "$D" "$([[ "$USE_WILDCARD" == "true" ]] && echo "wildcard" || echo "per-host")" "$N"
  else
    printf '  %sPort 443:%s Caddy (TLS %s)\n' "$B" "$N" "$([[ "$USE_WILDCARD" == "true" ]] && echo "wildcard" || echo "per-host")"
  fi
  for i in "${!LOC_KEYS[@]}"; do
    printf '    %-28s → [%-11s] 127.0.0.1:%s\n' "${LOC_KEYS[$i]}" "${LOC_TYPES[$i]}" "${LOC_PORTS[$i]}"
  done
  if [[ -n "$DEFAULT_PORT" ]]; then
    printf '    %-28s → [ws/upgrade ] 127.0.0.1:%s  %s(Upgrade requests)%s\n' "/" "$DEFAULT_PORT" "$D" "$N"
  fi
  if [[ "$ENABLE_FALLBACK" == "true" ]]; then
    printf '    %-28s → camouflage site %s(%s)%s\n' "browsers" "$D" "$FALLBACK_DIR" "$N"
  fi
}

show_xui_hint() {
  printf '\n  %s3x-ui reminders:%s\n' "$B" "$N"
  printf '    Inbounds : Listen 127.0.0.1 · Security none · transport = route type\n'
  printf '    Clients  : TLS on · port 443 · address/SNI/Host = your domain · path as listed\n'
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
  show_routes
  show_xui_hint
  printf '\n  %sConfig:%s %s\n\n' "$B" "$N" "$CADDYFILE"
}

show_status() {
  step "Status"
  printf '  Caddy:     %s (%s)\n' "$(systemctl is-active caddy 2>/dev/null || true)" "$(caddy version 2>/dev/null | awk '{print $1}')"
  printf '  Domain(s): %s\n' "$DOMAINS"
  show_routes
  echo
}

deploy() {
  step "Preparing the server"
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
  install_caddy
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
    printf '  %s4)%s Full reconfigure\n' "$B" "$N"
    printf '  %s5)%s Show status\n' "$B" "$N"
    printf '  %s6)%s Quit\n\n' "$B" "$N"
    choice="$(ask "Choose" "1")"
    case "$choice" in
      1) step "Add route"; show_routes; echo; prompt_locations; reapply; return 0 ;;
      2) step "Remove route"; remove_location; reapply; return 0 ;;
      3) step "SOCKS5 / HTTP / Mixed on 443"; configure_mixed; reapply; return 0 ;;
      4) step "Full reconfigure"; gather_full; deploy; return 0 ;;
      5) show_status ;;
      6|q|Q) exit 0 ;;
      *) err "Pick 1-6." ;;
    esac
  done
}

main() {
  require_root
  require_apt
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
