#!/usr/bin/env bash
#
# caddy.sh — automatic HTTPS reverse proxy powered by Caddy
# Automatic HTTPS reverse proxy for 3x-ui / Xray behind a single domain.
#
#   curl -fsSL https://raw.githubusercontent.com/Kabut27/caddy/main/caddy.sh -o caddy.sh
#   sudo bash caddy.sh
#
# What it does:
#   • Installs Caddy (official repo) and obtains/renews the TLS cert by itself
#   • Routes /1../4 (or any path you choose) to your Xray inbounds on 127.0.0.1
#   • Optional camouflage website for normal browsers
#   • Re-run any time: add / remove locations without retyping anything
#   • Validates every change and rolls back automatically on failure
#
set -Eeuo pipefail

readonly VERSION="2.0.0"
readonly REPO_RAW="https://raw.githubusercontent.com/Kabut27/caddy/main"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly STATE_DIR="/etc/caddy-deploy"
readonly CONF_FILE="${STATE_DIR}/config.env"
readonly LOC_FILE="${STATE_DIR}/locations.tsv"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LEGACY_STATE="/etc/nginx-deploy-state.sh"
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
  ┌────────────────────────────────────────────────┐
  │   Caddy Reverse Proxy  ·  3x-ui / Xray         │
  └────────────────────────────────────────────────┘
EOF
  printf '%s  %sv%s%s\n' "$N" "$D" "$VERSION" "$N"
}

ask() { # ask "prompt" "default" -> prints answer
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "  ${prompt} ${D}[${default}]${N}: " ans
    printf '%s' "${ans:-$default}"
  else
    read -r -p "  ${prompt}: " ans
    printf '%s' "$ans"
  fi
}

confirm() { # confirm "prompt" "y|n"
  local def="${2:-y}" hint ans
  if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "  $1 ${D}[${hint}]${N}: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ───────────────────────────── Validation ─────────────────────────────
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._~/@:+-]+$ ]]; }
valid_email() { [[ -z "$1" || "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

normalize_path() {
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  while [[ ${#p} -gt 1 && "$p" == */ ]]; do p="${p%/}"; done
  printf '%s' "$p"
}

# ───────────────────────────── State ─────────────────────────────
declare -a HOSTS=() LOC_PATHS=() LOC_PORTS=()
DOMAINS=""
EMAIL=""
DEFAULT_PORT="10000"
ENABLE_FALLBACK="true"
FALLBACK_DIR="/var/www/fallback"
PLAIN_HTTP="false"
LEGACY_DOMAIN=""
LEGACY_PORT=""

save_state() {
  local i
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  {
    printf 'DOMAINS=%q\n' "$DOMAINS"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'DEFAULT_PORT=%q\n' "$DEFAULT_PORT"
    printf 'ENABLE_FALLBACK=%q\n' "$ENABLE_FALLBACK"
    printf 'FALLBACK_DIR=%q\n' "$FALLBACK_DIR"
    printf 'PLAIN_HTTP=%q\n' "$PLAIN_HTTP"
  } > "$CONF_FILE"
  : > "$LOC_FILE"
  for i in "${!LOC_PATHS[@]}"; do
    printf '%s\t%s\n' "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}" >> "$LOC_FILE"
  done
}

load_state() {
  local p q
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  read -ra HOSTS <<< "$DOMAINS"
  LOC_PATHS=(); LOC_PORTS=()
  if [[ -f "$LOC_FILE" ]]; then
    while IFS=$'\t' read -r p q; do
      if [[ -n "$p" && -n "$q" ]]; then LOC_PATHS+=("$p"); LOC_PORTS+=("$q"); fi
    done < "$LOC_FILE"
  fi
}

# Read domain / port / locations from the old nginx-based setup (read-only).
import_legacy() {
  local kind a b out
  out="$(bash -c '
    source "$1" 2>/dev/null || exit 0
    printf "DOMAIN\t%s\t\n" "${DOMAIN:-}"
    printf "PORT\t%s\t\n" "${DEFAULT_PORT:-}"
    for i in "${!LOC_PATHS[@]}"; do printf "LOC\t%s\t%s\n" "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}"; done
  ' _ "$LEGACY_STATE" 2>/dev/null || true)"
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      DOMAIN) LEGACY_DOMAIN="$a" ;;
      PORT)   LEGACY_PORT="$a" ;;
      LOC)
        a="$(normalize_path "$a")"
        if valid_path "$a" && valid_port "$b"; then add_location "$a" "$b" quiet; fi
        ;;
    esac
  done <<< "$out"
}

# ───────────────────────────── Locations ─────────────────────────────
add_location() { # add_location path port [quiet]
  local path port i
  path="$(normalize_path "$1")"; port="$2"
  for i in "${!LOC_PATHS[@]}"; do
    if [[ "${LOC_PATHS[$i]}" == "$path" ]]; then
      LOC_PORTS[$i]="$port"
      [[ "${3:-}" == "quiet" ]] || info "${path} already existed — updated to 127.0.0.1:${port}"
      return 0
    fi
  done
  LOC_PATHS+=("$path"); LOC_PORTS+=("$port")
  [[ "${3:-}" == "quiet" ]] || ok "Added ${path} → 127.0.0.1:${port}"
}

prompt_locations() {
  local p q
  info "Add extra locations (e.g. your 3x-ui panel path, a websocket inbound…)."
  info "Leave the path empty when you are done."
  while true; do
    echo
    p="$(ask "Path (e.g. /panel or /ws)" "")"
    if [[ -z "$p" ]]; then break; fi
    p="$(normalize_path "$p")"
    if ! valid_path "$p"; then err "Invalid path. Use letters, digits and . _ ~ / - only (and not just \"/\")."; continue; fi
    q="$(ask "Backend port for ${p}" "")"
    if ! valid_port "$q"; then err "Invalid port."; continue; fi
    add_location "$p" "$q"
  done
}

remove_location() {
  local i n
  if (( ${#LOC_PATHS[@]} == 0 )); then warn "No locations to remove."; return 0; fi
  for i in "${!LOC_PATHS[@]}"; do
    printf '    %s%d)%s %s → 127.0.0.1:%s\n' "$B" "$((i + 1))" "$N" "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}"
  done
  n="$(ask "Number to remove (blank to cancel)" "")"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#LOC_PATHS[@]} )); then
    n=$((n - 1))
    ok "Removed ${LOC_PATHS[$n]}"
    unset 'LOC_PATHS[n]' 'LOC_PORTS[n]'
    LOC_PATHS=("${LOC_PATHS[@]}"); LOC_PORTS=("${LOC_PORTS[@]}")
  else
    info "Nothing removed."
  fi
}

# ───────────────────────────── Questions ─────────────────────────────
ask_domains() {
  local input host good
  while true; do
    input="$(ask "Domain(s), space separated" "${1:-}")"
    input="${input//,/ }"; input="${input,,}"
    read -ra HOSTS <<< "$input"
    good=true
    (( ${#HOSTS[@]} > 0 )) || good=false
    for host in "${HOSTS[@]}"; do
      if ! valid_host "$host"; then err "\"${host}\" is not a valid domain (use e.g. vpn.example.com)."; good=false; fi
    done
    if [[ "$good" == "true" ]]; then break; fi
  done
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

gather_full() {
  local def_domain="${LEGACY_DOMAIN:-example.com}" def_port="${LEGACY_PORT:-10000}" ans

  step "1/4  Domain & certificate"
  info "Caddy requests and renews the certificate automatically (Let's Encrypt)."
  info "Point your domain's A/AAAA record to this server first. DNS-only (grey cloud) is simplest."
  ask_domains "$def_domain"
  ask_email ""

  step "2/4  Default backend"
  info "Any path not listed below goes to your main VLESS/HTTPUpgrade inbound."
  while true; do
    ans="$(ask "Default backend port" "$def_port")"
    if valid_port "$ans"; then DEFAULT_PORT="$ans"; break; fi
    err "Invalid port."
  done
  if confirm "Also accept plain HTTP on port 80 for proxy clients (no TLS)?" "n"; then PLAIN_HTTP="true"; else PLAIN_HTTP="false"; fi

  step "3/4  Camouflage website"
  info "Normal browsers get a real-looking site; your VLESS/HTTPUpgrade clients are unaffected."
  if confirm "Enable the camouflage website?" "y"; then
    ENABLE_FALLBACK="true"
    FALLBACK_DIR="$(ask "Directory to serve it from" "$FALLBACK_DIR")"
  else
    ENABLE_FALLBACK="false"
  fi

  step "4/4  Locations"
  if (( ${#LOC_PATHS[@]} > 0 )); then
    info "Imported from your previous setup:"
    local i
    for i in "${!LOC_PATHS[@]}"; do info "  ${LOC_PATHS[$i]} → 127.0.0.1:${LOC_PORTS[$i]}"; done
  elif confirm "Quick-add standard paths /1→10001, /2→10002, /3→10003, /4→10004?" "y"; then
    local n
    for n in 1 2 3 4; do add_location "/${n}" "$((10000 + n))"; done
  fi
  prompt_locations
}

# ───────────────────────────── System preparation ─────────────────────────────
require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root:  sudo bash caddy.sh"; }
require_apt()  { command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu (apt) only."; }

free_ports() {
  local busy
  if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "nginx is running and uses ports 80/443 (Caddy replaces it)."
    if confirm "Stop and disable nginx now? (its config files are kept)" "y"; then
      systemctl disable --now nginx >/dev/null 2>&1 || true
      ok "nginx stopped and disabled."
    fi
  fi
  busy="$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"caddy"' || true)"
  if [[ -n "$busy" ]]; then
    err "Ports 80/443 are still in use by another program:"
    printf '%s\n' "$busy" | sed 's/^/      /' >&2
    die "Free those ports and re-run."
  fi
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy already installed ($(caddy version | awk '{print $1}'))."
    return 0
  fi
  info "Installing Caddy from the official repository…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gpg >/dev/null
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  ok "Caddy installed ($(caddy version | awk '{print $1}'))."
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp  >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    ok "ufw: opened 80/tcp, 443/tcp, 443/udp."
  fi
}

check_dns() {
  local host srv_ip dns_ip mismatch=false
  srv_ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  for host in "${HOSTS[@]}"; do
    dns_ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [[ -z "$dns_ip" ]]; then
      warn "${host} has no A record yet."; mismatch=true
    elif [[ -n "$srv_ip" && "$dns_ip" != "$srv_ip" ]]; then
      warn "${host} → ${dns_ip}, but this server is ${srv_ip} (fine only if behind a proxy/CDN)."; mismatch=true
    else
      ok "DNS looks good: ${host} → ${dns_ip}"
    fi
  done
  if [[ "$mismatch" == "true" ]]; then
    confirm "Certificate issuance may fail. Continue anyway?" "n" || die "Fix DNS and re-run."
  fi
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
render_caddyfile() {
  local h https="" http="" i
  for h in "${HOSTS[@]}"; do
    https+="${https:+, }${h}"
    http+="${http:+, }http://${h}"
  done

  printf '# Generated by caddy.sh v%s on %s\n' "$VERSION" "$(date '+%F %T')"
  printf '# Manual edits are overwritten — re-run the script to change settings.\n\n'

  if [[ -n "$EMAIL" || "$PLAIN_HTTP" == "true" ]]; then
    echo "{"
    if [[ -n "$EMAIL" ]]; then echo "    email ${EMAIL}"; fi
    if [[ "$PLAIN_HTTP" == "true" ]]; then echo "    auto_https disable_redirects"; fi
    echo "}"
    echo
  fi

  echo "(proxy) {"
  echo "    header -Server"
  echo
  for i in "${!LOC_PATHS[@]}"; do
    echo "    @loc${i} path ${LOC_PATHS[$i]} ${LOC_PATHS[$i]}/*"
    echo "    handle @loc${i} {"
    echo "        reverse_proxy 127.0.0.1:${LOC_PORTS[$i]} {"
    echo "            flush_interval -1"
    echo "        }"
    echo "    }"
    echo
  done
  if [[ "$ENABLE_FALLBACK" == "true" ]]; then
    echo "    @browser {"
    echo "        not header Upgrade *"
    echo "    }"
    echo "    handle @browser {"
    echo "        root * ${FALLBACK_DIR}"
    echo "        rewrite * /index.html"
    echo "        file_server"
    echo "    }"
    echo
  fi
  echo "    handle {"
  echo "        rewrite * /"
  echo "        reverse_proxy 127.0.0.1:${DEFAULT_PORT} {"
  echo "            flush_interval -1"
  echo "        }"
  echo "    }"
  echo "}"
  echo
  echo "${https} {"
  echo "    import proxy"
  echo "}"
  if [[ "$PLAIN_HTTP" == "true" ]]; then
    echo
    echo "${http} {"
    echo "    import proxy"
    echo "}"
  fi
}

apply_config() {
  local tmp backup=""
  tmp="$(mktemp)"
  render_caddyfile > "$tmp"
  caddy fmt --overwrite "$tmp" >/dev/null 2>&1 || true

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
  install -m 644 "$tmp" "$CADDYFILE"
  rm -f "$tmp" "${tmp}.err"

  systemctl enable caddy >/dev/null 2>&1 || true
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy || { rollback "$backup"; return 1; }
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
  local host="${HOSTS[0]}" tries=0
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
  printf '\n  %sRoutes%s\n' "$B" "$N"
  for i in "${!LOC_PATHS[@]}"; do
    printf '    %-22s → 127.0.0.1:%s\n' "${LOC_PATHS[$i]}" "${LOC_PORTS[$i]}"
  done
  printf '    %-22s → 127.0.0.1:%s  %s(catch-all)%s\n' "/" "$DEFAULT_PORT" "$D" "$N"
}

summary() {
  printf '\n%s━━━ Done ━━━%s\n' "$B$G" "$N"
  printf '  Domain(s):   %s\n' "$DOMAINS"
  printf '  TLS:         automatic (Caddy)\n'
  if [[ "$ENABLE_FALLBACK" == "true" ]]; then printf '  Camouflage:  %s\n' "$FALLBACK_DIR"; fi
  show_routes
  printf '\n  %sTip:%s set each Xray inbound / the 3x-ui panel to listen on 127.0.0.1\n' "$B" "$N"
  printf '       so nothing can reach them while bypassing Caddy.\n'
  printf '  %sConfig:%s %s   %sBackups:%s %s\n\n' "$B" "$N" "$CADDYFILE" "$B" "$N" "$BACKUP_DIR"
}

show_status() {
  step "Status"
  printf '  Caddy:    %s (%s)\n' "$(systemctl is-active caddy 2>/dev/null || true)" "$(caddy version 2>/dev/null | awk '{print $1}')"
  printf '  Domain(s): %s\n' "$DOMAINS"
  show_routes
  echo
}

# ───────────────────────────── Flows ─────────────────────────────
deploy() {
  step "Preparing the server"
  check_dns
  free_ports
  install_caddy
  open_firewall
  setup_fallback
  step "Applying configuration"
  apply_config || die "Deployment aborted. Nothing was changed on the running service."
  save_state
  verify_https
  summary
}

reapply() {
  step "Applying configuration"
  apply_config || die "Aborted. Previous configuration is still active."
  save_state
  summary
}

menu() {
  local choice
  while true; do
    printf '\n  %s1)%s Add location(s)\n' "$B" "$N"
    printf '  %s2)%s Remove a location\n' "$B" "$N"
    printf '  %s3)%s Full reconfigure (domain, ports, camouflage…)\n' "$B" "$N"
    printf '  %s4)%s Show status\n' "$B" "$N"
    printf '  %s5)%s Quit\n\n' "$B" "$N"
    choice="$(ask "Choose" "1")"
    case "$choice" in
      1) step "Add locations"; show_routes; echo; prompt_locations; reapply; return 0 ;;
      2) step "Remove a location"; remove_location; reapply; return 0 ;;
      3) step "Full reconfigure"; gather_full; deploy; return 0 ;;
      4) show_status ;;
      5|q|Q) exit 0 ;;
      *) err "Pick 1-5." ;;
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

  if [[ -f "$LEGACY_STATE" ]]; then
    info "Found a previous nginx setup."
    if confirm "Import its domain and locations?" "y"; then
      import_legacy
      ok "Imported ${#LOC_PATHS[@]} location(s)."
    fi
  fi
  gather_full
  deploy
}

main "$@"
