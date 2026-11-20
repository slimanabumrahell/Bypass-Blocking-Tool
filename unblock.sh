#!/system/bin/sh
# Root Network Unblocker v2.2 - Cloudflare WARP TUN tunnel (sing-box) for rooted Android
# Path: /data/local/tmp/unblock.sh
#
# Commands: install | start [--no-ask] | stop | restart | status | logs | renew
#           proxy set|off|status | autostart on|off | uninstall | help

export PATH="$PATH:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
PID_FILE="$WORK_DIR/singbox.pid"
LOG_FILE="$WORK_DIR/sing-box.log"
STATE_FILE="$WORK_DIR/state.env"
ACTIVE_PROXY_FILE="$WORK_DIR/active.proxy"
CRED_FILE="/data/adb/warp.conf"
OLD_CRED_FILE="$WORK_DIR/warp_creds.env"
USER_CONF="/data/adb/unblock.conf"
BOOT_HOOK="/data/adb/service.d/99-unblock.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

say()  { printf '%b\n' "$*"; }
info() { say "${CYAN}[*] $*${NC}"; }
warn() { say "${YELLOW}[!] $*${NC}"; }
ok()   { say "${GREEN}[+] $*${NC}"; }
die()  { say "${RED}[x] $*${NC}"; exit 1; }

# ---------------------------------------------------------------- helpers

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; }

need_curl() { command -v curl >/dev/null 2>&1 || die "curl not found. In Termux run: pkg install curl"; }

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Optional persistent settings (/data/adb/unblock.conf). Command-line env wins.
CONF_VARS="PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE WARP_ENDPOINT WARP_PORT TUN_STACK SB_VER"
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
  eval "$1=\$_a"
}

# ask_secret VAR "prompt"   -> same, but nothing is echoed (passwords)
ask_secret() {
  printf '%b' "${CYAN}$2${NC}"
  stty -echo 2>/dev/null
  read -r _a || { stty echo 2>/dev/null; die "Input closed."; }
  stty echo 2>/dev/null
  printf '\n'
  eval "$1=\$_a"
}

# confirm "prompt" Y|N      -> returns 0 for yes
confirm() {
  while :; do
    if [ "$2" = "Y" ]; then printf '%b' "${CYAN}$1 [Y/n]: ${NC}"; else printf '%b' "${CYAN}$1 [y/N]: ${NC}"; fi
    read -r _a || die "Input closed."
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

# Questions shown before "start" (only on an interactive terminal and without --no-ask)
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
  info "Installing Root Network Unblocker v2.2..."
  if [ ! -x "$SINGBOX_BIN" ] || [ -n "$FORCE" ]; then download_core; else ok "Core already present (use FORCE=1 to re-download)."; fi
  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    mkdir -p "$(dirname "$CRED_FILE")"; cp "$OLD_CRED_FILE" "$CRED_FILE"; chmod 600 "$CRED_FILE"
    ok "Migrated old credentials to $CRED_FILE"
  fi
  if [ ! -f "$CRED_FILE" ]; then register_warp; else ok "WARP credentials already exist (use 'renew' to create new ones)."; fi
  info "Next: su -c 'sh $SELF start'"
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
  [ -f "$CRED_FILE" ] || die "No WARP credentials. Run 'install' first."
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
  cat <<EOF
{
  "type": "$P_TYPE",
  "tag": "proxy-out",
  "server": "$(json_esc "$PROXY_IP")",
  "server_port": $PROXY_PORT,
  $EXTRA
  $AUTH_JSON
  "detour": "warp-out"
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
  load_creds
  if validate_proxy; then
    OUTBOUNDS="$(proxy_outbound),
    $(wg_outbound)"
    FINAL_TAG="proxy-out"
  else
    OUTBOUNDS="$(wg_outbound)"
    FINAL_TAG="warp-out"
  fi

  ( umask 077
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "warn", "output": "$LOG_FILE" },
  "dns": {
    "servers": [ { "tag": "cf-dns", "address": "1.1.1.1", "detour": "warp-out" } ],
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
    "rules": [ { "protocol": "dns", "outbound": "dns-out" } ]
  }
}
EOF
  )
}

# ---------------------------------------------------------------- system state (IPv6 / Private DNS)

# Android's settings service rejects uid 0 on many ROMs -> run as shell (2000)
asettings() { su 2000 -c "settings $*" 2>/dev/null || settings "$@" 2>/dev/null; }

save_state() {
  [ -f "$STATE_FILE" ] && return 0   # keep the ORIGINAL state across restarts
  PD_MODE=$(asettings get global private_dns_mode 2>/dev/null)
  PD_SPEC=$(asettings get global private_dns_specifier 2>/dev/null)
  V6_IN=$(ip6tables -S INPUT 2>/dev/null | sed -n 's/^-P INPUT //p')
  V6_OUT=$(ip6tables -S OUTPUT 2>/dev/null | sed -n 's/^-P OUTPUT //p')
  ( umask 077
    cat > "$STATE_FILE" <<EOF
PD_MODE='$PD_MODE'
PD_SPEC='$PD_SPEC'
V6_IN='${V6_IN:-ACCEPT}'
V6_OUT='${V6_OUT:-ACCEPT}'
EOF
  )
}

block_ipv6() {
  ip6tables -C INPUT  -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || ip6tables -I OUTPUT -o lo -j ACCEPT 2>/dev/null
  ip6tables -P INPUT DROP 2>/dev/null
  ip6tables -P OUTPUT DROP 2>/dev/null
}

set_private_dns() {
  asettings put global private_dns_mode hostname 2>/dev/null
  asettings put global private_dns_specifier one.one.one.one 2>/dev/null
}

restore_system() {
  PD_MODE=opportunistic; PD_SPEC=""; V6_IN=ACCEPT; V6_OUT=ACCEPT
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"

  ip6tables -P INPUT  "$V6_IN"  2>/dev/null
  ip6tables -P OUTPUT "$V6_OUT" 2>/dev/null
  ip6tables -D INPUT  -i lo -j ACCEPT 2>/dev/null
  ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null

  if [ -z "$PD_MODE" ] || [ "$PD_MODE" = "null" ]; then
    asettings delete global private_dns_mode 2>/dev/null
  else
    asettings put global private_dns_mode "$PD_MODE" 2>/dev/null
  fi
  if [ -z "$PD_SPEC" ] || [ "$PD_SPEC" = "null" ]; then
    asettings delete global private_dns_specifier 2>/dev/null
  else
    asettings put global private_dns_specifier "$PD_SPEC" 2>/dev/null
  fi
  rm -f "$STATE_FILE"
}

# ---------------------------------------------------------------- start / stop / status

start_bypass() {
  if [ ! -x "$SINGBOX_BIN" ]; then warn "Core not installed yet - installing first."; install_core; fi
  [ -x "$SINGBOX_BIN" ] || die "Core not installed."
  if is_running; then warn "Already running. Use 'restart', or 'proxy set' / 'proxy off' to change the proxy."; return 0; fi

  maybe_ask_proxy
  build_config
  info "Validating config..."
  CHK=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1) || { say "$CHK"; die "Config is invalid."; }

  info "Starting global tunnel..."
  save_state
  block_ipv6
  : > "$LOG_FILE"
  nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  i=0
  while [ $i -lt 10 ]; do
    is_running || break
    ip link show tun0 >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done

  if ! is_running; then
    rm -f "$PID_FILE"
    restore_system
    say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
    die "sing-box failed to start. Network restored."
  fi

  set_private_dns

  if [ -n "$PROXY_IP" ]; then proxy_summary > "$ACTIVE_PROXY_FILE"; else rm -f "$ACTIVE_PROXY_FILE"; fi

  TRACE=$(curl -s --connect-timeout 8 --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  if [ -n "$TRACE" ]; then
    ok "Tunnel is up. IP: $(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')  Country: $(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')  WARP: $(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')"
  else
    warn "Tunnel process is running but no traffic passed yet."
    if [ -n "$PROXY_IP" ]; then
      warn "The proxy may be down, blocked, or the credentials/type are wrong."
      if [ -z "$NOASK" ] && [ -t 0 ] && confirm "Continue WITHOUT the proxy (WARP only)?" Y; then
        stop_bypass
        clear_proxy_vars
        NOASK=1
        start_bypass
        info "Proxy is still saved; remove it with: sh $SELF proxy off"
        return 0
      fi
      warn "Remove the proxy with:  sh $SELF proxy off"
    else
      warn "Try another port:  WARP_PORT=500 sh $SELF restart   (also 1701, 4500)"
    fi
  fi
  [ -n "$PROXY_IP" ] && ok "Chain: device -> WARP -> $(proxy_summary)"
}

stop_bypass() {
  info "Stopping tunnel..."
  if [ -f "$PID_FILE" ]; then
    P=$(cat "$PID_FILE" 2>/dev/null)
    kill "$P" 2>/dev/null
    i=0; while [ $i -lt 5 ] && kill -0 "$P" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    kill -9 "$P" 2>/dev/null
    rm -f "$PID_FILE"
  fi
  killall sing-box 2>/dev/null || pkill -f "$SINGBOX_BIN" 2>/dev/null
  restore_system
  rm -f "$ACTIVE_PROXY_FILE"
  say "${RED}[-] Stopped. Network restored to previous settings.${NC}"
}

check_status() {
  if is_running; then
    ok "Status: RUNNING (PID $(cat "$PID_FILE"))"
    TRACE=$(curl -s --connect-timeout 6 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    if [ -n "$TRACE" ]; then
      info "Public IP : $(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')"
      info "Country   : $(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')"
      info "WARP      : $(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')  (on/plus = tunnel active)"
      [ -s "$ACTIVE_PROXY_FILE" ] && info "Proxy     : $(cat "$ACTIVE_PROXY_FILE")" || info "Proxy     : none"
    else
      warn "Could not reach Cloudflare through the tunnel."
    fi
  else
    say "${RED}[-] Status: STOPPED${NC}"
  fi
}

show_logs() { [ -f "$LOG_FILE" ] && tail -n 40 "$LOG_FILE" || warn "No log file yet."; }

# ---------------------------------------------------------------- proxy command

proxy_cmd() {
  case "$1" in
    set|on)
      [ -t 0 ] || die "'proxy set' needs an interactive terminal (or edit $USER_CONF)."
      proxy_wizard
      save_proxy_conf
      ok "Proxy saved: $(proxy_summary)"
      if is_running; then
        confirm "Tunnel is running. Restart now to apply the proxy?" Y && { stop_bypass; NOASK=1; start_bypass; }
      else
        info "It will be used on the next start."
      fi
      ;;
    off|stop|clear|remove)
      remove_proxy_conf
      clear_proxy_vars
      ok "Proxy removed from settings."
      if is_running && [ -s "$ACTIVE_PROXY_FILE" ]; then
        info "Restarting the tunnel without the proxy (WARP only)..."
        stop_bypass
        NOASK=1
        start_bypass
      fi
      ;;
    status|"")
      if [ -n "$PROXY_IP" ]; then info "Saved proxy  : $(proxy_summary)"; else info "Saved proxy  : none"; fi
      if is_running && [ -s "$ACTIVE_PROXY_FILE" ]; then info "Active proxy : $(cat "$ACTIVE_PROXY_FILE")"; else info "Active proxy : none"; fi
      ;;
    *) die "Usage: proxy set | proxy off | proxy status" ;;
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
      info "Put proxy settings in $USER_CONF if you want them at boot."
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
  say "${CYAN}Root Network Unblocker v2.2${NC}  (all traffic -> Cloudflare WARP, optional proxy chain)"
  say "  su -c 'sh $SELF install'      ${YELLOW}# download core + register free WARP (once)${NC}"
  say "  su -c 'sh $SELF start'        ${GREEN}# unblock + change IP (asks if you want a proxy)${NC}"
  say "  su -c 'sh $SELF start --no-ask'   ${YELLOW}# no questions, use saved settings${NC}"
  say "  su -c 'sh $SELF stop'         ${RED}# stop everything and restore the network${NC}"
  say "  su -c 'sh $SELF proxy set'    ${YELLOW}# choose socks5 | socks4 | http | https, ip, port, user/pass${NC}"
  say "  su -c 'sh $SELF proxy off'    ${YELLOW}# remove the proxy (WARP keeps running)${NC}"
  say "  su -c 'sh $SELF proxy status'"
  say "  su -c 'sh $SELF restart|status|logs|renew'"
  say "  su -c 'sh $SELF autostart on|off'"
  say "  su -c 'sh $SELF uninstall'"
  say "Env: PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE=1"
  say "     WARP_PORT (2408|500|1701|4500)  WARP_ENDPOINT  TUN_STACK (system|gvisor)  SB_VER  SB_URL  FORCE=1"
}

# ---- main ----
case "$1" in
  ""|help|-h|--help) usage; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root access required. Run with: su -c 'sh $SELF $1'"

PROXY_EXPLICIT=""; [ -n "$PROXY_IP" ] && PROXY_EXPLICIT=1   # proxy given on the command line
load_user_conf
SB_VER="${SB_VER:-1.10.1}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"
WARP_PORT="${WARP_PORT:-2408}"
TUN_STACK="${TUN_STACK:-system}"

for _arg in "$@"; do
  case "$_arg" in --no-ask|--yes|-y) NOASK=1 ;; esac
done

case "$1" in
  install)   install_core ;;
  start)     start_bypass ;;
  stop)      stop_bypass ;;
  restart)   NOASK=1; is_running && stop_bypass; start_bypass ;;
  status)    check_status ;;
  logs)      show_logs ;;
  renew)     renew_warp ;;
  proxy)     proxy_cmd "$2" ;;
  autostart) autostart "$2" ;;
  uninstall) uninstall_all ;;
  *)         usage; exit 1 ;;
esac
