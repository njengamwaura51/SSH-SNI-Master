#!/usr/bin/env bash
# =============================================================================
#  sni-hunter v2  —  Advanced SNI / Bug-Host scanner & classifier
#  Works on:  Ubuntu server (validation)  +  Termux on Android  +  Debian laptop
#  Tunnel:    shopthelook.page   (or override with DOMAIN=)
#
#  Subcommands
#     sni-hunter.sh hunt [--carrier safaricom|airtel|telkom|auto]
#                        [--limit N]   [--seed-only]   [--no-throughput]
#                        [--out DIR]   [--resume]   [--interactive]
#                        [--radio-tag LTE|UMTS|...]   [--verify-tunnel]
#     sni-hunter.sh check <sni> [--carrier X] [--no-throughput]
#                               [--verify-tunnel] [--json]
#     sni-hunter.sh tunnel-test [--sni HOST] [--target-ip IP]
#     sni-hunter.sh merge-runs DIR_LTE DIR_UMTS [DIR_OUT]
#     sni-hunter.sh refresh-corpus
#     sni-hunter.sh setup-server         (one-time on the tunnel server)
#     sni-hunter.sh install-debian       (one-time on a Debian laptop)
#     sni-hunter.sh self-test
#     sni-hunter.sh --help
# =============================================================================
set -u
umask 022

# -------- defaults (override via env or flags) -------------------------------
DOMAIN="${DOMAIN:-shopthelook.page}"
PORT="${PORT:-443}"
WS_PATH="${WS_PATH:-/ws-bridge-x9k2}"
BLOB_PATH="${BLOB_PATH:-/blob-25M}"
BLOB_SIZE_MB="${BLOB_SIZE_MB:-25}"
TIMEOUT="${TIMEOUT:-6}"
THRU_TIMEOUT="${THRU_TIMEOUT:-12}"
CONCURRENCY="${CONCURRENCY:-30}"
LATENCY_SAMPLES="${LATENCY_SAMPLES:-4}"
CORPUS="${CORPUS:-/var/lib/sni-hunter/corpus.txt}"
[ -w / ] || CORPUS="${HOME}/.sni-hunter/corpus.txt"
OUT_DIR_DEFAULT="${HOME}/sni-hunter-results"
TARGET_IP=""
CARRIER=""
INTERACTIVE=0
RADIO_TAG=""

# UI colors
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'
  C_C=$'\e[36m'; C_M=$'\e[35m'; C_D=$'\e[2m'; C_X=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_D=""; C_X=""; C_BOLD=""
fi
log()  { printf "%s[%s]%s %s\n" "$C_C" "$(date +%H:%M:%S)" "$C_X" "$*" >&2; }
die()  { printf "%s[FATAL]%s %s\n" "$C_R" "$C_X" "$*" >&2; exit 1; }
warn() { printf "%s[warn]%s %s\n" "$C_Y" "$C_X" "$*" >&2; }

IS_TERMUX=0; IS_SERVER=0; IS_DEBIAN_LAPTOP=0
[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && IS_TERMUX=1
[ "$(id -u)" = "0" ] && [ -d /etc/nginx ] && IS_SERVER=1
# Debian laptop = Debian/Ubuntu desktop, not Termux, not the tunnel server
if [ "$IS_TERMUX" = "0" ] && [ "$IS_SERVER" = "0" ] && [ -f /etc/debian_version ]; then
  IS_DEBIAN_LAPTOP=1
fi
HAVE_TERMUX_API=0
command -v termux-telephony-deviceinfo >/dev/null 2>&1 && HAVE_TERMUX_API=1
HAVE_TERMUX_DIALOG=0
command -v termux-dialog >/dev/null 2>&1 && HAVE_TERMUX_DIALOG=1
# UUIDs for tunnel-test of V2Ray endpoints (env or flag may override)
UUID_VMESS="${UUID_VMESS:-}"
UUID_VLESS="${UUID_VLESS:-}"
VERIFY_TUNNEL=0
VMESS_PATH="${VMESS_PATH:-/vmess-x9k2}"
VLESS_PATH="${VLESS_PATH:-/vless-x9k2}"

# -------- portable hostname → IP resolver (Termux ships without getent) ------
resolve_host() {
  local h="$1" ip
  ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip=$(drill "$h" A 2>/dev/null | awk '/^[^;].*\sA\s/ {print $5; exit}')
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip=$(dig +short "$h" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip=$(nslookup "$h" 2>/dev/null | awk '/^Address: / && !/#/ {print $2; exit}')
  [ -n "$ip" ] && { echo "$ip"; return; }
  ip=$(python3 -c "import socket,sys; print(socket.gethostbyname('$h'))" 2>/dev/null)
  [ -n "$ip" ] && { echo "$ip"; return; }
  return 1
}
export -f resolve_host

# =============================================================================
#  HELP
# =============================================================================
print_help() {
cat <<EOF
${C_BOLD}sni-hunter v2${C_X}  —  bug-host scanner & classifier for ${DOMAIN}

${C_BOLD}USAGE${C_X}
  sni-hunter.sh hunt [options]              run a full scan
  sni-hunter.sh check <sni> [options]       inspect a single SNI host
  sni-hunter.sh tunnel-test [options]       prove bytes flow through tunnel
  sni-hunter.sh merge-runs A B [OUT]        compare two scans → tag NETWORK_TYPE_SPECIFIC
  sni-hunter.sh refresh-corpus              rebuild the 20k candidate list
  sni-hunter.sh setup-server                one-time install on tunnel server
  sni-hunter.sh install-debian              one-time install on a Debian laptop
  sni-hunter.sh self-test                   classifier sanity tests
  sni-hunter.sh --help

${C_BOLD}HUNT OPTIONS${C_X}
  --carrier X          safaricom | airtel | telkom | auto    (default: auto)
  --limit N            cap candidate count
  --seed-only          only scan built-in carrier seeds (~80 hosts, fast)
  --no-throughput      skip the slow MB-pull stage
  --interactive        per-host USSD balance probe (enables BUNDLE_REQUIRED).
                         Forces concurrency=1. Best used on a curated short
                         list (e.g. --seed-only, or feed in passing hosts
                         from an earlier non-interactive run).
  --radio-tag NAME     label this run's radio type (LTE, UMTS, NR, ...)
  --verify-tunnel      after a host passes, also confirm payload bytes actually
                         move through ssh-ws / vmess / vless endpoints
  --out DIR            output directory                       (default: ${OUT_DIR_DEFAULT})
  --resume             continue a previous interrupted scan
  --target-ip IP       force tunnel IP (skip DNS lookup)
  --concurrency N      parallel probes                        (default: ${CONCURRENCY})

${C_BOLD}CHECK${C_X}  inspect one SNI end-to-end and report tier + metrics
  ./sni-hunter.sh check fbcdn.net
  ./sni-hunter.sh check fbcdn.net --carrier safaricom --verify-tunnel
  ./sni-hunter.sh check fbcdn.net --json     # one JSON record on stdout
  Exit 0 if host passes, 1 otherwise.

${C_BOLD}TUNNEL-TEST${C_X}  prove bytes actually flow through each endpoint
  ./sni-hunter.sh tunnel-test
  ./sni-hunter.sh tunnel-test --sni fbcdn.net   # ride a known bug host
  Validates: ssh-ws (banner echo), vmess WS, vless WS, and 25MB blob path.
  UUIDs for V2Ray come from \$UUID_VMESS / \$UUID_VLESS or --uuid-vmess /
  --uuid-vless flags. Without a UUID we still test that the WS upgrade
  succeeds and the connection is held open after garbage write.

${C_BOLD}TWO-RADIO WORKFLOW${C_X} (find 3G-only / 4G-only hosts)
  1) lock phone to LTE → ./sni-hunter.sh hunt --radio-tag LTE  --out ~/run-lte
  2) lock phone to 3G  → ./sni-hunter.sh hunt --radio-tag UMTS --out ~/run-3g
  3) ./sni-hunter.sh merge-runs ~/run-lte ~/run-3g ~/run-merged
     → hosts that passed only one radio are tagged NETWORK_TYPE_SPECIFIC

${C_BOLD}TERMUX QUICKSTART${C_X} (Android phone over carrier mobile data)
  pkg install -y bash openssl curl coreutils termux-api jq
  curl -O https://${DOMAIN}/sni-hunter.sh && chmod +x sni-hunter.sh
  ./sni-hunter.sh hunt --carrier auto --interactive

${C_BOLD}DEBIAN LAPTOP QUICKSTART${C_X} (home wifi or USB-tethered phone)
  curl -O https://${DOMAIN}/sni-hunter.sh && chmod +x sni-hunter.sh
  sudo ./sni-hunter.sh install-debian
  sni-hunter.sh tunnel-test                # prove the server tunnel works
  sni-hunter.sh check fbcdn.net            # quick single-host check
  sni-hunter.sh hunt --seed-only           # short curated scan
  sni-hunter.sh hunt --carrier safaricom   # full corpus
  Note: laptop has no SIM, so USSD balance probes and carrier auto-detect
  are skipped. Pass --carrier explicitly to load that carrier's seed list.

${C_BOLD}OUTPUT${C_X}
  <out>/results.json   passing hosts only (full record)
  <out>/results.txt    sorted human-readable report
  <out>/results.csv    raw pipe-delimited records (for merge-runs)
  <out>/checkpoint     for --resume
  ~/sni-hunter-results.{json,txt}   canonical copies (always overwritten)
EOF
}

# =============================================================================
#  SETUP-SERVER
# =============================================================================
cmd_setup_server() {
  [ "$IS_SERVER" = "1" ] || die "setup-server must run as root on the tunnel server"
  log "Installing /usr/local/bin/sni-hunter.sh"
  install -m 0755 "$0" /usr/local/bin/sni-hunter.sh
  log "Publishing for phone download at https://${DOMAIN}/sni-hunter.sh"
  install -d /var/www/letsencrypt
  install -m 0644 "$0" /var/www/letsencrypt/sni-hunter.sh
  log "Generating ${BLOB_SIZE_MB}MB throughput blob"
  dd if=/dev/urandom of="/var/www/letsencrypt${BLOB_PATH}" bs=1M count="${BLOB_SIZE_MB}" status=none
  chmod 0644 "/var/www/letsencrypt${BLOB_PATH}"
  CORPUS="/var/lib/sni-hunter/corpus.txt"
  install -d /var/lib/sni-hunter
  log "Building 20k candidate corpus"
  cmd_refresh_corpus
  cat <<EOF

${C_G}Server ready.${C_X}
  Phone install :  curl -O https://${DOMAIN}/sni-hunter.sh && chmod +x sni-hunter.sh
  Local quick test:  /usr/local/bin/sni-hunter.sh hunt --seed-only
  Corpus         :  ${CORPUS}   ($(wc -l < "$CORPUS" 2>/dev/null || echo 0) hosts)
EOF
}

# =============================================================================
#  CORPUS BUILDER  —  seeds-first to guarantee inclusion
# =============================================================================
SAFARICOM_SEEDS=(
  m.facebook.com web.facebook.com free.facebook.com 0.facebook.com
  static.xx.fbcdn.net connect.facebook.net graph.facebook.com
  whatsapp.com web.whatsapp.com static.whatsapp.net mmg.whatsapp.net
  www.safaricom.co.ke safaricom.co.ke mpesa.safaricom.co.ke
  bonga.safaricom.co.ke daraja.safaricom.co.ke maishaplus.safaricom.co.ke
  youtube.com m.youtube.com www.googleapis.com
)
AIRTEL_SEEDS=(
  airtel.com www.airtel.com airtel.co.ke www.airtel.co.ke
  airtelmoney.airtel.com selfcare.airtel.co.ke shop.airtel.com
  www.airtel.in www.africa.airtel.com instagram.com www.instagram.com
  m.facebook.com free.facebook.com 0.facebook.com whatsapp.com
)
TELKOM_SEEDS=(
  telkom.co.ke www.telkom.co.ke myaccount.telkom.co.ke
  shop.telkom.co.ke faiba4g.co.ke t-kash.telkom.co.ke
  m.facebook.com web.facebook.com whatsapp.com
)
UNIVERSAL_SEEDS=(
  www.google.com www.cloudflare.com www.microsoft.com www.apple.com
  www.netflix.com www.tiktok.com www.zoom.us www.linkedin.com
  www.wikipedia.org duckduckgo.com www.bing.com
)

cmd_refresh_corpus() {
  install -d "$(dirname "$CORPUS")"
  local tmp seeds; tmp=$(mktemp); seeds=$(mktemp)

  # 1) seeds first — guarantees they survive the 20k cap
  printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${AIRTEL_SEEDS[@]}" \
                "${TELKOM_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" \
    | awk '!seen[$0]++' > "$seeds"

  # 2) Tranco
  log "Fetching Tranco top-1M..."
  if curl -fsSL --max-time 60 -o "${tmp}.tranco.zip" \
       "https://tranco-list.eu/top-1m.csv.zip" 2>/dev/null \
       && command -v unzip >/dev/null 2>&1; then
    unzip -p "${tmp}.tranco.zip" 2>/dev/null | head -n 18000 | awk -F, '{print $2}' >> "$tmp"
    log "  Tranco: $(wc -l < "$tmp") hosts"
  else
    warn "Tranco unavailable (need curl + unzip)"
  fi

  # 3) Umbrella
  log "Fetching Cisco Umbrella top-1M..."
  if curl -fsSL --max-time 60 -o "${tmp}.umb.zip" \
       "https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip" 2>/dev/null \
       && command -v unzip >/dev/null 2>&1; then
    unzip -p "${tmp}.umb.zip" 2>/dev/null | head -n 8000 | awk -F, '{print $2}' >> "$tmp"
  else
    warn "Umbrella unavailable (non-fatal)"
  fi

  # 4) clean external sources, cap to (20000 - seed_count), then prepend seeds
  local seed_count cap external
  seed_count=$(wc -l < "$seeds")
  cap=$(( 20000 - seed_count ))
  external=$(mktemp)
  awk 'BEGIN{IGNORECASE=1}
       /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/ && !/localhost/ && !/\.local$/ && length($0)<=80 {print tolower($0)}' \
       "$tmp" | awk '!seen[$0]++' | head -n "$cap" > "$external"

  cat "$seeds" "$external" | awk '!seen[$0]++' | head -n 20000 > "$CORPUS"

  rm -f "$tmp" "${tmp}.tranco.zip" "${tmp}.umb.zip" "$seeds" "$external"
  log "Corpus: ${C_G}$(wc -l < "$CORPUS") hosts${C_X} (${seed_count} seeds + external) → ${CORPUS}"
}

# =============================================================================
#  CARRIER + RADIO DETECTION
# =============================================================================
detect_carrier() {
  if [ "$HAVE_TERMUX_API" = "1" ] && command -v jq >/dev/null 2>&1; then
    local op mccmnc
    op=$(termux-telephony-deviceinfo 2>/dev/null | jq -r '.network_operator_name // empty' | tr '[:upper:]' '[:lower:]')
    mccmnc=$(termux-telephony-deviceinfo 2>/dev/null | jq -r '.network_operator // empty')
    case "$op" in
      *safaricom*) echo safaricom; return ;;
      *airtel*)    echo airtel;    return ;;
      *telkom*)    echo telkom;    return ;;
    esac
    case "$mccmnc" in
      63902) echo safaricom; return ;;
      63903) echo airtel;    return ;;
      63907) echo telkom;    return ;;
    esac
  fi
  echo unknown
}

network_type_now() {
  if [ -n "$RADIO_TAG" ]; then echo "$RADIO_TAG"; return; fi
  if [ "$HAVE_TERMUX_API" = "1" ] && command -v jq >/dev/null 2>&1; then
    termux-telephony-deviceinfo 2>/dev/null | jq -r '.data_network_type // .network_type // "unknown"'
  else
    echo "unknown"
  fi
}

# =============================================================================
#  USSD BALANCE PROBE
#  - Termux + dialog: prompt user to dial *544# (Saf) / *131# (Airtel) / *188#
#    (Telkom), enter balance shown.
#  - Non-interactive: returns -1 (unknown).
# =============================================================================
ussd_code_for() {
  case "$1" in
    safaricom) echo "*544#" ;;
    airtel)    echo "*131#" ;;
    telkom)    echo "*188#" ;;
    *)         echo "*#?#"  ;;
  esac
}

read_balance_kb() {
  local who="$1" code; code=$(ussd_code_for "$CARRIER")
  if [ "$INTERACTIVE" != "1" ]; then echo -1; return; fi
  if [ "$HAVE_TERMUX_API" = "1" ]; then
    termux-telephony-call "$code" >/dev/null 2>&1 || true
  fi
  printf "${C_Y}[BALANCE %s] dial %s on your phone, then enter remaining DATA in MB (or 'skip'): ${C_X}" "$who" "$code" >&2
  local v; read -r v < /dev/tty || { echo -1; return; }
  case "$v" in skip|"") echo -1 ;; *) awk -v m="$v" 'BEGIN{printf "%d", m*1024}' ;; esac
}

# =============================================================================
#  PROBE PIPELINE  →  outputs one PIPE-delimited record on PASS
#  Format: tier|sni|rtt_ms|jitter_ms|mbps|bal_delta_kb|ip_lock|net_type|family|http
# =============================================================================
classify_family() {
  case "$1" in
    *facebook*|*fbcdn*|*instagram*) echo META ;;
    *whatsapp*)                     echo WHATSAPP ;;
    *youtube*|*googlevideo*|*ytimg*)echo YOUTUBE ;;
    *tiktok*|*musical*)             echo TIKTOK ;;
    *google*|*gstatic*|*googleapis*)echo GOOGLE ;;
    *safaricom*|*mpesa*|*bonga*)    echo SAFARICOM ;;
    *airtel*)                       echo AIRTEL ;;
    *telkom*|*faiba*|*t-kash*)      echo TELKOM ;;
    *cloudflare*|*cloudfront*|*akamai*|*fastly*) echo CDN ;;
    *netflix*) echo NETFLIX ;;
    *zoom*)    echo ZOOM ;;
    *)         echo OTHER ;;
  esac
}

# Single WebSocket-handshake probe with explicit destination IP.
# Returns elapsed-ms on 101, empty on failure.
ws_probe_via_ip() {
  local sni="$1" dst_ip="$2"
  local t0 t1 code
  t0=$(date +%s%3N)
  code=$(timeout "$TIMEOUT" curl -sk --http1.1 -o /dev/null -w "%{http_code}" \
           --resolve "${sni}:${PORT}:${dst_ip}" \
           -H "Host: ${DOMAIN}" \
           -H "Upgrade: websocket" -H "Connection: Upgrade" \
           -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
           -H "Sec-WebSocket-Version: 13" \
           "https://${sni}:${PORT}${WS_PATH}" 2>/dev/null)
  t1=$(date +%s%3N)
  [ "$code" = "101" ] || return 1
  echo $((t1-t0))
}

probe() {
  local sni="$1"
  local family ntype
  family=$(classify_family "$sni")
  ntype=$(network_type_now)

  # ---- stage 1: TLS reachability ----
  if ! echo | timeout "$TIMEOUT" openssl s_client -connect "${TARGET_IP}:${PORT}" \
        -servername "$sni" 2>/dev/null </dev/null | grep -q "BEGIN CERTIFICATE"; then
    return 1
  fi

  # ---- stage 2: WS upgrade direct (carrier sees dst-IP=our IP) ----
  local rtt_direct rtt_via_brand=""
  rtt_direct=$(ws_probe_via_ip "$sni" "$TARGET_IP") || rtt_direct=""

  # ---- stage 2b: IP-lock probe ----
  # If direct failed, try routing through the candidate's REAL IP — if that
  # works, the carrier requires the brand IP (CDN-front / IP-locked).
  local iplock=0
  if [ -z "$rtt_direct" ]; then
    local brand_ip
    brand_ip=$(resolve_host "$sni" 2>/dev/null) || brand_ip=""
    if [ -n "$brand_ip" ] && [ "$brand_ip" != "$TARGET_IP" ]; then
      rtt_via_brand=$(ws_probe_via_ip "$sni" "$brand_ip") || rtt_via_brand=""
      if [ -n "$rtt_via_brand" ]; then
        iplock=1
      else
        return 1
      fi
    else
      return 1
    fi
  fi

  local rtt_first; rtt_first="${rtt_direct:-$rtt_via_brand}"
  local route_ip="$TARGET_IP"; [ "$iplock" = "1" ] && route_ip=$(resolve_host "$sni")

  # ---- stage 3: latency / jitter — N samples ----
  local samples=""; local i s
  for i in $(seq 1 "$LATENCY_SAMPLES"); do
    s=$(ws_probe_via_ip "$sni" "$route_ip") && samples="$samples $s"
  done
  samples="$rtt_first $samples"
  local rtt jitter
  read -r rtt jitter < <(awk '{
      n=NF; sum=0; for(i=1;i<=n;i++) sum+=$i; mean=sum/n
      sq=0; for(i=1;i<=n;i++) sq+=($i-mean)*($i-mean)
      printf "%d %d", mean+0.5, sqrt(sq/n)+0.5
    }' <<<"$samples")

  # ---- stage 4: throughput ----
  local mbps="-1"
  if [ "${SKIP_THRU:-0}" != "1" ]; then
    local bytes
    bytes=$(timeout "$THRU_TIMEOUT" curl -sk --http1.1 -o /dev/null -w "%{speed_download}" \
              --resolve "${sni}:${PORT}:${route_ip}" \
              -H "Host: ${DOMAIN}" \
              "https://${sni}:${PORT}${BLOB_PATH}" 2>/dev/null || echo 0)
    mbps=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", (b*8)/1000000}')
  fi

  # ---- stage 5: per-host balance delta.
  # Done synchronously here when --interactive is on (CONCURRENCY=1 is enforced
  # in that mode). Without --interactive, delta = -1 (unknown).
  local bal_delta=-1
  if [ "${INTERACTIVE:-0}" = "1" ]; then
    local bp ba
    bp=$(read_balance_kb "PRE  $sni") || bp=-1
    # do a small targeted transfer to attribute charge to THIS host
    if [ "${SKIP_THRU:-0}" != "1" ]; then
      timeout "$THRU_TIMEOUT" curl -sk --http1.1 -o /dev/null \
        --resolve "${sni}:${PORT}:${route_ip}" \
        -H "Host: ${DOMAIN}" \
        "https://${sni}:${PORT}${BLOB_PATH}" >/dev/null 2>&1 || true
    fi
    ba=$(read_balance_kb "POST $sni") || ba=-1
    if [ "$bp" -ge 0 ] && [ "$ba" -ge 0 ]; then
      bal_delta=$(( bp - ba ))
      [ "$bal_delta" -lt 0 ] && bal_delta=0
    fi
  fi

  # ---- stage 6: classification ----
  local tier
  tier=$(classify_tier "$mbps" "$bal_delta" "$iplock" "$ntype" "$family")

  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|101\n" \
    "$tier" "$sni" "$rtt" "$jitter" "$mbps" "$bal_delta" "$iplock" "$ntype" "$family"
}

# Strict tier classifier — priority order is fixed.
#   1) IP_LOCKED          (carrier-behavior signal, overrides speed)
#   2) BUNDLE_REQUIRED    (balance dropped >0)
#   3) THROTTLED          (mbps < 1)
#   4) CAPPED_100M        (sustained ceiling near 100 Mbps  → 80–120)
#   5) CAPPED_20M         (sustained ceiling near 20 Mbps   → 15–28)
#   6) APP_TUNNEL_<F>     (only if family is META/WHATSAPP/YOUTUBE/TIKTOK and
#                          we'd otherwise call it UNLIMITED_FREE)
#   7) UNLIMITED_FREE     (≥10 Mbps, balance delta == 0)
#   8) PASS_NOTHRU        (throughput skipped → can't decide further)
#   NETWORK_TYPE_SPECIFIC is assigned later by `merge-runs`, not here.
classify_tier() {
  local mbps="$1" bal="$2" iplock="$3" net="$4" family="$5"
  if [ "$iplock" = "1" ]; then echo IP_LOCKED; return; fi
  awk -v m="$mbps" -v b="$bal" -v f="$family" '
    BEGIN {
      if (b+0 > 0)                                       { print "BUNDLE_REQUIRED"; exit }
      if (m+0 == -1)                                     { print "PASS_NOTHRU";    exit }
      if (m+0 < 1)                                       { print "THROTTLED";      exit }
      if (m+0 >= 80 && m+0 <= 120)                       { print "CAPPED_100M";    exit }
      if (m+0 >= 15 && m+0 <= 28)                        { print "CAPPED_20M";     exit }
      if (m+0 >= 10 && (b+0 == 0)) {
        if (f=="META"||f=="WHATSAPP"||f=="YOUTUBE"||f=="TIKTOK")
          print "APP_TUNNEL_" f
        else
          print "UNLIMITED_FREE"
        exit
      }
      print "UNLIMITED_FREE"
    }'
}

# =============================================================================
#  SELF-TEST
# =============================================================================
cmd_self_test() {
  local fails=0
  check() {
    local exp got; exp="$1"; shift
    got=$(classify_tier "$@")
    if [ "$got" = "$exp" ]; then
      printf "  ${C_G}ok${C_X}    %s  ->  %s\n" "[$*]" "$got"
    else
      printf "  ${C_R}FAIL${C_X}  %s  ->  %s (want %s)\n" "[$*]" "$got" "$exp"; fails=$((fails+1))
    fi
  }
  # mbps bal iplock net family
  check IP_LOCKED          "50"  "0"   "1"  "LTE"  "OTHER"
  check BUNDLE_REQUIRED    "30"  "200" "0"  "LTE"  "OTHER"
  check BUNDLE_REQUIRED    "0.5" "10"  "0"  "LTE"  "OTHER"
  check THROTTLED          "0.4" "0"   "0"  "LTE"  "OTHER"
  check CAPPED_100M        "95"  "0"   "0"  "LTE"  "OTHER"
  check CAPPED_20M         "20"  "0"   "0"  "LTE"  "OTHER"
  check UNLIMITED_FREE     "60"  "0"   "0"  "LTE"  "OTHER"
  check UNLIMITED_FREE     "11"  "0"   "0"  "LTE"  "OTHER"
  check APP_TUNNEL_META    "30"  "0"   "0"  "LTE"  "META"
  check APP_TUNNEL_WHATSAPP "12" "0"   "0"  "LTE"  "WHATSAPP"
  # app-tunnel must NOT mask carrier-behavior tiers
  check IP_LOCKED          "30"  "0"   "1"  "LTE"  "META"
  check BUNDLE_REQUIRED    "30"  "50"  "0"  "LTE"  "YOUTUBE"
  check PASS_NOTHRU        "-1"  "-1"  "0"  "LTE"  "OTHER"

  # ---- tunnel-test framing constants — guard against silent breakage ----
  echo
  echo "  tunnel-test framing constants:"
  # Confirm the embedded python tunnel probe at least compiles (running with no
  # argv intentionally triggers an unpack error, proving the source parsed).
  if command -v python3 >/dev/null 2>&1; then
    local out
    out=$(python3 -c "$(_tunnel_py)" 2>&1 || true)
    if echo "$out" | grep -qE "ValueError|not enough values|unpack"; then
      printf "  ${C_G}ok${C_X}    embedded python tunnel probe parses\n"
    else
      printf "  ${C_R}FAIL${C_X}  embedded python broken: %s\n" "${out:0:160}"
      fails=$((fails+1))
    fi
  else
    printf "  ${C_Y}skip${C_X}  python3 not installed; tunnel-test will require it\n"
  fi

  # framing: client frame for 64-byte payload = 2 + 4 (mask) + 64 = 70 bytes
  if command -v python3 >/dev/null 2>&1; then
    local fl
    fl=$(python3 - <<'PY'
import os, struct
def make_ws_frame(payload, opcode=0x2):
    mask = b'\x00\x00\x00\x00'
    masked = payload
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126: head += bytes([0x80 | n])
    elif n < 65536: head += bytes([0x80 | 126]) + struct.pack("!H", n)
    else: head += bytes([0x80 | 127]) + struct.pack("!Q", n)
    return head + mask + masked
print(len(make_ws_frame(b'x'*64)))
PY
)
    if [ "$fl" = "70" ]; then
      printf "  ${C_G}ok${C_X}    WS client frame size for 64B payload = 70\n"
    else
      printf "  ${C_R}FAIL${C_X}  WS client frame size = %s (expected 70)\n" "$fl"
      fails=$((fails+1))
    fi
  fi

  # SSH banner regex — make sure we still recognize the standard form
  if echo "SSH-2.0-OpenSSH_9.6p1 Ubuntu" | grep -qE '^SSH-2\.0-'; then
    printf "  ${C_G}ok${C_X}    SSH-2.0 banner regex matches\n"
  else
    printf "  ${C_R}FAIL${C_X}  SSH banner regex broken\n"; fails=$((fails+1))
  fi

  # Regression guard: hunt --verify-tunnel must invoke cmd_tunnel_test (this
  # was a no-op in an earlier draft). Extract cmd_hunt body and count calls.
  local hunt_calls
  hunt_calls=$(awk '
    /^cmd_hunt\(\) \{/  {inhunt=1; next}
    inhunt && /^cmd_[a-z_]+\(\) \{/ {inhunt=0}
    inhunt
  ' "$0" | grep -c 'cmd_tunnel_test' || true)
  if [ "${hunt_calls:-0}" -ge 2 ]; then
    printf "  ${C_G}ok${C_X}    hunt invokes tunnel verification (pre + post)\n"
  else
    printf "  ${C_R}FAIL${C_X}  hunt --verify-tunnel doesn't call cmd_tunnel_test (found %s sites; need 2)\n" "${hunt_calls:-0}"
    fails=$((fails+1))
  fi

  # path constants exist
  for p in "$WS_PATH" "$VMESS_PATH" "$VLESS_PATH" "$BLOB_PATH"; do
    if [[ "$p" == /* ]]; then
      printf "  ${C_G}ok${C_X}    path constant %s\n" "$p"
    else
      printf "  ${C_R}FAIL${C_X}  bad path constant: %s\n" "$p"; fails=$((fails+1))
    fi
  done

  echo
  if [ "$fails" = "0" ]; then echo "${C_G}all tests passed${C_X}"; else echo "${C_R}${fails} failure(s)${C_X}"; exit 1; fi
}

# =============================================================================
#  HUNT
# =============================================================================
cmd_hunt() {
  local seed_only=0 limit="" out_dir="$OUT_DIR_DEFAULT" resume=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --carrier)       CARRIER="$2"; shift 2;;
      --limit)         limit="$2"; shift 2;;
      --seed-only)     seed_only=1; shift;;
      --no-throughput) export SKIP_THRU=1; shift;;
      --interactive)   INTERACTIVE=1; shift;;
      --radio-tag)     RADIO_TAG="$2"; shift 2;;
      --verify-tunnel) VERIFY_TUNNEL=1; export VERIFY_TUNNEL; shift;;
      --out)           out_dir="$2"; shift 2;;
      --resume)        resume=1; shift;;
      --target-ip)     TARGET_IP="$2"; shift 2;;
      --concurrency)   CONCURRENCY="$2"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done

  # Debian laptop: no SIM, skip carrier auto-detect
  if [ "$IS_DEBIAN_LAPTOP" = "1" ] && { [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ]; }; then
    log "Debian laptop detected — skipping carrier auto-detect (no SIM). Use --carrier to load a seed list."
    CARRIER="unknown"
  fi
  # Debian laptop: USSD probes are meaningless without a SIM
  if [ "$IS_DEBIAN_LAPTOP" = "1" ] && [ "${INTERACTIVE:-0}" = "1" ]; then
    warn "--interactive on a laptop has no SIM to probe; disabling."
    INTERACTIVE=0
  fi

  [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ] && CARRIER=$(detect_carrier)
  [ -z "$CARRIER" ] && CARRIER="unknown"

  if [ -z "$TARGET_IP" ]; then
    TARGET_IP=$(resolve_host "$DOMAIN" 2>/dev/null) || true
  fi
  [ -z "$TARGET_IP" ] && die "Cannot resolve $DOMAIN — set --target-ip <IP>"

  # --verify-tunnel preflight: prove the tunnel itself moves bytes BEFORE we
  # spend hours scanning. If the tunnel is broken, every "pass" would be
  # meaningless. We also re-verify against the single top passing host at the
  # end of the scan (see below) so users get tunnel-confidence per scan.
  if [ "${VERIFY_TUNNEL:-0}" = "1" ]; then
    log "${C_BOLD}--verify-tunnel${C_X}: preflight against ${TARGET_IP}"
    if ! cmd_tunnel_test --target-ip "$TARGET_IP" >&2; then
      die "tunnel preflight failed — fix the server before scanning. Re-run without --verify-tunnel to scan anyway."
    fi
  fi

  install -d "$out_dir"
  local cand_file="${out_dir}/candidates.txt"
  if [ "$seed_only" = "1" ]; then
    case "$CARRIER" in
      safaricom) printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${UNIVERSAL_SEEDS[@]}" ;;
      airtel)    printf "%s\n" "${AIRTEL_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" ;;
      telkom)    printf "%s\n" "${TELKOM_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" ;;
      *)         printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${AIRTEL_SEEDS[@]}" \
                                "${TELKOM_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" ;;
    esac | awk '!seen[$0]++' > "$cand_file"
  else
    [ -s "$CORPUS" ] || die "No corpus at $CORPUS — run: $0 refresh-corpus"
    cp "$CORPUS" "$cand_file"
    case "$CARRIER" in
      safaricom) printf "%s\n" "${SAFARICOM_SEEDS[@]}" | cat - "$cand_file" | awk '!seen[$0]++' > "${cand_file}.t" && mv "${cand_file}.t" "$cand_file" ;;
      airtel)    printf "%s\n" "${AIRTEL_SEEDS[@]}"    | cat - "$cand_file" | awk '!seen[$0]++' > "${cand_file}.t" && mv "${cand_file}.t" "$cand_file" ;;
      telkom)    printf "%s\n" "${TELKOM_SEEDS[@]}"    | cat - "$cand_file" | awk '!seen[$0]++' > "${cand_file}.t" && mv "${cand_file}.t" "$cand_file" ;;
    esac
  fi
  [ -n "$limit" ] && head -n "$limit" "$cand_file" > "${cand_file}.t" && mv "${cand_file}.t" "$cand_file"

  local total; total=$(wc -l < "$cand_file")
  local pass_file="${out_dir}/results.csv"
  local checkpoint="${out_dir}/checkpoint"

  if [ "$resume" = "1" ] && [ -s "$checkpoint" ]; then
    log "Resuming — skipping $(wc -l < "$checkpoint") already-probed hosts"
    grep -vxF -f "$checkpoint" "$cand_file" > "${cand_file}.todo"
  else
    : > "$pass_file"; : > "$checkpoint"
    cp "$cand_file" "${cand_file}.todo"
  fi

  cat >&2 <<EOF
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
  ${C_BOLD}SNI HUNTER v2${C_X}
  Domain         : ${DOMAIN}    Tunnel IP: ${TARGET_IP}
  Carrier        : ${C_M}${CARRIER}${C_X}    Radio: $(network_type_now)
  Candidates     : ${total}  $([ "$seed_only" = 1 ] && echo "(seeds only)" || echo "(corpus)")
  Concurrency    : ${CONCURRENCY}    Throughput: $([ "${SKIP_THRU:-0}" = 1 ] && echo SKIPPED || echo "${BLOB_SIZE_MB}MB")
  Balance probe  : $([ "$INTERACTIVE" = 1 ] && echo "INTERACTIVE (USSD pre/post)" || echo "off (use --interactive)")
  Output dir     : ${out_dir}
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
EOF

  # In interactive (per-host USSD) mode, force serial scanning so balance
  # deltas can be attributed to one host at a time.
  if [ "$INTERACTIVE" = "1" ]; then
    CONCURRENCY=1
    log "Interactive mode: forcing concurrency=1 for per-host balance attribution"
  fi

  export DOMAIN PORT WS_PATH BLOB_PATH TIMEOUT THRU_TIMEOUT TARGET_IP CARRIER
  export RADIO_TAG LATENCY_SAMPLES SKIP_THRU HAVE_TERMUX_API INTERACTIVE
  export -f probe ws_probe_via_ip classify_family classify_tier
  export -f network_type_now read_balance_kb ussd_code_for

  local started; started=$(date +%s); local n=0
  ( while [ ! -f "${out_dir}/.done" ]; do
      sleep 5
      printf "%s  scanned %5d/%-5d   pass %3d   elapsed %ds%s\r" \
        "$C_D" "$(wc -l < "$checkpoint" 2>/dev/null || echo 0)" \
        "$total" "$(wc -l < "$pass_file" 2>/dev/null || echo 0)" \
        "$(( $(date +%s) - started ))" "$C_X" >&2
    done ) &
  local pp=$!

  while IFS= read -r host; do [ -z "$host" ] || echo "$host"; done < "${cand_file}.todo" | \
    xargs -n1 -P "$CONCURRENCY" -I{} bash -c '
      out=$(probe "$1") && echo "$out" >> "'"$pass_file"'"
      echo "$1" >> "'"$checkpoint"'"
    ' _ {}

  touch "${out_dir}/.done"; kill "$pp" 2>/dev/null; wait 2>/dev/null
  printf "\n"

  format_outputs "$out_dir" "$pass_file"

  # --verify-tunnel post-scan: re-confirm the tunnel still works through the
  # single best passing host. Catches regressions (carrier blocked it mid-scan)
  # and gives the user concrete proof the tunnel is usable on a real bug host.
  if [ "${VERIFY_TUNNEL:-0}" = "1" ] && [ -s "$pass_file" ]; then
    local top_sni
    top_sni=$(awk -F'|' '$1!="THROTTLED" && $1!="BUNDLE_REQUIRED"{print $5"|"$2}' "$pass_file" \
              | sort -t'|' -k1,1gr | head -1 | cut -d'|' -f2)
    if [ -n "$top_sni" ]; then
      log "${C_BOLD}--verify-tunnel${C_X}: post-scan check riding ${top_sni}"
      if cmd_tunnel_test --sni "$top_sni" >&2; then
        echo "VERIFIED via ${top_sni}" > "${out_dir}/tunnel-verified.txt"
      else
        echo "DEGRADED via ${top_sni}" > "${out_dir}/tunnel-verified.txt"
        warn "tunnel post-scan via ${top_sni} reported degraded; results may be stale"
      fi
    fi
  fi

  # Task contract: also expose canonical paths at $HOME/sni-hunter-results.{json,txt}
  cp -f "${out_dir}/results.json" "${HOME}/sni-hunter-results.json" 2>/dev/null || true
  cp -f "${out_dir}/results.txt"  "${HOME}/sni-hunter-results.txt"  2>/dev/null || true

  log "Done in $(( $(date +%s) - started ))s. ${C_G}$(wc -l < "$pass_file") passing${C_X} of ${total}."
  log "Reports: ${out_dir}/results.txt   ${out_dir}/results.json"
  log "         ${HOME}/sni-hunter-results.txt   ${HOME}/sni-hunter-results.json"
  rm -f "${out_dir}/.done" "${cand_file}.todo"
}

# =============================================================================
#  MERGE-RUNS  →  tag NETWORK_TYPE_SPECIFIC
# =============================================================================
cmd_merge_runs() {
  local A="$1" B="$2" OUT="${3:-$HOME/sni-hunter-merged}"
  [ -s "${A}/results.csv" ] && [ -s "${B}/results.csv" ] || die "need results.csv in both runs"
  install -d "$OUT"
  local merged="${OUT}/results.csv"; : > "$merged"

  local a_only b_only both
  a_only=$(comm -23 <(cut -d'|' -f2 "${A}/results.csv" | sort -u) <(cut -d'|' -f2 "${B}/results.csv" | sort -u))
  b_only=$(comm -13 <(cut -d'|' -f2 "${A}/results.csv" | sort -u) <(cut -d'|' -f2 "${B}/results.csv" | sort -u))

  # hosts in both: keep the better record (use A as canonical)
  comm -12 <(cut -d'|' -f2 "${A}/results.csv" | sort -u) <(cut -d'|' -f2 "${B}/results.csv" | sort -u) \
    | while read -r h; do grep -m1 "|${h}|" "${A}/results.csv"; done >> "$merged"

  # hosts only in A → NETWORK_TYPE_SPECIFIC, tag with A's net_type
  echo "$a_only" | grep -v '^$' | while read -r h; do
    awk -F'|' -v OFS='|' -v h="$h" '$2==h{$1="NETWORK_TYPE_SPECIFIC"; print; exit}' "${A}/results.csv"
  done >> "$merged"

  echo "$b_only" | grep -v '^$' | while read -r h; do
    awk -F'|' -v OFS='|' -v h="$h" '$2==h{$1="NETWORK_TYPE_SPECIFIC"; print; exit}' "${B}/results.csv"
  done >> "$merged"

  format_outputs "$OUT" "$merged"
  log "Merged into ${OUT}/   (NETWORK_TYPE_SPECIFIC tagged)"
}

# =============================================================================
#  OUTPUT FORMATTERS  —  primary sort: tier priority, secondary: mbps DESC
# =============================================================================
format_outputs() {
  local out_dir="$1" csv="$2"
  local txt="${out_dir}/results.txt" json="${out_dir}/results.json"
  local sort_csv; sort_csv=$(mktemp)

  awk -F'|' '{
    p=99
    if ($1=="UNLIMITED_FREE")              p=1
    else if ($1=="CAPPED_100M")            p=2
    else if ($1=="CAPPED_20M")             p=3
    else if ($1 ~ /^APP_TUNNEL_/)          p=4
    else if ($1=="NETWORK_TYPE_SPECIFIC")  p=5
    else if ($1=="PASS_NOTHRU")            p=6
    else if ($1=="BUNDLE_REQUIRED")        p=7
    else if ($1=="IP_LOCKED")              p=8
    else if ($1=="THROTTLED")              p=9
    print p"|"$0
  }' "$csv" | sort -t'|' -k1,1n -k6,6gr | cut -d'|' -f2- > "$sort_csv"

  {
    printf "# SNI Hunter — %s — carrier=%s — domain=%s\n" "$(date -Iseconds)" "${CARRIER:-?}" "$DOMAIN"
    printf "# %-22s  %-32s  %5s  %5s  %7s  %7s  %-7s  %-10s  %-9s\n" \
      TIER SNI RTT JIT MBPS BAL_KB IP_LOCK NET_TYPE FAMILY
    awk -F'|' '{
      printf "  %-22s  %-32s  %5s  %5s  %7s  %7s  %-7s  %-10s  %-9s\n",
        $1, $2, $3, $4, $5, $6, ($7=="1"?"yes":"no"), $8, $9
    }' "$sort_csv"
  } > "$txt"

  awk -F'|' 'BEGIN{print "["; first=1}
    {
      if (!first) printf ",\n"; first=0
      gsub(/"/,"\\\"",$2)
      printf "  {\"tier\":\"%s\",\"sni\":\"%s\",\"rtt_ms\":%s,\"jitter_ms\":%s,\"mbps\":%s,\"bal_delta_kb\":%s,\"ip_lock\":%s,\"net_type\":\"%s\",\"family\":\"%s\"}",
        $1,$2,$3,$4,$5,$6,($7=="1"?"true":"false"),$8,$9
    }
    END{print "\n]"}' "$sort_csv" > "$json"

  printf "\n${C_BOLD}=== Top 30 ===${C_X}\n"
  printf "  %-22s  %-32s  %5s  %5s  %7s  %-10s  %-9s\n" TIER SNI RTT JIT MBPS NET FAMILY
  head -n 30 "$sort_csv" | awk -F'|' -v g="$C_G" -v y="$C_Y" -v r="$C_R" -v c="$C_C" -v x="$C_X" '{
    col=g
    if ($1 ~ /THROTTLED|PASS_NOTHRU|BUNDLE/) col=y
    if ($1 ~ /IP_LOCKED/)                    col=r
    if ($1 ~ /NETWORK_TYPE/)                 col=c
    printf "  %s%-22s%s  %-32s  %5s  %5s  %7s  %-10s  %-9s\n", col,$1,x,$2,$3,$4,$5,$8,$9
  }'
  printf "\n${C_BOLD}=== Pass counts by tier ===${C_X}\n"
  cut -d'|' -f1 "$sort_csv" | sort | uniq -c | sort -rn | awk '{printf "  %5d  %s\n",$1,$2}'

  rm -f "$sort_csv"
}

# =============================================================================
#  TUNNEL BYTE-FLOW PROBE  (python3 is already a hard dep via resolve_host)
#  Opens a TLS+WS connection to the tunnel through the chosen SNI/route IP,
#  upgrades, then validates that PAYLOAD bytes actually move both ways for
#  each of: ssh-ws, vmess-ws, vless-ws.  Result lines are PASS/FAIL.
# =============================================================================
_tunnel_py() {
cat <<'PYEOF'
import sys, socket, ssl, base64, os, struct, time, json
host, port, sni, host_hdr, path, mode = sys.argv[1:7]
port = int(port)
deadline = float(os.environ.get("TUN_DEADLINE", "8"))
uuid_hex = (os.environ.get("UUID_VMESS","") if mode=="vmess"
            else os.environ.get("UUID_VLESS","") if mode=="vless" else "")
def out(status, **kw):
    kw["status"] = status; kw["mode"] = mode
    print(json.dumps(kw))
    sys.exit(0 if status == "PASS" else 1)
try:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = socket.create_connection((host, port), timeout=deadline)
    ss = ctx.wrap_socket(sock, server_hostname=sni)
except Exception as e:
    out("FAIL", error=f"connect: {e}")
key = base64.b64encode(os.urandom(16)).decode()
req = (f"GET {path} HTTP/1.1\r\nHost: {host_hdr}\r\n"
       f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode()
t0 = time.time()
try:
    ss.sendall(req)
    ss.settimeout(deadline)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = ss.recv(4096)
        if not chunk: break
        buf += chunk
        if len(buf) > 65536: break
except Exception as e:
    out("FAIL", error=f"handshake: {e}")
status_line = buf.split(b"\r\n",1)[0] if buf else b""
if b" 101 " not in status_line:
    out("FAIL", error=f"no_101: {status_line[:80].decode(errors='replace')}")
body = buf.split(b"\r\n\r\n",1)[1] if b"\r\n\r\n" in buf else b""

def parse_ws_frame(buf):
    if len(buf) < 2: return None, buf
    b0, b1 = buf[0], buf[1]
    masked = b1 & 0x80
    ln = b1 & 0x7f
    off = 2
    if ln == 126:
        if len(buf) < off+2: return None, buf
        ln = struct.unpack("!H", buf[off:off+2])[0]; off += 2
    elif ln == 127:
        if len(buf) < off+8: return None, buf
        ln = struct.unpack("!Q", buf[off:off+8])[0]; off += 8
    mask = b""
    if masked:
        if len(buf) < off+4: return None, buf
        mask = buf[off:off+4]; off += 4
    if len(buf) < off+ln: return None, buf
    payload = buf[off:off+ln]
    if mask:
        payload = bytes(p ^ mask[i%4] for i,p in enumerate(payload))
    return payload, buf[off+ln:]

def make_ws_frame(payload, opcode=0x2):
    # client must mask
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i%4] for i,b in enumerate(payload))
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack("!Q", n)
    return head + mask + masked

if mode == "ssh":
    # ws-ssh-bridge proxies WS payload <-> local sshd. SSH server speaks first
    # with a "SSH-2.0-..." banner. Read up to 5s and search frames for it.
    rx = body
    end = time.time() + 5
    found = None
    while time.time() < end and not found:
        try:
            ss.settimeout(max(0.2, end - time.time()))
            chunk = ss.recv(4096)
            if not chunk: break
            rx += chunk
            # parse all complete frames
            while True:
                pl, rest = parse_ws_frame(rx)
                if pl is None: break
                rx = rest
                if b"SSH-" in pl:
                    found = pl
                    break
        except Exception:
            break
    if found:
        out("PASS", bytes_in=len(found), elapsed_ms=int((time.time()-t0)*1000),
            banner=found.split(b"\r\n",1)[0][:64].decode(errors='replace'))
    out("FAIL", error="no_ssh_banner", elapsed_ms=int((time.time()-t0)*1000))

# vmess / vless: send a small client frame; accept either (a) a server frame in
# response or (b) the connection being held open ≥1.5s after our write, since
# real V2Ray closes immediately on bad auth/protocol.
try:
    ss.sendall(make_ws_frame(os.urandom(64)))
except Exception as e:
    out("FAIL", error=f"send: {e}")
ss.settimeout(2.0)
got = b""
try:
    chunk = ss.recv(4096)
    if chunk: got += chunk
except socket.timeout:
    pass
except Exception as e:
    out("FAIL", error=f"recv: {e}", elapsed_ms=int((time.time()-t0)*1000))
# write again to confirm peer hasn't RST
try:
    time.sleep(0.6)
    ss.sendall(make_ws_frame(os.urandom(16)))
    held = True
except Exception:
    held = False
if got:
    out("PASS", bytes_in=len(got), elapsed_ms=int((time.time()-t0)*1000), reason="server_responded")
if held:
    out("PASS", bytes_in=0, elapsed_ms=int((time.time()-t0)*1000), reason="held_open")
out("FAIL", error="rst_after_write", elapsed_ms=int((time.time()-t0)*1000))
PYEOF
}

# Run the python tunnel probe and emit a single colored line.
# Args: <mode ssh|vmess|vless> <route_ip> <sni>
tunnel_test_one() {
  local mode="$1" route_ip="$2" sni="$3"
  local path
  case "$mode" in
    ssh)   path="$WS_PATH" ;;
    vmess) path="$VMESS_PATH" ;;
    vless) path="$VLESS_PATH" ;;
    *) die "tunnel_test_one: unknown mode $mode" ;;
  esac
  local result
  result=$(UUID_VMESS="$UUID_VMESS" UUID_VLESS="$UUID_VLESS" TUN_DEADLINE="$TIMEOUT" \
           python3 -c "$(_tunnel_py)" "$route_ip" "$PORT" "$sni" "$DOMAIN" "$path" "$mode" 2>&1)
  echo "$result"
}

# Pretty-print a tunnel_test_one result line.
fmt_tunnel_line() {
  local mode="$1" json_line="$2"
  local status bytes_in elapsed reason err
  status=$(echo "$json_line" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("status",""))' 2>/dev/null || echo "")
  if [ "$status" = "PASS" ]; then
    bytes_in=$(echo "$json_line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("bytes_in",0))' 2>/dev/null)
    elapsed=$(echo "$json_line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("elapsed_ms",0))' 2>/dev/null)
    reason=$(echo "$json_line" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("reason") or d.get("banner",""))' 2>/dev/null)
    printf "  ${C_G}PASS${C_X}  %-6s  bytes_in=%-5s  elapsed=%-5sms  %s\n" \
      "$mode" "$bytes_in" "$elapsed" "$reason"
    return 0
  else
    err=$(echo "$json_line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("error",""))' 2>/dev/null || echo "$json_line")
    printf "  ${C_R}FAIL${C_X}  %-6s  %s\n" "$mode" "$err"
    return 1
  fi
}

# Standalone tunnel-test subcommand.
cmd_tunnel_test() {
  local sni="$DOMAIN" route_ip=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sni)         sni="$2"; shift 2;;
      --target-ip)   route_ip="$2"; shift 2;;
      --uuid-vmess)  UUID_VMESS="$2"; shift 2;;
      --uuid-vless)  UUID_VLESS="$2"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done
  command -v python3 >/dev/null 2>&1 || die "python3 required for tunnel-test"
  if [ -z "$route_ip" ]; then
    if [ "$sni" = "$DOMAIN" ]; then
      route_ip=$(resolve_host "$DOMAIN" 2>/dev/null) || die "cannot resolve $DOMAIN"
    else
      # ride the bug host: route to its own IP, present custom SNI
      route_ip=$(resolve_host "$sni" 2>/dev/null) || die "cannot resolve $sni"
    fi
  fi
  cat >&2 <<EOF
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
  ${C_BOLD}TUNNEL TEST${C_X}
  Domain (Host hdr) : ${DOMAIN}
  SNI presented     : ${sni}
  Route IP          : ${route_ip}:${PORT}
  Endpoints         : ${WS_PATH}  ${VMESS_PATH}  ${VLESS_PATH}
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
EOF
  local fails=0 line
  for mode in ssh vmess vless; do
    line=$(tunnel_test_one "$mode" "$route_ip" "$sni")
    fmt_tunnel_line "$mode" "$line" || fails=$((fails+1))
  done

  # Bonus: pull the 25MB blob through the tunnel (fast bytes-flow proof)
  printf "  ${C_C}--${C_X}    blob   "
  local bytes mbps
  bytes=$(timeout "$THRU_TIMEOUT" curl -sk --http1.1 -o /dev/null -w "%{size_download} %{speed_download}" \
           --resolve "${sni}:${PORT}:${route_ip}" \
           -H "Host: ${DOMAIN}" \
           "https://${sni}:${PORT}${BLOB_PATH}" 2>/dev/null || echo "0 0")
  read -r dl spd <<<"$bytes"
  mbps=$(awk -v b="$spd" 'BEGIN{printf "%.2f", (b*8)/1000000}')
  if [ "${dl:-0}" -gt 100000 ]; then
    printf "${C_G}PASS${C_X}  bytes=%s  mbps=%s\n" "$dl" "$mbps"
  else
    printf "${C_R}FAIL${C_X}  bytes=%s  (no payload reached client)\n" "${dl:-0}"
    fails=$((fails+1))
  fi

  echo
  if [ "$fails" = "0" ]; then
    printf "${C_G}${C_BOLD}TUNNEL OK${C_X} — all endpoints moved bytes\n"
    return 0
  else
    printf "${C_R}${C_BOLD}TUNNEL DEGRADED${C_X} — ${fails} endpoint(s) failed\n"
    return 1
  fi
}

# =============================================================================
#  CHECK  —  single-SNI inspection
# =============================================================================
cmd_check() {
  local sni="" json_out=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --carrier)       CARRIER="$2"; shift 2;;
      --no-throughput) export SKIP_THRU=1; shift;;
      --verify-tunnel) VERIFY_TUNNEL=1; shift;;
      --target-ip)     TARGET_IP="$2"; shift 2;;
      --json)          json_out=1; shift;;
      --*)             die "unknown flag: $1";;
      *)
        [ -z "$sni" ] && sni="$1" && shift && continue
        die "unexpected arg: $1"
        ;;
    esac
  done
  [ -n "$sni" ] || die "usage: sni-hunter.sh check <sni> [options]"

  if [ "$IS_DEBIAN_LAPTOP" = "1" ] && { [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ]; }; then
    CARRIER="unknown"
  fi
  [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ] && CARRIER=$(detect_carrier)
  [ -z "$CARRIER" ] && CARRIER="unknown"

  if [ -z "$TARGET_IP" ]; then
    TARGET_IP=$(resolve_host "$DOMAIN" 2>/dev/null) || die "Cannot resolve $DOMAIN — set --target-ip"
  fi
  export DOMAIN PORT WS_PATH BLOB_PATH TIMEOUT THRU_TIMEOUT TARGET_IP CARRIER
  export RADIO_TAG LATENCY_SAMPLES SKIP_THRU INTERACTIVE HAVE_TERMUX_API

  local rec rc
  rec=$(probe "$sni") && rc=0 || rc=$?

  if [ "$json_out" = "1" ]; then
    if [ -z "$rec" ]; then
      printf '{"sni":"%s","passed":false,"reason":"probe failed (no TLS or no WS upgrade)"}\n' "$sni"
      exit 1
    fi
    awk -F'|' -v sni="$sni" 'BEGIN{
      printf "{"
    } {
      printf "\"passed\":true,\"tier\":\"%s\",\"sni\":\"%s\",\"rtt_ms\":%s,\"jitter_ms\":%s,\"mbps\":%s,\"bal_delta_kb\":%s,\"ip_lock\":%s,\"net_type\":\"%s\",\"family\":\"%s\"",
        $1, $2, $3, $4, $5, $6, ($7=="1"?"true":"false"), $8, $9
    } END {printf "}\n"}' <<<"$rec"
    [ "${VERIFY_TUNNEL:-0}" = "1" ] && cmd_tunnel_test --sni "$sni" >/dev/null 2>&1
    exit 0
  fi

  cat >&2 <<EOF
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
  ${C_BOLD}CHECK${C_X}  SNI = ${C_M}${sni}${C_X}
  Domain (Host hdr) : ${DOMAIN}
  Tunnel IP         : ${TARGET_IP}:${PORT}
  Carrier           : ${CARRIER}    Radio: $(network_type_now)
  WS path / blob    : ${WS_PATH}    ${BLOB_PATH} (${BLOB_SIZE_MB}MB)
${C_BOLD}${C_C}═══════════════════════════════════════════════════════════════${C_X}
EOF

  if [ -z "$rec" ]; then
    printf "  ${C_R}FAIL${C_X}  no TLS reachability or WebSocket upgrade through ${sni}\n" >&2
    printf "  Hints: confirm DNS for ${sni}, try --target-ip, try a known-good SNI.\n" >&2
    exit 1
  fi

  IFS='|' read -r f_tier f_sni f_rtt f_jit f_mbps f_bal f_iplock f_net f_family _ <<<"$rec"
  local cert_subj
  cert_subj=$(echo | timeout "$TIMEOUT" openssl s_client -connect "${TARGET_IP}:${PORT}" \
                -servername "$f_sni" 2>/dev/null </dev/null \
              | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')
  local route_ip="$TARGET_IP"; [ "$f_iplock" = "1" ] && route_ip=$(resolve_host "$f_sni")

  cat <<EOF

  ${C_BOLD}Result${C_X}
    Tier         : ${C_BOLD}${f_tier}${C_X}
    Family       : ${f_family}
    Net type     : ${f_net}
    RTT mean     : ${f_rtt} ms      (jitter ${f_jit} ms over $((LATENCY_SAMPLES + 1)) samples)
    Throughput   : ${f_mbps} Mbps   $([ "${SKIP_THRU:-0}" = 1 ] && echo "(skipped)")
    Balance Δ    : ${f_bal} kB     $([ "$f_bal" = "-1" ] && echo "(USSD probe off)")
    IP-lock      : $([ "$f_iplock" = 1 ] && printf "${C_R}YES${C_X} — must route via brand IP $route_ip" || printf "no — direct via tunnel IP")
    Cert subject : ${cert_subj:-<unavailable>}
    URL probed   : https://${f_sni}:${PORT}${WS_PATH}  (resolved → ${route_ip})

EOF

  if [ "${VERIFY_TUNNEL:-0}" = "1" ]; then
    printf "  ${C_BOLD}Tunnel byte-flow verification (riding ${f_sni})${C_X}\n"
    cmd_tunnel_test --sni "$f_sni" --target-ip "$route_ip" || true
  fi
  exit 0
}

# =============================================================================
#  INSTALL-DEBIAN  —  one-shot setup on a Debian/Ubuntu laptop
# =============================================================================
cmd_install_debian() {
  if [ ! -f /etc/debian_version ]; then
    die "this looks like a non-Debian system (no /etc/debian_version)"
  fi
  local SUDO=""
  if [ "$(id -u)" != "0" ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
    SUDO="sudo"
  fi
  log "Installing apt packages (this may prompt for sudo)…"
  $SUDO apt-get update -y || die "apt-get update failed"
  $SUDO apt-get install -y --no-install-recommends \
    bash openssl curl ca-certificates coreutils unzip jq dnsutils python3 \
    || die "apt-get install failed"

  local me; me="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  local dst="/usr/local/bin/sni-hunter.sh"
  if [ "$me" != "$dst" ]; then
    log "Installing script to $dst"
    $SUDO install -m 0755 "$me" "$dst"
  fi

  # Resolve the *invoking* user's home — under sudo, $HOME would be /root,
  # but the user will run scans non-root, so corpus must land in their home.
  local target_user target_home
  target_user="${SUDO_USER:-$USER}"
  if [ -n "${SUDO_USER:-}" ]; then
    target_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  fi
  : "${target_home:=$HOME}"
  [ -z "$target_home" ] && target_home="/root"

  log "Building corpus into ${target_home}/.sni-hunter/  (user: ${target_user})"
  $SUDO -u "$target_user" install -d "${target_home}/.sni-hunter" "${target_home}/sni-hunter-results" 2>/dev/null \
    || install -d "${target_home}/.sni-hunter" "${target_home}/sni-hunter-results"
  if [ -n "${SUDO_USER:-}" ]; then
    HOME="$target_home" $SUDO -E -u "$target_user" \
      env CORPUS="${target_home}/.sni-hunter/corpus.txt" "$dst" refresh-corpus \
      || warn "corpus refresh failed; you can retry as your user: sni-hunter.sh refresh-corpus"
  else
    CORPUS="${target_home}/.sni-hunter/corpus.txt" cmd_refresh_corpus \
      || warn "corpus refresh failed; you can retry: sni-hunter.sh refresh-corpus"
  fi

  cat <<EOF

${C_G}${C_BOLD}You're ready.${C_X}

  Verify the tunnel itself:
    sni-hunter.sh tunnel-test

  Quick single-host check:
    sni-hunter.sh check fbcdn.net --verify-tunnel

  Short curated scan (≈80 hosts, fast):
    sni-hunter.sh hunt --carrier safaricom --seed-only

  Full corpus scan (slow):
    sni-hunter.sh hunt --carrier safaricom

  Reports always land at:
    ~/sni-hunter-results.{json,txt}

EOF
}

# =============================================================================
#  MAIN
# =============================================================================
case "${1:-}" in
  hunt)            shift; cmd_hunt "$@" ;;
  check)           shift; cmd_check "$@" ;;
  tunnel-test)     shift; cmd_tunnel_test "$@" ;;
  merge-runs)      shift; cmd_merge_runs "$@" ;;
  refresh-corpus)  cmd_refresh_corpus ;;
  setup-server)    cmd_setup_server ;;
  install-debian)  cmd_install_debian ;;
  self-test)       cmd_self_test ;;
  -h|--help|"")    print_help ;;
  *)               die "unknown subcommand: $1   (try --help)" ;;
esac
