#!/system/bin/sh
# Root Network Unblocker v2.6 - Cloudflare WARP & Proxy controller (sing-box) for rooted Android
# Path: /data/local/tmp/unblock.sh
#
# Independent & composable modes:
#   warp  -> device -> WARP -> internet
#   proxy -> device -> proxy -> internet
#   both  -> device -> WARP -> proxy -> internet
#
# Stopping WARP while in "both" keeps proxy running ("proxy").
# Stopping proxy while in "both" keeps WARP running ("warp").

VERSION="2.6"

export PATH="$PATH:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
PID_FILE="$WORK_DIR/singbox.pid"
LOG_FILE="$WORK_DIR/singbox.log"
STATE_FILE="$WORK_DIR/state.env"
ACTIVE_PROXY_FILE="$WORK_DIR/active.proxy"
MODE_FILE="$WORK_DIR/active.mode"
WARP_OK_FILE="$WORK_DIR/warp.ok"
CRED_FILE="/data/adb/warp.conf"
OLD_CRED_FILE="$WORK_DIR/warp_creds.env"
USER_CONF="/data/adb/unblock.conf"
BOOT_HOOK="/data/adb/service.d/99-unblock.sh"
V6_CHAIN="UNBLOCK_V6"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

say()  { printf '%b\n' "$*"; }
info() { say "${CYAN}[*] $*${NC}"; }
warn() { say "${YELLOW}[!] $*${NC}"; }
ok()   { say "${GREEN}[+] $*${NC}"; }
die()  { say "${RED}[x] $*${NC}"; exit 1; }

# ---------------------------------------------------------------- helpers

is_running() {
  [ -f "$PID_FILE" ] || return 1
  _pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

# warp | proxy | both | ""
current_mode() {
  is_running && cat "$MODE_FILE" 2>/dev/null
}

need_curl() {
  command -v curl >/dev/null 2>&1 || die "curl not found. In Termux run: pkg install curl"
}

json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

CONF_VARS="PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE WARP_ENDPOINT WARP_PORT WARP_MTU TUN_STACK SB_VER BLOCK_IPV6 HIDE_PASS PRIVATE_DNS KEEP_ON_FAIL DNS_TRIES FAST_START"

load_user_conf() {
  [ -f "$USER_CONF" ] || return 0
  for v in $CONF_VARS; do
    eval "cli_$v=\"\$$v\""
  done
  . "$USER_CONF"
  for v in $CONF_VARS; do
    eval "[ -n \"\$cli_$v\" ] && $v=\"\$cli_$v\""
  done
}

# ---------------------------------------------------------------- interactive helpers

ask() {
  printf '%b' "${CYAN}$2${NC}"
  read -r _a || die "Input closed."
  _a=$(printf '%s' "$_a" | tr -d '\r')
  eval "$1=\$_a"
}

ask_secret() {
  if [ "$HIDE_PASS" = "1" ] && [ -r /dev/tty ]; then
    printf '%b' "${CYAN}$2${NC}"
    ( trap '' TTOU; stty -echo </dev/tty ) 2>/dev/null
    read -r _a </dev/tty || _a=""
    ( trap '' TTOU; stty echo </dev/tty ) 2>/dev/null
    printf '\n'
  else
    ask _a "$2(visible) "
  fi
  _a=$(printf '%s' "$_a" | tr -d '\r')
  eval "$1=\$_a"
}

confirm() {
  while :; do
    if [ "$2" = "Y" ]; then
      printf '%b' "${CYAN}$1 [Y/n]: ${NC}"
    else
      printf '%b' "${CYAN}$1 [y/N]: ${NC}"
    fi
    read -r _a || die "Input closed."
    _a=$(printf '%s' "$_a" | tr -d '\r')
    [ -n "$_a" ] || _a="$2"
    case "$_a" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
    esac
  done
}

is_ip()      { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_host() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; }
valid_port() { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_mtu()  { printf '%s' "$1" | grep -Eq '^[0-9]{3,4}$' && [ "$1" -ge 1200 ] && [ "$1" -le 1500 ]; }

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

proxy_summary() {
  S="$PROXY_TYPE://$PROXY_IP:$PROXY_PORT"
  [ -n "$PROXY_USER" ] && S="$S (user: $PROXY_USER)"
  printf '%s' "$S"
}

clear_proxy_vars() {
  PROXY_TYPE=""; PROXY_IP=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""
}

proxy_wizard() {
  say "${CYAN}--- Proxy setup ---${NC}"
  say "  1) socks5"
  say "  2) socks4"
  say "  3) http"
  say "  4) https"
  while :; do
    ask _c "Proxy type [1-4] (default 1): "
    case "$_c" in
      ""|1|socks5) PROXY_TYPE=socks5; break ;;
      2|socks4)    PROXY_TYPE=socks4; break ;;
      3|http)      PROXY_TYPE=http;   break ;;
      4|https)     PROXY_TYPE=https;  break ;;
      *) warn "Please choose 1, 2, 3 or 4." ;;
    esac
  done
  while :; do
    ask PROXY_IP "Proxy IP / host: "
    valid_host "$PROXY_IP" && break
    warn "Invalid IP / host."
  done
  while :; do
    ask PROXY_PORT "Proxy port: "
    valid_port "$PROXY_PORT" && break
    warn "Port must be a number between 1 and 65535."
  done
  PROXY_PASS=""
  ask PROXY_USER "Username (press Enter if none): "
  if [ -n "$PROXY_USER" ]; then
    if [ "$PROXY_TYPE" = "socks4" ]; then
      warn "SOCKS4 has no password support - only the user id is sent."
    else
      ask_secret PROXY_PASS "Password (press Enter if none): "
    fi
  fi
}

PROXY_LINE_RE='^[[:space:]]*PROXY_(TYPE|IP|PORT|USER|PASS)='

remove_proxy_conf() {
  [ -f "$USER_CONF" ] || return 0
  ( umask 077
    grep -Ev "$PROXY_LINE_RE" "$USER_CONF" > "$USER_CONF.tmp" 2>/dev/null || : > "$USER_CONF.tmp"
    cat "$USER_CONF.tmp" > "$USER_CONF"
    rm -f "$USER_CONF.tmp" )
}

save_proxy_conf() {
  mkdir -p "$(dirname "$USER_CONF")"
  remove_proxy_conf
  ( umask 077
    {
      printf 'PROXY_TYPE=%s\n' "$(sq "$PROXY_TYPE")"
      printf 'PROXY_IP=%s\n'   "$(sq "$PROXY_IP")"
      printf 'PROXY_PORT=%s\n' "$(sq "$PROXY_PORT")"
      [ -n "$PROXY_USER" ] && printf 'PROXY_USER=%s\n' "$(sq "$PROXY_USER")"
      [ -n "$PROXY_PASS" ] && printf 'PROXY_PASS=%s\n' "$(sq "$PROXY_PASS")"
    } >> "$USER_CONF" )
  chmod 600 "$USER_CONF" 2>/dev/null
}

maybe_ask_proxy() {
  [ -n "$NOASK" ] && return 0
  [ -n "$PROXY_EXPLICIT" ] && return 0
  [ -t 0 ] || return 0
  if [ -n "$PROXY_IP" ]; then
    say "${CYAN}Saved proxy:${NC} $(proxy_summary)"
    say "  1) Use it"
    say "  2) Change it"
    say "  3) No proxy this time"
    ask _c "Choice [1]: "
    case "$_c" in
      2) proxy_wizard
         confirm "Save this proxy for next time?" Y && { save_proxy_conf; ok "Proxy saved."; } ;;
      3) clear_proxy_vars ;;
    esac
  else
    if confirm "Do you want to use a proxy (socks5 / socks4 / http / https)?" N; then
      proxy_wizard
      confirm "Save this proxy for next time?" Y && { save_proxy_conf; ok "Proxy saved."; }
    fi
  fi
}

ensure_proxy() {
  if [ -z "$PROXY_IP" ] || [ -z "$PROXY_PORT" ]; then
    [ -t 0 ] || die "No proxy saved. Run: su -c 'sh $SELF proxy set'"
    warn "No proxy saved yet - let's set one up."
    proxy_wizard
    confirm "Save this proxy for next time?" Y && { save_proxy_conf; ok "Proxy saved."; }
  fi
}

# ---------------------------------------------------------------- install

download_core() {
  need_curl
  mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"

  case "$(uname -m)" in
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7*|armv8l|arm) SB_ARCH="armv7" ;;
    x86_64) SB_ARCH="amd64" ;;
    i686|i386) SB_ARCH="386" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  URL="${SB_URL:-https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-android-${SB_ARCH}.tar.gz}"
  info "Downloading sing-box ${SB_VER} (${SB_ARCH})..."
  curl -fL --retry 3 --connect-timeout 15 -o "$WORK_DIR/sb.tar.gz" "$URL" \
    || die "Download failed. Check internet, or set SB_URL=<mirror link>."

  tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" || die "Extraction failed."
  mv "$WORK_DIR"/sing-box-*/sing-box "$SINGBOX_BIN" 2>/dev/null || die "sing-box binary not found in archive."
  rm -rf "$WORK_DIR"/sing-box-* "$WORK_DIR/sb.tar.gz"
  chmod 755 "$SINGBOX_BIN"

  "$SINGBOX_BIN" version >/dev/null 2>&1 || die "Downloaded binary does not run on this device."
  ok "Core installed: $("$SINGBOX_BIN" version 2>/dev/null | head -n1)"
}

register_warp() {
  need_curl
  KEYS=$("$SINGBOX_BIN" generate wg-keypair 2>/dev/null)
  PRIV_KEY=$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p')
  PUB_KEY=$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p')
  [ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "Key generation failed."

  info "Registering a free Cloudflare WARP account..."
  TOS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  BODY="{\"key\":\"$PUB_KEY\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$TOS\",\"type\":\"Android\",\"model\":\"PC\",\"locale\":\"en_US\"}"

  CLIENT_IPV4=""
  for V in v0a1922 v0a2158; do
    RES=$(curl -s --connect-timeout 10 --max-time 30 -X POST "https://api.cloudflareclient.com/$V/reg" \
      -H "Content-Type: application/json" \
      -H "User-Agent: okhttp/3.12.1" \
      -H "CF-Client-Version: a-6.3-1922" \
      -d "$BODY")
    CLIENT_IPV4=$(printf '%s' "$RES" | grep -o '"v4":"172\.[^"]*"' | head -n1 | cut -d'"' -f4)
    [ -n "$CLIENT_IPV4" ] && break
  done
  [ -n "$CLIENT_IPV4" ] || die "WARP registration failed (API unreachable or rate-limited). Try again later."

  PEER_PUB=$(printf '%s' "$RES" | grep -o '"public_key":"[^"]*"' | head -n1 | cut -d'"' -f4)
  CLIENT_ID=$(printf '%s' "$RES" | grep -o '"client_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
  [ -n "$PEER_PUB" ] || die "Could not read WARP peer key from API response."

  RESERVED=""
  if [ -n "$CLIENT_ID" ]; then
    R=$(printf '%s' "$CLIENT_ID" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null | tr -s ' ' ',' | sed 's/^,//; s/,$//')
    printf '%s' "$R" | grep -Eq '^[0-9]+,[0-9]+,[0-9]+$' && RESERVED="$R"
  fi

  mkdir -p "$(dirname "$CRED_FILE")"
  ( umask 077
    cat > "$CRED_FILE" <<EOF
PRIV_KEY="$PRIV_KEY"
CLIENT_IPV4="$CLIENT_IPV4"
PEER_PUB="$PEER_PUB"
RESERVED="$RESERVED"
EOF
  )
  chmod 600 "$CRED_FILE"
  ok "WARP account saved to $CRED_FILE (IP: $CLIENT_IPV4)"
}

install_core() {
  info "Installing Root Network Unblocker v$VERSION..."
  if [ ! -x "$SINGBOX_BIN" ] || [ -n "$FORCE" ]; then
    download_core
  else
    ok "Core already present (use FORCE=1 to re-download)."
  fi
  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    mkdir -p "$(dirname "$CRED_FILE")"
    cp "$OLD_CRED_FILE" "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    ok "Migrated old credentials to $CRED_FILE"
  fi
  if [ ! -f "$CRED_FILE" ]; then
    register_warp
  else
    ok "WARP credentials already exist (use 'renew' to create new ones)."
  fi
  info "Ready! Commands: warp on|off | proxy on|off | all on|off"
}

renew_warp() {
  [ -x "$SINGBOX_BIN" ] || die "Core not installed. Run 'install' first."
  _prev_mode=$(current_mode)
  is_running && stop_bypass
  rm -f "$CRED_FILE" "$WARP_OK_FILE"
  register_warp
  if [ "$_prev_mode" = "warp" ] || [ "$_prev_mode" = "both" ]; then
    MODE="$_prev_mode"
    NOASK=1
    start_bypass
  fi
}

# ---------------------------------------------------------------- config

load_creds() {
  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    cp "$OLD_CRED_FILE" "$CRED_FILE" && chmod 600 "$CRED_FILE"
  fi
  if [ ! -f "$CRED_FILE" ]; then
    info "No WARP account yet - registering one..."
    register_warp
  fi
  . "$CRED_FILE"
  PRIV_KEY=$(printf '%s' "$PRIV_KEY" | tr -cd 'A-Za-z0-9+/=')
  PEER_PUB=$(printf '%s' "$PEER_PUB" | tr -cd 'A-Za-z0-9+/=')
  CLIENT_IPV4=$(printf '%s' "$CLIENT_IPV4" | tr -cd '0-9.')
  RESERVED=$(printf '%s' "$RESERVED" | tr -cd '0-9,')
  [ "${#PRIV_KEY}" -eq 44 ] && [ "${#PEER_PUB}" -eq 44 ] \
    && printf '%s' "$CLIENT_IPV4" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "WARP credentials are corrupted. Run: su -c 'sh $SELF renew'"
  printf '%s' "$RESERVED" | grep -Eq '^[0-9]+,[0-9]+,[0-9]+$' || RESERVED=""
}

wg_outbound() {
  RES_LINE=""
  [ -n "$RESERVED" ] && RES_LINE="\"reserved\": [$RESERVED],"
  _mtu="${WARP_MTU:-1360}"
  valid_mtu "$_mtu" || _mtu="1360"
  cat <<EOF
{
  "type": "wireguard",
  "tag": "warp-out",
  "server": "$WARP_ENDPOINT",
  "server_port": $WARP_PORT,
  "local_address": ["$CLIENT_IPV4/32"],
  "private_key": "$PRIV_KEY",
  "peer_public_key": "$PEER_PUB",
  $RES_LINE
  "mtu": $_mtu
}
EOF
}

proxy_outbound() {
  EXTRA=""
  case "$PROXY_TYPE" in
    socks5) P_TYPE="socks"; EXTRA='"version": "5",' ;;
    socks4) P_TYPE="socks"
            if is_ip "$PROXY_IP"; then SV="4"; else SV="4a"; fi
            EXTRA="\"version\": \"$SV\"," ;;
    http)   P_TYPE="http" ;;
    https)  P_TYPE="http"
            SNI="$PROXY_SNI"
            [ -z "$SNI" ] && ! is_ip "$PROXY_IP" && SNI="$PROXY_IP"
            SNI_JSON=""
            [ -n "$SNI" ] && SNI_JSON="\"server_name\": \"$(json_esc "$SNI")\","
            INS="false"; [ "$PROXY_INSECURE" = "1" ] && INS="true"
            EXTRA="\"tls\": { \"enabled\": true, $SNI_JSON \"insecure\": $INS }," ;;
  esac

  AUTH_JSON=""
  if [ -n "$PROXY_USER" ]; then
    AUTH_JSON="\"username\": \"$(json_esc "$PROXY_USER")\","
    if [ -n "$PROXY_PASS" ] && [ "$PROXY_TYPE" != "socks4" ]; then
      AUTH_JSON="$AUTH_JSON \"password\": \"$(json_esc "$PROXY_PASS")\","
    fi
  fi

  # In "both" mode, proxy sits on top of WARP: device -> WARP -> proxy
  # In "proxy" mode, proxy connects directly: device -> proxy
  DETOUR_JSON=""
  [ "$MODE" = "both" ] && DETOUR_JSON='"detour": "warp-out",'

  cat <<EOF
{
  "type": "$P_TYPE",
  "tag": "proxy-out",
  $EXTRA
  $AUTH_JSON
  $DETOUR_JSON
  "server": "$(json_esc "$PROXY_IP")",
  "server_port": $PROXY_PORT
}
EOF
}

validate_proxy() {
  [ -n "$PROXY_IP" ] || [ -n "$PROXY_PORT" ] || return 1
  [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ] || die "Both proxy IP and port are required."
  [ -n "$PROXY_TYPE" ] || PROXY_TYPE="socks5"
  PROXY_TYPE=$(printf '%s' "$PROXY_TYPE" | tr 'A-Z' 'a-z')
  case "$PROXY_TYPE" in
    socks|socks5h) PROXY_TYPE="socks5" ;;
    socks4a)       PROXY_TYPE="socks4" ;;
  esac
  case "$PROXY_TYPE" in
    socks5|socks4|http|https) ;;
    *) die "Unknown proxy type '$PROXY_TYPE'. Use: socks5 | socks4 | http | https" ;;
  esac
  valid_host "$PROXY_IP"   || die "Invalid proxy IP / host."
  valid_port "$PROXY_PORT" || die "Proxy port must be a number between 1 and 65535."
  return 0
}

build_config() {
  DNS_RULES=""
  case "$MODE" in
    warp)
      load_creds
      OUTBOUNDS="$(wg_outbound)"
      FINAL_TAG="warp-out"
      DNS_SERVER='{ "tag": "cf-dns", "address": "1.1.1.1", "detour": "warp-out" }'
      DNS_OUTBOUND_TAG="warp-out"
      ;;
    both)
      load_creds
      validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
      OUTBOUNDS="$(proxy_outbound),
    $(wg_outbound)"
      FINAL_TAG="proxy-out"
      DNS_SERVER='{ "tag": "cf-dns", "address": "1.1.1.1", "detour": "warp-out" }'
      DNS_OUTBOUND_TAG="warp-out"
      ;;
    proxy)
      validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
      OUTBOUNDS="$(proxy_outbound)"
      FINAL_TAG="proxy-out"
      DNS_SERVER='{ "tag": "cf-dns", "address": "tcp://1.1.1.1", "detour": "proxy-out" }'
      DNS_OUTBOUND_TAG="proxy-out"
      if ! is_ip "$PROXY_IP"; then
        DNS_SERVER="$DNS_SERVER,
      { \"tag\": \"boot-dns\", \"address\": \"1.1.1.1\", \"detour\": \"direct\" }"
        DNS_RULES="\"rules\": [ { \"domain\": [\"$(json_esc "$PROXY_IP")\"], \"server\": \"boot-dns\" } ],"
      fi
      ;;
    *) die "Internal error: unknown mode '$MODE'." ;;
  esac

  ( umask 077
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "warn", "output": "$LOG_FILE" },
  "dns": {
    "servers": [ $DNS_SERVER ],
    $DNS_RULES
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "$TUN_STACK",
      "sniff": true
    }
  ],
  "outbounds": [
    $OUTBOUNDS,
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "$FINAL_TAG",
    "rules": [
      { "protocol": "dns", "outbound": "$DNS_OUTBOUND_TAG" },
      { "port": 53, "outbound": "$DNS_OUTBOUND_TAG" }
    ]
  }
}
EOF
  )
}

# ---------------------------------------------------------------- system state

asettings() {
  _r=$(su 2000 -c "settings $*" 2>&1 </dev/null)
  case "$_r" in *Failure*|*Exception*|*"Error"*|*"not found"*)
    _r=$(settings "$@" 2>&1 </dev/null) ;;
  esac
  case "$_r" in *Failure*|*Exception*|*"Error"*|*"not found"*) return 1 ;; esac
  [ -n "$_r" ] && printf '%s\n' "$_r"
  return 0
}

save_state() {
  [ -f "$STATE_FILE" ] && return 0
  PD_OK=1
  PD_MODE=$(asettings get global private_dns_mode) || PD_OK=0
  PD_SPEC=$(asettings get global private_dns_specifier) || PD_OK=0
  case "$PD_MODE" in off|opportunistic|hostname|null) ;; *) PD_OK=0 ;; esac
  [ "$PD_OK" = "1" ] || { PD_MODE=""; PD_SPEC=""; }
  ( umask 077
    cat > "$STATE_FILE" <<EOF
PD_OK='$PD_OK'
PD_MODE='$PD_MODE'
PD_SPEC='$PD_SPEC'
EOF
  )
}

pd_usable() { [ -f "$STATE_FILE" ] && grep -q "^PD_OK='1'" "$STATE_FILE"; }

apply_private_dns() {
  [ "$PRIVATE_DNS" = "keep" ] && return 0
  if pd_usable; then
    asettings put global private_dns_mode off || warn "Could not switch Private DNS off."
  fi
}

unblock_v6_rules() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  _t=0
  while [ $_t -lt 5 ] && ip6tables -D OUTPUT -j "$V6_CHAIN" 2>/dev/null; do _t=$((_t + 1)); done
  ip6tables -F "$V6_CHAIN" 2>/dev/null
  ip6tables -X "$V6_CHAIN" 2>/dev/null
  return 0
}

block_ipv6() {
  [ "$BLOCK_IPV6" = "0" ] && return 0
  if ip link show 2>/dev/null | grep -Eq '^[0-9]+: (v4-|clat)'; then
    warn "IPv6-only mobile network (464XLAT) detected - keeping IPv6."
    return 0
  fi
  command -v ip6tables >/dev/null 2>&1 || return 0
  unblock_v6_rules
  ip6tables -N "$V6_CHAIN" 2>/dev/null
  ip6tables -A "$V6_CHAIN" -o lo -j RETURN 2>/dev/null
  ip6tables -A "$V6_CHAIN" -j REJECT 2>/dev/null || ip6tables -A "$V6_CHAIN" -j DROP 2>/dev/null
  ip6tables -I OUTPUT 1 -j "$V6_CHAIN" 2>/dev/null || warn "Could not install IPv6 rule."
}

restore_system() {
  unblock_v6_rules
  PD_OK=0; PD_MODE=""; PD_SPEC=""
  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
    if [ "$PD_OK" = "1" ]; then
      if [ -z "$PD_MODE" ] || [ "$PD_MODE" = "null" ]; then
        asettings delete global private_dns_mode
      else
        asettings put global private_dns_mode "$PD_MODE"
      fi
      if [ -z "$PD_SPEC" ] || [ "$PD_SPEC" = "null" ]; then
        asettings delete global private_dns_specifier
      else
        asettings put global private_dns_specifier "$PD_SPEC"
      fi
    fi
    rm -f "$STATE_FILE"
  fi
  return 0
}

cleanup_leftovers() {
  _ours=0
  ip addr show tun0 2>/dev/null | grep -q '172\.19\.0\.1' && _ours=1
  ip rule show 2>/dev/null | grep -q 'lookup 2022' && _ours=1
  [ $_ours -eq 1 ] || return 0
  ip link del tun0 2>/dev/null
  for _fam in -4 -6; do
    _p=9000
    while [ $_p -le 9010 ]; do
      _t=0
      while [ $_t -lt 8 ] && ip $_fam rule del priority $_p 2>/dev/null; do _t=$((_t + 1)); done
      _p=$((_p + 1))
    done
  done
  ip route flush table 2022 2>/dev/null
  ip -6 route flush table 2022 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- core process / WARP endpoint

WARP_CANDIDATES="162.159.192.1:2408 162.159.192.1:500 162.159.192.1:4500 162.159.192.1:1701 162.159.193.1:2408 162.159.195.1:500 188.114.97.1:2408 188.114.96.1:500 188.114.98.1:4500 188.114.99.1:1701"

kill_stale() {
  for _p in $(pidof sing-box 2>/dev/null); do
    if [ "$(readlink "/proc/$_p/exe" 2>/dev/null)" = "$SINGBOX_BIN" ]; then
      kill "$_p" 2>/dev/null; sleep 1; kill -9 "$_p" 2>/dev/null
    fi
  done
}

kill_core() {
  if [ -f "$PID_FILE" ]; then
    P=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$P" ]; then
      kill "$P" 2>/dev/null
      i=0; while [ $i -lt 5 ] && kill -0 "$P" 2>/dev/null; do sleep 1; i=$((i + 1)); done
      kill -0 "$P" 2>/dev/null && kill -9 "$P" 2>/dev/null
    fi
    rm -f "$PID_FILE"
  fi
  kill_stale
}

launch_core() {
  build_config
  CHK=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1) || { say "$CHK"; die "Config is invalid."; }
  : > "$LOG_FILE"
  nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  i=0
  while [ $i -lt 10 ]; do
    is_running || break
    ip link show tun0 >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done
  is_running
}

probe_warp() {
  i=0
  while [ $i -lt 2 ]; do
    T=$(curl -4 -s --connect-timeout 3 --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
    case "$T" in *warp=on*|*warp=plus*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

find_warp_endpoint() {
  info "Finding best WARP endpoint..."
  _keep_mode="$MODE"; MODE="warp"
  LAST=""; [ -s "$WARP_OK_FILE" ] && LAST=$(cat "$WARP_OK_FILE" 2>/dev/null)
  for c in $LAST $WARP_CANDIDATES; do
    WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    if launch_core && probe_warp; then
      ok "WARP endpoint ready: $WARP_ENDPOINT:$WARP_PORT"
      printf '%s' "$c" > "$WARP_OK_FILE"
      kill_core
      MODE="$_keep_mode"
      return 0
    fi
    kill_core
  done
  MODE="$_keep_mode"
  return 1
}

# ---------------------------------------------------------------- health checks

verify_tunnel() {
  _i=0
  while [ $_i -lt 3 ]; do
    if [ $((_i % 2)) -eq 0 ]; then _h="1.1.1.1"; else _h="1.0.0.1"; fi
    TRACE=$(curl -4 -s --connect-timeout 5 --max-time 8 "https://$_h/cdn-cgi/trace" 2>/dev/null)
    case "$TRACE" in
      *ip=*)
        T_IP=$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')
        T_LOC=$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')
        T_WARP=$(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')
        return 0 ;;
    esac
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

dns_ready() {
  DNS_RC=0
  _n=0
  while [ $_n -lt "${DNS_TRIES:-3}" ]; do
    curl -4 -s -o /dev/null --connect-timeout 4 --max-time 6 https://www.cloudflare.com 2>/dev/null
    DNS_RC=$?
    [ $DNS_RC -eq 0 ] && return 0
    _n=$((_n + 1))
    [ $_n -lt "${DNS_TRIES:-3}" ] && sleep 1
  done
  return 1
}

probe_proxy_direct() {
  PROBE_RC=1
  case "$PROXY_TYPE" in
    socks5) _sch="socks5h" ;;
    socks4) if is_ip "$PROXY_IP"; then _sch="socks4"; else _sch="socks4a"; fi ;;
    *)      _sch="$PROXY_TYPE" ;;
  esac
  set -- -4 -s --connect-timeout 6 --max-time 10 -x "$_sch://$PROXY_IP:$PROXY_PORT"
  if [ -n "$PROXY_USER" ]; then
    if [ "$PROXY_TYPE" = "socks4" ]; then set -- "$@" --proxy-user "$PROXY_USER:"
    else set -- "$@" --proxy-user "$PROXY_USER:$PROXY_PASS"; fi
  fi
  [ "$PROXY_INSECURE" = "1" ] && set -- "$@" --proxy-insecure
  T=$(curl "$@" https://1.1.1.1/cdn-cgi/trace 2>/dev/null); PROBE_RC=$?
  case "$T" in *ip=*) return 0 ;; esac
  return 1
}

proxy_probe_reason() {
  case "$PROBE_RC" in
    5|6|7|28) printf '%s' "unreachable directly (blocked by ISP or proxy offline)" ;;
    97)       printf '%s' "handshake rejected (check type/user/pass)" ;;
    56|52|55) printf '%s' "connection reset/blocked" ;;
    *)        printf '%s' "curl exit $PROBE_RC" ;;
  esac
}

dns_servers() {
  dumpsys connectivity 2>/dev/null | grep -o 'DnsAddresses: \[[^]]*\]' \
    | sed 's/DnsAddresses: \[//; s/\]//; s#/##g; s/,/ /g' | tr -s ' ' '\n' | sed '/^$/d' | sort -u
}

# ---------------------------------------------------------------- start / stop / switch

rollback_start() {
  if [ "$KEEP_ON_FAIL" = "1" ]; then
    warn "KEEP_ON_FAIL=1: keeping tunnel running for inspection."
    return 1
  fi
  say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
  stop_bypass
  warn "Start failed - normal network restored."
  return 1
}

handle_no_traffic() {
  case "$MODE" in
    both)
      warn "Traffic through WARP+proxy failed; falling back to WARP only."
      stop_bypass
      clear_proxy_vars
      NOASK=1
      MODE="warp"
      start_bypass
      return $?
      ;;
    proxy)
      warn "Direct proxy failed; trying over WARP (device -> WARP -> proxy)..."
      if [ -z "$CHAIN_OFFERED" ]; then
        CHAIN_OFFERED=1
        stop_bypass
        MODE="both"
        start_bypass
        return $?
      fi
      ;;
    *) warn "No traffic passes through WARP." ;;
  esac
  rollback_start
}

start_bypass() {
  if [ ! -x "$SINGBOX_BIN" ]; then
    warn "Core not installed yet - installing first."
    if [ "$MODE" = "proxy" ]; then download_core; else install_core; fi
  fi
  [ -x "$SINGBOX_BIN" ] || die "Core not installed."
  if is_running; then
    warn "Already running (mode: $(current_mode))."
    return 0
  fi

  case "$MODE" in
    warp)       clear_proxy_vars ;;
    proxy|both) ensure_proxy ;;
    *)          maybe_ask_proxy
                if [ -n "$PROXY_IP" ]; then MODE="both"; else MODE="warp"; fi ;;
  esac

  if [ "$MODE" != "warp" ]; then
    validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
  fi

  if [ "$MODE" = "proxy" ] && [ -z "$FAST_START" ]; then
    if ! probe_proxy_direct; then
      warn "Direct proxy check failed ($(proxy_probe_reason))."
      if [ -f "$CRED_FILE" ] || [ -z "$NOASK" ]; then
        CHAIN_OFFERED=1
        MODE="both"
        info "Switching to WARP -> proxy chain..."
      fi
    fi
  fi

  save_state
  block_ipv6

  if [ "$MODE" != "proxy" ] && [ -z "$WARP_FIXED" ]; then
    if [ -s "$WARP_OK_FILE" ] && [ -n "$FAST_START" ]; then
      c=$(cat "$WARP_OK_FILE")
      WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    elif [ -s "$WARP_OK_FILE" ]; then
      c=$(cat "$WARP_OK_FILE")
      WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
      if ! ( launch_core && probe_warp ); then
        kill_core
        find_warp_endpoint || {
          cleanup_leftovers; restore_system
          die "No reachable WARP endpoint found."
        }
      else
        kill_core
      fi
    else
      find_warp_endpoint || {
        cleanup_leftovers; restore_system
        die "No reachable WARP endpoint found."
      }
    fi
    if [ -s "$WARP_OK_FILE" ]; then
      c=$(cat "$WARP_OK_FILE")
      WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    fi
  fi

  case "$MODE" in
    warp)  info "Starting WARP (device -> WARP -> internet)..." ;;
    proxy) info "Starting Proxy (device -> proxy -> internet)..." ;;
    both)  info "Starting WARP + Proxy (device -> WARP -> proxy -> internet)..." ;;
  esac

  launch_core
  if ! is_running; then
    rm -f "$PID_FILE"
    kill_stale
    cleanup_leftovers
    restore_system
    say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
    die "sing-box failed to start. Network restored."
  fi

  apply_private_dns

  printf '%s' "$MODE" > "$MODE_FILE"
  if [ "$MODE" != "warp" ] && [ -n "$PROXY_IP" ]; then
    proxy_summary > "$ACTIVE_PROXY_FILE"
  else
    rm -f "$ACTIVE_PROXY_FILE"
  fi

  if ! verify_tunnel; then
    handle_no_traffic
    return $?
  fi

  case "$MODE" in
    warp) ok "Active: WARP only | IP: $T_IP | Loc: $T_LOC | WARP: $T_WARP" ;;
    proxy) ok "Active: Proxy only | IP: $T_IP | Loc: $T_LOC | Proxy: $(proxy_summary)" ;;
    both)  ok "Active: WARP + Proxy | IP: $T_IP | Loc: $T_LOC | Chain: WARP -> $(proxy_summary)" ;;
  esac

  dns_ready && ok "DNS: OK" || warn "DNS check retrying (curl exit ${DNS_RC:-?})"
  return 0
}

stop_bypass() {
  info "Stopping tunnel..."
  kill_core
  cleanup_leftovers
  restore_system
  rm -f "$ACTIVE_PROXY_FILE" "$MODE_FILE"
  say "${RED}[-] Stopped. Normal network restored.${NC}"
}

# Hot-switch or layer modes cleanly without dropping the remaining component
apply_layer_mode() {
  _target="$1"
  _cur=$(current_mode)
  if [ "$_cur" = "$_target" ]; then
    warn "Already active in '$_target' mode."
    return 0
  fi

  if is_running; then
    MODE="$_target"
    if [ "$_target" != "warp" ]; then
      validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
    fi
    if [ "$_target" != "proxy" ] && [ -s "$WARP_OK_FILE" ]; then
      c=$(cat "$WARP_OK_FILE")
      WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    fi
    kill_core
    launch_core || { cleanup_leftovers; restore_system; die "Failed to switch mode to $_target."; }
    printf '%s' "$_target" > "$MODE_FILE"
    if [ "$_target" != "warp" ] && [ -n "$PROXY_IP" ]; then
      proxy_summary > "$ACTIVE_PROXY_FILE"
    else
      rm -f "$ACTIVE_PROXY_FILE"
    fi
    if verify_tunnel; then
      case "$_target" in
        warp)  ok "Switched to WARP only | IP: $T_IP | Loc: $T_LOC | WARP: $T_WARP" ;;
        proxy) ok "Switched to Proxy only | IP: $T_IP | Loc: $T_LOC | Proxy: $(proxy_summary)" ;;
        both)  ok "Switched to WARP + Proxy | IP: $T_IP | Loc: $T_LOC | Chain: WARP -> $(proxy_summary)" ;;
      esac
      return 0
    fi
    handle_no_traffic
    return $?
  fi

  MODE="$_target"
  start_bypass
}

check_status() {
  if is_running; then
    ok "Status: RUNNING (PID $(cat "$PID_FILE"))"
    case "$(current_mode)" in
      warp)  info "Mode      : WARP only (device -> WARP)" ;;
      proxy) info "Mode      : Proxy only (device -> proxy)" ;;
      both)  info "Mode      : WARP + Proxy (device -> WARP -> proxy)" ;;
      *)     info "Mode      : unknown" ;;
    esac
    TRACE=$(curl -4 -s --connect-timeout 5 --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
    if [ -n "$TRACE" ]; then
      info "Public IP : $(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')"
      info "Country   : $(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')"
      info "WARP      : $(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')"
      [ -s "$ACTIVE_PROXY_FILE" ] && info "Proxy     : $(cat "$ACTIVE_PROXY_FILE")" || info "Proxy     : none"
      DNS_TRIES=1
      dns_ready && info "DNS       : OK" || warn "DNS       : failed (curl exit $DNS_RC)"
    else
      warn "Could not reach Cloudflare through the active tunnel."
    fi
  else
    say "${RED}[-] Status: STOPPED${NC}"
  fi
}

show_logs() { [ -f "$LOG_FILE" ] && tail -n 40 "$LOG_FILE" || warn "No log file yet."; }

doctor() {
  say "${CYAN}=== Root Network Unblocker v$VERSION - diagnostics ===${NC}"
  say "Device       : $(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null) | Android $(getprop ro.build.version.release 2>/dev/null) | $(uname -m)"
  say "Root         : $(id 2>/dev/null)"
  [ -x "$SINGBOX_BIN" ] && say "Core         : $("$SINGBOX_BIN" version 2>/dev/null | head -n1)" || say "Core         : NOT installed"
  [ -f "$CRED_FILE" ] && say "WARP account : present" || say "WARP account : missing"
  say "WARP endpoint: $(cat "$WARP_OK_FILE" 2>/dev/null || echo 'not searched yet')"
  [ -n "$PROXY_IP" ] && say "Saved proxy  : $(proxy_summary)" || say "Saved proxy  : none"
  if is_running; then say "Tunnel       : RUNNING (mode: $(current_mode), PID $(cat "$PID_FILE"))"; else say "Tunnel       : stopped"; fi
  say "tun0         : $(ip addr show tun0 2>/dev/null | grep 'inet ' | tr -s ' ' | head -n1)"
  say "DNS servers  : $(dns_servers | tr '\n' ' ')"
  tail -n 15 "$LOG_FILE" 2>/dev/null
}

# ---------------------------------------------------------------- warp / proxy / all commands

warp_cmd() {
  case "$1" in
    on)
      case "$(current_mode)" in
        warp)  warn "WARP is already running." ;;
        proxy) ensure_proxy; apply_layer_mode both ;;
        both)  warn "WARP + Proxy is already running." ;;
        *)     apply_layer_mode warp ;;
      esac ;;
    off)
      case "$(current_mode)" in
        warp) stop_bypass ;;
        both) info "Stopping WARP while keeping proxy running..."; apply_layer_mode proxy ;;
        *)    warn "WARP is not running." ;;
      esac ;;
    status|"") check_status ;;
    *) die "Usage: warp on | warp off | warp status" ;;
  esac
}

proxy_cmd() {
  case "$1" in
    on)
      ensure_proxy
      case "$(current_mode)" in
        warp)  apply_layer_mode both ;;
        both)  warn "WARP + Proxy is already running." ;;
        proxy) warn "Proxy is already running." ;;
        *)     apply_layer_mode proxy ;;
      esac ;;
    off|stop)
      case "$(current_mode)" in
        proxy) stop_bypass ;;
        both)  info "Stopping proxy while keeping WARP running..."; apply_layer_mode warp ;;
        *)     warn "Proxy is not running." ;;
      esac ;;
    set)
      [ -t 0 ] || die "'proxy set' needs an interactive terminal."
      proxy_wizard
      save_proxy_conf
      ok "Proxy saved: $(proxy_summary)"
      CM=$(current_mode)
      if [ "$CM" = "proxy" ] || [ "$CM" = "both" ]; then
        confirm "Restart active tunnel to apply new proxy?" Y && apply_layer_mode "$CM"
      fi ;;
    clear|remove)
      remove_proxy_conf
      clear_proxy_vars
      ok "Saved proxy removed."
      case "$(current_mode)" in
        proxy) stop_bypass ;;
        both)  apply_layer_mode warp ;;
      esac ;;
    status|"")
      [ -n "$PROXY_IP" ] && info "Saved proxy  : $(proxy_summary)" || info "Saved proxy  : none"
      is_running && [ -s "$ACTIVE_PROXY_FILE" ] && info "Active proxy : $(cat "$ACTIVE_PROXY_FILE")" || info "Active proxy : none"
      ;;
    *) die "Usage: proxy on | proxy off | proxy set | proxy clear | proxy status" ;;
  esac
}

all_cmd() {
  case "$1" in
    on)
      ensure_proxy
      apply_layer_mode both ;;
    off|stop)
      if is_running || [ -f "$STATE_FILE" ] || ip link show tun0 >/dev/null 2>&1; then
        stop_bypass
      else
        warn "Nothing is running."
      fi ;;
    status|"") check_status ;;
    *) die "Usage: all on | all off | all status" ;;
  esac
}

autostart() {
  case "$1" in
    on)
      mkdir -p /data/adb/service.d
      cat > "$BOOT_HOOK" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 15
FAST_START=1 sh $SELF start --no-ask >> $WORK_DIR/boot.log 2>&1
EOF
      chmod 755 "$BOOT_HOOK"
      ok "Autostart enabled ($BOOT_HOOK)."
      ;;
    off) rm -f "$BOOT_HOOK"; ok "Autostart disabled." ;;
    *) die "Usage: autostart on|off" ;;
  esac
}

uninstall_all() {
  is_running && stop_bypass
  rm -f "$BOOT_HOOK"
  rm -rf "$WORK_DIR"
  [ -n "$PURGE" ] && rm -f "$CRED_FILE" "$USER_CONF"
  ok "Uninstalled."
}

usage() {
  say "${CYAN}Root Network Unblocker v$VERSION${NC}"
  say "  warp on | warp off          (WARP only; if proxy is active, 'warp off' leaves proxy running)"
  say "  proxy on | proxy off        (Proxy only; if WARP is active, 'proxy on' layers proxy over WARP)"
  say "  all on | all off            (Both WARP + Proxy together; 'all off' stops all)"
  say "  proxy set | proxy clear | proxy status"
  say "  install | start | stop | restart | status | logs | doctor | renew | autostart on|off | uninstall"
}

case "$1" in
  ""|help|-h|--help) usage; exit 0 ;;
  version|-v|--version) say "Root Network Unblocker v$VERSION"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root access required. Run with: su -c 'sh $SELF $*'"

PROXY_EXPLICIT=""; [ -n "$PROXY_IP" ] && PROXY_EXPLICIT=1
load_user_conf
WARP_FIXED=""; [ -n "$WARP_ENDPOINT$WARP_PORT" ] && WARP_FIXED=1
SB_VER="${SB_VER:-1.10.1}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"
WARP_PORT="${WARP_PORT:-2408}"
TUN_STACK="${TUN_STACK:-system}"
PRIVATE_DNS="${PRIVATE_DNS:-off}"
MODE=""
CHAIN_OFFERED=""

for _arg in "$@"; do
  case "$_arg" in --no-ask|--yes|-y) NOASK=1 ;; esac
done

case "$1" in
  install)   install_core ;;
  start)     start_bypass ;;
  stop)      all_cmd off ;;
  restart)   NOASK=1; _cm=$(current_mode); is_running && stop_bypass; [ -n "$_cm" ] && MODE="$_cm"; start_bypass ;;
  status)    check_status ;;
  logs)      show_logs ;;
  doctor)    doctor ;;
  renew)     renew_warp ;;
  warp)      warp_cmd "$2" ;;
  proxy)     proxy_cmd "$2" ;;
  all|both)  all_cmd "$2" ;;
  autostart) autostart "$2" ;;
  uninstall) uninstall_all ;;
  *)         usage; exit 1 ;;
esac
