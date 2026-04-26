#!/usr/bin/env bash
# tools/tunnel-tui.sh — whiptail-based control panel for the tunnel server.
# Designed to run over SSH on the Digital Ocean droplet that hosts
# shopthelook.page + the v2ray/ssh/dropbear/stunnel4/ws-ssh tunnel stack.
#
# Launch:
#   sudo tunnel-tui              (after `server-install.sh install` symlinks it)
#   sudo bash tools/tunnel-tui.sh
#
# Required: whiptail (Ubuntu: `apt install whiptail`), jq, qrencode.
# server-install.sh installs all three.

set -uo pipefail

# --------------------------------------------------------------- constants --
DOMAIN="${TUNNEL_DOMAIN:-shopthelook.page}"
V2RAY_CFG="${V2RAY_CFG:-/usr/local/etc/v2ray/config.json}"
RELEASES_DIR="${RELEASES_DIR:-/var/www/sni-hunter/releases}"
NGINX_ACCESS_LOG="${NGINX_ACCESS_LOG:-/var/log/nginx/access.log}"
NGINX_ERROR_LOG="${NGINX_ERROR_LOG:-/var/log/nginx/error.log}"
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"
V2RAY_LOG="${V2RAY_LOG:-/var/log/v2ray/access.log}"

# WS path conventions from the existing nginx config.
WS_BRIDGE_PATH="/ws-bridge-x9k2"
VMESS_PATH="/vmess-x9k2"
VLESS_PATH="/vless-x9k2"

TITLE="Tunnel Control Panel  ·  ${DOMAIN}"

# ---------------------------------------------------------------- helpers --
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    whiptail --title "Permission" --msgbox "This panel needs root. Re-run with sudo." 8 50
    exit 1
  fi
}

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "Missing required command: $c" >&2
      echo "Install with: apt install -y whiptail jq qrencode" >&2
      exit 1
    }
  done
}

is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Extracts VMESS_UUID and VLESS_UUID from v2ray config into the caller's env.
get_v2ray_uuids() {
  VMESS_UUID=""; VLESS_UUID=""
  [ -r "$V2RAY_CFG" ] || return 0
  command -v jq >/dev/null || return 0
  VMESS_UUID="$(jq -r '.. | objects | select(.protocol=="vmess") | .settings.clients[0].id' "$V2RAY_CFG" 2>/dev/null | head -n1)"
  VLESS_UUID="$(jq -r '.. | objects | select(.protocol=="vless") | .settings.clients[0].id' "$V2RAY_CFG" 2>/dev/null | head -n1)"
  [ "$VMESS_UUID" = "null" ] && VMESS_UUID=""
  [ "$VLESS_UUID" = "null" ] && VLESS_UUID=""
}

# Build vmess:// share URI from $1=uuid (uses module-scope $DOMAIN/$VMESS_PATH)
build_vmess_uri() {
  local uuid="$1"
  local v_json
  v_json="$(jq -nc --arg add "$DOMAIN" --arg id "$uuid" --arg path "$VMESS_PATH" \
    '{v:"2",ps:"tunnel",add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$add,path:$path,tls:"tls",sni:$add}')"
  printf 'vmess://%s' "$(printf '%s' "$v_json" | base64 -w0)"
}

# Build vless:// share URI from $1=uuid
build_vless_uri() {
  local uuid="$1" path_enc
  path_enc="$(printf '%s' "$VLESS_PATH" | jq -sRr @uri)"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#tunnel' \
    "$uuid" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$path_enc"
}

# Build the standard HTTP-Custom WS upgrade payload for /ws-bridge-x9k2
build_ssh_payload() {
  printf 'GET %s HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]User-Agent: Mozilla/5.0[crlf][crlf]' \
    "$WS_BRIDGE_PATH" "$DOMAIN"
}

# Render text in $1 inside a scrollable textbox; auto-sized.
show_text() {
  local title="$1" body="$2"
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$body" > "$tmp"
  whiptail --title "$title" --scrolltext --textbox "$tmp" 24 90
  rm -f "$tmp"
}

# ------------------------------------------------------------ status pane --
action_status() {
  local out=""
  out+="=== Service status ===\n"
  for svc in nginx ssh dropbear stunnel4 v2ray ws-ssh sni-hunter-api openvpn; do
    if is_active "$svc"; then
      out+=$(printf '  %-16s : active\n' "$svc")$'\n'
    elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      out+=$(printf '  %-16s : INACTIVE\n' "$svc")$'\n'
    else
      out+=$(printf '  %-16s : not installed\n' "$svc")$'\n'
    fi
  done

  out+="\n=== Listening sockets ===\n"
  out+="$(ss -tlnp 2>/dev/null | awk 'NR==1 || /:(22|443|445|8090|8888|10000|10001)\s/' | sed 's/^/  /')\n"

  out+="\n=== Active SSH sessions ===\n"
  if command -v who >/dev/null; then
    out+="$(who | sed 's/^/  /')\n"
  fi
  out+="  (also dropbear via :445 / stunnel via :10000-10001)\n"

  out+="\n=== Disk / memory ===\n"
  out+="$(df -h / | sed 's/^/  /')\n"
  out+="$(free -h | sed 's/^/  /')\n"

  out+="\n=== Public reachability ===\n"
  out+="  https://${DOMAIN}/                 → HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/")\n"
  out+="  https://${DOMAIN}/sni-hunter/api/releases → HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://${DOMAIN}/sni-hunter/api/releases")\n"

  show_text "Status & health" "$out"
}

# ----------------------------------------------------- connection info pane
# Pulls UUIDs from /usr/local/etc/v2ray/config.json. Builds vmess:// and
# vless:// share URIs and renders a QR for the chosen one.
action_connection() {
  if [ ! -r "$V2RAY_CFG" ]; then
    whiptail --msgbox "v2ray config not readable at $V2RAY_CFG" 8 60
    return
  fi
  get_v2ray_uuids
  local vmess_uuid="$VMESS_UUID" vless_uuid="$VLESS_UUID"

  local choice
  choice="$(whiptail --title "Connection info" --menu "Pick a config to display + QR:" 16 70 6 \
              "vmess"  "VMess over WS+TLS  (UUID: ${vmess_uuid:-<none>})" \
              "vless"  "VLESS over WS+TLS  (UUID: ${vless_uuid:-<none>})" \
              "ssh-ws" "SSH over WS bridge ${WS_BRIDGE_PATH}" \
              "raw"    "Raw connection details (no QR)" \
              3>&1 1>&2 2>&3)" || return

  local body="" share=""
  case "$choice" in
    vmess)
      [ -n "$vmess_uuid" ] || { whiptail --msgbox "No VMess client found in v2ray config." 8 50; return; }
      local v_json
      v_json="$(jq -nc --arg add "$DOMAIN" --arg id "$vmess_uuid" --arg path "$VMESS_PATH" \
        '{v:"2",ps:"tunnel",add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$add,path:$path,tls:"tls",sni:$add}')"
      share="vmess://$(printf '%s' "$v_json" | base64 -w0)"
      body="VMess (v2rayN / v2rayNG / Nekoray):\n  Address : ${DOMAIN}\n  Port    : 443\n  UUID    : ${vmess_uuid}\n  AlterId : 0\n  Network : ws\n  Path    : ${VMESS_PATH}\n  Host    : ${DOMAIN}\n  TLS     : on (SNI=${DOMAIN})\n\nShare URI:\n${share}\n";;
    vless)
      [ -n "$vless_uuid" ] || { whiptail --msgbox "No VLESS client found in v2ray config." 8 50; return; }
      share="vless://${vless_uuid}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=$(printf '%s' "$VLESS_PATH" | jq -sRr @uri)#tunnel"
      body="VLESS (v2rayN / v2rayNG / Nekoray):\n  Address    : ${DOMAIN}\n  Port       : 443\n  UUID       : ${vless_uuid}\n  Network    : ws\n  Path       : ${VLESS_PATH}\n  Host       : ${DOMAIN}\n  TLS        : on (SNI=${DOMAIN})\n  Encryption : none\n\nShare URI:\n${share}\n";;
    ssh-ws)
      body="SSH over WebSocket bridge\n  Outer URL  : wss://${DOMAIN}${WS_BRIDGE_PATH}\n  Inner SSH  : 127.0.0.1:22 (handled by ws-ssh-bridge.py)\n  Use with   : HTTP-Injector / KPN-Tunnel / NPV-Tunnel custom payload\n\nExample payload (HTTP/1.1 GET upgrade):\n  GET ${WS_BRIDGE_PATH} HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]\n\nDirect SSH-over-TLS alternatives on this server:\n  stunnel  : ${DOMAIN}:10000 → ssh:22\n  stunnel  : ${DOMAIN}:10001 → dropbear:445\n  dropbear : ${DOMAIN}:445   (plain)\n";;
    raw)
      body="Raw tunnel surface for ${DOMAIN}\n\n  ssh           tcp/22\n  dropbear      tcp/445\n  stunnel→ssh   tcp/10000  (TLS-wrapped)\n  stunnel→dbr   tcp/10001  (TLS-wrapped)\n  v2ray vmess   wss/443${VMESS_PATH}\n  v2ray vless   wss/443${VLESS_PATH}\n  ws-ssh        wss/443${WS_BRIDGE_PATH}\n  https         tcp/443    (nginx terminates TLS for shopthelook.page)\n\nVMess UUID : ${vmess_uuid:-<none>}\nVLESS UUID : ${vless_uuid:-<none>}\n";;
  esac

  if [ -n "$share" ] && command -v qrencode >/dev/null; then
    local qr; qr="$(qrencode -t ANSIUTF8 -- "$share" 2>/dev/null || true)"
    body="${body}\n${qr}"
  fi

  show_text "Connection · ${choice}" "$(printf '%b' "$body")"
}

# ---------------------------------------------------- ssh user management --
action_users() {
  local sub
  sub="$(whiptail --title "SSH users" --menu "Pick action:" 14 60 4 \
          "list"   "List tunnel users + expiry dates" \
          "add"    "Add a new SSH/dropbear user (with expiry)" \
          "remove" "Remove an SSH user" \
          "passwd" "Reset password for a user" \
          3>&1 1>&2 2>&3)" || return

  case "$sub" in
    list)
      local body="UID/Login/Expiry (only normal users with /home dirs)\n\n"
      while IFS=: read -r u _ uid _ _ home shell; do
        [ "$uid" -ge 1000 ] || continue
        [ "$uid" -lt 65000 ] || continue
        [ -d "$home" ] || continue
        local exp; exp="$(chage -l "$u" 2>/dev/null | awk -F: '/Account expires/ {print $2}' | xargs)"
        body+=$(printf '  %-20s uid=%-5s expiry=%s shell=%s\n' "$u" "$uid" "${exp:-never}" "$shell")$'\n'
      done < /etc/passwd
      show_text "SSH users" "$body";;
    add)
      local user pass days
      user="$(whiptail --inputbox "New username (lowercase, no spaces):" 8 50 3>&1 1>&2 2>&3)" || return
      [[ "$user" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || { whiptail --msgbox "Invalid username." 7 40; return; }
      id "$user" >/dev/null 2>&1 && { whiptail --msgbox "User '$user' already exists." 7 50; return; }
      pass="$(whiptail --passwordbox "Password for $user:" 8 50 3>&1 1>&2 2>&3)" || return
      [ ${#pass} -ge 6 ] || { whiptail --msgbox "Password must be at least 6 chars." 7 50; return; }
      days="$(whiptail --inputbox "Expire in how many days? (1-365, blank=never)" 8 50 "30" 3>&1 1>&2 2>&3)" || return
      useradd -m -s /bin/false "$user" || { whiptail --msgbox "useradd failed" 7 40; return; }
      echo "${user}:${pass}" | chpasswd
      if [ -n "$days" ] && [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ] && [ "$days" -le 365 ]; then
        local exp_date; exp_date="$(date -d "+${days} days" +%Y-%m-%d)"
        chage -E "$exp_date" "$user"
        whiptail --msgbox "User '$user' created. Expires ${exp_date}.\nShell is /bin/false (tunnel-only).\nWorks for ssh:22, dropbear:445, stunnel:10000-10001." 11 70
      else
        whiptail --msgbox "User '$user' created with no expiry.\nShell is /bin/false (tunnel-only)." 9 60
      fi;;
    remove)
      local user
      user="$(whiptail --inputbox "Username to remove:" 8 50 3>&1 1>&2 2>&3)" || return
      id "$user" >/dev/null 2>&1 || { whiptail --msgbox "No such user." 7 40; return; }
      local uid; uid="$(id -u "$user")"
      [ "$uid" -ge 1000 ] || { whiptail --msgbox "Refusing to remove system user (uid=$uid)." 7 60; return; }
      whiptail --yesno "Really delete '$user' and their home directory?" 8 60 || return
      pkill -KILL -u "$user" 2>/dev/null || true
      userdel -r "$user" 2>/dev/null && whiptail --msgbox "Deleted '$user'." 7 40 || whiptail --msgbox "userdel failed." 7 40;;
    passwd)
      local user pass
      user="$(whiptail --inputbox "Username:" 8 50 3>&1 1>&2 2>&3)" || return
      id "$user" >/dev/null 2>&1 || { whiptail --msgbox "No such user." 7 40; return; }
      pass="$(whiptail --passwordbox "New password for $user:" 8 50 3>&1 1>&2 2>&3)" || return
      [ ${#pass} -ge 6 ] || { whiptail --msgbox "Password must be at least 6 chars." 7 50; return; }
      echo "${user}:${pass}" | chpasswd && whiptail --msgbox "Password updated for '$user'." 7 50;;
  esac
}

# ----------------------------------------------------------- log viewer ---
action_logs() {
  local choice
  choice="$(whiptail --title "Live logs (Ctrl-C to quit tail)" --menu "Pick a log:" 16 60 6 \
          "nginx-access" "$NGINX_ACCESS_LOG" \
          "nginx-error"  "$NGINX_ERROR_LOG" \
          "auth"         "$AUTH_LOG (ssh/sudo)" \
          "v2ray"        "$V2RAY_LOG" \
          "sni-api"      "journalctl -u sni-hunter-api" \
          "ws-ssh"       "journalctl -u ws-ssh" \
          3>&1 1>&2 2>&3)" || return

  clear
  case "$choice" in
    nginx-access) tail -F "$NGINX_ACCESS_LOG" 2>/dev/null;;
    nginx-error)  tail -F "$NGINX_ERROR_LOG"  2>/dev/null;;
    auth)         tail -F "$AUTH_LOG"         2>/dev/null;;
    v2ray)        tail -F "$V2RAY_LOG"        2>/dev/null;;
    sni-api)      journalctl -u sni-hunter-api -f --no-pager;;
    ws-ssh)       journalctl -u ws-ssh        -f --no-pager;;
  esac
  echo; read -rp "Press Enter to return to menu..." _
}

# ------------------------------------------------------- restart services -
action_restart() {
  local svc
  svc="$(whiptail --title "Restart a service" --menu "Pick service:" 16 50 7 \
          "nginx"          "" \
          "ssh"            "" \
          "dropbear"       "" \
          "stunnel4"       "" \
          "v2ray"          "" \
          "ws-ssh"         "" \
          "sni-hunter-api" "" \
          3>&1 1>&2 2>&3)" || return

  whiptail --yesno "Restart '$svc' now?" 7 50 || return
  if systemctl restart "$svc" 2>&1; then
    sleep 1
    if is_active "$svc"; then
      whiptail --msgbox "$svc restarted and active." 7 50
    else
      whiptail --msgbox "$svc restarted but is NOT active.\nCheck: journalctl -u $svc -n 30" 9 60
    fi
  else
    whiptail --msgbox "Restart failed for $svc." 7 40
  fi
}

# ---------------------------------------------------------- sni hunter ----
action_sni_hunt() {
  local script="${SNI_HUNTER_SCRIPT:-/opt/sni-hunter-src/tools/sni-hunter.sh}"
  if [ ! -f "$script" ]; then
    whiptail --msgbox "SNI hunter script not found at:\n  $script\n\nPull the repo to /opt/sni-hunter-src or export SNI_HUNTER_SCRIPT." 11 70
    return
  fi
  local sub
  sub="$(whiptail --title "SNI hunter" --menu "Pick action:" 16 70 5 \
          "hunt"        "Full hunt (auto refresh-corpus if missing)" \
          "seed-only"   "Fast scan (~80 built-in seeds, ~2 min)" \
          "tunnel-test" "Test ssh+vmess+vless tunnel surface (auto-UUIDs)" \
          "self-test"   "Run sni-hunter --self-test (no network)" \
          "help"        "Show sni-hunter --help" \
          3>&1 1>&2 2>&3)" || return
  clear
  local out_dir="/tmp/sni-hunter-tui"
  mkdir -p "$out_dir"
  get_v2ray_uuids
  local uuid_args=()
  [ -n "$VMESS_UUID" ] && uuid_args+=(--uuid-vmess "$VMESS_UUID")
  [ -n "$VLESS_UUID" ] && uuid_args+=(--uuid-vless "$VLESS_UUID")
  case "$sub" in
    hunt)
      if [ ! -s /var/lib/sni-hunter/corpus.txt ]; then
        echo "[bootstrap] no corpus yet — running refresh-corpus first..."
        bash "$script" refresh-corpus 2>&1 | tail -n 20
        echo
      fi
      echo "Running: bash $script hunt --out $out_dir ${uuid_args[*]}"
      echo "(this can take several minutes; Ctrl-C to abort)"
      echo
      bash "$script" hunt --out "$out_dir" "${uuid_args[@]}" 2>&1 | tail -n 400
      echo; echo "=== passing.txt ==="; cat "$out_dir/passing.txt" 2>/dev/null || echo "(none)" ;;
    seed-only)
      echo "Running: bash $script hunt --seed-only --out $out_dir ${uuid_args[*]}"
      echo
      bash "$script" hunt --seed-only --out "$out_dir" "${uuid_args[@]}" 2>&1 | tail -n 200
      echo; echo "=== passing.txt ==="; cat "$out_dir/passing.txt" 2>/dev/null || echo "(none)" ;;
    tunnel-test)
      echo "Running: bash $script tunnel-test ${uuid_args[*]}"
      echo
      bash "$script" tunnel-test "${uuid_args[@]}" 2>&1 | tail -n 200 ;;
    self-test)   bash "$script" self-test 2>&1 | tail -n 200 ;;
    help)        bash "$script" --help 2>&1 | tail -n 200 ;;
  esac
  echo
  read -rp "Press Enter to return to menu..." _
}

# ----------------------------------------- update from GitHub ------------
action_update() {
  clear
  echo "=== Pulling latest from GitHub and redeploying (idempotent) ==="
  echo
  bash /opt/sni-hunter-src/tools/server-install.sh update 2>&1 | tail -n 200
  echo
  echo "------------------------------------------------------------------"
  echo "  Done. EXIT and re-launch  sudo tunnel-tui  to load any new TUI"
  echo "  code. Service restarts (sni-hunter-api / nginx) already done."
  echo "------------------------------------------------------------------"
  read -rp "Press Enter to return..." _
}

# ------------------------------------------ run hardening pass -----------
action_harden() {
  whiptail --yesno \
"Run the hardening pass?\n\nWill install / configure:\n  - unattended-upgrades (security patches)\n  - ufw (default deny + allow 22/80/443/445/10000/10001)\n  - fail2ban (sshd + nginx jails)\n  - sysctl (BBR + syncookies + martians)\n  - sshd hardening drop-in (LoginGrace, MaxAuth, ClientAlive)\n  - 'tunnel' group + per-user limits.conf caps\n\nSafe to re-run. Will NOT disable password auth or root login\n(those are manual opt-in steps to avoid lock-outs)." 20 72 || return
  clear
  bash /opt/sni-hunter-src/tools/server-harden.sh 2>&1 | tail -n 400
  echo
  read -rp "Press Enter to return..." _
}

# ----------------------------------- generate user + payload card --------
# Creates an SSH tunnel user (with expiry) and writes a printable text card
# to /root/cards/<user>.txt containing: credentials, HTTP-Custom payload,
# vmess:// + vless:// share URIs, and ANSI QR codes for both.
action_generate_card() {
  local user pass days plan
  user="$(whiptail --inputbox "Customer username (lowercase, no spaces):" 8 60 3>&1 1>&2 2>&3)" || return
  [[ "$user" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || { whiptail --msgbox "Invalid username." 7 40; return; }
  if id "$user" >/dev/null 2>&1; then
    whiptail --yesno "User '$user' already exists. Re-issue card with EXISTING credentials?\n(Pick No to abort, then Remove first.)" 10 70 || return
    pass=""  # cannot recover hash; warn user
  else
    pass="$(whiptail --passwordbox "Password (min 6 chars; will be shown on the card):" 8 60 3>&1 1>&2 2>&3)" || return
    [ ${#pass} -ge 6 ] || { whiptail --msgbox "Password must be at least 6 chars." 7 50; return; }
    days="$(whiptail --inputbox "Expiry in days (1-365):" 8 50 "30" 3>&1 1>&2 2>&3)" || return
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] && [ "$days" -le 365 ] || { whiptail --msgbox "Bad expiry." 7 40; return; }
    plan="$(whiptail --inputbox "Plan label (free text, e.g. 'Monthly Unlimited'):" 8 60 "Monthly" 3>&1 1>&2 2>&3)" || plan="Plan"
    useradd -m -s /bin/false "$user" || { whiptail --msgbox "useradd failed" 7 40; return; }
    echo "${user}:${pass}" | chpasswd
    chage -E "$(date -d "+${days} days" +%Y-%m-%d)" "$user"
  fi

  local exp_date; exp_date="$(chage -l "$user" 2>/dev/null | awk -F: '/Account expires/ {print $2}' | xargs)"
  get_v2ray_uuids
  local vmess_share="" vless_share="" vmess_qr="" vless_qr=""
  if [ -n "$VMESS_UUID" ]; then
    vmess_share="$(build_vmess_uri "$VMESS_UUID")"
    command -v qrencode >/dev/null && vmess_qr="$(qrencode -t ANSIUTF8 -- "$vmess_share" 2>/dev/null)"
  fi
  if [ -n "$VLESS_UUID" ]; then
    vless_share="$(build_vless_uri "$VLESS_UUID")"
    command -v qrencode >/dev/null && vless_qr="$(qrencode -t ANSIUTF8 -- "$vless_share" 2>/dev/null)"
  fi
  local payload; payload="$(build_ssh_payload)"

  install -d -m 0700 /root/cards
  local out="/root/cards/${user}.txt"
  {
    echo "==============================================================="
    echo "  TUNNEL ACCESS CARD                  ${DOMAIN}"
    echo "==============================================================="
    echo "  Username     : ${user}"
    echo "  Password     : ${pass:-<unchanged — re-issue with old password>}"
    echo "  Plan         : ${plan:-Plan}"
    echo "  Expires      : ${exp_date:-never}"
    echo "  Issued       : $(date -u +%Y-%m-%dT%H:%MZ)"
    echo "---------------------------------------------------------------"
    echo "  PROFILE 1 — SSH over WebSocket+TLS  (HTTP Custom · SSH tab)"
    echo "---------------------------------------------------------------"
    echo "  ip:port@user:pass  ${DOMAIN}:443@${user}:${pass:-<password>}"
    echo "  Tick:              [Use Payload] [SSL] [Enable DNS]"
    echo "  Untick everything else (Enhanced/SlowDns/UDP/Psiphon/V2ray)"
    echo
    echo "  PAYLOAD (paste exactly, [crlf] is literal):"
    echo "  ${payload}"
    echo "  Remote Proxy: (leave empty)"
    echo "---------------------------------------------------------------"
    echo "  PROFILE 2 — V2Ray VMess  (HTTP Custom · SSH tab → V2ray)"
    echo "---------------------------------------------------------------"
    if [ -n "$vmess_share" ]; then
      echo "  Share URI (import or scan QR below):"
      echo "  ${vmess_share}"
      echo
      [ -n "$vmess_qr" ] && printf '%s\n' "$vmess_qr"
    else
      echo "  (no VMess client configured in v2ray)"
    fi
    echo "---------------------------------------------------------------"
    echo "  PROFILE 3 — V2Ray VLESS"
    echo "---------------------------------------------------------------"
    if [ -n "$vless_share" ]; then
      echo "  Share URI (import or scan QR below):"
      echo "  ${vless_share}"
      echo
      [ -n "$vless_qr" ] && printf '%s\n' "$vless_qr"
    else
      echo "  (no VLESS client configured in v2ray)"
    fi
    echo "---------------------------------------------------------------"
    echo "  PROFILE 4 — Direct SSH (PuTTY / Termius / OpenSSH)"
    echo "---------------------------------------------------------------"
    echo "  Host : ${DOMAIN}    Port: 22  (or 445 dropbear, 10000 stunnel)"
    echo "  User : ${user}      Pass: ${pass:-<password>}"
    echo "---------------------------------------------------------------"
    echo "  PROFILE 5 — CARRIER BYPASS payloads (HTTP Custom · SSH tab)"
    echo "  All three: ip:port = ${DOMAIN}:443, tick [Use Payload][SSL][DNS]"
    echo "---------------------------------------------------------------"
    echo
    echo "  ── 5A · TELKOM Unliminet (SNI=myaccount.telkom.co.ke) ──"
    echo "  SNI / Inject Host: myaccount.telkom.co.ke"
    echo "  Payload (single line, [crlf] is literal):"
    echo "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host: myaccount.telkom.co.ke[crlf]Expect: 100-continue[crlf][crlf][split][crlf][crlf]GET /cdn-cgi/ws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf][crlf]"
    echo
    echo "  ── 5B · SAFARICOM (SNI=mzstatic.com) ──"
    echo "  SNI / Inject Host: mzstatic.com"
    echo "  Payload:"
    echo "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host: mzstatic.com[crlf][crlf][split][crlf][crlf]GET /pop HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf][crlf]"
    echo
    echo "  ── 5C · AIRTEL (SNI=mobile.facebook.com) ──"
    echo "  SNI / Inject Host: mobile.facebook.com"
    echo "  Payload:"
    echo "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host: mobile.facebook.com[crlf][crlf][split][crlf][crlf]GET /ws-bridge-x9k2 HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf][crlf]"
    echo
    echo "==============================================================="
    echo "  How carrier bypasses work against THIS server:"
    echo "    1. Carrier sees TLS ClientHello with the spoofed SNI above"
    echo "       and rates the connection as free (whitelisted host)."
    echo "    2. Inside TLS our nginx serves the default cert; tunnel"
    echo "       client doesn't verify cert → handshake completes."
    echo "    3. /cdn-cgi/trace returns a real 200 (decoy for DPI)."
    echo "    4. After [split] the WS upgrade hits /cdn-cgi/ws or /pop"
    echo "       which proxy to ws-ssh-bridge → SSH on 127.0.0.1:22."
    echo
    echo "  If a carrier blocks all three SNIs above, run on the server:"
    echo "    sudo tunnel-tui → 6 → seed-only"
    echo "  then swap the SNI/Inject Host with any line from passing.txt"
    echo "==============================================================="
  } > "$out"
  chmod 0600 "$out"

  show_text "Card · ${user}  →  ${out}" "$(cat "$out")"
  whiptail --msgbox "Card saved to ${out}\n(0600, root-only)\n\nWhatsApp / email it to the customer." 10 70
}

# ----------------------------------------------------------- releases -----
action_releases() {
  local body=""
  if [ -d "$RELEASES_DIR" ]; then
    body+="Releases on disk (${RELEASES_DIR}):\n"
    body+="$(ls -lh "$RELEASES_DIR" 2>/dev/null | sed 's/^/  /')\n"
  else
    body+="(no releases directory at ${RELEASES_DIR})\n"
  fi
  body+="\nManifest from API:\n"
  body+="$(curl -sk "https://${DOMAIN}/sni-hunter/api/releases" | sed 's/^/  /')\n"
  show_text "Releases" "$body"
}

# --------------------------------------------------------------- main loop
main() {
  need_cmd whiptail
  need_root
  command -v jq       >/dev/null || whiptail --msgbox "jq not installed — connection-info UUIDs will not parse.\nInstall: apt install -y jq" 9 60
  command -v qrencode >/dev/null || true   # QR is optional; degrade silently

  while true; do
    local choice
    choice="$(whiptail --title "$TITLE" --menu "" 22 72 13 \
            "1"  "Status & health" \
            "2"  "Connection info (vmess/vless/ssh-ws + QR)" \
            "3"  "SSH user management" \
            "4"  "Live logs" \
            "5"  "Restart a service" \
            "6"  "Run SNI hunter scan" \
            "7"  "SNI Hunter releases" \
            "8"  "Generate user + payload card (for customers)" \
            "9"  "Update from GitHub (git pull + redeploy)" \
            "10" "Run hardening pass (ufw + fail2ban + sysctl + sshd)" \
            "0"  "Exit" \
            3>&1 1>&2 2>&3)" || break

    case "$choice" in
      1)  action_status;;
      2)  action_connection;;
      3)  action_users;;
      4)  action_logs;;
      5)  action_restart;;
      6)  action_sni_hunt;;
      7)  action_releases;;
      8)  action_generate_card;;
      9)  action_update;;
      10) action_harden;;
      0|"") break;;
    esac
  done
  clear
}

main
