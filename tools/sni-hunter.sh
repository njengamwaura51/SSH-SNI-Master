#!/usr/bin/env bash
# =============================================================================
#  sni-hunter v2  —  Advanced SNI / Bug-Host scanner & classifier
#  Works on:  Ubuntu (server, validation mode)  +  Termux on Android (full mode)
#  Tunnel:    shopthelook.page   (or override with DOMAIN=)
#
#  Subcommands
#     sni-hunter.sh hunt [--carrier safaricom|airtel|telkom|auto]
#                        [--limit N]   [--seed-only]   [--no-throughput]
#                        [--out DIR]   [--resume]
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
BLOB_PATH="${BLOB_PATH:-/blob-25M}"          # served by nginx, see setup-server
BLOB_SIZE_MB="${BLOB_SIZE_MB:-25}"
TIMEOUT="${TIMEOUT:-6}"
THRU_TIMEOUT="${THRU_TIMEOUT:-12}"
CONCURRENCY="${CONCURRENCY:-30}"
CORPUS="${CORPUS:-/var/lib/sni-hunter/corpus.txt}"
OUT_DIR_DEFAULT="${HOME}/sni-hunter-results"
TARGET_IP=""
CARRIER=""

# UI colors (auto-disabled if not a tty)
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'
  C_C=$'\e[36m'; C_M=$'\e[35m'; C_D=$'\e[2m'; C_X=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_D=""; C_X=""; C_BOLD=""
fi
log()  { printf "%s[%s]%s %s\n" "$C_C" "$(date +%H:%M:%S)" "$C_X" "$*" >&2; }
die()  { printf "%s[FATAL]%s %s\n" "$C_R" "$C_X" "$*" >&2; exit 1; }
warn() { printf "%s[warn]%s %s\n" "$C_Y" "$C_X" "$*" >&2; }

# -------- platform detect ----------------------------------------------------
IS_TERMUX=0; IS_SERVER=0
if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]]; then IS_TERMUX=1; fi
if [ "$(id -u)" = "0" ] && [ -d /etc/nginx ]; then IS_SERVER=1; fi
HAVE_TERMUX_API=0
command -v termux-telephony-deviceinfo >/dev/null 2>&1 && HAVE_TERMUX_API=1

# =============================================================================
#  HELP
# =============================================================================
print_help() {
cat <<EOF
${C_BOLD}sni-hunter v2${C_X}  —  bug-host scanner & classifier for ${DOMAIN}

${C_BOLD}USAGE${C_X}
  sni-hunter.sh hunt [options]      run a scan
  sni-hunter.sh refresh-corpus      rebuild the 20k candidate list
  sni-hunter.sh setup-server        one-time install on the tunnel server
  sni-hunter.sh self-test           classifier sanity tests
  sni-hunter.sh --help              this text

${C_BOLD}HUNT OPTIONS${C_X}
  --carrier X      safaricom | airtel | telkom | auto    (default: auto)
  --limit N        cap candidate count                   (default: all of corpus)
  --seed-only      only scan the built-in carrier seeds (~80 hosts, fast)
  --no-throughput  skip the slow MB-pull stage (faster, no tier classification)
  --out DIR        output directory                      (default: ${OUT_DIR_DEFAULT})
  --resume         continue a previous interrupted scan
  --target-ip IP   force tunnel IP (skip DNS lookup)
  --concurrency N  parallel probes                       (default: ${CONCURRENCY})

${C_BOLD}TERMUX QUICKSTART${C_X} (run on phone over mobile data)
  pkg install -y bash openssl curl coreutils termux-api jq
  curl -O https://${DOMAIN}/sni-hunter.sh && chmod +x sni-hunter.sh
  ./sni-hunter.sh hunt --carrier auto

${C_BOLD}OUTPUT${C_X}
  <out>/results.json   structured records, passing hosts only
  <out>/results.txt    sorted human-readable report
  <out>/checkpoint     for --resume

Failing hosts are silently discarded.
EOF
}

# =============================================================================
#  SETUP-SERVER  (run once on tunnel server, as root)
# =============================================================================
cmd_setup_server() {
  [ "$IS_SERVER" = "1" ] || die "setup-server must run as root on the tunnel server (Ubuntu + nginx)"
  log "Installing /usr/local/bin/sni-hunter.sh"
  install -m 0755 "$0" /usr/local/bin/sni-hunter.sh

  log "Publishing script for phone download at https://${DOMAIN}/sni-hunter.sh"
  install -d /var/www/letsencrypt
  install -m 0644 "$0" /var/www/letsencrypt/sni-hunter.sh

  log "Generating ${BLOB_SIZE_MB}MB throughput blob at /var/www/letsencrypt${BLOB_PATH}"
  dd if=/dev/urandom of="/var/www/letsencrypt${BLOB_PATH}" bs=1M count="${BLOB_SIZE_MB}" status=none
  chmod 0644 "/var/www/letsencrypt${BLOB_PATH}"

  log "Building 20k candidate corpus"
  cmd_refresh_corpus

  cat <<EOF

${C_G}Server is ready.${C_X}
  Phone download :  curl -O https://${DOMAIN}/sni-hunter.sh
  Local run      :  /usr/local/bin/sni-hunter.sh hunt --seed-only
  Corpus path    :  ${CORPUS}   ($(wc -l < "$CORPUS" 2>/dev/null || echo 0) hosts)

EOF
}

# =============================================================================
#  CORPUS BUILDER
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
  install -d "$(dirname "$CORPUS")" 2>/dev/null || install -d "$HOME/.sni-hunter" && CORPUS="$HOME/.sni-hunter/corpus.txt"
  local tmp; tmp=$(mktemp)
  log "Fetching Tranco top-1M (this may take a minute)..."
  if curl -fsSL --max-time 60 -o "${tmp}.tranco.zip" \
       "https://tranco-list.eu/top-1m.csv.zip" 2>/dev/null; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -p "${tmp}.tranco.zip" | head -n 18000 | awk -F, '{print $2}' >> "$tmp"
      log "  Tranco: $(wc -l < "$tmp") hosts"
    else
      warn "unzip not available — falling back to seeds only"
    fi
  else
    warn "Tranco fetch failed — using seeds + universal list only"
  fi

  log "Fetching Cisco Umbrella top-1M..."
  if curl -fsSL --max-time 60 -o "${tmp}.umb.zip" \
       "https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip" 2>/dev/null; then
    command -v unzip >/dev/null 2>&1 && \
      unzip -p "${tmp}.umb.zip" | head -n 8000 | awk -F, '{print $2}' >> "$tmp"
  else
    warn "Umbrella fetch failed (non-fatal)"
  fi

  # add seeds
  printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${AIRTEL_SEEDS[@]}" \
                "${TELKOM_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" >> "$tmp"

  # clean: lowercase, strip subs of "localhost", keep only valid hostnames, dedupe, cap
  awk 'BEGIN{IGNORECASE=1}
       /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/ && !/localhost/ && !/\.local$/ && length($0)<=80 {print tolower($0)}' \
       "$tmp" | awk '!seen[$0]++' | head -n 20000 > "$CORPUS"
  rm -f "$tmp" "${tmp}.tranco.zip" "${tmp}.umb.zip"
  log "Corpus saved: ${C_G}$(wc -l < "$CORPUS") hosts${C_X} → ${CORPUS}"
}

# =============================================================================
#  CARRIER DETECTION
# =============================================================================
detect_carrier() {
  if [ "$HAVE_TERMUX_API" = "1" ]; then
    local mccmnc op
    op=$(termux-telephony-deviceinfo 2>/dev/null | jq -r '.network_operator_name // empty' | tr '[:upper:]' '[:lower:]')
    mccmnc=$(termux-telephony-deviceinfo 2>/dev/null | jq -r '.network_operator // empty')
    case "$op" in
      *safaricom*) echo safaricom; return ;;
      *airtel*)    echo airtel;    return ;;
      *telkom*)    echo telkom;    return ;;
    esac
    case "$mccmnc" in
      63902|63907) echo safaricom; return ;;
      63903|63905) echo airtel;    return ;;
      63907|63911) echo telkom;    return ;;   # Telkom KE = 63907 (shared with Safaricom legacy) / 63911
    esac
  fi
  echo unknown
}

network_type_now() {
  if [ "$HAVE_TERMUX_API" = "1" ]; then
    termux-telephony-deviceinfo 2>/dev/null | jq -r '.data_network_type // .network_type // "unknown"'
  else
    echo "unknown"
  fi
}

# =============================================================================
#  PROBE PIPELINE  —  runs once per candidate SNI, returns one CSV line on PASS
#  Format: tier|sni|rtt_ms|mbps|ip_lock|net_type|family|http_code
# =============================================================================
classify_family() {
  case "$1" in
    *facebook*|*fbcdn*|*instagram*) echo "META" ;;
    *whatsapp*)      echo "WHATSAPP" ;;
    *youtube*|*googlevideo*|*ytimg*) echo "YOUTUBE" ;;
    *tiktok*|*musical*) echo "TIKTOK" ;;
    *google*|*gstatic*|*googleapis*) echo "GOOGLE" ;;
    *safaricom*|*mpesa*|*bonga*) echo "SAFARICOM" ;;
    *airtel*) echo "AIRTEL" ;;
    *telkom*|*faiba*|*t-kash*) echo "TELKOM" ;;
    *cloudflare*|*cloudfront*|*akamai*|*fastly*) echo "CDN" ;;
    *netflix*) echo "NETFLIX" ;;
    *zoom*) echo "ZOOM" ;;
    *) echo "OTHER" ;;
  esac
}

# Read carrier balance via USSD (best-effort, Termux only).
# Falls back to printing 0 if not supported.
balance_kb() {
  # Real USSD scripting on Android requires user interaction; we cannot read
  # the popup response programmatically without root. Return 0 — the user can
  # diff manually pre/post by dialing *544# (Safaricom) etc.
  echo 0
}

probe() {
  local sni="$1"
  local t0 t1 dt code mbps iplock=0 family ntype
  t0=$(date +%s%3N)

  # ---- stage 1: TLS reachability with SNI=candidate, IP=our server ---------
  if ! echo | timeout "$TIMEOUT" openssl s_client -connect "${TARGET_IP}:${PORT}" \
        -servername "$sni" 2>/dev/null </dev/null | grep -q "BEGIN CERTIFICATE"; then
    return 1
  fi

  # ---- stage 2: WebSocket upgrade through tunnel ---------------------------
  code=$(timeout "$TIMEOUT" curl -sk --http1.1 -o /dev/null -w "%{http_code}" \
           --resolve "${sni}:${PORT}:${TARGET_IP}" \
           -H "Host: ${DOMAIN}" \
           -H "Upgrade: websocket" -H "Connection: Upgrade" \
           -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
           -H "Sec-WebSocket-Version: 13" \
           "https://${sni}:${PORT}${WS_PATH}" 2>/dev/null)
  [ "$code" = "101" ] || return 1

  t1=$(date +%s%3N); dt=$((t1-t0))
  family=$(classify_family "$sni")
  ntype=$(network_type_now)

  # ---- stage 3: throughput probe (skippable) -------------------------------
  if [ "${SKIP_THRU:-0}" = "1" ]; then
    mbps="-1"   # unknown → defer tier
  else
    mbps=$(timeout "$THRU_TIMEOUT" curl -sk --http1.1 -o /dev/null -w "%{speed_download}" \
             --resolve "${sni}:${PORT}:${TARGET_IP}" \
             -H "Host: ${DOMAIN}" \
             "https://${sni}:${PORT}${BLOB_PATH}" 2>/dev/null || echo 0)
    # bytes/s → Mbps (×8 ÷ 1e6)
    mbps=$(awk -v b="$mbps" 'BEGIN{printf "%.2f", (b*8)/1000000}')
  fi

  # ---- stage 4: IP-lock probe — does carrier require dst-IP=brand IP? ------
  # Resolve candidate's real IP and try connecting there with Host=our domain.
  # If WS upgrade only works via candidate IP and NOT via our IP (already ruled
  # out above since stage 2 passed), it's NOT ip-locked. If it ALSO works via
  # candidate IP, mark as ip-flexible. We tag ip_lock=1 only when carrier seems
  # to require the brand IP — which we can't fully determine remotely; leave 0.
  iplock=0

  # ---- stage 5: tier classification ----------------------------------------
  local tier
  tier=$(classify_tier "$mbps" "$ntype" "$family")

  printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
    "$tier" "$sni" "$dt" "$mbps" "$iplock" "$ntype" "$family" "$code"
}

classify_tier() {
  local mbps="$1" ntype="$2" family="$3"
  # mbps == -1  → throughput skipped
  if [ "$mbps" = "-1" ]; then echo "PASS_NOTHRU"; return; fi
  # numeric compare
  awk -v m="$mbps" -v n="$ntype" -v f="$family" '
    BEGIN {
      if (m+0 >= 80)        tier="UNLIMITED_FREE"
      else if (m+0 >= 50)   tier="CAPPED_100M"
      else if (m+0 >= 12)   tier="CAPPED_100M"
      else if (m+0 >= 1.5)  tier="CAPPED_20M"
      else if (m+0 > 0)     tier="THROTTLED"
      else                  tier="DEAD"
      # app-tunnel override for known zero-rated families
      if (m+0 >= 1 && (f=="META"||f=="WHATSAPP"||f=="YOUTUBE"||f=="TIKTOK"))
        tier = "APP_TUNNEL_" f
      print tier
    }'
}

# =============================================================================
#  SELF-TEST  (classifier sanity)
# =============================================================================
cmd_self_test() {
  local fails=0
  check() {
    local exp got; exp="$1"; shift
    got=$(classify_tier "$@")
    if [ "$got" = "$exp" ]; then
      printf "  ${C_G}ok${C_X}    classify_tier %-18s -> %s\n" "$*" "$got"
    else
      printf "  ${C_R}FAIL${C_X}  classify_tier %-18s -> %s (expected %s)\n" "$*" "$got" "$exp"; fails=$((fails+1))
    fi
  }
  check UNLIMITED_FREE         "92.0"  "LTE" "OTHER"
  check CAPPED_100M            "55.0"  "LTE" "OTHER"
  check CAPPED_100M            "13.0"  "LTE" "OTHER"
  check CAPPED_20M             "2.4"   "LTE" "OTHER"
  check THROTTLED              "0.4"   "LTE" "OTHER"
  check DEAD                   "0"     "LTE" "OTHER"
  check APP_TUNNEL_META        "30"    "LTE" "META"
  check APP_TUNNEL_WHATSAPP    "5"     "LTE" "WHATSAPP"
  check PASS_NOTHRU            "-1"    "LTE" "OTHER"
  echo
  if [ "$fails" = "0" ]; then echo "${C_G}all tests passed${C_X}"; else echo "${C_R}${fails} failure(s)${C_X}"; exit 1; fi
}

# =============================================================================
#  HUNT
# =============================================================================
cmd_hunt() {
  # ---- args ----
  local seed_only=0 limit="" out_dir="$OUT_DIR_DEFAULT" resume=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --carrier)       CARRIER="$2"; shift 2;;
      --limit)         limit="$2"; shift 2;;
      --seed-only)     seed_only=1; shift;;
      --no-throughput) export SKIP_THRU=1; shift;;
      --out)           out_dir="$2"; shift 2;;
      --resume)        resume=1; shift;;
      --target-ip)     TARGET_IP="$2"; shift 2;;
      --concurrency)   CONCURRENCY="$2"; shift 2;;
      *) die "unknown flag: $1";;
    esac
  done

  # ---- carrier ----
  [ -z "$CARRIER" ] || [ "$CARRIER" = "auto" ] && CARRIER=$(detect_carrier)
  [ -z "$CARRIER" ] && CARRIER="unknown"

  # ---- target ip ----
  if [ -z "$TARGET_IP" ]; then
    TARGET_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$TARGET_IP" ] && TARGET_IP=$(curl -sk --max-time 5 -o /dev/null -w "%{remote_ip}" "https://${DOMAIN}/" 2>/dev/null || true)
  fi
  [ -z "$TARGET_IP" ] && die "Cannot resolve $DOMAIN — set --target-ip <IP>"

  # ---- candidate list ----
  install -d "$out_dir"
  local cand_file="${out_dir}/candidates.txt"
  if [ "$seed_only" = "1" ]; then
    case "$CARRIER" in
      safaricom) printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${UNIVERSAL_SEEDS[@]}" ;;
      airtel)    printf "%s\n" "${AIRTEL_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" ;;
      telkom)    printf "%s\n" "${TELKOM_SEEDS[@]}"    "${UNIVERSAL_SEEDS[@]}" ;;
      *)         printf "%s\n" "${SAFARICOM_SEEDS[@]}" "${AIRTEL_SEEDS[@]}" "${TELKOM_SEEDS[@]}" "${UNIVERSAL_SEEDS[@]}" ;;
    esac | awk '!seen[$0]++' > "$cand_file"
  else
    [ -s "$CORPUS" ] || die "No corpus at $CORPUS — run: $0 refresh-corpus"
    cp "$CORPUS" "$cand_file"
    # prepend carrier seeds so they probe first
    case "$CARRIER" in
      safaricom) printf "%s\n" "${SAFARICOM_SEEDS[@]}" | cat - "$cand_file" | awk '!seen[$0]++' > "$cand_file.tmp" && mv "$cand_file.tmp" "$cand_file" ;;
      airtel)    printf "%s\n" "${AIRTEL_SEEDS[@]}"    | cat - "$cand_file" | awk '!seen[$0]++' > "$cand_file.tmp" && mv "$cand_file.tmp" "$cand_file" ;;
      telkom)    printf "%s\n" "${TELKOM_SEEDS[@]}"    | cat - "$cand_file" | awk '!seen[$0]++' > "$cand_file.tmp" && mv "$cand_file.tmp" "$cand_file" ;;
    esac
  fi
  [ -n "$limit" ] && head -n "$limit" "$cand_file" > "$cand_file.tmp" && mv "$cand_file.tmp" "$cand_file"

  local total; total=$(wc -l < "$cand_file")
  local pass_file="${out_dir}/results.csv"
  local checkpoint="${out_dir}/checkpoint"

  if [ "$resume" = "1" ] && [ -s "$checkpoint" ]; then
    log "Resuming — skipping $(wc -l < "$checkpoint") already-probed hosts"
    grep -vxF -f "$checkpoint" "$cand_file" > "$cand_file.todo"
  else
    : > "$pass_file"; : > "$checkpoint"
    cp "$cand_file" "$cand_file.todo"
  fi

  # ---- banner ----
  cat >&2 <<EOF
${C_BOLD}${C_C}══════════════════════════════════════════════════════════${C_X}
  ${C_BOLD}SNI HUNTER v2${C_X}
  Domain         : ${DOMAIN}
  Tunnel IP      : ${TARGET_IP}
  Carrier        : ${C_M}${CARRIER}${C_X}
  Network type   : $(network_type_now)
  Candidates     : ${total}  ($([ "$seed_only" = 1 ] && echo "seeds only" || echo "full corpus"))
  Concurrency    : ${CONCURRENCY}     Throughput: $([ "${SKIP_THRU:-0}" = 1 ] && echo SKIPPED || echo "${BLOB_SIZE_MB}MB")
  Output dir     : ${out_dir}
${C_BOLD}${C_C}══════════════════════════════════════════════════════════${C_X}

EOF

  # ---- export everything probe() needs to subshells ----
  export DOMAIN PORT WS_PATH BLOB_PATH TIMEOUT THRU_TIMEOUT TARGET_IP
  export -f probe classify_family classify_tier network_type_now balance_kb
  export HAVE_TERMUX_API SKIP_THRU

  # ---- run ----
  local started; started=$(date +%s)
  local n=0
  # progress in background
  ( while [ ! -f "${out_dir}/.done" ]; do
      sleep 5
      local d p
      d=$(wc -l < "$checkpoint" 2>/dev/null || echo 0)
      p=$(wc -l < "$pass_file"  2>/dev/null || echo 0)
      printf "%s  scanned %5d/%-5d   pass %3d   elapsed %ds%s\r" \
        "$C_D" "$d" "$total" "$p" "$(( $(date +%s) - started ))" "$C_X" >&2
    done
  ) &
  local pp=$!

  while IFS= read -r host; do
    [ -z "$host" ] && continue
    printf "%s\n" "$host"
  done < "$cand_file.todo" | \
    xargs -n1 -P "$CONCURRENCY" -I{} bash -c '
      out=$(probe "$1") && echo "$out" >> "'"$pass_file"'"
      echo "$1" >> "'"$checkpoint"'"
    ' _ {}

  touch "${out_dir}/.done"; kill "$pp" 2>/dev/null; wait 2>/dev/null
  printf "\n\n"

  # ---- write outputs ----
  format_outputs "$out_dir" "$pass_file"

  local elapsed=$(( $(date +%s) - started ))
  log "Done in ${elapsed}s. ${C_G}$(wc -l < "$pass_file") passing${C_X} of ${total}."
  log "Reports: ${out_dir}/results.txt   ${out_dir}/results.json"
  rm -f "${out_dir}/.done" "$cand_file.todo"
}

# =============================================================================
#  OUTPUT FORMATTERS
# =============================================================================
format_outputs() {
  local out_dir="$1" csv="$2"
  local txt="${out_dir}/results.txt"
  local json="${out_dir}/results.json"

  # tier sort priority
  local sort_csv; sort_csv=$(mktemp)
  awk -F'|' '{
    p=99
    if ($1=="UNLIMITED_FREE")          p=1
    else if ($1=="CAPPED_100M")        p=2
    else if ($1=="CAPPED_20M")         p=3
    else if ($1 ~ /^APP_TUNNEL_/)      p=4
    else if ($1=="PASS_NOTHRU")        p=5
    else if ($1=="THROTTLED")          p=6
    else if ($1=="BUNDLE_REQUIRED")    p=7
    else if ($1=="IP_LOCKED")          p=8
    print p"|"$0
  }' "$csv" | sort -t'|' -k1,1n -k5,5gr | cut -d'|' -f2- > "$sort_csv"

  {
    printf "# SNI Hunter results — %s — carrier=%s — domain=%s\n" "$(date -Iseconds)" "${CARRIER:-unknown}" "$DOMAIN"
    printf "# %-22s  %-32s  %7s  %7s  %-8s  %-12s  %-6s\n" \
      TIER SNI RTT_ms MBPS IP_LOCK NET_TYPE FAMILY
    awk -F'|' '{
      printf "  %-22s  %-32s  %7s  %7s  %-8s  %-12s  %-6s\n",
        $1, $2, $3, $4, ($5=="1"?"yes":"no"), $6, $7
    }' "$sort_csv"
  } > "$txt"

  # JSON
  awk -F'|' 'BEGIN{print "["; first=1}
    {
      if (!first) printf ",\n"; first=0
      gsub(/"/,"\\\"",$2)
      printf "  {\"tier\":\"%s\",\"sni\":\"%s\",\"rtt_ms\":%s,\"mbps\":%s,\"ip_lock\":%s,\"net_type\":\"%s\",\"family\":\"%s\",\"http\":%s}",
        $1,$2,$3,$4,($5=="1"?"true":"false"),$6,$7,$8
    }
    END{print "\n]"}' "$sort_csv" > "$json"

  # stdout summary
  printf "\n${C_BOLD}=== Top 30 ===${C_X}\n"
  printf "  %-22s  %-32s  %7s  %7s  %-12s  %-8s\n" TIER SNI RTT MBPS NET FAMILY
  head -n 30 "$sort_csv" | awk -F'|' -v g="$C_G" -v y="$C_Y" -v r="$C_R" -v x="$C_X" '{
    c=g
    if ($1 ~ /THROTTLED|PASS_NOTHRU|BUNDLE/) c=y
    if ($1 ~ /DEAD|IP_LOCKED/)               c=r
    printf "  %s%-22s%s  %-32s  %7s  %7s  %-12s  %-8s\n", c,$1,x,$2,$3,$4,$6,$7
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
  refresh-corpus)  cmd_refresh_corpus ;;
  setup-server)    cmd_setup_server ;;
  self-test)       cmd_self_test ;;
  -h|--help|"")    print_help ;;
  *)               die "unknown subcommand: $1   (try --help)" ;;
esac
