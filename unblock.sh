#!/system/bin/sh
# Root Network Unblocker v2.5 - Cloudflare WARP TUN tunnel (sing-box) for rooted Android
# Path: /data/local/tmp/unblock.sh
#
# Modes:    warp  = device -> WARP -> internet
#           proxy = device -> proxy -> internet   (no WARP)
#           all   = device -> WARP -> proxy -> internet
#
# Commands: install | start [--no-ask] | stop | restart | status | logs | doctor | renew
#           warp  on|off|status
#           proxy on|off|set|clear|status
#           all   on|off|status
#           autostart on|off | uninstall | version | help
#
# Written for Android's mksh (/system/bin/sh): no bashisms, no "local".

VERSION="2.5"

export PATH="$PATH:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
PID_FILE="$WORK_DIR/singbox.pid"
LOG_FILE="$WORK_DIR/sing-box.log"
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

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; }

# warp | proxy | both  (empty when nothing is running)
current_mode() { is_running && cat "$MODE_FILE" 2>/dev/null; }

need_curl() { command -v curl >/dev/null 2>&1 || die "curl not found. In Termux run: pkg install curl"; }

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Optional persistent settings (/data/adb/unblock.conf). Command-line env wins.
CONF_VARS="PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE WARP_ENDPOINT WARP_PORT TUN_STACK SB_VER BLOCK_IPV6 HIDE_PASS PRIVATE_DNS KEEP_ON_FAIL DNS_TRIES"
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

# ask VAR "prompt"          -> read a line into VAR
ask() {
  printf '%b' "${CYAN}$2${NC}"
  read -r _a || die "Input closed."
  _a=$(printf '%s' "$_a" | tr -d '\r')      # Termux/su can add a hidden CR
  eval "$1=\$_a"
}

# ask_secret VAR "prompt"   -> read a password.
# "stty -echo" freezes under "su -c" on many devices (SIGTTOU), so the password is
# visible while typing by default. Do not share screenshots of this step.
# Hidden input is optional: HIDE_PASS=1 (uses stty on /dev/tty with SIGTTOU ignored).
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

# confirm "prompt" Y|N      -> returns 0 for yes
confirm() {
  while :; do
    if [ "$2" = "Y" ]; then printf '%b' "${CYAN}$1 [Y/n]: ${NC}"; else printf '%b' "${CYAN}$1 [y/N]: ${NC}"; fi
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

# single-quote a value so it can be safely sourced from the config file
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

proxy_summary() {
  S="$PROXY_TYPE://$PROXY_IP:$PROXY_PORT"
  [ -n "$PROXY_USER" ] && S="$S (user: $PROXY_USER)"
  printf '%s' "$S"
}

clear_proxy_vars() { PROXY_TYPE=""; PROXY_IP=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""; }

# ---- proxy wizard: type -> ip -> port -> optional user/pass
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

# ---- persist / remove proxy lines in /data/adb/unblock.conf (other settings are kept)
PROXY_LINE_RE='^[[:space:]]*PROXY_(TYPE|IP|PORT|USER|PASS)='

remove_proxy_conf() {
  [ -f "$USER_CONF" ] || return 0
  ( umask 077
    grep -Ev "$PROXY_LINE_RE" "$USER_CONF" > "$USER_CONF.tmp"
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

# Questions shown by plain "start" (auto mode; only on an interactive terminal and without --no-ask)
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

# Used by the "proxy" and "all" modes: a proxy is required
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

  # "reserved" bytes = first 3 bytes of client_id (needed on some networks)
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
  if [ ! -x "$SINGBOX_BIN" ] || [ -n "$FORCE" ]; then download_core; else ok "Core already present (use FORCE=1 to re-download)."; fi
  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    mkdir -p "$(dirname "$CRED_FILE")"; cp "$OLD_CRED_FILE" "$CRED_FILE"; chmod 600 "$CRED_FILE"
    ok "Migrated old credentials to $CRED_FILE"
  fi
  if [ ! -f "$CRED_FILE" ]; then register_warp; else ok "WARP credentials already exist (use 'renew' to create new ones)."; fi
  info "Next: su -c 'sh $SELF all on'  (or: warp on / proxy on)"
}

renew_warp() {
  [ -x "$SINGBOX_BIN" ] || die "Core not installed. Run 'install' first."
  is_running && stop_bypass
  rm -f "$CRED_FILE"
  register_warp
}

# ---------------------------------------------------------------- config

load_creds() {
  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    cp "$OLD_CRED_FILE" "$CRED_FILE" && chmod 600 "$CRED_FILE"
  fi
  # first use of WARP on a device that only ran proxy mode so far: register now
  if [ ! -f "$CRED_FILE" ]; then
    info "No WARP account yet - registering one..."
    register_warp
  fi
  . "$CRED_FILE"
  # strip hidden \r / newlines / spaces that break the JSON
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
  "mtu": 1280
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

  # chain through WARP only in "both" mode
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
  [ -n "$PROXY_IP" ] || [ -n "$PROXY_PORT" ] || return 1      # no proxy requested
  [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ] || die "Both proxy IP and port are required."
  [ -n "$PROXY_TYPE" ] || PROXY_TYPE="http"
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
      ;;
    both)
      load_creds
      validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
      OUTBOUNDS="$(proxy_outbound),
    $(wg_outbound)"
      FINAL_TAG="proxy-out"
      DNS_SERVER='{ "tag": "cf-dns", "address": "1.1.1.1", "detour": "warp-out" }'
      ;;
    proxy)
      validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
      OUTBOUNDS="$(proxy_outbound)"
      FINAL_TAG="proxy-out"
      # DNS over TCP, because HTTP proxies cannot carry UDP
      DNS_SERVER='{ "tag": "cf-dns", "address": "tcp://1.1.1.1", "detour": "proxy-out" }'
      if ! is_ip "$PROXY_IP"; then
        # The proxy's own host name must be resolved WITHOUT the proxy, otherwise
        # DNS waits for the proxy and the proxy waits for DNS (deadlock).
        DNS_SERVER="$DNS_SERVER,
      { \"tag\": \"boot-dns\", \"address\": \"1.1.1.1\" }"
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
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "$FINAL_TAG",
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "port": 53, "outbound": "dns-out" }
    ]
  }
}
EOF
  )
}

# ---------------------------------------------------------------- system state (IPv6 / Private DNS)

# Android's settings service rejects uid 0 on many ROMs -> run as shell (2000)
# Returns 1 (and prints nothing) when the settings service fails ("Failed transaction").
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
  [ -f "$STATE_FILE" ] && return 0   # keep the ORIGINAL state across restarts
  PD_OK=1
  PD_MODE=$(asettings get global private_dns_mode) || PD_OK=0
  PD_SPEC=$(asettings get global private_dns_specifier) || PD_OK=0
  # only trust values Android can really have, so a garbage answer is never "restored"
  case "$PD_MODE" in off|opportunistic|hostname|null) ;; *) PD_OK=0 ;; esac
  [ "$PD_OK" = "1" ] || { PD_MODE=""; PD_SPEC=""; }
  V6_IN=$(ip6tables -S INPUT 2>/dev/null | sed -n 's/^-P INPUT //p')
  V6_OUT=$(ip6tables -S OUTPUT 2>/dev/null | sed -n 's/^-P OUTPUT //p')
  ( umask 077
    cat > "$STATE_FILE" <<EOF
PD_OK='$PD_OK'
PD_MODE='$PD_MODE'
PD_SPEC='$PD_SPEC'
V6_IN='${V6_IN:-ACCEPT}'
V6_OUT='${V6_OUT:-ACCEPT}'
EOF
  )
}

# Private DNS is only touched when we could READ the original value (so we can restore it).
pd_usable() { [ -f "$STATE_FILE" ] && grep -q "^PD_OK='1'" "$STATE_FILE"; }

# Private DNS (DoT) is switched OFF while the tunnel runs. Plain DNS is then captured by the
# tunnel and answered through WARP / the proxy. A strict Private DNS host name can leave ALL
# lookups failing while Android is still validating it. PRIVATE_DNS=keep leaves it untouched.
apply_private_dns() {
  [ "$PRIVATE_DNS" = "keep" ] && return 0
  if pd_usable; then
    asettings put global private_dns_mode off || warn "Could not switch Private DNS off."
  else
    warn "Could not access Android settings - Private DNS left unchanged (harmless)."
  fi
}

# IPv6 is not carried by the tunnel, so it is rejected (instead of silently dropped):
# an immediate refusal lets Android fall back to IPv4 at once, a DROP makes every
# lookup wait for a timeout. Uses its own chain, so cleanup never touches other rules.
unblock_v6_rules() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  _t=0
  while [ $_t -lt 5 ] && ip6tables -D OUTPUT -j "$V6_CHAIN" 2>/dev/null; do _t=$((_t + 1)); done
  ip6tables -F "$V6_CHAIN" 2>/dev/null
  ip6tables -X "$V6_CHAIN" 2>/dev/null
  return 0
}

block_ipv6() {
  [ "$BLOCK_IPV6" = "0" ] && { warn "IPv6 blocking disabled (BLOCK_IPV6=0)."; return 0; }
  if ip link show 2>/dev/null | grep -Eq '^[0-9]+: (v4-|clat)'; then
    warn "IPv6-only mobile network (464XLAT) detected - IPv6 is NOT blocked, otherwise data would die."
    return 0
  fi
  command -v ip6tables >/dev/null 2>&1 || { warn "ip6tables not found - IPv6 is not blocked."; return 0; }
  unblock_v6_rules
  ip6tables -N "$V6_CHAIN" 2>/dev/null
  ip6tables -A "$V6_CHAIN" -o lo -j RETURN 2>/dev/null
  ip6tables -A "$V6_CHAIN" -j REJECT 2>/dev/null || ip6tables -A "$V6_CHAIN" -j DROP 2>/dev/null
  ip6tables -I OUTPUT 1 -j "$V6_CHAIN" 2>/dev/null || warn "Could not install the IPv6 block rule."
}

restore_system() {
  unblock_v6_rules
  PD_OK=0; PD_MODE=""; PD_SPEC=""; V6_IN=""; V6_OUT=""
  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
    # (policies are not changed any more; this only repairs a leftover from v2.4)
    [ -n "$V6_IN" ]  && ip6tables -P INPUT  "$V6_IN"  2>/dev/null
    [ -n "$V6_OUT" ] && ip6tables -P OUTPUT "$V6_OUT" 2>/dev/null
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

# If sing-box was killed hard it can leave tun0 and its ip rules behind, which blackholes the
# whole network. Only things that are provably ours (172.19.0.1 / table 2022) are removed.
cleanup_leftovers() {
  _ours=0
  ip addr show tun0 2>/dev/null | grep -q '172\.19\.0\.1' && _ours=1
  ip rule show 2>/dev/null | grep -q 'lookup 2022' && _ours=1
  [ $_ours -eq 1 ] || return 0
  if ip addr show tun0 2>/dev/null | grep -q '172\.19\.0\.1'; then ip link del tun0 2>/dev/null; fi
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

# ---------------------------------------------------------------- core process / WARP endpoint search
# Many ISPs block UDP 2408 or some Cloudflare IPs. We try several endpoint:port pairs and keep the first
# one that really passes traffic through WARP (checked with warp=on in Cloudflare's trace).
WARP_CANDIDATES="162.159.192.1:2408 162.159.192.1:500 162.159.192.1:4500 162.159.192.1:1701 162.159.193.1:2408 162.159.195.1:500 188.114.97.1:2408 188.114.96.1:500 188.114.98.1:4500 188.114.99.1:1701 162.159.192.1:854 162.159.192.1:880 162.159.192.1:1180"

# Only OUR sing-box (matched by its path) - never another app's sing-box (NekoBox, Magisk modules...)
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
  sleep 1
}

# build config + start sing-box + wait for tun0. returns 0 when the process is alive.
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

# 0 when traffic really leaves through WARP (no DNS needed: uses the IP 1.1.1.1, IPv4 only)
probe_warp() {
  i=0
  while [ $i -lt 2 ]; do
    T=$(curl -4 -s --connect-timeout 4 --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
    case "$T" in *warp=on*|*warp=plus*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

find_warp_endpoint() {
  info "Searching for a WARP endpoint that works on your network (one-time, ~10 s per try)..."
  _keep_mode="$MODE"; MODE="warp"
  LAST=""; [ -s "$WARP_OK_FILE" ] && LAST=$(cat "$WARP_OK_FILE" 2>/dev/null)
  for c in $LAST $WARP_CANDIDATES; do
    WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    info "  trying $WARP_ENDPOINT:$WARP_PORT ..."
    if launch_core && probe_warp; then
      ok "WARP works via $WARP_ENDPOINT:$WARP_PORT"
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

# 0 and sets T_IP / T_LOC / T_WARP when traffic passes through the tunnel (uses IPs, no DNS needed)
verify_tunnel() {
  _i=0
  while [ $_i -lt 3 ]; do
    if [ $((_i % 2)) -eq 0 ]; then _h="1.1.1.1"; else _h="1.0.0.1"; fi
    TRACE=$(curl -4 -s --connect-timeout 6 --max-time 10 "https://$_h/cdn-cgi/trace" 2>/dev/null)
    case "$TRACE" in
      *ip=*)
        T_IP=$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')
        T_LOC=$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')
        T_WARP=$(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')
        return 0 ;;
    esac
    _i=$((_i + 1)); sleep 2
  done
  return 1
}

# 0 when host NAMES resolve through the tunnel (retries: Android needs a moment after the switch).
# On failure DNS_RC holds curl's exit code (6 = could not resolve host).
dns_ready() {
  DNS_RC=0
  _n=0
  while [ $_n -lt "${DNS_TRIES:-3}" ]; do
    curl -4 -s -o /dev/null --connect-timeout 5 --max-time 8 https://www.cloudflare.com 2>/dev/null
    DNS_RC=$?
    [ $DNS_RC -eq 0 ] && return 0
    _n=$((_n + 1))
    [ $_n -lt "${DNS_TRIES:-3}" ] && sleep 2
  done
  return 1
}

# Can the saved proxy be used straight from this network (tunnel OFF)?  Sets PROBE_RC (curl exit code).
probe_proxy_direct() {
  PROBE_RC=1
  case "$PROXY_TYPE" in
    socks5) _sch="socks5h" ;;
    socks4) if is_ip "$PROXY_IP"; then _sch="socks4"; else _sch="socks4a"; fi ;;
    *)      _sch="$PROXY_TYPE" ;;
  esac
  set -- -4 -s --connect-timeout 8 --max-time 15 -x "$_sch://$PROXY_IP:$PROXY_PORT"
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
    5|6|7|28) printf '%s' "cannot connect to it from this network (blocked by the ISP, or the proxy is down)" ;;
    97)       printf '%s' "it answered but rejected the handshake (wrong type, user or password?)" ;;
    56|52|55) printf '%s' "the connection was cut during the handshake (ISP/DPI block, or wrong type)" ;;
    *)        printf '%s' "curl exit code $PROBE_RC" ;;
  esac
}

# DNS servers Android currently hands out (one per line)
dns_servers() {
  dumpsys connectivity 2>/dev/null | grep -o 'DnsAddresses: \[[^]]*\]' \
    | sed 's/DnsAddresses: \[//; s/\]//; s#/##g; s/,/ /g' | tr -s ' ' '\n' | sed '/^$/d' | sort -u
}

# ---------------------------------------------------------------- start / stop / status

# Failure path: leave the phone online again (unless KEEP_ON_FAIL=1 asks to keep the tunnel for debugging)
rollback_start() {
  if [ "$KEEP_ON_FAIL" = "1" ]; then
    warn "KEEP_ON_FAIL=1: tunnel left running for debugging. See: logs | doctor | stop"
    return 1
  fi
  say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
  stop_bypass
  warn "Start failed - your normal network is back. For details run: su -c 'sh $SELF doctor'"
  return 1
}

# The tunnel is up but no traffic passes. Try the sensible fallback, otherwise roll back.
handle_no_traffic() {
  case "$MODE" in
    both)
      warn "WARP works, but nothing passes through the proxy (down, blocked, or wrong type/credentials)."
      _fb=""
      if [ -z "$NOASK" ] && [ -t 0 ]; then
        confirm "Continue WITHOUT the proxy (WARP only)?" Y && _fb=1
      else
        info "Non-interactive start: falling back to WARP only."
        _fb=1
      fi
      if [ -n "$_fb" ]; then
        stop_bypass
        clear_proxy_vars
        NOASK=1
        MODE="warp"
        start_bypass; _rc=$?
        info "Your proxy is still saved. Retry later with: su -c 'sh $SELF all on'"
        return $_rc
      fi
      ;;
    proxy)
      warn "Nothing passes through the proxy (down, blocked, or wrong type/credentials)."
      if [ -z "$CHAIN_OFFERED" ] && [ -z "$NOASK" ] && [ -t 0 ]; then
        CHAIN_OFFERED=1
        if confirm "Try reaching the proxy THROUGH WARP instead (device -> WARP -> proxy)?" Y; then
          stop_bypass
          MODE="both"
          start_bypass
          return $?
        fi
      fi
      ;;
    *) warn "No traffic passes through WARP." ;;
  esac
  rollback_start
}

# MODE: warp | proxy | both | "" (auto: plain 'start' -> asks about a proxy)
start_bypass() {
  if [ ! -x "$SINGBOX_BIN" ]; then
    warn "Core not installed yet - installing first."
    if [ "$MODE" = "proxy" ]; then download_core; else install_core; fi
  fi
  [ -x "$SINGBOX_BIN" ] || die "Core not installed."
  if is_running; then warn "Already running (mode: $(current_mode)). Use 'warp|proxy|all on' to switch, or 'stop'."; return 0; fi

  case "$MODE" in
    warp)       clear_proxy_vars ;;
    proxy|both) ensure_proxy ;;
    *)          maybe_ask_proxy
                if [ -n "$PROXY_IP" ]; then MODE="both"; else MODE="warp"; fi ;;
  esac
  if [ "$MODE" != "warp" ]; then
    validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
  fi

  # Proxy-only: check BEFORE touching the network whether the proxy answers directly.
  # (Some ISPs block the direct connection, while the same proxy works through WARP.)
  if [ "$MODE" = "proxy" ]; then
    info "Checking that the proxy answers from this network..."
    if probe_proxy_direct; then
      ok "Proxy answers."
    else
      warn "The proxy does not answer directly: $(proxy_probe_reason)."
      if [ -z "$NOASK" ] && [ -t 0 ]; then
        CHAIN_OFFERED=1
        if confirm "Reach the proxy THROUGH WARP instead (device -> WARP -> proxy)?" Y; then MODE="both"; fi
      fi
    fi
  fi

  build_config
  info "Validating config..."
  CHK=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1) || { say "$CHK"; die "Config is invalid."; }

  save_state
  block_ipv6

  if [ "$MODE" != "proxy" ] && [ -z "$WARP_FIXED" ]; then
    if ! find_warp_endpoint; then
      cleanup_leftovers
      restore_system
      say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
      die "No WARP endpoint is reachable from this network (WARP may be blocked by your ISP). Network restored.
    Try: Wi-Fi instead of mobile data (or the reverse), 'renew', TUN_STACK=gvisor, or proxy-only mode."
    fi
    [ -f "$WARP_OK_FILE" ] && { c=$(cat "$WARP_OK_FILE"); WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"; }
  fi

  case "$MODE" in
    warp)  info "Starting tunnel: device -> WARP -> internet" ;;
    proxy) info "Starting tunnel: device -> proxy -> internet" ;;
    both)  info "Starting tunnel: device -> WARP -> proxy -> internet" ;;
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
  if [ "$MODE" != "warp" ] && [ -n "$PROXY_IP" ]; then proxy_summary > "$ACTIVE_PROXY_FILE"; else rm -f "$ACTIVE_PROXY_FILE"; fi

  if ! verify_tunnel; then
    handle_no_traffic
    return $?
  fi

  case "$MODE" in
    warp) ok "Tunnel is up (mode: warp). IP: $T_IP  Country: $T_LOC  WARP: $T_WARP" ;;
    *)    ok "Tunnel is up (mode: $MODE). Exit IP: $T_IP  Country: $T_LOC  (WARP: $T_WARP - 'off' is expected here, the exit is the proxy)" ;;
  esac
  [ "$MODE" = "both" ]  && ok "Chain: device -> WARP -> $(proxy_summary)"
  [ "$MODE" = "proxy" ] && ok "Path: device -> $(proxy_summary)"

  if dns_ready; then
    ok "DNS works: names resolve through the tunnel."
  else
    warn "Traffic passes, but host NAMES do not resolve (curl exit ${DNS_RC:-?}) - browsers and apps will fail."
    warn "Wait ~20 s and retry. If it stays: su -c 'sh $SELF doctor'  (IPv6-only DNS on mobile data? try BLOCK_IPV6=0)"
  fi
  return 0
}

stop_bypass() {
  info "Stopping tunnel..."
  kill_core
  cleanup_leftovers
  restore_system
  rm -f "$ACTIVE_PROXY_FILE" "$MODE_FILE"
  say "${RED}[-] Stopped. Network restored to previous settings.${NC}"
}

# switch_mode warp|proxy|both : start it, or restart if another mode is running
switch_mode() {
  NEW="$1"
  if is_running; then
    if [ "$(current_mode)" = "$NEW" ]; then warn "Already running in '$NEW' mode."; return 0; fi
    stop_bypass
  fi
  MODE="$NEW"
  start_bypass
}

check_status() {
  if is_running; then
    ok "Status: RUNNING (PID $(cat "$PID_FILE"))"
    case "$(current_mode)" in
      warp)  info "Mode      : WARP only" ;;
      proxy) info "Mode      : proxy only" ;;
      both)  info "Mode      : WARP + proxy" ;;
      *)     info "Mode      : unknown" ;;
    esac
    TRACE=$(curl -4 -s --connect-timeout 6 --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
    if [ -n "$TRACE" ]; then
      info "Public IP : $(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')"
      info "Country   : $(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')"
      info "WARP      : $(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')  (on/plus = WARP is the exit; off is normal with a proxy)"
      [ -s "$ACTIVE_PROXY_FILE" ] && info "Proxy     : $(cat "$ACTIVE_PROXY_FILE")" || info "Proxy     : none"
      DNS_TRIES=1
      if dns_ready; then info "DNS       : names resolve"; else warn "DNS       : names do NOT resolve (curl exit $DNS_RC)"; fi
    else
      warn "Could not reach Cloudflare through the tunnel."
    fi
  else
    say "${RED}[-] Status: STOPPED${NC}"
  fi
}

show_logs() { [ -f "$LOG_FILE" ] && tail -n 40 "$LOG_FILE" || warn "No log file yet."; }

# Everything needed to find a problem. Prints no passwords or keys.
doctor() {
  say "${CYAN}=== Root Network Unblocker v$VERSION - diagnostics ===${NC}"
  say "Device       : $(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null) | Android $(getprop ro.build.version.release 2>/dev/null) | $(uname -m) | kernel $(uname -r)"
  say "Root         : $(id 2>/dev/null)"
  if [ -x "$SINGBOX_BIN" ]; then say "Core         : $("$SINGBOX_BIN" version 2>/dev/null | head -n1)"; else say "Core         : NOT installed (run: install)"; fi
  if [ -f "$CRED_FILE" ]; then say "WARP account : present"; else say "WARP account : missing (run: install / renew)"; fi
  say "WARP endpoint: $(cat "$WARP_OK_FILE" 2>/dev/null || echo 'not searched yet')"
  if [ -n "$PROXY_IP" ]; then
    _auth="no"; [ -n "$PROXY_USER" ] && _auth="yes"
    say "Saved proxy  : ${PROXY_TYPE:-?}://$PROXY_IP:$PROXY_PORT (auth: $_auth)"
  else
    say "Saved proxy  : none"
  fi
  if is_running; then say "Tunnel       : RUNNING, mode $(current_mode), PID $(cat "$PID_FILE")"; else say "Tunnel       : stopped"; fi
  say "tun0         : $(ip addr show tun0 2>/dev/null | grep 'inet ' | tr -s ' ' | head -n1)"
  say "Private DNS  : mode=$(asettings get global private_dns_mode 2>/dev/null) host=$(asettings get global private_dns_specifier 2>/dev/null)"
  _ds=$(dns_servers | tr '\n' ' ')
  say "System DNS   : ${_ds:-unknown}"
  if [ -n "$_ds" ] && ! printf '%s' "$_ds" | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    warn "All system DNS servers are IPv6. With IPv6 blocked, lookups fail: try BLOCK_IPV6=0"
  fi
  say "IPv6 block   : $(ip6tables -S "$V6_CHAIN" 2>/dev/null | grep -c '^-A') rule(s) in chain $V6_CHAIN"
  say "ip rules     :"; ip rule show 2>/dev/null | head -n 14 | sed 's/^/   /'
  say "${CYAN}--- tests ---${NC}"
  TRACE=$(curl -4 -s --connect-timeout 6 --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null); _rc=$?
  if printf '%s' "$TRACE" | grep -q '^ip='; then
    say "IP traffic   : OK  (ip=$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p') loc=$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p') warp=$(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p'))"
  else
    say "IP traffic   : FAILED (curl exit $_rc)"
  fi
  curl -4 -s -o /dev/null --connect-timeout 5 --max-time 8 https://www.cloudflare.com 2>/dev/null; _rc=$?
  if [ $_rc -eq 0 ]; then say "Name lookup  : OK"; else say "Name lookup  : FAILED (curl exit $_rc; 6 = DNS lookup failed, 28 = timeout)"; fi
  if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ]; then
    if is_running; then
      say "Proxy direct : skipped while the tunnel is running (run 'stop' first to test it)"
    else
      [ -n "$PROXY_TYPE" ] || PROXY_TYPE="http"
      if probe_proxy_direct; then say "Proxy direct : OK (reachable from this network)"; else say "Proxy direct : FAILED - $(proxy_probe_reason). Try: all on"; fi
    fi
  fi
  say "${CYAN}--- last sing-box log lines ---${NC}"
  tail -n 15 "$LOG_FILE" 2>/dev/null
  say "${CYAN}Paste this output when asking for help (it contains no passwords).${NC}"
}

# ---------------------------------------------------------------- warp / proxy / all commands

warp_cmd() {
  case "$1" in
    on)  switch_mode warp ;;
    off)
      case "$(current_mode)" in
        warp) stop_bypass ;;
        both) info "Turning WARP off, keeping the proxy..."; switch_mode proxy ;;
        *)    warn "WARP is not running." ;;
      esac ;;
    status|"") check_status ;;
    *) die "Usage: warp on | warp off | warp status" ;;
  esac
}

proxy_cmd() {
  case "$1" in
    on)  switch_mode proxy ;;
    off|stop)
      case "$(current_mode)" in
        proxy) stop_bypass ;;
        both)  info "Turning the proxy off, keeping WARP..."; switch_mode warp ;;
        *)     warn "The proxy is not running." ;;
      esac ;;
    set)
      [ -t 0 ] || die "'proxy set' needs an interactive terminal (or edit $USER_CONF)."
      proxy_wizard
      save_proxy_conf
      ok "Proxy saved: $(proxy_summary)"
      CM=$(current_mode)
      case "$CM" in
        proxy|both)
          confirm "Tunnel is running. Restart now to apply the new proxy?" Y && { stop_bypass; MODE="$CM"; start_bypass; } ;;
        warp) info "Use 'proxy on' (proxy only) or 'all on' (WARP + proxy) to start it." ;;
        *)    info "Start it with: proxy on   |   all on" ;;
      esac
      ;;
    clear|remove)
      remove_proxy_conf
      clear_proxy_vars
      ok "Saved proxy removed."
      case "$(current_mode)" in
        proxy) stop_bypass ;;
        both)  info "Restarting with WARP only..."; switch_mode warp ;;
      esac
      ;;
    status|"")
      if [ -n "$PROXY_IP" ]; then info "Saved proxy  : $(proxy_summary)"; else info "Saved proxy  : none"; fi
      if is_running && [ -s "$ACTIVE_PROXY_FILE" ]; then info "Active proxy : $(cat "$ACTIVE_PROXY_FILE")"; else info "Active proxy : none"; fi
      ;;
    *) die "Usage: proxy on | proxy off | proxy set | proxy clear | proxy status" ;;
  esac
}

all_cmd() {
  case "$1" in
    on)  switch_mode both ;;
    off|stop)
      # also cleans up after a crashed / killed tunnel (stale tun0, ip rules, IPv6 rule, Private DNS)
      if is_running || [ -f "$STATE_FILE" ] || ip link show tun0 >/dev/null 2>&1; then stop_bypass; else warn "Nothing is running."; fi ;;
    status|"") check_status ;;
    *) die "Usage: all on | all off | all status" ;;
  esac
}

# ---------------------------------------------------------------- autostart / uninstall

autostart() {
  case "$1" in
    on)
      [ -d /data/adb/service.d ] || mkdir -p /data/adb/service.d
      cat > "$BOOT_HOOK" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 20
sh $SELF start --no-ask >> $WORK_DIR/boot.log 2>&1
EOF
      chmod 755 "$BOOT_HOOK"
      ok "Autostart enabled ($BOOT_HOOK). Needs Magisk / KernelSU / APatch."
      info "At boot: WARP + proxy if a proxy is saved in $USER_CONF (falls back to WARP only if the proxy fails), otherwise WARP only."
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
  ok "Uninstalled. (Credentials kept in $CRED_FILE; use PURGE=1 to delete them too.)"
}

usage() {
  say "${CYAN}Root Network Unblocker v$VERSION${NC}  (WARP and/or proxy, all device traffic)"
  say ""
  say "${CYAN}WARP only${NC}  (device -> WARP)"
  say "  su -c 'sh $SELF warp on'"
  say "  su -c 'sh $SELF warp off'"
  say "${CYAN}Proxy only${NC} (device -> proxy)"
  say "  su -c 'sh $SELF proxy set'      ${YELLOW}# socks5 | socks4 | http | https, ip, port, user/pass${NC}"
  say "  su -c 'sh $SELF proxy on'"
  say "  su -c 'sh $SELF proxy off'"
  say "  su -c 'sh $SELF proxy clear'    ${YELLOW}# forget the saved proxy${NC}"
  say "${CYAN}Both together${NC} (device -> WARP -> proxy)"
  say "  su -c 'sh $SELF all on'         ${GREEN}# start both${NC}"
  say "  su -c 'sh $SELF all off'        ${RED}# stop both, restore the network${NC}"
  say ""
  say "  su -c 'sh $SELF install|status|logs|doctor|renew|restart'"
  say "  su -c 'sh $SELF start [--no-ask]'   ${YELLOW}# classic: asks about a proxy${NC}"
  say "  su -c 'sh $SELF stop'               ${YELLOW}# same as: all off (also repairs a crashed tunnel)${NC}"
  say "  su -c 'sh $SELF autostart on|off'"
  say "  su -c 'sh $SELF uninstall'"
  say "Env: PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE=1"
  say "     BLOCK_IPV6=0 (do not block IPv6)  HIDE_PASS=1 (hide password while typing)"
  say "     PRIVATE_DNS=keep (do not touch Android Private DNS)  KEEP_ON_FAIL=1 (keep a failed tunnel for debugging)"
  say "     WARP_PORT (2408|500|1701|4500)  WARP_ENDPOINT  TUN_STACK (system|gvisor)  SB_VER  SB_URL  FORCE=1"
}

# ---- main ----
case "$1" in
  ""|help|-h|--help) usage; exit 0 ;;
  version|-v|--version) say "Root Network Unblocker v$VERSION"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root access required. Run with: su -c 'sh $SELF $1'"

PROXY_EXPLICIT=""; [ -n "$PROXY_IP" ] && PROXY_EXPLICIT=1   # proxy given on the command line
load_user_conf
WARP_FIXED=""; [ -n "$WARP_ENDPOINT$WARP_PORT" ] && WARP_FIXED=1   # user pinned an endpoint/port -> no auto-search
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
  restart)   NOASK=1; MODE="$(current_mode)"; is_running && stop_bypass; start_bypass ;;
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
