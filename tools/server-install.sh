#!/usr/bin/env bash
# tools/server-install.sh — idempotent installer for the SNI Hunter download
# surface (api-server + /dl/) on the same Digital Ocean droplet that already
# runs shopthelook.page and the universal tunnel stack (nginx + ssh + dropbear
# + stunnel4 + v2ray + ws-ssh bridge).
#
# What this script does NOT do:
#   - It will *not* reconfigure your existing tunnel stack. Those services
#     (ssh:22, dropbear:445, stunnel4:10000/10001, v2ray, ws-ssh:8888) and
#     the nginx WS proxy paths (/ws-bridge-x9k2, /vmess-x9k2, /vless-x9k2)
#     are detected read-only and left untouched.
#   - It will *not* overwrite your shopthelook (Velour) api-server. The SNI
#     Hunter releases endpoint mounts under a distinct prefix so the two
#     coexist behind one nginx.
#
# What it DOES do:
#   1. install  — install Node.js (if missing), drop the SNI Hunter
#      api-server bundle under /opt/sni-hunter, register a hardened
#      systemd unit on 127.0.0.1:8090, append a `location /sni-hunter/`
#      block to the shopthelook nginx vhost (idempotent), and reload.
#   2. check    — print the same diagnostic banner you already get from
#      your repair scripts, plus the SNI Hunter side.
#   3. add-release <file> [<file>...]
#               — copy a built artifact (.AppImage / .deb / .apk) into
#      $RELEASES_DIR with a .sha256 sidecar so /api/releases/latest
#      surfaces it.
#   4. uninstall — remove the systemd unit and nginx snippet (does NOT
#      touch your tunnel stack).
#
# Usage:
#   sudo bash tools/server-install.sh install [--domain shopthelook.page] \
#                                             [--port 8090] \
#                                             [--prefix /sni-hunter] \
#                                             [--releases-dir /var/www/sni-hunter/releases] \
#                                             [--bundle /path/to/api-server-dist.tar.gz]
#   sudo bash tools/server-install.sh check
#   sudo bash tools/server-install.sh add-release ./SNIHunter-0.4.0.AppImage
#   sudo bash tools/server-install.sh uninstall

set -euo pipefail

# ---------------------------------------------------------------- defaults --
DOMAIN="${SNI_HUNTER_DOMAIN:-shopthelook.page}"
PORT="${SNI_HUNTER_PORT:-8090}"
PREFIX="${SNI_HUNTER_PREFIX:-/sni-hunter}"     # nginx location prefix
RELEASES_DIR="${SNI_HUNTER_RELEASES_DIR:-/var/www/sni-hunter/releases}"
INSTALL_DIR="/opt/sni-hunter"
SERVICE_NAME="sni-hunter-api"
NGINX_SITE="/etc/nginx/sites-enabled/${DOMAIN}"
NGINX_SNIPPET="/etc/nginx/snippets/sni-hunter.conf"
BUNDLE=""                                       # optional pre-built tarball

# ----------------------------------------------------------------- helpers --
c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$*"; }

log()  { printf '  %s %s\n' "$(c_green '➜')"  "$*"; }
warn() { printf '  %s %s\n' "$(c_yellow '⚠')" "$*"; }
die()  { printf '  %s %s\n' "$(c_red '✘')"     "$*" >&2; exit 1; }
hdr()  { printf '\n%s\n' "$(c_green "=== $* ===")"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $*)"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Parse flags shared by all sub-commands.
parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)        DOMAIN="$2";        shift 2;;
      --port)          PORT="$2";          shift 2;;
      --prefix)        PREFIX="$2";        shift 2;;
      --releases-dir)  RELEASES_DIR="$2";  shift 2;;
      --bundle)        BUNDLE="$2";        shift 2;;
      -h|--help)       usage; exit 0;;
      --)              shift; break;;
      -*)              die "unknown flag: $1";;
      *)               POSITIONAL+=("$1"); shift;;
    esac
  done
  NGINX_SITE="/etc/nginx/sites-enabled/${DOMAIN}"
}

usage() {
  sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# -------------------------------------------- detect existing tunnel stack --
detect_tunnel_stack() {
  hdr "Existing tunnel stack (read-only probe)"
  for svc in nginx ssh dropbear stunnel4 v2ray ws-ssh openvpn; do
    if is_active "$svc"; then
      printf '  %-12s : %s\n' "$svc" "$(c_green active)"
    elif systemctl list-unit-files | grep -q "^${svc}\.service"; then
      printf '  %-12s : %s\n' "$svc" "$(c_yellow inactive)"
    else
      printf '  %-12s : %s\n' "$svc" "$(c_dim 'not installed')"
    fi
  done

  hdr "Listening sockets"
  ss -tlnp 2>/dev/null | awk 'NR==1 || /:(22|443|445|8888|10000|10001|'"${PORT}"')\s/' || true

  hdr "WebSocket handshakes (expect HTTP/1.1 101)"
  for path in /ws-bridge-x9k2 /vmess-x9k2 /vless-x9k2 "${PREFIX}/api/releases"; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' \
              -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
              -H 'Sec-WebSocket-Version: 13' \
              -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
              "https://${DOMAIN}${path}" 2>/dev/null || true)"
    [ -n "${code}" ] || code="ERR"
    printf '  %-30s → HTTP %s\n' "${path}" "${code}"
  done

  hdr "Website reachability"
  printf '  %s → HTTP %s\n' "${DOMAIN}" \
    "$(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/")"
}

# ---------------------------------------------- install Node.js if missing --
ensure_node() {
  if have_cmd node && node -v | grep -qE '^v(18|20|22|24)\.'; then
    log "Node.js $(node -v) already present"
    return
  fi
  log "Installing Node.js 20.x via NodeSource"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
}

# ------------------------------- install or update the api-server bundle --
install_bundle() {
  # Wipe any stale install dir from previous attempts so old dist/ files
  # cannot be picked up by an out-of-date systemd unit.
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  # Ship the tiny zero-dependency releases server. The full velour api-server
  # in artifacts/ requires DATABASE_URL et al and is unrelated to the
  # download surface, so we deliberately do NOT use it here.
  local src="$(dirname "$0")/releases-server.mjs"
  [ -f "$src" ] || die "missing tools/releases-server.mjs (re-pull the repo)"
  log "Installing releases-server.mjs to ${INSTALL_DIR}/"
  install -m 0644 "$src" "${INSTALL_DIR}/releases-server.mjs"

  # Persistent release artifacts live outside INSTALL_DIR so re-installs
  # don't blow them away.
  mkdir -p "${RELEASES_DIR}"
  chown -R www-data:www-data "${RELEASES_DIR}" || true
  chmod 755 "${RELEASES_DIR}"
}

# ---------------------------------------- write the hardened systemd unit --
install_systemd() {
  local entry="${INSTALL_DIR}/releases-server.mjs"
  [ -f "${entry}" ] || die "missing entrypoint: ${entry}"

  log "Writing /etc/systemd/system/${SERVICE_NAME}.service"
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SNI Hunter download/release api-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
Environment=HOST=127.0.0.1
Environment=RELEASES_DIR=${RELEASES_DIR}
Environment=RELEASES_PUBLIC_BASE_URL=https://${DOMAIN}${PREFIX}
ExecStart=/usr/bin/node ${entry}
Restart=on-failure
RestartSec=2

# --- hardening (no root, no surprises) ---
DynamicUser=yes
ReadWritePaths=${RELEASES_DIR}
ReadOnlyPaths=${INSTALL_DIR}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
  systemctl enable --now "${SERVICE_NAME}"
  sleep 1
  is_active "${SERVICE_NAME}" \
    || die "service did not start; journalctl -u ${SERVICE_NAME} -n 50"
  log "${SERVICE_NAME} active on 127.0.0.1:${PORT}"
}

# ------------------------------------ append nginx location block (idempotent)
install_nginx_snippet() {
  # Honour an explicit override first.
  [ -z "${NGINX_SITE_OVERRIDE:-}" ] || NGINX_SITE="${NGINX_SITE_OVERRIDE}"
  # The vhost file is rarely named exactly after the domain. Auto-detect by
  # grepping for \`server_name <domain>\` across sites-enabled and conf.d.
  if [ ! -f "${NGINX_SITE}" ]; then
    local found
    found="$(grep -RlE "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN//./\\.}([[:space:]]|;)" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"
    if [ -n "${found}" ]; then
      log "Auto-detected nginx vhost for ${DOMAIN}: ${found}"
      NGINX_SITE="${found}"
    else
      hdr "Available nginx vhosts"
      ls -la /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sed 's/^/  /'
      die "could not find an nginx vhost containing 'server_name ${DOMAIN}'. Re-run with: NGINX_SITE_OVERRIDE=/etc/nginx/sites-enabled/<file> $0 install"
    fi
  fi
  [ -f "${NGINX_SITE}" ] || die "nginx site not found: ${NGINX_SITE}"

  log "Writing ${NGINX_SNIPPET}"
  # The /api routes go to the node process; /dl serves files directly off
  # disk so large downloads bypass node entirely.
  cat > "${NGINX_SNIPPET}" <<EOF
# SNI Hunter download surface — generated by tools/server-install.sh.
# Coexists with the shopthelook.page api-server; do not edit by hand.

location ${PREFIX}/api/ {
    proxy_pass http://127.0.0.1:${PORT}/api/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 30s;
}

location ${PREFIX}/dl/ {
    alias ${RELEASES_DIR}/;
    autoindex off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "public, max-age=300" always;
    types {
        application/octet-stream AppImage deb apk dmg exe msi;
        text/plain               sha256;
    }
    default_type application/octet-stream;
}
EOF

  # Insert `include snippets/sni-hunter.conf;` exactly once into the first
  # `server { ... listen 443 ... }` block of the site.
  if grep -q 'snippets/sni-hunter.conf' "${NGINX_SITE}"; then
    log "nginx site already includes snippet; leaving as-is"
  else
    log "Patching ${NGINX_SITE} to include the snippet"
    # Use a sentinel comment so re-runs are safe.
    awk -v inc="    include snippets/sni-hunter.conf; # added by sni-hunter" '
      BEGIN { added = 0 }
      { print }
      !added && /listen[[:space:]]+443/ { print inc; added = 1 }
    ' "${NGINX_SITE}" > "${NGINX_SITE}.new"
    mv "${NGINX_SITE}.new" "${NGINX_SITE}"
  fi

  log "nginx -t"
  nginx -t
  log "nginx -s reload"
  systemctl reload nginx
}

# --------------------------------------------------------- public commands --
cmd_install() {
  require_root
  hdr "SNI Hunter installer"
  log "Domain         : ${DOMAIN}"
  log "Local port     : ${PORT}"
  log "Public prefix  : https://${DOMAIN}${PREFIX}"
  log "Releases dir   : ${RELEASES_DIR}"

  detect_tunnel_stack
  ensure_node
  install_bundle
  install_systemd
  install_nginx_snippet

  hdr "Smoke test"
  local url="https://${DOMAIN}${PREFIX}/api/releases"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' "${url}")"
  if [ "${code}" = "200" ]; then
    log "$(c_green "${url} → HTTP 200")"
  else
    warn "${url} returned HTTP ${code} — check 'systemctl status ${SERVICE_NAME}' and nginx logs"
  fi

  hdr "Done"
  cat <<EOF
  Configure your desktop/Android client Settings → Tunnel server with:
    domain : ${DOMAIN}
    port   : 443
    ws     : /ws-bridge-x9k2  (already present)
    vmess  : /vmess-x9k2      (already present)
    vless  : /vless-x9k2      (already present)

  Drop new release artifacts with:
    sudo $0 add-release ./SNIHunter-0.4.0.AppImage

  Browse the manifest:
    curl https://${DOMAIN}${PREFIX}/api/releases | jq .
EOF
}

cmd_check() {
  detect_tunnel_stack
  hdr "SNI Hunter api-server"
  if is_active "${SERVICE_NAME}"; then
    log "${SERVICE_NAME}: $(c_green active) on 127.0.0.1:${PORT}"
  else
    warn "${SERVICE_NAME} not active — run \`sudo $0 install\`"
  fi
  if [ -d "${RELEASES_DIR}" ]; then
    log "Releases in ${RELEASES_DIR}:"
    ls -lh "${RELEASES_DIR}" | sed 's/^/    /'
  fi
}

cmd_add_release() {
  require_root
  [ ${#POSITIONAL[@]} -gt 0 ] || die "usage: add-release <file> [<file>...]"
  mkdir -p "${RELEASES_DIR}"
  for f in "${POSITIONAL[@]}"; do
    [ -f "$f" ] || { warn "skip (not a file): $f"; continue; }
    local base; base="$(basename "$f")"
    log "Installing release: ${base}"
    install -m 0644 "$f" "${RELEASES_DIR}/${base}"
    sha256sum "${RELEASES_DIR}/${base}" \
      | awk '{print $1}' > "${RELEASES_DIR}/${base}.sha256"
    chmod 0644 "${RELEASES_DIR}/${base}.sha256"
  done
  chown -R www-data:www-data "${RELEASES_DIR}" || true
  hdr "Latest manifest"
  curl -sk "https://${DOMAIN}${PREFIX}/api/releases/latest" | sed 's/^/  /'
  echo
}

cmd_uninstall() {
  require_root
  hdr "Uninstalling SNI Hunter download surface"
  warn "This does NOT touch your tunnel stack (ssh/dropbear/stunnel/v2ray/ws-ssh)."
  systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  rm -f "${NGINX_SNIPPET}"
  if [ -f "${NGINX_SITE}" ] && grep -q 'snippets/sni-hunter.conf' "${NGINX_SITE}"; then
    sed -i '/snippets\/sni-hunter\.conf/d' "${NGINX_SITE}"
    nginx -t && systemctl reload nginx
  fi
  log "Removed unit + nginx snippet. Bundle dir ${INSTALL_DIR} and releases at ${RELEASES_DIR} kept (delete by hand if you want them gone)."
}

# --------------------------------------------------------- argv dispatch --
[ $# -gt 0 ] || { usage; exit 1; }
SUB="$1"; shift || true
POSITIONAL=()
parse_flags "$@"
set -- "${POSITIONAL[@]:-}"

case "${SUB}" in
  install)        cmd_install;;
  check|status)   cmd_check;;
  add-release)    cmd_add_release;;
  uninstall)      cmd_uninstall;;
  -h|--help|help) usage;;
  *)              die "unknown sub-command: ${SUB} (try: install | check | add-release | uninstall)";;
esac
