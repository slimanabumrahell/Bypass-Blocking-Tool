#!/system/bin/sh
# Root Network Unblocker v3.0 - Multi-Engine Anti-DPI Suite (sing-box + Xray-core + ByeDPI + wireproxy)
# Path: /data/local/tmp/unblock.sh
#
# Modes & Layers:
#   warp  -> device -> WARP -> internet
#   proxy -> device -> proxy / Xray -> internet
#   dpi   -> device -> ByeDPI (Anti-DPI fragmentation) -> internet
#   both  -> device -> WARP -> proxy / Xray / ByeDPI -> internet

VERSION="3.0"

export PATH="$PATH:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
XRAY_BIN="$WORK_DIR/xray"
BYEDPI_BIN="$WORK_DIR/ciadpi"
WIREPROXY_BIN="$WORK_DIR/wireproxy"

CONFIG_FILE="$WORK_DIR/config.json"
XRAY_CONFIG="$WORK_DIR/xray.json"
WP_CONFIG="$WORK_DIR/wireproxy.conf"

PID_FILE="$WORK_DIR/singbox.pid"
XRAY_PID_FILE="$WORK_DIR/xray.pid"
DPI_PID_FILE="$WORK_DIR/byedpi.pid"
WP_PID_FILE="$WORK_DIR/wireproxy.pid"

LOG_FILE="$WORK_DIR/singbox.log"
XRAY_LOG="$WORK_DIR/xray.log"
DPI_LOG="$WORK_DIR/byedpi.log"
WP_LOG="$WORK_DIR/wireproxy.log"

STATE_FILE="$WORK_DIR/state.env"
ACTIVE_PROXY_FILE="$WORK_DIR/active.proxy"
MODE_FILE="$WORK_DIR/active.mode"
WARP_OK_FILE="$WORK_DIR/warp.ok"
CRED_FILE="/data/adb/warp.conf"
OLD_CRED_FILE="$WORK_DIR/warp_creds.env"
USER_CONF="/data/adb/unblock.conf"
BOOT_HOOK="/data/adb/service.d/99-unblock.sh"
V6_CHAIN="UNBLOCK_V6"

XRAY_LOCAL_PORT="10808"
DPI_LOCAL_PORT="10809"
WP_LOCAL_PORT="40000"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

say()  { printf '%b\n' "$*"; }
info() { say "${CYAN}[*] $*${NC}"; }
warn() { say "${YELLOW}[!] $*${NC}"; }
ok()   { say "${GREEN}[+] $*${NC}"; }
die()  { say "${RED}[x] $*${NC}"; exit 1; }

pid_alive() {
  [ -f "$1" ] || return 1
  _p=$(cat "$1" 2>/dev/null)
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

is_running() { pid_alive "$PID_FILE"; }
current_mode() { is_running && cat "$MODE_FILE" 2>/dev/null; }

need_curl() { command -v curl >/dev/null 2>&1 || die "curl not found. In Termux run: pkg install curl"; }
need_unzip() { command -v unzip >/dev/null 2>&1 || die "unzip not found. In Termux run: pkg install unzip"; }
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

CONF_VARS="PROXY_TYPE PROXY_URI PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_SNI PROXY_INSECURE WARP_ENDPOINT WARP_PORT WARP_MTU WARP_ENGINE DPI_ARGS TUN_STACK SB_VER XRAY_VER BYEDPI_VER WP_VER BLOCK_IPV6 HIDE_PASS PRIVATE_DNS KEEP_ON_FAIL DNS_TRIES FAST_START TLS_FRAG"

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
valid_mtu()  { printf '%s' "$1" | grep -Eq '^[0-9]{3,4}$' && [ "$1" -ge 1200 ] && [ "$1" -le 1500 ]; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

proxy_summary() {
  if [ "$PROXY_TYPE" = "byedpi" ]; then
    printf 'byedpi (127.0.0.1:%s)' "$DPI_LOCAL_PORT"
    return
  fi
  if [ "$PROXY_TYPE" = "xray" ] && [ -n "$PROXY_URI" ]; then
    _proto="${PROXY_URI%%://*}"
    printf 'xray (%s -> 127.0.0.1:%s)' "$_proto" "$XRAY_LOCAL_PORT"
    return
  fi
  S="$PROXY_TYPE://$PROXY_IP:$PROXY_PORT"
  [ -n "$PROXY_USER" ] && S="$S (user: $PROXY_USER)"
  printf '%s' "$S"
}

clear_proxy_vars() {
  PROXY_TYPE=""; PROXY_URI=""; PROXY_IP=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""
}

proxy_wizard() {
  say "${CYAN}--- Proxy / Anti-DPI Setup ---${NC}"
  say "  1) socks5"
  say "  2) socks4"
  say "  3) http"
  say "  4) https"
  say "  5) Xray Link (vless:// | vmess:// | trojan:// | ss://)"
  say "  6) ByeDPI Local Fragmentation (Anti-DPI)"
  while :; do
    ask _c "Choice [1-6] (default 1): "
    case "$_c" in
      ""|1|socks5) PROXY_TYPE=socks5; PROXY_URI=""; break ;;
      2|socks4)    PROXY_TYPE=socks4; PROXY_URI=""; break ;;
      3|http)      PROXY_TYPE=http;   PROXY_URI=""; break ;;
      4|https)     PROXY_TYPE=https;  PROXY_URI=""; break ;;
      5|xray)      PROXY_TYPE=xray;   break ;;
      6|byedpi|dpi) PROXY_TYPE=byedpi; PROXY_URI=""; PROXY_IP="127.0.0.1"; PROXY_PORT="$DPI_LOCAL_PORT"; return 0 ;;
      *) warn "Please choose 1 to 6." ;;
    esac
  done

  if [ "$PROXY_TYPE" = "xray" ]; then
    while :; do
      ask PROXY_URI "Paste Xray URI (vless://, vmess://, trojan://, ss://): "
      case "$PROXY_URI" in
        vless://*|vmess://*|trojan://*|ss://*)
          PROXY_IP="127.0.0.1"
          PROXY_PORT="$XRAY_LOCAL_PORT"
          PROXY_USER=""
          PROXY_PASS=""
          break ;;
        *) warn "Unsupported URI. Must start with vless://, vmess://, trojan://, or ss://" ;;
      esac
    done
    return 0
  fi

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

PROXY_LINE_RE='^[[:space:]]*PROXY_(TYPE|URI|IP|PORT|USER|PASS)='

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
      [ -n "$PROXY_URI" ]  && printf 'PROXY_URI=%s\n'  "$(sq "$PROXY_URI")"
      printf 'PROXY_IP=%s\n'   "$(sq "$PROXY_IP")"
      printf 'PROXY_PORT=%s\n' "$(sq "$PROXY_PORT")"
      [ -n "$PROXY_USER" ] && printf 'PROXY_USER=%s\n' "$(sq "$PROXY_USER")"
      [ -n "$PROXY_PASS" ] && printf 'PROXY_PASS=%s\n' "$(sq "$PROXY_PASS")"
    } >> "$USER_CONF" )
  chmod 600 "$USER_CONF" 2>/dev/null
}

ensure_proxy() {
  if [ "$PROXY_TYPE" = "byedpi" ]; then
    PROXY_IP="127.0.0.1"
    PROXY_PORT="$DPI_LOCAL_PORT"
    return 0
  fi
  if [ "$PROXY_TYPE" = "xray" ] && [ -n "$PROXY_URI" ]; then
    PROXY_IP="127.0.0.1"
    PROXY_PORT="$XRAY_LOCAL_PORT"
    return 0
  fi
  if [ -z "$PROXY_IP" ] || [ -z "$PROXY_PORT" ]; then
    [ -t 0 ] || die "No proxy saved. Run: su -c 'sh $SELF proxy set'"
    warn "No proxy saved yet - let's set one up."
    proxy_wizard
    confirm "Save this proxy for next time?" Y && { save_proxy_conf; ok "Proxy saved."; }
  fi
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64)
      SB_ARCH="arm64"; XRAY_ARCH="arm64-v8a"; DPI_ARCH="arm64"; WP_ARCH="arm64" ;;
    armv7*|armv8l|arm)
      SB_ARCH="armv7"; XRAY_ARCH="arm32-v7a"; DPI_ARCH="arm"; WP_ARCH="arm" ;;
    x86_64)
      SB_ARCH="amd64"; XRAY_ARCH="64"; DPI_ARCH="x86_64"; WP_ARCH="amd64" ;;
    i686|i386)
      SB_ARCH="386"; XRAY_ARCH="32"; DPI_ARCH="x86"; WP_ARCH="386" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

download_singbox() {
  need_curl
  detect_arch
  mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"
  URL="${SB_URL:-https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-android-${SB_ARCH}.tar.gz}"
  info "Downloading sing-box v${SB_VER} (${SB_ARCH})..."
  curl -fL --retry 3 --connect-timeout 15 -o "$WORK_DIR/sb.tar.gz" "$URL" \
    || die "sing-box download failed."
  tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR" || die "sing-box extraction failed."
  mv "$WORK_DIR"/sing-box-*/sing-box "$SINGBOX_BIN" 2>/dev/null || die "sing-box binary missing."
  rm -rf "$WORK_DIR"/sing-box-* "$WORK_DIR/sb.tar.gz"
  chmod 755 "$SINGBOX_BIN"
  "$SINGBOX_BIN" version >/dev/null 2>&1 || die "sing-box binary incompatible."
  ok "Engine [sing-box] ready: $("$SINGBOX_BIN" version 2>/dev/null | head -n1)"
}

download_xray() {
  need_curl
  need_unzip
  detect_arch
  mkdir -p "$WORK_DIR"
  XURL="${XRAY_URL:-https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-android-${XRAY_ARCH}.zip}"
  info "Downloading Xray-core v${XRAY_VER} (${XRAY_ARCH})..."
  if curl -fL --retry 3 --connect-timeout 15 -o "$WORK_DIR/xray.zip" "$XURL"; then
    mkdir -p "$WORK_DIR/xray_tmp"
    unzip -oq "$WORK_DIR/xray.zip" -d "$WORK_DIR/xray_tmp" 2>/dev/null
    if [ -f "$WORK_DIR/xray_tmp/xray" ]; then
      mv "$WORK_DIR/xray_tmp/xray" "$XRAY_BIN"
      chmod 755 "$XRAY_BIN"
      ok "Engine [Xray-core] ready: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
    else
      warn "Xray binary not found in archive."
    fi
    rm -rf "$WORK_DIR/xray_tmp" "$WORK_DIR/xray.zip"
  else
    warn "Xray-core download failed (optional engine)."
  fi
}

download_byedpi() {
  need_curl
  detect_arch
  mkdir -p "$WORK_DIR"
  DURL="${BYEDPI_URL:-https://github.com/hufrea/byedpi/releases/download/v${BYEDPI_VER}/byedpi-${BYEDPI_VER}-${DPI_ARCH}.tar.gz}"
  info "Downloading ByeDPI (ciadpi) v${BYEDPI_VER} (${DPI_ARCH})..."
  if curl -fL --retry 3 --connect-timeout 15 -o "$WORK_DIR/dpi.tar.gz" "$DURL"; then
    mkdir -p "$WORK_DIR/dpi_tmp"
    tar -xzf "$WORK_DIR/dpi.tar.gz" -C "$WORK_DIR/dpi_tmp" 2>/dev/null
    _found=$(find "$WORK_DIR/dpi_tmp" -type f -name "ciadpi" 2>/dev/null | head -n1)
    if [ -n "$_found" ]; then
      mv "$_found" "$BYEDPI_BIN"
      chmod 755 "$BYEDPI_BIN"
      ok "Engine [ByeDPI / ciadpi] ready."
    else
      warn "ciadpi binary not found in archive."
    fi
    rm -rf "$WORK_DIR/dpi_tmp" "$WORK_DIR/dpi.tar.gz"
  else
    warn "ByeDPI download failed (optional engine)."
  fi
}

download_wireproxy() {
  need_curl
  detect_arch
  mkdir -p "$WORK_DIR"
  WURL="${WP_URL:-https://github.com/whyvl/wireproxy/releases/download/v${WP_VER}/wireproxy_linux_${WP_ARCH}.tar.gz}"
  info "Downloading wireproxy v${WP_VER} (${WP_ARCH})..."
  if curl -fL --retry 3 --connect-timeout 15 -o "$WORK_DIR/wp.tar.gz" "$WURL"; then
    mkdir -p "$WORK_DIR/wp_tmp"
    tar -xzf "$WORK_DIR/wp.tar.gz" -C "$WORK_DIR/wp_tmp" 2>/dev/null
    if [ -f "$WORK_DIR/wp_tmp/wireproxy" ]; then
      mv "$WORK_DIR/wp_tmp/wireproxy" "$WIREPROXY_BIN"
      chmod 755 "$WIREPROXY_BIN"
      ok "Engine [wireproxy] ready: v${WP_VER}"
    else
      warn "wireproxy binary not found in archive."
    fi
    rm -rf "$WORK_DIR/wp_tmp" "$WORK_DIR/wp.tar.gz"
  else
    warn "wireproxy download failed (optional engine)."
  fi
}

register_warp() {
  need_curl
  KEYS=$("$SINGBOX_BIN" generate wg-keypair 2>/dev/null)
  PRIV_KEY=$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p')
  PUB_KEY=$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p')
  [ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "Key generation failed."

  info "Registering Cloudflare WARP account..."
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
  [ -n "$CLIENT_IPV4" ] || die "WARP registration failed (API unreachable or rate-limited)."

  PEER_PUB=$(printf '%s' "$RES" | grep -o '"public_key":"[^"]*"' | head -n1 | cut -d'"' -f4)
  CLIENT_ID=$(printf '%s' "$RES" | grep -o '"client_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
  [ -n "$PEER_PUB" ] || die "Could not read WARP peer key."

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
  ok "WARP credentials saved (IP: $CLIENT_IPV4)"
}

install_core() {
  info "Installing Root Network Unblocker v$VERSION..."
  if [ ! -x "$SINGBOX_BIN" ] || [ -n "$FORCE" ]; then download_singbox; else ok "sing-box already installed."; fi
  if [ ! -x "$XRAY_BIN" ] || [ -n "$FORCE" ]; then download_xray; else ok "Xray-core already installed."; fi
  if [ ! -x "$BYEDPI_BIN" ] || [ -n "$FORCE" ]; then download_byedpi; else ok "ByeDPI already installed."; fi
  if [ ! -x "$WIREPROXY_BIN" ] || [ -n "$FORCE" ]; then download_wireproxy; else ok "wireproxy already installed."; fi

  if [ ! -f "$CRED_FILE" ] && [ -f "$OLD_CRED_FILE" ]; then
    mkdir -p "$(dirname "$CRED_FILE")"
    cp "$OLD_CRED_FILE" "$CRED_FILE" && chmod 600 "$CRED_FILE"
  fi
  if [ ! -f "$CRED_FILE" ]; then
    register_warp
  else
    ok "WARP account already exists."
  fi
  info "Installation complete! Commands: warp on|off | proxy on|off | dpi on|off | all on|off"
}
renew_warp() {
  [ -x "$SINGBOX_BIN" ] || die "Core not installed. Run 'install' first."
  _prev=$(current_mode)
  is_running && stop_bypass
  rm -f "$CRED_FILE" "$WARP_OK_FILE"
  register_warp
  if [ "$_prev" = "warp" ] || [ "$_prev" = "both" ]; then
    MODE="$_prev"; NOASK=1; start_bypass
  fi
}

build_xray_config() {
  [ -x "$XRAY_BIN" ] || { download_xray; [ -x "$XRAY_BIN" ] || die "Xray-core binary not available."; }
  _uri="$PROXY_URI"
  _proto="${_uri%%://*}"
  _rest="${_uri#*://}"
  _rest="${_rest%%#*}"

  _frag_block=""
  if [ "${TLS_FRAG:-1}" = "1" ]; then
    _frag_block=',
    {
      "tag": "fragment",
      "protocol": "freedom",
      "settings": {
        "fragment": {
          "packets": "tlshello",
          "length": "10-20",
          "interval": "10-20"
        }
      }
    }'
  fi

  _dialer_opt=""
  if [ "$MODE" = "both" ] && [ "$WARP_ENGINE" = "wireproxy" ]; then
    _dialer_opt='"sockopt": { "dialerProxy": "wp-warp" },'
  fi

  _wp_out=""
  if [ "$MODE" = "both" ] && [ "$WARP_ENGINE" = "wireproxy" ]; then
    _wp_out=", {
      \"tag\": \"wp-warp\",
      \"protocol\": \"socks\",
      \"settings\": { \"servers\": [ { \"address\": \"127.0.0.1\", \"port\": $WP_LOCAL_PORT } ] }
    }"
  fi

  case "$_proto" in
    vless)
      _uuid="${_rest%%@*}"
      _hostport_q="${_rest#*@}"
      _hostport="${_hostport_q%%\?*}"
      _query=""
      case "$_hostport_q" in *\?*) _query="${_hostport_q#*\?}" ;; esac
      _srv="${_hostport%:*}"
      _prt="${_hostport##*:}"
      _sni=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^sni=//p' | head -n1)
      _sec=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^security=//p' | head -n1)
      _net=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^type=//p' | head -n1)
      _pbk=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^pbk=//p' | head -n1)
      _sid=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^sid=//p' | head -n1)
      _fp=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^fp=//p' | head -n1)
      _flow=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^flow=//p' | head -n1)
      _path=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^path=//p' | head -n1 | sed 's/%2F/\//g')
      [ -z "$_net" ] && _net="tcp"
      [ -z "$_fp" ] && _fp="chrome"
      [ -z "$_sni" ] && _sni="$_srv"

      _stream="\"network\": \"$_net\""
      if [ "$_sec" = "reality" ]; then
        _stream="$_stream, \"security\": \"reality\", \"realitySettings\": { \"serverName\": \"$_sni\", \"fingerprint\": \"$_fp\", \"publicKey\": \"$_pbk\", \"shortId\": \"$_sid\" }"
      elif [ "$_sec" = "tls" ]; then
        _stream="$_stream, \"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$_sni\", \"fingerprint\": \"$_fp\", \"allowInsecure\": false }"
      fi
      if [ "$_net" = "ws" ]; then
        _stream="$_stream, \"wsSettings\": { \"path\": \"${_path:-/}\", \"headers\": { \"Host\": \"$_sni\" } }"
      elif [ "$_net" = "grpc" ]; then
        _stream="$_stream, \"grpcSettings\": { \"serviceName\": \"${_path}\" }"
      fi
      _flow_json=""
      [ -n "$_flow" ] && _flow_json="\"flow\": \"$_flow\","

      _out_json="{
        \"tag\": \"proxy\",
        \"protocol\": \"vless\",
        \"settings\": {
          \"vnext\": [ { \"address\": \"$_srv\", \"port\": $_prt, \"users\": [ { \"id\": \"$_uuid\", $_flow_json \"encryption\": \"none\" } ] } ]
        },
        \"streamSettings\": { $_dialer_opt $_stream }
      }"
      ;;
    trojan)
      _pass="${_rest%%@*}"
      _hostport_q="${_rest#*@}"
      _hostport="${_hostport_q%%\?*}"
      _query=""
      case "$_hostport_q" in *\?*) _query="${_hostport_q#*\?}" ;; esac
      _srv="${_hostport%:*}"
      _prt="${_hostport##*:}"
      _sni=$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^sni=//p' | head -n1)
      [ -z "$_sni" ] && _sni="$_srv"
      _out_json="{
        \"tag\": \"proxy\",
        \"protocol\": \"trojan\",
        \"settings\": { \"servers\": [ { \"address\": \"$_srv\", \"port\": $_prt, \"password\": \"$_pass\" } ] },
        \"streamSettings\": { $_dialer_opt \"network\": \"tcp\", \"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$_sni\", \"fingerprint\": \"chrome\" } }
      }"
      ;;
    ss)
      _cred_part="${_rest%%@*}"
      _hostport="${_rest#*@}"
      _srv="${_hostport%:*}"
      _prt="${_hostport##*:}"
      _dec=$(printf '%s' "$_cred_part" | base64 -d 2>/dev/null)
      [ -z "$_dec" ] && _dec="$_cred_part"
      _method="${_dec%%:*}"
      _pass="${_dec#*:}"
      _out_json="{
        \"tag\": \"proxy\",
        \"protocol\": \"shadowsocks\",
        \"settings\": { \"servers\": [ { \"address\": \"$_srv\", \"port\": $_prt, \"method\": \"$_method\", \"password\": \"$_pass\" } ] },
        \"streamSettings\": { $_dialer_opt \"network\": \"tcp\" }
      }"
      ;;
    vmess)
      _dec=$(printf '%s' "$_rest" | base64 -d 2>/dev/null)
      _srv=$(printf '%s' "$_dec" | grep -o '"add":"[^"]*"' | head -n1 | cut -d'"' -f4)
      _prt=$(printf '%s' "$_dec" | grep -o '"port":[0-9]*' | head -n1 | cut -d':' -f2)
      [ -z "$_prt" ] && _prt=$(printf '%s' "$_dec" | grep -o '"port":"[0-9]*"' | head -n1 | cut -d'"' -f4)
      _uuid=$(printf '%s' "$_dec" | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)
      _net=$(printf '%s' "$_dec" | grep -o '"net":"[^"]*"' | head -n1 | cut -d'"' -f4)
      _tls=$(printf '%s' "$_dec" | grep -o '"tls":"[^"]*"' | head -n1 | cut -d'"' -f4)
      _sni=$(printf '%s' "$_dec" | grep -o '"sni":"[^"]*"' | head -n1 | cut -d'"' -f4)
      _path=$(printf '%s' "$_dec" | grep -o '"path":"[^"]*"' | head -n1 | cut -d'"' -f4)
      [ -z "$_net" ] && _net="tcp"
      [ -z "$_sni" ] && _sni="$_srv"
      _sec_json=""
      [ "$_tls" = "tls" ] && _sec_json=", \"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$_sni\", \"fingerprint\": \"chrome\" }"
      _ws_json=""
      [ "$_net" = "ws" ] && _ws_json=", \"wsSettings\": { \"path\": \"${_path:-/}\" }"
      _out_json="{
        \"tag\": \"proxy\",
        \"protocol\": \"vmess\",
        \"settings\": { \"vnext\": [ { \"address\": \"$_srv\", \"port\": $_prt, \"users\": [ { \"id\": \"$_uuid\", \"alterId\": 0 } ] } ] },
        \"streamSettings\": { $_dialer_opt \"network\": \"$_net\" $_sec_json $_ws_json }
      }"
      ;;
    *) die "Unsupported Xray protocol: $_proto" ;;
  esac

  ( umask 077
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning", "access": "none", "error": "$XRAY_LOG" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": $XRAY_LOCAL_PORT,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    $_out_json,
    { "tag": "direct", "protocol": "freedom" }$_wp_out$_frag_block
  ]
}
EOF
  )
}

start_xray() {
  stop_xray
  build_xray_config
  : > "$XRAY_LOG"
  nohup "$XRAY_BIN" run -c "$XRAY_CONFIG" >>"$XRAY_LOG" 2>&1 &
  echo $! > "$XRAY_PID_FILE"
  sleep 1
  pid_alive "$XRAY_PID_FILE" || die "Xray-core failed to start. Check: $XRAY_LOG"
  ok "Xray-core active on 127.0.0.1:$XRAY_LOCAL_PORT (TLS Fragmentation: ${TLS_FRAG:-1})"
}

stop_xray() {
  if [ -f "$XRAY_PID_FILE" ]; then
    _xp=$(cat "$XRAY_PID_FILE" 2>/dev/null)
    [ -n "$_xp" ] && kill "$_xp" 2>/dev/null
    rm -f "$XRAY_PID_FILE"
  fi
}

start_byedpi() {
  stop_byedpi
  [ -x "$BYEDPI_BIN" ] || { download_byedpi; [ -x "$BYEDPI_BIN" ] || die "ByeDPI (ciadpi) binary not available."; }
  : > "$DPI_LOG"
  _args="${DPI_ARGS:--i 127.0.0.1 -p $DPI_LOCAL_PORT -f 1 -s 2 -o 1 -r 1+s}"
  nohup "$BYEDPI_BIN" $_args >>"$DPI_LOG" 2>&1 &
  echo $! > "$DPI_PID_FILE"
  sleep 1
  pid_alive "$DPI_PID_FILE" || die "ByeDPI failed to start. Check: $DPI_LOG"
  ok "ByeDPI active on 127.0.0.1:$DPI_LOCAL_PORT (Anti-DPI packet splitting)"
}

stop_byedpi() {
  if [ -f "$DPI_PID_FILE" ]; then
    _dp=$(cat "$DPI_PID_FILE" 2>/dev/null)
    [ -n "$_dp" ] && kill "$_dp" 2>/dev/null
    rm -f "$DPI_PID_FILE"
  fi
}

build_wireproxy_config() {
  load_creds
  _mtu="${WARP_MTU:-1360}"
  ( umask 077
    cat > "$WP_CONFIG" <<EOF
[Interface]
PrivateKey = $PRIV_KEY
Address = $CLIENT_IPV4/32
DNS = 1.1.1.1
MTU = $_mtu

[Peer]
PublicKey = $PEER_PUB
Endpoint = $WARP_ENDPOINT:$WARP_PORT
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:$WP_LOCAL_PORT
EOF
  )
}

start_wireproxy() {
  stop_wireproxy
  [ -x "$WIREPROXY_BIN" ] || { download_wireproxy; [ -x "$WIREPROXY_BIN" ] || die "wireproxy not available."; }
  build_wireproxy_config
  : > "$WP_LOG"
  nohup "$WIREPROXY_BIN" -c "$WP_CONFIG" >>"$WP_LOG" 2>&1 &
  echo $! > "$WP_PID_FILE"
  sleep 1
  pid_alive "$WP_PID_FILE" || die "wireproxy failed to start."
  ok "wireproxy WARP active on 127.0.0.1:$WP_LOCAL_PORT"
}

stop_wireproxy() {
  if [ -f "$WP_PID_FILE" ]; then
    _wp=$(cat "$WP_PID_FILE" 2>/dev/null)
    [ -n "$_wp" ] && kill "$_wp" 2>/dev/null
    rm -f "$WP_PID_FILE"
  fi
}

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
    || die "WARP credentials corrupted. Run: su -c 'sh $SELF renew'"
  printf '%s' "$RESERVED" | grep -Eq '^[0-9]+,[0-9]+,[0-9]+$' || RESERVED=""
}

wg_outbound() {
  if [ "$WARP_ENGINE" = "wireproxy" ]; then
    cat <<EOF
{
  "type": "socks",
  "tag": "warp-out",
  "version": "5",
  "server": "127.0.0.1",
  "server_port": $WP_LOCAL_PORT
}
EOF
    return
  fi

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
  if [ "$PROXY_TYPE" = "byedpi" ]; then
    DETOUR_JSON=""
    [ "$MODE" = "both" ] && DETOUR_JSON='"detour": "warp-out",'
    cat <<EOF
{
  "type": "socks",
  "tag": "proxy-out",
  "version": "5",
  $DETOUR_JSON
  "server": "127.0.0.1",
  "server_port": $DPI_LOCAL_PORT
}
EOF
    return
  fi

  if [ "$PROXY_TYPE" = "xray" ]; then
    DETOUR_JSON=""
    [ "$MODE" = "both" ] && [ "$WARP_ENGINE" != "wireproxy" ] && DETOUR_JSON='"detour": "warp-out",'
    cat <<EOF
{
  "type": "socks",
  "tag": "proxy-out",
  "version": "5",
  $DETOUR_JSON
  "server": "127.0.0.1",
  "server_port": $XRAY_LOCAL_PORT
}
EOF
    return
  fi

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
  if [ "$PROXY_TYPE" = "byedpi" ]; then
    PROXY_IP="127.0.0.1"
    PROXY_PORT="$DPI_LOCAL_PORT"
    return 0
  fi
  if [ "$PROXY_TYPE" = "xray" ]; then
    [ -n "$PROXY_URI" ] || die "Xray URI is missing. Run: su -c 'sh $SELF proxy set'"
    PROXY_IP="127.0.0.1"
    PROXY_PORT="$XRAY_LOCAL_PORT"
    return 0
  fi
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
    *) die "Unknown proxy type '$PROXY_TYPE'." ;;
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
      if [ "$PROXY_TYPE" != "xray" ] && [ "$PROXY_TYPE" != "byedpi" ] && ! is_ip "$PROXY_IP"; then
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

WARP_CANDIDATES="162.159.192.1:2408 162.159.192.1:500 162.159.192.1:4500 162.159.192.1:1701 162.159.193.1:2408 162.159.195.1:500 188.114.97.1:2408 188.114.96.1:500 188.114.98.1:4500 188.114.99.1:1701 162.159.192.1:854 162.159.192.1:880 162.159.192.1:1180"

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
  if [ "$MODE" != "proxy" ] && [ "$WARP_ENGINE" = "wireproxy" ]; then
    start_wireproxy
  else
    stop_wireproxy
  fi

  if [ "$MODE" != "warp" ] && [ "$PROXY_TYPE" = "xray" ]; then
    start_xray
  else
    stop_xray
  fi

  if [ "$MODE" != "warp" ] && [ "$PROXY_TYPE" = "byedpi" ]; then
    start_byedpi
  else
    stop_byedpi
  fi

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
  _keep_mode="$MODE"; _keep_eng="$WARP_ENGINE"
  MODE="warp"; WARP_ENGINE="sing-box"
  LAST=""; [ -s "$WARP_OK_FILE" ] && LAST=$(cat "$WARP_OK_FILE" 2>/dev/null)
  for c in $LAST $WARP_CANDIDATES; do
    WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    if launch_core && probe_warp; then
      ok "WARP endpoint ready: $WARP_ENDPOINT:$WARP_PORT"
      printf '%s' "$c" > "$WARP_OK_FILE"
      kill_core
      MODE="$_keep_mode"; WARP_ENGINE="$_keep_eng"
      return 0
    fi
    kill_core
  done
  MODE="$_keep_mode"; WARP_ENGINE="$_keep_eng"
  return 1
}

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

dns_servers() {
  dumpsys connectivity 2>/dev/null | grep -o 'DnsAddresses: \[[^]]*\]' \
    | sed 's/DnsAddresses: \[//; s/\]//; s#/##g; s/,/ /g' | tr -s ' ' '\n' | sed '/^$/d' | sort -u
}

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
      warn "Direct proxy failed; chaining over WARP (device -> WARP -> proxy)..."
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
    install_core
  fi
  if is_running; then
    warn "Already running (mode: $(current_mode))."
    return 0
  fi

  case "$MODE" in
    warp)       clear_proxy_vars ;;
    proxy|both) ensure_proxy ;;
    *)          if [ -n "$PROXY_IP" ] || [ -n "$PROXY_URI" ]; then MODE="both"; else MODE="warp"; fi ;;
  esac

  if [ "$MODE" != "warp" ]; then
    validate_proxy || die "No proxy configured. Run: su -c 'sh $SELF proxy set'"
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
        find_warp_endpoint || { cleanup_leftovers; restore_system; die "No reachable WARP endpoint found."; }
      else
        kill_core
      fi
    else
      find_warp_endpoint || { cleanup_leftovers; restore_system; die "No reachable WARP endpoint found."; }
    fi
    if [ -s "$WARP_OK_FILE" ]; then
      c=$(cat "$WARP_OK_FILE")
      WARP_ENDPOINT="${c%:*}"; WARP_PORT="${c##*:}"
    fi
  fi

  case "$MODE" in
    warp)  info "Starting WARP (engine: ${WARP_ENGINE:-sing-box})..." ;;
    proxy) info "Starting Proxy ($(proxy_summary))..." ;;
    both)  info "Starting WARP (${WARP_ENGINE:-sing-box}) + Proxy ($(proxy_summary))..." ;;
  esac

  launch_core
  if ! is_running; then
    rm -f "$PID_FILE"
    stop_xray; stop_byedpi; stop_wireproxy
    kill_stale; cleanup_leftovers; restore_system
    say "--- last log lines ---"; tail -n 15 "$LOG_FILE" 2>/dev/null
    die "Tunnel failed to start. Network restored."
  fi

  apply_private_dns

  printf '%s' "$MODE" > "$MODE_FILE"
  if [ "$MODE" != "warp" ] && { [ -n "$PROXY_IP" ] || [ -n "$PROXY_URI" ]; }; then
    proxy_summary > "$ACTIVE_PROXY_FILE"
  else
    rm -f "$ACTIVE_PROXY_FILE"
  fi

  if ! verify_tunnel; then
    handle_no_traffic
    return $?
  fi

  case "$MODE" in
    warp)  ok "Active: WARP only | IP: $T_IP | Loc: $T_LOC | WARP: $T_WARP" ;;
    proxy) ok "Active: Proxy only | IP: $T_IP | Loc: $T_LOC | Proxy: $(proxy_summary)" ;;
    both)  ok "Active: WARP + Proxy | IP: $T_IP | Loc: $T_LOC | Chain: WARP -> $(proxy_summary)" ;;
  esac

  dns_ready && ok "DNS: OK" || warn "DNS check retrying (curl exit ${DNS_RC:-?})"
  return 0
}

stop_bypass() {
  info "Stopping all engines..."
  stop_xray
  stop_byedpi
  stop_wireproxy
  kill_core
  cleanup_leftovers
  restore_system
  rm -f "$ACTIVE_PROXY_FILE" "$MODE_FILE"
  say "${RED}[-] Stopped. Normal network restored.${NC}"
}

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
    launch_core || { stop_xray; stop_byedpi; stop_wireproxy; cleanup_leftovers; restore_system; die "Failed to switch mode."; }
    printf '%s' "$_target" > "$MODE_FILE"
    if [ "$_target" != "warp" ] && { [ -n "$PROXY_IP" ] || [ -n "$PROXY_URI" ]; }; then
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
    ok "Status: RUNNING (sing-box PID $(cat "$PID_FILE"))"
    pid_alive "$XRAY_PID_FILE" && info "Xray-core : RUNNING (PID $(cat "$XRAY_PID_FILE"), port $XRAY_LOCAL_PORT)"
    pid_alive "$DPI_PID_FILE"  && info "ByeDPI    : RUNNING (PID $(cat "$DPI_PID_FILE"), port $DPI_LOCAL_PORT)"
    pid_alive "$WP_PID_FILE"   && info "wireproxy : RUNNING (PID $(cat "$WP_PID_FILE"), port $WP_LOCAL_PORT)"
    case "$(current_mode)" in
      warp)  info "Mode      : WARP only (device -> WARP)" ;;
      proxy) info "Mode      : Proxy/Anti-DPI only (device -> proxy)" ;;
      both)  info "Mode      : WARP + Proxy/Anti-DPI (device -> WARP -> proxy)" ;;
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
      warn "Could not reach Cloudflare through active tunnel."
    fi
  else
    say "${RED}[-] Status: STOPPED${NC}"
  fi
}

show_logs() {
  say "${CYAN}=== sing-box log ===${NC}"
  [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || warn "No sing-box log."
  if [ -f "$XRAY_LOG" ] && [ -s "$XRAY_LOG" ]; then
    say "${CYAN}=== Xray-core log ===${NC}"
    tail -n 15 "$XRAY_LOG"
  fi
  if [ -f "$DPI_LOG" ] && [ -s "$DPI_LOG" ]; then
    say "${CYAN}=== ByeDPI log ===${NC}"
    tail -n 15 "$DPI_LOG"
  fi
  if [ -f "$WP_LOG" ] && [ -s "$WP_LOG" ]; then
    say "${CYAN}=== wireproxy log ===${NC}"
    tail -n 15 "$WP_LOG"
  fi
}

doctor() {
  say "${CYAN}=== Root Network Unblocker v$VERSION - Diagnostics ===${NC}"
  say "Device       : $(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null) | Android $(getprop ro.build.version.release 2>/dev/null) | $(uname -m)"
  say "Root         : $(id 2>/dev/null)"
  [ -x "$SINGBOX_BIN" ]   && say "sing-box     : $("$SINGBOX_BIN" version 2>/dev/null | head -n1)" || say "sing-box     : NOT installed"
  [ -x "$XRAY_BIN" ]      && say "Xray-core    : $("$XRAY_BIN" version 2>/dev/null | head -n1)"    || say "Xray-core    : NOT installed"
  [ -x "$BYEDPI_BIN" ]    && say "ByeDPI       : installed" || say "ByeDPI       : NOT installed"
  [ -x "$WIREPROXY_BIN" ] && say "wireproxy    : installed" || say "wireproxy    : NOT installed"
  [ -f "$CRED_FILE" ]     && say "WARP account : present" || say "WARP account : missing"
  say "WARP endpoint: $(cat "$WARP_OK_FILE" 2>/dev/null || echo 'not searched yet')"
  { [ -n "$PROXY_IP" ] || [ -n "$PROXY_URI" ]; } && say "Saved proxy  : $(proxy_summary)" || say "Saved proxy  : none"
  if is_running; then say "Tunnel       : RUNNING (mode: $(current_mode))"; else say "Tunnel       : stopped"; fi
  say "tun0         : $(ip addr show tun0 2>/dev/null | grep 'inet ' | tr -s ' ' | head -n1)"
  say "DNS servers  : $(dns_servers | tr '\n' ' ')"
}

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
        both) info "Stopping WARP, keeping proxy..."; apply_layer_mode proxy ;;
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
        both)  info "Stopping proxy, keeping WARP..."; apply_layer_mode warp ;;
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
      { [ -n "$PROXY_IP" ] || [ -n "$PROXY_URI" ]; } && info "Saved proxy  : $(proxy_summary)" || info "Saved proxy  : none"
      is_running && [ -s "$ACTIVE_PROXY_FILE" ] && info "Active proxy : $(cat "$ACTIVE_PROXY_FILE")" || info "Active proxy : none"
      ;;
    *) die "Usage: proxy on | proxy off | proxy set | proxy clear | proxy status" ;;
  esac
}

dpi_cmd() {
  case "$1" in
    on)
      PROXY_TYPE="byedpi"; PROXY_URI=""; PROXY_IP="127.0.0.1"; PROXY_PORT="$DPI_LOCAL_PORT"
      case "$(current_mode)" in
        warp)  apply_layer_mode both ;;
        both)  warn "WARP + ByeDPI is already running." ;;
        proxy) warn "ByeDPI/Proxy is already running." ;;
        *)     apply_layer_mode proxy ;;
      esac ;;
    off|stop)
      case "$(current_mode)" in
        proxy) stop_bypass ;;
        both)  info "Stopping ByeDPI, keeping WARP..."; apply_layer_mode warp ;;
        *)     warn "ByeDPI is not running." ;;
      esac ;;
    status|"") check_status ;;
    *) die "Usage: dpi on | dpi off | dpi status" ;;
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
  say "${CYAN}Root Network Unblocker v$VERSION (sing-box + Xray-core + ByeDPI + wireproxy)${NC}"
  say "  warp on | warp off          (WARP only)"
  say "  proxy on | proxy off        (Proxy or Xray link)"
  say "  dpi on | dpi off            (ByeDPI Anti-DPI packet fragmentation)"
  say "  all on | all off            (WARP + Proxy/Xray/ByeDPI together)"
  say "  proxy set | proxy clear | proxy status"
  say "  install | status | logs | doctor | renew | autostart on|off | uninstall"
}

case "$1" in
  ""|help|-h|--help) usage; exit 0 ;;
  version|-v|--version) say "Root Network Unblocker v$VERSION"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root access required. Run with: su -c 'sh $SELF $*'"

load_user_conf
WARP_FIXED=""; [ -n "$WARP_ENDPOINT$WARP_PORT" ] && WARP_FIXED=1
SB_VER="${SB_VER:-1.10.1}"
XRAY_VER="${XRAY_VER:-24.11.30}"
BYEDPI_VER="${BYEDPI_VER:-0.16.1}"
WP_VER="${WP_VER:-1.0.9}"
WARP_ENGINE="${WARP_ENGINE:-sing-box}"
WARP_ENDPOINT="${WARP_ENDPOINT:-162.159.192.1}"
WARP_PORT="${WARP_PORT:-2408}"
TUN_STACK="${TUN_STACK:-system}"
PRIVATE_DNS="${PRIVATE_DNS:-off}"
TLS_FRAG="${TLS_FRAG:-1}"
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
  dpi|byedpi) dpi_cmd "$2" ;;
  all|both)  all_cmd "$2" ;;
  autostart) autostart "$2" ;;
  uninstall) uninstall_all ;;
  *)         usage; exit 1 ;;
esac
