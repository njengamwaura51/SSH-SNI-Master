#!/usr/bin/env bash
# =============================================================================
#  sni-hunter v2  —  Advanced SNI / Bug-Host scanner & classifier
#  Works on:  Ubuntu (server, validation mode)  +  Termux on Android (full mode)
#  Tunnel:    shopthelook.page   (or override with DOMAIN=)
#
#  Subcommands
#     sni-hunter.sh hunt [--carrier safaricom|airtel|telkom|auto]
#                        [--limit N]   [--seed-only]   [--no-throughput]
#                        [--out DIR]   [--resume]   [--interactive]
#                        [--radio-tag LTE|UMTS|...]
#     sni-hunter.sh merge-runs DIR_LTE DIR_UMTS [DIR_OUT]
#     sni-hunter.sh refresh-corpus
#     sni-hunter.sh setup-server         (one-time on the tunnel server)
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

IS_TERMUX=0; IS_SERVER=0
[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && IS_TERMUX=1
[ "$(id -u)" = "0" ] && [ -d /etc/nginx ] && IS_SERVER=1
HAVE_TERMUX_API=0
command -v termux-telephony-deviceinfo >/dev/null 2>&1 && HAVE_TERMUX_API=1
HAVE_TERMUX_DIALOG=0
command -v termux-dialog >/dev/null 2>&1 && HAVE_TERMUX_DIALOG=1

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
  sni-hunter.sh hunt [options]              run a scan
  sni-hunter.sh merge-runs A B [OUT]        compare two scans → tag NETWORK_TYPE_SPECIFIC
  sni-hunter.sh refresh-corpus              rebuild the 20k candidate list
  sni-hunter.sh setup-server                one-time install on tunnel server
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
  --out DIR            output directory                       (default: ${OUT_DIR_DEFAULT})
  --resume             continue a previous interrupted scan
  --target-ip IP       force tunnel IP (skip DNS lookup)
  --concurrency N      parallel probes                        (default: ${CONCURRENCY})

${C_BOLD}TWO-RADIO WORKFLOW${C_X} (find 3G-only / 4G-only hosts)
  1) lock phone to LTE → ./sni-hunter.sh hunt --radio-tag LTE  --out ~/run-lte
  2) lock phone to 3G  → ./sni-hunter.sh hunt --radio-tag UMTS --out ~/run-3g
  3) ./sni-hunter.sh merge-runs ~/run-lte ~/run-3g ~/run-merged
     → hosts that passed only one radio are tagged NETWORK_TYPE_SPECIFIC

${C_BOLD}TERMUX QUICKSTART${C_X}
  pkg install -y bash openssl curl coreutils termux-api jq
  curl -O https://${DOMAIN}/sni-hunter.sh && chmod +x sni-hunter.sh
  ./sni-hunter.sh hunt --carrier auto --interactive

${C_BOLD}OUTPUT${C_X}
  <out>/results.json   passing hosts only (full record)
  <out>/results.txt    sorted human-readable report
  <out>/results.csv    raw pipe-delimited records (for merge-runs)
  <out>/checkpoint     for --resume
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
      --out)           out_dir="$2"; shift 2;;
      --resume)        resume=1; shift;;
      --target-ip)     TARGET_IP="$2"; shift 2;;
      --concurrency)   CONCURRENCY="$2"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done

  [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ] && CARRIER=$(detect_carrier)
  [ -z "$CARRIER" ] && CARRIER="unknown"

  if [ -z "$TARGET_IP" ]; then
    TARGET_IP=$(resolve_host "$DOMAIN" 2>/dev/null) || true
  fi
  [ -z "$TARGET_IP" ] && die "Cannot resolve $DOMAIN — set --target-ip <IP>"

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
#  MAIN
# =============================================================================
case "${1:-}" in
  hunt)            shift; cmd_hunt "$@" ;;
  merge-runs)      shift; cmd_merge_runs "$@" ;;
  refresh-corpus)  cmd_refresh_corpus ;;
  setup-server)    cmd_setup_server ;;
  self-test)       cmd_self_test ;;
  -h|--help|"")    print_help ;;
  *)               die "unknown subcommand: $1   (try --help)" ;;
esac
