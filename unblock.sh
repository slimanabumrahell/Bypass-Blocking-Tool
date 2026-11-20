#!/system/bin/sh
# Root Network Unblocker v2.1 - Cloudflare WARP TUN tunnel (sing-box) for rooted Android
# Path: /data/local/tmp/unblock.sh
#
# Commands: install | start | stop | restart | status | logs | renew
#           autostart on|off | uninstall | help

export PATH="$PATH:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
PID_FILE="$WORK_DIR/singbox.pid"
LOG_FILE="$WORK_DIR/sing-box.log"
STATE_FILE="$WORK_DIR/state.env"
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
load_user_conf() {
  [ -f "$USER_CONF" ] || return 0
  for v in PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS WARP_ENDPOINT WARP_PORT TUN_STACK SB_VER; do
    eval "cli_$v=\"\$$v\""
  done
  . "$USER_CONF"
  for v in PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS WARP_ENDPOINT WARP_PORT TUN_STACK SB_VER; do
    eval "[ -n \"\$cli_$v\" ] && $v=\"\$cli_$v\""
  done
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
  info "Installing Root Network Unblocker v2.1..."
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
  AUTH_JSON=""
  if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    AUTH_JSON="\"username\": \"$(json_esc "$PROXY_USER")\", \"password\": \"$(json_esc "$PROXY_PASS")\","
  fi
  cat <<EOF
{
  "type": "http",
  "tag": "proxy-out",
  "server": "$(json_esc "$PROXY_IP")",
  "server_port": $PROXY_PORT,
  $AUTH_JSON
  "detour": "warp-out"
}
EOF
}

build_config() {
  load_creds
  if [ -n "$PROXY_IP" ] || [ -n "$PROXY_PORT" ]; then
    [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ] || die "Both PROXY_IP and PROXY_PORT are required."
    printf '%s' "$PROXY_PORT" | grep -Eq '^[0-9]+$' || die "PROXY_PORT must be a number."
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
  [ -x "$SINGBOX_BIN" ] || die "Core not installed. Run 'install' first."
  if is_running; then warn "Already running."; return 0; fi

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

  TRACE=$(curl -s --connect-timeout 8 --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  if [ -n "$TRACE" ]; then
    ok "Tunnel is up. IP: $(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')  Country: $(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')  WARP: $(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')"
  else
    warn "Tunnel process is running but no traffic passed yet."
    warn "Try another port:  WARP_PORT=500 sh $SELF restart   (also 1701, 4500)"
  fi
  [ -n "$PROXY_IP" ] && ok "Chain: device -> WARP -> HTTP proxy ($PROXY_IP:$PROXY_PORT)"
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
    else
      warn "Could not reach Cloudflare through the tunnel."
    fi
  else
    say "${RED}[-] Status: STOPPED${NC}"
  fi
}

show_logs() { [ -f "$LOG_FILE" ] && tail -n 40 "$LOG_FILE" || warn "No log file yet."; }

# ---------------------------------------------------------------- autostart / uninstall

autostart() {
  case "$1" in
    on)
      [ -d /data/adb/service.d ] || mkdir -p /data/adb/service.d
      cat > "$BOOT_HOOK" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 20
sh $SELF start >> $WORK_DIR/boot.log 2>&1
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
  say "${CYAN}Root Network Unblocker v2.1${NC}  (all traffic -> Cloudflare WARP)"
  say "  su -c 'sh $SELF install'     ${YELLOW}# download core + register free WARP (once)${NC}"
  say "  su -c 'sh $SELF start'       ${GREEN}# unblock + change IP${NC}"
  say "  su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 [PROXY_USER=u PROXY_PASS=p] sh $SELF start'"
  say "  su -c 'sh $SELF stop|restart|status|logs'"
  say "  su -c 'sh $SELF renew'       ${YELLOW}# new WARP account${NC}"
  say "  su -c 'sh $SELF autostart on|off'"
  say "  su -c 'sh $SELF uninstall'"
  say "Env: WARP_PORT (2408|500|1701|4500)  WARP_ENDPOINT  TUN_STACK (system|gvisor)  SB_VER  SB_URL  FORCE=1"
}

# ---- main ----
case "$1" in
  ""|help|-h|--help) usage; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root access required. Run with: su -c 'sh $SELF $1'"

load_user_conf
SB_VER="${SB_VER:-1.10.1}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"
WARP_PORT="${WARP_PORT:-2408}"
TUN_STACK="${TUN_STACK:-system}"

case "$1" in
  install)   install_core ;;
  start)     start_bypass ;;
  stop)      stop_bypass ;;
  restart)   is_running && stop_bypass; start_bypass ;;
  status)    check_status ;;
  logs)      show_logs ;;
  renew)     renew_warp ;;
  autostart) autostart "$2" ;;
  uninstall) uninstall_all ;;
  *)         usage; exit 1 ;;
esac
