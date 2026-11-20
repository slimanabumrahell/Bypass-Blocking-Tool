#!/system/bin/sh
# Root Network Unblocker & DPI Bypass Suite v3.0
# Engines : sing-box (system-wide TUN gateway), wireproxy (Cloudflare WARP),
#           ByeDPI/ciadpi (local DPI bypass), Xray-core (VLESS/VMess/Trojan/SS links)
# Path    : /data/local/tmp/unblock.sh
# Usage   : su -c 'sh /data/local/tmp/unblock.sh <command>'
#
# Architecture (every mode uses the same gateway):
#   apps -> tun0 (sing-box) -> local SOCKS5 engine -> internet
#     warp  : wireproxy   127.0.0.1:40000  (WireGuard to Cloudflare WARP)
#     dpi   : ciadpi      127.0.0.1:10800  (SNI split / fragmentation)
#     proxy : Xray        127.0.0.1:10808  (links)  or sing-box native (socks/http)
#     both  : WARP first, then proxy        (device -> WARP -> proxy -> internet)
# Engines run as ENGINE_UID (default 2000) and that UID is excluded from the
# TUN, so engine traffic never loops back into the tunnel.

VERSION="3.0"
TERMUX_USR="/data/data/com.termux/files/usr"
export PATH="/system/bin:/system/xbin:$PATH:$TERMUX_USR/bin"

SELF="/data/local/tmp/unblock.sh"
WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
XRAY_BIN="$WORK_DIR/xray"
WIREPROXY_BIN="$WORK_DIR/wireproxy"
BYEDPI_BIN="$WORK_DIR/ciadpi"

CONFIG_FILE="$WORK_DIR/config.json"
XRAY_CONFIG="$WORK_DIR/xray.json"
WP_CONF="$WORK_DIR/wireproxy.conf"

PID_FILE="$WORK_DIR/singbox.pid"
XRAY_PID="$WORK_DIR/xray.pid"
WP_PID="$WORK_DIR/wireproxy.pid"
DPI_PID="$WORK_DIR/ciadpi.pid"

LOG_FILE="$WORK_DIR/singbox.log"
XRAY_LOG="$WORK_DIR/xray.log"
WP_LOG="$WORK_DIR/wireproxy.log"
DPI_LOG="$WORK_DIR/ciadpi.log"

STATE_FILE="$WORK_DIR/state.env"
MODE_FILE="$WORK_DIR/active.mode"
ACTIVE_PROXY_FILE="$WORK_DIR/active.proxy"
WARP_OK_FILE="$WORK_DIR/warp.ok"

CRED_FILE="/data/adb/warp.conf"
USER_CONF="/data/adb/unblock.conf"
V6_CHAIN="UNBLOCK_V6"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
say()  { printf '%b\n' "$*"; }
info() { say "${CYAN}[*]${NC} $*"; }
warn() { say "${YELLOW}[!]${NC} $*"; }
ok()   { say "${GREEN}[+]${NC} $*"; }
die()  { say "${RED}[x]${NC} $*"; exit 1; }

# ------------------------------------------------------------------ config
CONF_VARS="PROXY_TYPE PROXY_IP PROXY_PORT PROXY_USER PROXY_PASS PROXY_URL PROXY_SNI PROXY_INSECURE WARP_ENDPOINT WARP_PORT WARP_MTU TUN_STACK SB_VER XRAY_VER BYEDPI_URL BLOCK_IPV6 HIDE_PASS PRIVATE_DNS DNS_TRIES ENGINE_UID SOCKS_WARP SOCKS_DPI SOCKS_XRAY DPI_ARGS XRAY_FRAGMENT XRAY_FRAG_LEN XRAY_FRAG_INT"

set_defaults() {
    : "${WARP_MTU:=1280}"
    : "${TUN_STACK:=mixed}"
    : "${BLOCK_IPV6:=1}"
    : "${HIDE_PASS:=1}"
    : "${PRIVATE_DNS:=off}"
    : "${DNS_TRIES:=3}"
    : "${ENGINE_UID:=2000}"
    : "${SOCKS_WARP:=40000}"
    : "${SOCKS_DPI:=10800}"
    : "${SOCKS_XRAY:=10808}"
    : "${DPI_ARGS:=-s 1+s -d 1+s -r 1+s}"
    : "${XRAY_FRAGMENT:=1}"
    : "${XRAY_FRAG_LEN:=100-200}"
    : "${XRAY_FRAG_INT:=10-20}"
    : "${PROXY_INSECURE:=0}"
}

load_user_conf() {
    [ -f "$USER_CONF" ] && . "$USER_CONF"
    set_defaults
}

# Cloudflare WARP endpoints tried in order (the last working one is cached)
WARP_CANDIDATES="162.159.192.1:2408 162.159.192.1:500 162.159.192.1:4500 162.159.192.1:1701 162.159.192.1:854 162.159.195.1:2408 162.159.195.1:500 188.114.97.1:2408 188.114.97.1:500 188.114.98.1:4500 188.114.99.1:1701 162.159.192.1:880 162.159.192.1:1180"

# ------------------------------------------------------------------ helpers
need_curl() {
    command -v curl >/dev/null 2>&1 || die "curl not found. In Termux run: pkg install curl"
}

pid_alive() {
    [ -f "$1" ] || return 1
    _pp=$(cat "$1" 2>/dev/null)
    [ -n "$_pp" ] && kill -0 "$_pp" 2>/dev/null
}

kill_pidfile() {
    [ -f "$1" ] || return 0
    _pp=$(cat "$1" 2>/dev/null)
    if [ -n "$_pp" ]; then
        kill "$_pp" 2>/dev/null
        _ki=0
        while [ "$_ki" -lt 5 ] && kill -0 "$_pp" 2>/dev/null; do sleep 1; _ki=$((_ki + 1)); done
        kill -0 "$_pp" 2>/dev/null && kill -9 "$_pp" 2>/dev/null
    fi
    rm -f "$1"
    return 0
}

# kill leftovers that run OUR binaries (never touches other copies on the system)
kill_stale() {
    for _n in sing-box xray wireproxy ciadpi; do
        for _p in $(pidof "$_n" 2>/dev/null); do
            _e=$(readlink "/proc/$_p/exe" 2>/dev/null)
            case "$_e" in "$WORK_DIR"/*) kill -9 "$_p" 2>/dev/null ;; esac
        done
    done
    return 0
}

is_running() { pid_alive "$PID_FILE"; }

current_mode() { is_running && cat "$MODE_FILE" 2>/dev/null; }

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# single-quote a value so it can be written to a sourced config file
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"; }

is_ip()      { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_host() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; }
valid_port() { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# give an engine's config to ENGINE_UID only
give_engine() {
    [ "$ENGINE_UID" = "0" ] || chown "$ENGINE_UID:$ENGINE_UID" "$1" 2>/dev/null
    chmod 600 "$1" 2>/dev/null
}

# run a long-lived engine: spawn_engine <log> <binary> [args...]
# runs as ENGINE_UID (excluded from the TUN) and records its PID in <pidfile>
spawn_engine() {
    _log="$1"; _pidf="$2"; shift 2
    : > "$_log"; chmod 600 "$_log"
    if [ "$ENGINE_UID" = "0" ]; then
        nohup "$@" >>"$_log" 2>&1 &
    else
        nohup su "$ENGINE_UID" -c "exec $*" >>"$_log" 2>&1 &
    fi
    sleep 1
    _bn="${1##*/}"
    _sp=$(pidof "$_bn" 2>/dev/null | tr ' ' '\n' | sort -n | tail -n 1)
    [ -n "$_sp" ] || return 1
    printf '%s' "$_sp" > "$_pidf"
    return 0
}

# ------------------------------------------------------------------ prompts
ask() {
    printf '%b' "${CYAN}$2${NC}"
    read -r _a || die "Input closed."
    _a=$(printf '%s' "$_a" | tr -d '\r')
    eval "$1=\$_a"
}

ask_secret() {
    if [ "$HIDE_PASS" = "1" ] && [ -t 0 ]; then
        printf '%b' "${CYAN}$2${NC}"
        trap 'stty echo 2>/dev/null; exit 130' INT
        stty -echo 2>/dev/null
        read -r _a || _a=""
        stty echo 2>/dev/null
        trap - INT
        printf '\n'
    else
        printf '%b' "${CYAN}$2(visible) ${NC}"
        read -r _a || _a=""
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

# ------------------------------------------------------------------ proxy config
proxy_summary() {
    if [ -n "$PROXY_URL" ]; then
        printf '%s' "Link ($(printf '%s' "$PROXY_URL" | cut -d':' -f1))"
    else
        _s="$PROXY_TYPE://$PROXY_IP:$PROXY_PORT"
        [ -n "$PROXY_USER" ] && _s="$_s (user:$PROXY_USER)"
        printf '%s' "$_s"
    fi
}

proxy_configured() { [ -n "$PROXY_URL" ] || [ -n "$PROXY_IP" ]; }

clear_proxy_vars() {
    PROXY_TYPE=""; PROXY_IP=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""; PROXY_URL=""
}

proxy_wizard() {
    say "${CYAN}--- Proxy setup ---${NC}"
    say "  1) Standard proxy (SOCKS5 / SOCKS4 / HTTP / HTTPS)"
    say "  2) Link: vless:// vmess:// trojan:// ss://   (runs through Xray-core)"
    ask _choice "Select [1-2] (default 1): "
    if [ "$_choice" = "2" ]; then
        while :; do
            ask PROXY_URL "Paste link: "
            case "$PROXY_URL" in
                vless://*|vmess://*|trojan://*|ss://*) break ;;
            esac
            warn "Link must start with vless:// vmess:// trojan:// or ss://"
        done
        if ! parse_link "$PROXY_URL"; then
            warn "Could not read that link - check it and try again."
            PROXY_URL=""
            return 1
        fi
        PROXY_TYPE="url"; PROXY_IP=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""
        ok "Link OK: $L_SCHEME -> $L_HOST:$L_PORT ($L_NET/$L_SEC)"
        return 0
    fi
    PROXY_URL=""
    say "  1) socks5   2) socks4   3) http   4) https"
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
    ask PROXY_USER "Username (Enter if none): "
    if [ -n "$PROXY_USER" ]; then
        if [ "$PROXY_TYPE" = "socks4" ]; then
            warn "SOCKS4 sends a user id only (no password)."
        else
            ask_secret PROXY_PASS "Password (Enter if none): "
        fi
    fi
    return 0
}

PROXY_LINE_RE='^[[:space:]]*PROXY_(TYPE|IP|PORT|USER|PASS|URL)='

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
        [ -n "$PROXY_IP" ]   && printf 'PROXY_IP=%s\n'   "$(sq "$PROXY_IP")"
        [ -n "$PROXY_PORT" ] && printf 'PROXY_PORT=%s\n' "$(sq "$PROXY_PORT")"
        [ -n "$PROXY_USER" ] && printf 'PROXY_USER=%s\n' "$(sq "$PROXY_USER")"
        [ -n "$PROXY_PASS" ] && printf 'PROXY_PASS=%s\n' "$(sq "$PROXY_PASS")"
        [ -n "$PROXY_URL" ]  && printf 'PROXY_URL=%s\n'  "$(sq "$PROXY_URL")"
      } >> "$USER_CONF" )
    chmod 600 "$USER_CONF" 2>/dev/null
}

ensure_proxy() {
    proxy_configured && return 0
    [ -t 0 ] || die "No proxy saved. Run: su -c 'sh $SELF proxy set'"
    warn "No proxy configured - let's set one up."
    proxy_wizard || die "Proxy setup failed."
    confirm "Save this proxy configuration?" Y && { save_proxy_conf; ok "Proxy saved."; }
}

# ------------------------------------------------------------------ link parsing
b64d() {
    _s=$(printf '%s' "$1" | tr '_-' '/+' | tr -d '\r\n ')
    case $(( ${#_s} % 4 )) in
        2) _s="$_s==" ;;
        3) _s="$_s=" ;;
    esac
    printf '%s' "$_s" | base64 -d 2>/dev/null
}

urldec() {
    printf '%s' "$1" | sed 's/%2[Ff]/\//g; s/%3[Dd]/=/g; s/%2[Bb]/+/g; s/%3[Aa]/:/g; s/%2[Cc]/,/g; s/%3[Ff]/?/g; s/%26/\&/g; s/%20/ /g; s/%40/@/g; s/%25/%/g'
}

qget() { printf '%s' "$L_Q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }

jget() {
    printf '%s' "$_j" | sed -n 's/.*[{,][[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' | head -n 1 | sed 's/\\//g'
}

# parse_link <url>  ->  L_SCHEME L_HOST L_PORT L_ID L_PASS L_METHOD L_NET L_SEC
#                       L_SNI L_FP L_PBK L_SID L_SPX L_FLOW L_PATH L_HHOST L_SVC L_ALPN L_INS L_ENC L_AID L_SCY
parse_link() {
    _u="$1"
    L_SCHEME="${_u%%://*}"
    L_HOST=""; L_PORT=""; L_ID=""; L_PASS=""; L_METHOD=""; L_Q=""
    L_NET="tcp"; L_SEC="none"; L_SNI=""; L_FP=""; L_PBK=""; L_SID=""; L_SPX=""
    L_FLOW=""; L_PATH=""; L_HHOST=""; L_SVC=""; L_ALPN=""; L_INS="0"; L_ENC="none"
    L_AID="0"; L_SCY="auto"
    _r="${_u#*://}"
    case "$L_SCHEME" in
        vmess)
            _r="${_r%%#*}"
            _j=$(b64d "$_r")
            [ -n "$_j" ] || return 1
            L_HOST=$(jget add); L_PORT=$(jget port); L_ID=$(jget id)
            _t=$(jget aid);  [ -n "$_t" ] && L_AID="$_t"
            _t=$(jget scy);  [ -n "$_t" ] && L_SCY="$_t"
            _t=$(jget net);  [ -n "$_t" ] && L_NET="$_t"
            L_PATH=$(jget path); L_HHOST=$(jget host); L_SNI=$(jget sni)
            L_FP=$(jget fp); L_ALPN=$(jget alpn)
            [ "$(jget tls)" = "tls" ] && L_SEC="tls"
            ;;
        vless|trojan|ss|shadowsocks)
            _r="${_r%%#*}"
            case "$_r" in *\?*) L_Q="${_r#*\?}"; _r="${_r%%\?*}" ;; esac
            _r="${_r%/}"
            if [ "$L_SCHEME" = "ss" ] || [ "$L_SCHEME" = "shadowsocks" ]; then
                case "$_r" in
                    *@*) _ui="${_r%@*}"; _hp="${_r##*@}"
                         case "$_ui" in *:*) ;; *) _ui=$(b64d "$_ui") ;; esac ;;
                    *)   _d=$(b64d "$_r"); _ui="${_d%@*}"; _hp="${_d##*@}" ;;
                esac
                L_SCHEME="ss"
                L_METHOD="${_ui%%:*}"
                L_PASS=$(urldec "${_ui#*:}")
            else
                case "$_r" in *@*) ;; *) return 1 ;; esac
                _ui="${_r%@*}"; _hp="${_r##*@}"
                L_ID=$(urldec "$_ui"); L_PASS="$L_ID"
                [ "$L_SCHEME" = "trojan" ] && L_SEC="tls"
            fi
            L_HOST="${_hp%:*}"; L_PORT="${_hp##*:}"
            _t=$(qget type);        [ -n "$_t" ] && L_NET="$_t"
            _t=$(qget security);    [ -n "$_t" ] && L_SEC="$_t"
            _t=$(qget encryption);  [ -n "$_t" ] && L_ENC="$_t"
            L_SNI=$(qget sni); L_FP=$(qget fp); L_PBK=$(qget pbk); L_SID=$(qget sid)
            L_SPX=$(urldec "$(qget spx)"); L_FLOW=$(qget flow)
            L_PATH=$(urldec "$(qget path)"); L_HHOST=$(qget host); L_SVC=$(qget serviceName)
            L_ALPN=$(urldec "$(qget alpn)")
            _t=$(qget allowInsecure); [ -n "$_t" ] && L_INS="$_t"
            ;;
        *) return 1 ;;
    esac
    [ -n "$L_HOST" ] || return 1
    valid_port "$L_PORT" || return 1
    case "$L_SCHEME" in
        ss) [ -n "$L_METHOD" ] && [ -n "$L_PASS" ] || return 1 ;;
        trojan) [ -n "$L_PASS" ] || return 1 ;;
        *) [ -n "$L_ID" ] || return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------ Xray config
xray_stream() {
    _net="$L_NET"
    case "$_net" in
        tcp|ws|grpc|httpupgrade|xhttp) ;;
        splithttp) _net="xhttp" ;;
        h2|http)   _net="http" ;;
        *)         _net="tcp" ;;
    esac
    _st="\"network\": \"$_net\""
    case "$_net" in
        ws)
            _x="\"path\": \"$(json_esc "${L_PATH:-/}")\""
            [ -n "$L_HHOST" ] && _x="$_x, \"headers\": { \"Host\": \"$(json_esc "$L_HHOST")\" }"
            _st="$_st, \"wsSettings\": { $_x }" ;;
        grpc)
            _st="$_st, \"grpcSettings\": { \"serviceName\": \"$(json_esc "$L_SVC")\" }" ;;
        httpupgrade|xhttp)
            _x="\"path\": \"$(json_esc "${L_PATH:-/}")\""
            [ -n "$L_HHOST" ] && _x="$_x, \"host\": \"$(json_esc "$L_HHOST")\""
            _st="$_st, \"${_net}Settings\": { $_x }" ;;
        http)
            _x="\"path\": \"$(json_esc "${L_PATH:-/}")\""
            [ -n "$L_HHOST" ] && _x="$_x, \"host\": [ \"$(json_esc "$L_HHOST")\" ]"
            _st="$_st, \"httpSettings\": { $_x }" ;;
    esac
    _sni="$L_SNI"
    [ -z "$_sni" ] && _sni="$L_HHOST"
    [ -z "$_sni" ] && ! is_ip "$L_HOST" && _sni="$L_HOST"
    _fp="${L_FP:-chrome}"
    case "$L_SEC" in
        tls)
            _ins="false"; [ "$L_INS" = "1" ] && _ins="true"
            _al=""
            [ -n "$L_ALPN" ] && _al=", \"alpn\": [ $(printf '%s' "$L_ALPN" | sed 's/[^,][^,]*/"&"/g') ]"
            _st="$_st, \"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$(json_esc "$_sni")\", \"fingerprint\": \"$_fp\"$_al, \"allowInsecure\": $_ins }" ;;
        reality)
            _st="$_st, \"security\": \"reality\", \"realitySettings\": { \"serverName\": \"$(json_esc "$_sni")\", \"fingerprint\": \"$_fp\", \"publicKey\": \"$(json_esc "$L_PBK")\", \"shortId\": \"$(json_esc "$L_SID")\", \"spiderX\": \"$(json_esc "$L_SPX")\" }" ;;
    esac
    printf '%s' "$_st"
}

# xray_main_outbound <sockopt-json-body>
xray_main_outbound() {
    _h="$(json_esc "$L_HOST")"
    case "$L_SCHEME" in
        vless)
            _fl=""; [ -n "$L_FLOW" ] && _fl=", \"flow\": \"$(json_esc "$L_FLOW")\""
            _o="\"protocol\": \"vless\", \"settings\": { \"vnext\": [ { \"address\": \"$_h\", \"port\": $L_PORT, \"users\": [ { \"id\": \"$(json_esc "$L_ID")\", \"encryption\": \"$(json_esc "$L_ENC")\"$_fl } ] } ] }" ;;
        vmess)
            _o="\"protocol\": \"vmess\", \"settings\": { \"vnext\": [ { \"address\": \"$_h\", \"port\": $L_PORT, \"users\": [ { \"id\": \"$(json_esc "$L_ID")\", \"alterId\": ${L_AID:-0}, \"security\": \"$(json_esc "$L_SCY")\" } ] } ] }" ;;
        trojan)
            _o="\"protocol\": \"trojan\", \"settings\": { \"servers\": [ { \"address\": \"$_h\", \"port\": $L_PORT, \"password\": \"$(json_esc "$L_PASS")\" } ] }" ;;
        ss)
            _o="\"protocol\": \"shadowsocks\", \"settings\": { \"servers\": [ { \"address\": \"$_h\", \"port\": $L_PORT, \"method\": \"$(json_esc "$L_METHOD")\", \"password\": \"$(json_esc "$L_PASS")\" } ] }" ;;
        *) return 1 ;;
    esac
    printf '{ "tag": "proxy", %s, "streamSettings": { %s, "sockopt": { %s } } }' "$_o" "$(xray_stream)" "$1"
}

# build_xray_config [warp]   ("warp" = chain Xray's own traffic through WARP)
build_xray_config() {
    parse_link "$PROXY_URL" || die "Could not parse the proxy link."
    _extra=""
    if [ "$1" = "warp" ]; then
        _sock='"dialerProxy": "warp"'
        _extra=", { \"tag\": \"warp\", \"protocol\": \"socks\", \"settings\": { \"servers\": [ { \"address\": \"127.0.0.1\", \"port\": $SOCKS_WARP } ] } }"
    elif [ "$XRAY_FRAGMENT" = "1" ] && [ "$L_SEC" != "none" ]; then
        _sock='"dialerProxy": "frag"'
        _extra=", { \"tag\": \"frag\", \"protocol\": \"freedom\", \"settings\": { \"fragment\": { \"packets\": \"tlshello\", \"length\": \"$XRAY_FRAG_LEN\", \"interval\": \"$XRAY_FRAG_INT\" } } }"
    else
        _sock='"domainStrategy": "UseIPv4"'
    fi
    _main=$(xray_main_outbound "$_sock") || die "Unsupported proxy link."
    ( umask 077
      cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": [ "https+local://1.1.1.1/dns-query" ], "queryStrategy": "UseIPv4" },
  "inbounds": [
    { "tag": "socks-in", "listen": "127.0.0.1", "port": $SOCKS_XRAY, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true, "ip": "127.0.0.1" } }
  ],
  "outbounds": [ $_main$_extra, { "tag": "direct", "protocol": "freedom" } ]
}
EOF
    )
    give_engine "$XRAY_CONFIG"
}

# ------------------------------------------------------------------ sing-box gateway config
socks_out() {
    printf '{ "type": "socks", "tag": "%s", "server": "127.0.0.1", "server_port": %s, "version": "5" }' "$1" "$2"
}

# std_proxy_outbound [detour-tag]  -> native sing-box outbound tagged "up"
std_proxy_outbound() {
    _tls=""; _extra=""
    case "$PROXY_TYPE" in
        socks5) _t="socks"; _extra='"version": "5", ' ;;
        socks4) _t="socks"
                if is_ip "$PROXY_IP"; then _sv="4"; else _sv="4a"; fi
                _extra="\"version\": \"$_sv\", " ;;
        http)   _t="http" ;;
        https)  _t="http"
                _sn="$PROXY_SNI"
                [ -z "$_sn" ] && ! is_ip "$PROXY_IP" && _sn="$PROXY_IP"
                _snj=""; [ -n "$_sn" ] && _snj="\"server_name\": \"$(json_esc "$_sn")\", "
                _in="false"; [ "$PROXY_INSECURE" = "1" ] && _in="true"
                _extra="\"tls\": { \"enabled\": true, ${_snj}\"insecure\": $_in }, " ;;
        *) die "Unknown proxy type '$PROXY_TYPE'." ;;
    esac
    _auth=""
    if [ -n "$PROXY_USER" ]; then
        _auth="\"username\": \"$(json_esc "$PROXY_USER")\", "
        if [ -n "$PROXY_PASS" ] && [ "$PROXY_TYPE" != "socks4" ]; then
            _auth="$_auth\"password\": \"$(json_esc "$PROXY_PASS")\", "
        fi
    fi
    _det=""
    [ -n "$1" ] && _det="\"detour\": \"$1\", "
    printf '{ "type": "%s", "tag": "up", %s%s%s"server": "%s", "server_port": %s }' \
        "$_t" "$_extra" "$_auth" "$_det" "$(json_esc "$PROXY_IP")" "$PROXY_PORT"
}

build_singbox_config() {
    case "$MODE" in
        warp) OUTB=$(socks_out up "$SOCKS_WARP") ;;
        dpi)  OUTB=$(socks_out up "$SOCKS_DPI") ;;
        proxy)
            if [ -n "$PROXY_URL" ]; then OUTB=$(socks_out up "$SOCKS_XRAY")
            else OUTB=$(std_proxy_outbound ""); fi ;;
        both)
            if [ -n "$PROXY_URL" ]; then OUTB=$(socks_out up "$SOCKS_XRAY")
            else OUTB="$(std_proxy_outbound warp-up), $(socks_out warp-up "$SOCKS_WARP")"; fi ;;
        *) die "Internal error: unknown mode '$MODE'." ;;
    esac
    ( umask 077
      cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "warn", "output": "$LOG_FILE" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh", "server": "1.1.1.1", "detour": "up" },
      { "type": "https", "tag": "boot", "server": "1.1.1.1" }
    ],
    "final": "doh",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": [ "172.19.0.1/30" ],
      "auto_route": true,
      "strict_route": true,
      "stack": "$TUN_STACK",
      "exclude_uid": [ $ENGINE_UID ]
    }
  ],
  "outbounds": [
    $OUTB,
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "boot",
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "action": "route", "outbound": "direct" }
    ],
    "final": "up"
  }
}
EOF
    )
}

# ------------------------------------------------------------------ downloads
latest_tag() {
    curl -fsIL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null | sed 's|.*/tag/||'
}

fetch() {
    curl -fL --retry 3 --connect-timeout 15 -o "$1" "$2"
}

detect_arch() {
    case "$(uname -m)" in
        aarch64|arm64)  SB_ARCH="arm64"; XR_FILE="Xray-android-arm64-v8a.zip"; WP_ARCH="arm64"; BYE_ARCH="aarch64|arm64" ;;
        armv7*|armv8l|arm) SB_ARCH="armv7"; XR_FILE="Xray-linux-arm32-v7a.zip"; WP_ARCH="arm"; BYE_ARCH="armv7|arm32|arm" ;;
        x86_64)         SB_ARCH="amd64"; XR_FILE="Xray-linux-64.zip"; WP_ARCH="amd64"; BYE_ARCH="x86_64|amd64" ;;
        i686|i386)      SB_ARCH="386"; XR_FILE="Xray-linux-32.zip"; WP_ARCH="386"; BYE_ARCH="i686|x86" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

find_unzip() {
    if command -v unzip >/dev/null 2>&1; then UNZIP="unzip"
    elif command -v busybox >/dev/null 2>&1; then UNZIP="busybox unzip"
    else UNZIP=""; fi
}

install_singbox() {
    _v="$SB_VER"
    [ -n "$_v" ] || _v=$(latest_tag SagerNet/sing-box | sed 's/^v//')
    [ -n "$_v" ] || _v="1.12.0"
    _url="https://github.com/SagerNet/sing-box/releases/download/v${_v}/sing-box-${_v}-android-${SB_ARCH}.tar.gz"
    info "Downloading sing-box v$_v ($SB_ARCH)..."
    rm -rf "$WORK_DIR/tmp"; mkdir -p "$WORK_DIR/tmp"
    if fetch "$WORK_DIR/tmp/sb.tar.gz" "$_url" && tar -xzf "$WORK_DIR/tmp/sb.tar.gz" -C "$WORK_DIR/tmp"; then
        _f=$(find "$WORK_DIR/tmp" -type f -name sing-box | head -n 1)
        if [ -n "$_f" ]; then
            cp "$_f" "$SINGBOX_BIN" && chmod 755 "$SINGBOX_BIN"
            ok "sing-box installed: $("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
        else warn "sing-box binary not found in archive."; fi
    else
        warn "sing-box download failed ($_url)."
    fi
    rm -rf "$WORK_DIR/tmp"
}

install_xray() {
    find_unzip
    [ -n "$UNZIP" ] || { warn "unzip not found - in Termux run: pkg install unzip  (Xray skipped)"; return 0; }
    if [ -n "$XRAY_VER" ]; then _url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/$XR_FILE"
    else _url="https://github.com/XTLS/Xray-core/releases/latest/download/$XR_FILE"; fi
    info "Downloading Xray-core ($XR_FILE)..."
    rm -rf "$WORK_DIR/tmp"; mkdir -p "$WORK_DIR/tmp"
    if fetch "$WORK_DIR/tmp/xray.zip" "$_url" && $UNZIP -o "$WORK_DIR/tmp/xray.zip" -d "$WORK_DIR/tmp" >/dev/null 2>&1; then
        _f=$(find "$WORK_DIR/tmp" -type f -name xray | head -n 1)
        if [ -n "$_f" ]; then
            cp "$_f" "$XRAY_BIN" && chmod 755 "$XRAY_BIN"
            ok "Xray-core installed: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"
        else warn "xray binary not found in archive."; fi
    else
        warn "Xray download failed ($_url)."
    fi
    rm -rf "$WORK_DIR/tmp"
}

install_wireproxy() {
    _url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${WP_ARCH}.tar.gz"
    info "Downloading wireproxy ($WP_ARCH)..."
    rm -rf "$WORK_DIR/tmp"; mkdir -p "$WORK_DIR/tmp"
    if fetch "$WORK_DIR/tmp/wp.tar.gz" "$_url" && tar -xzf "$WORK_DIR/tmp/wp.tar.gz" -C "$WORK_DIR/tmp"; then
        _f=$(find "$WORK_DIR/tmp" -type f -name wireproxy | head -n 1)
        if [ -n "$_f" ]; then
            cp "$_f" "$WIREPROXY_BIN" && chmod 755 "$WIREPROXY_BIN"
            ok "wireproxy installed."
        else warn "wireproxy binary not found in archive."; fi
    else
        warn "wireproxy download failed ($_url)."
    fi
    rm -rf "$WORK_DIR/tmp"
}

# ByeDPI: use BYEDPI_URL if given, else search the latest GitHub release assets.
install_byedpi() {
    if [ -x "$BYEDPI_BIN" ]; then ok "ByeDPI already installed."; return 0; fi
    info "Looking for a ByeDPI (ciadpi) binary..."
    rm -rf "$WORK_DIR/tmp"; mkdir -p "$WORK_DIR/tmp"
    _url="$BYEDPI_URL"
    if [ -z "$_url" ]; then
        _api=$(curl -fsL --connect-timeout 15 "https://api.github.com/repos/hufrea/byedpi/releases/latest" 2>/dev/null)
        _url=$(printf '%s' "$_api" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
               | grep -Ei "($BYE_ARCH)" | grep -Ei 'tar\.gz|ciadpi' | head -n 1)
    fi
    if [ -n "$_url" ] && fetch "$WORK_DIR/tmp/dpi.dl" "$_url"; then
        if tar -xzf "$WORK_DIR/tmp/dpi.dl" -C "$WORK_DIR/tmp" 2>/dev/null; then
            _f=$(find "$WORK_DIR/tmp" -type f \( -name ciadpi -o -name 'ciadpi*' \) | head -n 1)
        else
            _f="$WORK_DIR/tmp/dpi.dl"
        fi
        if [ -n "$_f" ]; then
            cp "$_f" "$BYEDPI_BIN" && chmod 755 "$BYEDPI_BIN"
            ok "ByeDPI installed."
            rm -rf "$WORK_DIR/tmp"; return 0
        fi
    fi
    rm -rf "$WORK_DIR/tmp"
    warn "Could not download ByeDPI automatically."
    warn "Option A: set BYEDPI_URL='<direct link to a ciadpi binary or .tar.gz>' in $USER_CONF and run install again."
    warn "Option B: build it in Termux:  pkg install git clang make && git clone https://github.com/hufrea/byedpi && cd byedpi && make"
    warn "          then:  su -c 'cp ~/byedpi/ciadpi $BYEDPI_BIN && chmod 755 $BYEDPI_BIN'"
    return 0
}

register_warp() {
    need_curl
    [ -x "$SINGBOX_BIN" ] || die "sing-box is needed to generate WARP keys. Run 'install' first."
    _keys=$("$SINGBOX_BIN" generate wg-keypair 2>/dev/null)
    PRIV_KEY=$(printf '%s\n' "$_keys" | sed -n 's/^PrivateKey:[[:space:]]*//p')
    _pub=$(printf '%s\n' "$_keys" | sed -n 's/^PublicKey:[[:space:]]*//p')
    [ -n "$PRIV_KEY" ] && [ -n "$_pub" ] || die "Key generation failed."
    info "Registering a free Cloudflare WARP account..."
    _tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    _body="{\"key\":\"$_pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$_tos\",\"type\":\"Android\",\"model\":\"PC\",\"locale\":\"en_US\"}"
    CLIENT_IPV4=""
    for _api in v0a2158 v0a1922; do
        _res=$(curl -s --connect-timeout 10 --max-time 30 -X POST "https://api.cloudflareclient.com/$_api/reg" \
            -H "Content-Type: application/json" \
            -H "User-Agent: okhttp/3.12.1" \
            -H "CF-Client-Version: a-6.3-1922" \
            -d "$_body")
        CLIENT_IPV4=$(printf '%s' "$_res" | grep -o '"v4":"[^"]*"' | head -n 1 | cut -d'"' -f4)
        [ -n "$CLIENT_IPV4" ] && break
    done
    [ -n "$CLIENT_IPV4" ] || die "WARP registration failed (API unreachable or rate-limited). Try again later or from another network."
    PEER_PUB=$(printf '%s' "$_res" | grep -o '"public_key":"[^"]*"' | head -n 1 | cut -d'"' -f4)
    [ -n "$PEER_PUB" ] || PEER_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    mkdir -p "$(dirname "$CRED_FILE")"
    ( umask 077
      cat > "$CRED_FILE" <<EOF
PRIV_KEY="$PRIV_KEY"
CLIENT_IPV4="$CLIENT_IPV4"
PEER_PUB="$PEER_PUB"
EOF
    )
    chmod 600 "$CRED_FILE"
    ok "WARP account saved (internal IP: $CLIENT_IPV4)"
}

load_creds() {
    if [ ! -f "$CRED_FILE" ]; then
        info "No WARP account found - registering automatically..."
        register_warp
    fi
    . "$CRED_FILE"
    PRIV_KEY=$(printf '%s' "$PRIV_KEY" | tr -cd 'A-Za-z0-9+/=')
    PEER_PUB=$(printf '%s' "$PEER_PUB" | tr -cd 'A-Za-z0-9+/=')
    CLIENT_IPV4=$(printf '%s' "$CLIENT_IPV4" | tr -cd '0-9.')
}

install_core() {
    info "Installing Root Network Unblocker & Suite v$VERSION..."
    need_curl
    mkdir -p "$WORK_DIR" && chmod 755 "$WORK_DIR"
    detect_arch
    install_singbox
    install_wireproxy
    install_xray
    install_byedpi
    [ -f "$CRED_FILE" ] && ok "WARP credentials present." || register_warp
    ok "Setup finished. Try:  warp on | dpi on | proxy set | all on | status | doctor"
}

renew_warp() {
    _prev=$(current_mode)
    is_running && stop_bypass
    rm -f "$CRED_FILE" "$WARP_OK_FILE"
    register_warp
    [ -n "$_prev" ] && apply_mode "$_prev"
}

# ------------------------------------------------------------------ engines
write_wireproxy_conf() {
    load_creds
    ( umask 077
      cat > "$WP_CONF" <<EOF
[Interface]
PrivateKey = $PRIV_KEY
Address = $CLIENT_IPV4/32
MTU = $WARP_MTU
DNS = 1.1.1.1

[Peer]
PublicKey = $PEER_PUB
Endpoint = $1
AllowedIPs = 0.0.0.0/0

[Socks5]
BindAddress = 127.0.0.1:$SOCKS_WARP
EOF
    )
    give_engine "$WP_CONF"
}

probe_warp() {
    _pi=0
    while [ "$_pi" -lt "$1" ]; do
        _tr=$(curl -s --connect-timeout 3 --max-time 6 --socks5-hostname "127.0.0.1:$SOCKS_WARP" https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
        case "$_tr" in *warp=on*|*warp=plus*) return 0 ;; esac
        _pi=$((_pi + 1)); sleep 1
    done
    return 1
}

start_warp_engine() {
    pid_alive "$WP_PID" && probe_warp 1 && return 0
    kill_pidfile "$WP_PID"
    if [ -n "$WARP_ENDPOINT" ]; then
        _list="${WARP_ENDPOINT}:${WARP_PORT:-2408}"
    else
        _list=""
        [ -s "$WARP_OK_FILE" ] && _list=$(cat "$WARP_OK_FILE")
        _list="$_list $WARP_CANDIDATES"
    fi
    for _c in $_list; do
        info "Trying WARP endpoint $_c ..."
        kill_pidfile "$WP_PID"
        write_wireproxy_conf "$_c"
        if spawn_engine "$WP_LOG" "$WP_PID" "$WIREPROXY_BIN" -c "$WP_CONF" && probe_warp 4; then
            ok "WARP endpoint works: $_c"
            printf '%s' "$_c" > "$WARP_OK_FILE"
            return 0
        fi
    done
    kill_pidfile "$WP_PID"
    warn "No reachable WARP endpoint. Log: $WP_LOG"
    return 1
}

start_dpi_engine() {
    kill_pidfile "$DPI_PID"
    info "Starting ByeDPI (args: $DPI_ARGS)..."
    spawn_engine "$DPI_LOG" "$DPI_PID" "$BYEDPI_BIN" -i 127.0.0.1 -p "$SOCKS_DPI" $DPI_ARGS \
        || { warn "ByeDPI failed to start. See $DPI_LOG (try a different DPI_ARGS)."; return 1; }
    pid_alive "$DPI_PID" || { warn "ByeDPI exited. See $DPI_LOG"; return 1; }
    ok "ByeDPI listening on 127.0.0.1:$SOCKS_DPI"
    return 0
}

start_xray_engine() {
    kill_pidfile "$XRAY_PID"
    build_xray_config "$1"
    info "Starting Xray-core ($L_SCHEME -> $L_HOST:$L_PORT)..."
    spawn_engine "$XRAY_LOG" "$XRAY_PID" "$XRAY_BIN" run -c "$XRAY_CONFIG" \
        || { warn "Xray failed to start. See $XRAY_LOG"; return 1; }
    pid_alive "$XRAY_PID" || { warn "Xray exited. See $XRAY_LOG"; return 1; }
    return 0
}

stop_engines() {
    kill_pidfile "$XRAY_PID"
    kill_pidfile "$WP_PID"
    kill_pidfile "$DPI_PID"
}

# probe the exit through the engine itself (before touching any routes)
probe_engine() {
    case "$MODE" in
        warp) set -- --socks5-hostname "127.0.0.1:$SOCKS_WARP" ;;
        dpi)  set -- --socks5-hostname "127.0.0.1:$SOCKS_DPI" ;;
        *)
            if [ -n "$PROXY_URL" ]; then
                set -- --socks5-hostname "127.0.0.1:$SOCKS_XRAY"
            elif [ "$MODE" = "both" ]; then
                return 0
            else
                case "$PROXY_TYPE" in
                    socks5) set -- -x "socks5h://$PROXY_IP:$PROXY_PORT" ;;
                    socks4) set -- -x "socks4a://$PROXY_IP:$PROXY_PORT" ;;
                    http)   set -- -x "http://$PROXY_IP:$PROXY_PORT" ;;
                    https)  set -- -x "https://$PROXY_IP:$PROXY_PORT"
                            [ "$PROXY_INSECURE" = "1" ] && set -- "$@" --proxy-insecure ;;
                esac
                [ -n "$PROXY_USER" ] && set -- "$@" --proxy-user "$PROXY_USER:$PROXY_PASS"
            fi ;;
    esac
    PROBE_ERR=""
    _pi=0
    while [ "$_pi" -lt 2 ]; do
        for _u in https://www.cloudflare.com/cdn-cgi/trace https://1.1.1.1/cdn-cgi/trace https://api.ipify.org; do
            _out=$(curl -sS --connect-timeout 8 --max-time 12 "$@" "$_u" 2>&1)
            _rc=$?
            if [ "$_rc" -eq 0 ] && [ -n "$_out" ]; then return 0; fi
            PROBE_ERR="curl exit $_rc: $(printf '%s' "$_out" | tail -n 1)"
        done
        _pi=$((_pi + 1)); sleep 1
    done
    return 1
}

start_engines() {
    case "$MODE" in
        warp) start_warp_engine || return 1 ;;
        dpi)  start_dpi_engine || return 1 ;;
        proxy)
            [ -n "$PROXY_URL" ] && { start_xray_engine "" || return 1; } ;;
        both)
            start_warp_engine || return 1
            [ -n "$PROXY_URL" ] && { start_xray_engine warp || return 1; } ;;
    esac
    probe_engine || { warn "Engine started but cannot reach the internet (check proxy / endpoint / DPI_ARGS)."; [ -n "$PROBE_ERR" ] && warn "Reason -> $PROBE_ERR"; return 1; }
    return 0
}

# ------------------------------------------------------------------ system state
asettings() {
    _r=$(settings "$@" 2>&1 </dev/null)
    case "$_r" in *Exception*|*Failure*|*"not found"*|*Error*)
        _r=$(su 2000 -c "settings $*" 2>&1 </dev/null) ;;
    esac
    case "$_r" in *Exception*|*Failure*|*"not found"*|*Error*) return 1 ;; esac
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

apply_private_dns() {
    [ "$PRIVATE_DNS" = "keep" ] && return 0
    if [ -f "$STATE_FILE" ] && grep -q "^PD_OK='1'" "$STATE_FILE"; then
        asettings put global private_dns_mode off || warn "Could not disable Private DNS."
    fi
}

unblock_v6_rules() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    _t=0
    while [ "$_t" -lt 5 ] && ip6tables -D OUTPUT -j "$V6_CHAIN" 2>/dev/null; do _t=$((_t + 1)); done
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
    ip6tables -I OUTPUT 1 -j "$V6_CHAIN" 2>/dev/null || warn "Could not install the IPv6 leak rule."
}

restore_system() {
    unblock_v6_rules
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
    ip addr show tun0 2>/dev/null | grep -q '172.19.0.1' && _ours=1
    ip rule show 2>/dev/null | grep -q 'lookup 2022' && _ours=1
    [ "$_ours" -eq 1 ] || return 0
    ip link del tun0 2>/dev/null
    for _fam in -4 -6; do
        _p=9000
        while [ "$_p" -le 9010 ]; do
            _t=0
            while [ "$_t" -lt 8 ] && ip "$_fam" rule del priority "$_p" 2>/dev/null; do _t=$((_t + 1)); done
            _p=$((_p + 1))
        done
    done
    ip route flush table 2022 2>/dev/null
    ip -6 route flush table 2022 2>/dev/null
    return 0
}

# ------------------------------------------------------------------ gateway
launch_gateway() {
    build_singbox_config
    give_engine "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    _chk=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1) || { say "$_chk"; warn "sing-box rejected the config (version: $("$SINGBOX_BIN" version 2>/dev/null | head -n 1))."; return 1; }
    : > "$LOG_FILE"
    nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 &
    printf '%s' "$!" > "$PID_FILE"
    _gi=0
    while [ "$_gi" -lt 10 ]; do
        is_running || break
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 1; _gi=$((_gi + 1))
    done
    is_running && ip link show tun0 >/dev/null 2>&1
}

verify_tunnel() {
    T_IP=""; T_LOC=""; T_WARP=""
    if [ "$ENGINE_UID" = "0" ]; then
        T_IP="n/a"; T_LOC="n/a"; T_WARP="n/a"
        warn "ENGINE_UID=0: skipping the through-tunnel check."
        return 0
    fi
    _vi=0
    while [ "$_vi" -lt 3 ]; do
        TRACE=$(curl -4 -s --connect-timeout 5 --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
        case "$TRACE" in
            *ip=*)
                T_IP=$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p')
                T_LOC=$(printf '%s\n' "$TRACE" | sed -n 's/^loc=//p')
                T_WARP=$(printf '%s\n' "$TRACE" | sed -n 's/^warp=//p')
                return 0 ;;
        esac
        _vi=$((_vi + 1)); sleep 1
    done
    return 1
}

dns_ready() {
    DNS_RC=0
    _n=0
    while [ "$_n" -lt "$DNS_TRIES" ]; do
        curl -4 -s -o /dev/null --connect-timeout 4 --max-time 6 https://www.cloudflare.com 2>/dev/null
        DNS_RC=$?
        [ "$DNS_RC" -eq 0 ] && return 0
        _n=$((_n + 1))
        [ "$_n" -lt "$DNS_TRIES" ] && sleep 1
    done
    return 1
}

check_engines() {
    [ -x "$SINGBOX_BIN" ] || die "sing-box not installed. Run: su -c 'sh $SELF install'"
    case "$MODE" in
        warp) [ -x "$WIREPROXY_BIN" ] || die "wireproxy not installed. Run 'install' first." ;;
        dpi)  [ -x "$BYEDPI_BIN" ] || die "ByeDPI (ciadpi) not installed - see the install notes." ;;
        both) [ -x "$WIREPROXY_BIN" ] || die "wireproxy not installed. Run 'install' first." ;;
    esac
    case "$MODE" in
        proxy|both)
            ensure_proxy
            if [ -n "$PROXY_URL" ]; then
                [ -x "$XRAY_BIN" ] || die "Xray-core not installed (needed for links). Run 'install' first."
            fi ;;
    esac
    if [ "$ENGINE_UID" != "0" ] && ! su "$ENGINE_UID" -c "id" >/dev/null 2>&1; then
        die "'su $ENGINE_UID -c' is not supported by your root manager. Set ENGINE_UID=0 in $USER_CONF."
    fi
}

start_bypass() {
    check_engines
    if is_running; then warn "Tunnel already active (mode: $(current_mode))."; return 0; fi
    kill_stale
    # 1) engines first: nothing touches the network settings until they work
    if ! start_engines; then
        stop_engines
        die "Engine check failed. Network settings were not changed."
    fi
    # 2) system changes + gateway
    save_state
    block_ipv6
    info "Starting TUN gateway (mode: $MODE)..."
    if ! launch_gateway; then
        kill_pidfile "$PID_FILE"; stop_engines; kill_stale
        cleanup_leftovers; restore_system
        die "Gateway failed to start. Network restored. Log: $LOG_FILE"
    fi
    apply_private_dns
    printf '%s' "$MODE" > "$MODE_FILE"
    if [ "$MODE" = "proxy" ] || [ "$MODE" = "both" ]; then proxy_summary > "$ACTIVE_PROXY_FILE"; else rm -f "$ACTIVE_PROXY_FILE"; fi
    if ! verify_tunnel; then
        stop_bypass
        die "Tunnel is up but no traffic passes. Network restored."
    fi
    ok "Active: $MODE | Public IP: $T_IP | Country: $T_LOC | WARP: $T_WARP"
    dns_ready && ok "DNS resolution: OK" || warn "DNS check failed (curl exit $DNS_RC)"
    return 0
}

stop_bypass() {
    info "Stopping tunnel and engines..."
    kill_pidfile "$PID_FILE"
    stop_engines
    kill_stale
    cleanup_leftovers
    restore_system
    rm -f "$ACTIVE_PROXY_FILE" "$MODE_FILE"
    say "${RED}[-] Everything stopped. Network settings restored.${NC}"
}

apply_mode() {
    _target="$1"
    if is_running; then
        if [ "$(current_mode)" = "$_target" ]; then warn "Already running in '$_target' mode."; return 0; fi
        info "Switching mode: $(current_mode) -> $_target"
        stop_bypass
    fi
    MODE="$_target"
    start_bypass
}

# ------------------------------------------------------------------ status / diagnostics
engine_line() {
    if pid_alive "$2"; then ok "$1: running (PID $(cat "$2"))"; else say "${RED}[-]${NC} $1: stopped"; fi
}

check_status() {
    if is_running; then
        ok "Gateway (sing-box): RUNNING, mode: $(current_mode), PID $(cat "$PID_FILE")"
        [ -f "$ACTIVE_PROXY_FILE" ] && info "Proxy: $(cat "$ACTIVE_PROXY_FILE")"
    else
        say "${RED}[-]${NC} Gateway (sing-box): stopped"
    fi
    engine_line "WARP (wireproxy)" "$WP_PID"
    engine_line "ByeDPI (ciadpi)" "$DPI_PID"
    engine_line "Xray-core" "$XRAY_PID"
    if is_running && verify_tunnel; then
        info "Public IP: $T_IP | Country: $T_LOC | WARP: $T_WARP"
    fi
}

selfcheck() {
    _bad=0
    for _f in "$SELF" "$(dirname "$SELF")/start.sh" "$(dirname "$SELF")/stop.sh"; do
        [ -f "$_f" ] || continue
        if grep -q 'vert[{]}' "$_f" 2>/dev/null; then warn "$_f has leftover markdown/LaTeX markers (corrupted copy)."; _bad=1; fi
        if grep -q "$(printf '\342\200\213')" "$_f" 2>/dev/null; then warn "$_f contains hidden zero-width characters."; _bad=1; fi
        sh -n "$_f" 2>/dev/null || { warn "$_f has a syntax error."; _bad=1; }
    done
    [ "$_bad" -eq 0 ] && ok "Script files look healthy."
    return "$_bad"
}

doctor() {
    say "${CYAN}=== Root Network Unblocker v$VERSION doctor ===${NC}"
    say "Device arch : $(uname -m) | Android: $(getprop ro.build.version.release 2>/dev/null)"
    say "Root uid    : $(id -u) | ENGINE_UID: $ENGINE_UID"
    selfcheck
    for _b in "$SINGBOX_BIN" "$WIREPROXY_BIN" "$XRAY_BIN" "$BYEDPI_BIN"; do
        if [ -x "$_b" ]; then ok "found ${_b##*/}"; else warn "missing ${_b##*/}"; fi
    done
    [ -x "$SINGBOX_BIN" ] && say "sing-box    : $("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
    [ -f "$CRED_FILE" ] && ok "WARP account present" || warn "No WARP account (run install)"
    proxy_configured && info "Saved proxy : $(proxy_summary)" || info "Saved proxy : none"
    check_status
    ip link show tun0 >/dev/null 2>&1 && ok "tun0 is up" || info "tun0 is down"
    for _l in "$LOG_FILE" "$WP_LOG" "$DPI_LOG" "$XRAY_LOG"; do
        [ -s "$_l" ] && { say "--- tail ${_l##*/} ---"; tail -n 8 "$_l"; }
    done
}

show_logs() {
    for _l in "$LOG_FILE" "$WP_LOG" "$DPI_LOG" "$XRAY_LOG"; do
        [ -s "$_l" ] && { say "${CYAN}--- ${_l##*/} ---${NC}"; tail -n 30 "$_l"; }
    done
}

usage() {
    cat <<EOF
Root Network Unblocker & DPI Bypass Suite v$VERSION
Usage: su -c 'sh $SELF <command>'

  install             download engines + register a free WARP account
  warp on|off         Cloudflare WARP
  dpi on|off          local DPI bypass (ByeDPI)
  proxy set           configure proxy (SOCKS4/5, HTTP/S, vless/vmess/trojan/ss link)
  proxy on|off|show|clear
  all on|off          WARP + proxy chained (device -> WARP -> proxy -> internet)
  start [mode]        start (warp | dpi | proxy | all; default: auto)
  stop                emergency stop, restore network settings
  status | doctor | logs | renew
EOF
}

# ------------------------------------------------------------------ main
[ "$(id -u)" -eq 0 ] || { echo "[x] Root required. Run: su -c 'sh $SELF $*'"; exit 1; }
mkdir -p "$WORK_DIR" 2>/dev/null && chmod 755 "$WORK_DIR"
load_user_conf

_cmd="$1"; [ $# -gt 0 ] && shift
_arg="$1"

layer() {
    case "$2" in
        on)  apply_mode "$1" ;;
        off) if is_running || pid_alive "$WP_PID" || pid_alive "$DPI_PID" || pid_alive "$XRAY_PID"; then stop_bypass; else info "Nothing is running."; fi ;;
        status|"") check_status ;;
        *) usage; exit 1 ;;
    esac
}

case "$_cmd" in
    install)  install_core ;;
    warp)     layer warp "$_arg" ;;
    dpi)      layer dpi "$_arg" ;;
    all)      layer both "$_arg" ;;
    proxy)
        case "$_arg" in
            set)
                proxy_wizard || exit 1
                if confirm "Save this proxy configuration?" Y; then save_proxy_conf; ok "Proxy saved."; fi
                is_running && warn "Run 'proxy on' (or 'all on') to apply it." ;;
            show)  proxy_configured && info "Saved proxy: $(proxy_summary)" || info "No proxy saved." ;;
            clear) remove_proxy_conf; ok "Saved proxy removed." ;;
            on|off) layer proxy "$_arg" ;;
            *) usage; exit 1 ;;
        esac ;;
    start)
        case "$_arg" in
            warp|dpi|proxy) apply_mode "$_arg" ;;
            all|both)       apply_mode both ;;
            "")             if proxy_configured; then apply_mode both; else apply_mode warp; fi ;;
            *) usage; exit 1 ;;
        esac ;;
    stop)     stop_bypass ;;
    status)   check_status ;;
    doctor)   doctor ;;
    selfcheck) selfcheck ;;
    logs)     show_logs ;;
    renew)    renew_warp ;;
    version|--version|-v) echo "$VERSION" ;;
    *) usage; exit 1 ;;
esac
