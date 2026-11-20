#!/system/bin/sh
export PATH="/data/data/com.termux/files/usr/bin:$PATH"
# Project: Root Network Unblocker & WARP/HTTP Proxy Tunnel (v2.0)
# Path: /data/local/tmp/unblock.sh

WORK_DIR="/data/local/tmp/unblocker"
SINGBOX_BIN="$WORK_DIR/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
PID_FILE="$WORK_DIR/singbox.pid"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Error: Root access required. Run with 'su -c'.${NC}"
    exit 1
fi

install_core() {
    echo -e "${CYAN}[*] Starting v2.0 Installation (Standalone WARP Engine)...${NC}"
    mkdir -p "$WORK_DIR"

    # Detect CPU Architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) SB_ARCH="arm64" ;;
        armv7*|arm)    SB_ARCH="armv7" ;;
        x86_64)        SB_ARCH="amd64" ;;
        *) echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    echo -e "${YELLOW}[*] Downloading sing-box core ($SB_ARCH)...${NC}"
    SB_VER="1.10.1"
    PROTO="https://"
    GH_HOST="github.com"
    URL="${PROTO}${GH_HOST}/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-android-${SB_ARCH}.tar.gz"
    
    curl -sL "$URL" -o "$WORK_DIR/sb.tar.gz"
    if [ ! -s "$WORK_DIR/sb.tar.gz" ]; then
        echo -e "${RED}[!] Download failed. Check your internet connection or curl installation.${NC}"
        exit 1
    fi

    tar -xzf "$WORK_DIR/sb.tar.gz" -C "$WORK_DIR"
    mv "$WORK_DIR"/sing-box-*/sing-box "$SINGBOX_BIN"
    chmod 755 "$SINGBOX_BIN"
    rm -rf "$WORK_DIR"/sing-box-* "$WORK_DIR/sb.tar.gz"

    echo -e "${YELLOW}[*] Generating free Cloudflare WARP credentials...${NC}"
    # Generate WireGuard Keypair using sing-box
    KEYS=$($SINGBOX_BIN generate wg-keypair)
    PRIV_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUB_KEY=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')

    # Register WARP Account via Cloudflare API
    CF_HOST="api.cloudflareclient.com"
    API_URL="${PROTO}${CF_HOST}/v0a2158/reg"
    REG_RES=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${PUB_KEY}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"Android\",\"serial_number\":\"\",\"locale\":\"en_US\"}")

    # Extract clean 172.x.x.x client IPv4 address only
    CLIENT_IPV4=$(echo "$REG_RES" | grep -o '"v4":"172\.[^"]*' | cut -d'"' -f4)
    PEER_PUB=$(echo "$REG_RES" | grep -o '"public_key":"[^"]*' | head -n1 | cut -d'"' -f4)

    if [ -z "$CLIENT_IPV4" ]; then
        echo -e "${RED}[!] Failed to register WARP account. Try again.${NC}"
        exit 1
    fi

    # Save credentials
    cat <<EOF > "$WORK_DIR/warp_creds.env"
PRIV_KEY="$PRIV_KEY"
CLIENT_IPV4="$CLIENT_IPV4"
PEER_PUB="$PEER_PUB"
EOF

    echo -e "${GREEN}[✔] Installation complete! WARP IP assigned: $CLIENT_IPV4${NC}"
    echo -e "${CYAN}[i] Run 'su -c \"sh /data/local/tmp/unblock.sh start\"' to activate.${NC}"
}

build_config() {
    . "$WORK_DIR/warp_creds.env"

    if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ]; then
        # Chain HTTP Proxy through WARP
        AUTH_JSON=""
        if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
            AUTH_JSON="\"username\": \"$PROXY_USER\", \"password\": \"$PROXY_PASS\","
        fi

        OUTBOUNDS=$(cat <<EOF
    {
      "type": "http",
      "tag": "proxy-out",
      "server": "$PROXY_IP",
      "server_port": $PROXY_PORT,
      $AUTH_JSON
      "detour": "warp-out"
    },
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "162.159.192.1",
      "server_port": 2408,
      "local_address": ["$CLIENT_IPV4/32"],
      "private_key": "$PRIV_KEY",
      "peer_public_key": "$PEER_PUB",
      "mtu": 1280
    }
EOF
)
        FINAL_TAG="proxy-out"
    else
        # Direct WARP Tunnel
        OUTBOUNDS=$(cat <<EOF
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "162.159.192.1",
      "server_port": 2408,
      "local_address": ["$CLIENT_IPV4/32"],
      "private_key": "$PRIV_KEY",
      "peer_public_key": "$PEER_PUB",
      "mtu": 1280
    }
EOF
)
        FINAL_TAG="warp-out"
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  "log": { "level": "error" },
  "dns": {
    "servers": [
      { "tag": "cf-dns", "address": "1.1.1.1", "detour": "warp-out" }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
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
      { "protocol": "dns", "outbound": "cf-dns" }
    ]
  }
}
EOF
}

start_bypass() {
    if [ ! -f "$SINGBOX_BIN" ] || [ ! -f "$WORK_DIR/warp_creds.env" ]; then
        echo -e "${RED}[!] Core not installed. Run 'install' first!${NC}"
        exit 1
    fi

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}[!] Unblocker is already running.${NC}"
        exit 0
    fi

    echo -e "${YELLOW}[*] Starting global network unblocker...${NC}"
    
    # 1. Drop IPv6 to prevent leaks
    ip6tables -P OUTPUT DROP 2>/dev/null
    ip6tables -P INPUT DROP 2>/dev/null

    # 2. Set Private DNS safely via shell user
    su 2000 -c "settings put global private_dns_mode hostname" 2>/dev/null
    su 2000 -c "settings put global private_dns_specifier one.one.one.one" 2>/dev/null

    # 3. Build config & launch tunnel
    build_config
    nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2

    if [ -n "$PROXY_IP" ]; then
        echo -e "${GREEN}[✔] Active! All traffic routed via WARP -> HTTP Proxy ($PROXY_IP:$PROXY_PORT).${NC}"
    else
        echo -e "${GREEN}[✔] Active! All traffic routed via Cloudflare WARP (IP Changed & Unblocked).${NC}"
    fi
}

stop_bypass() {
    echo -e "${YELLOW}[*] Stopping network unblocker...${NC}"

    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    killall sing-box 2>/dev/null

    # Restore IPv6 & DNS
    ip6tables -P OUTPUT ACCEPT 2>/dev/null
    ip6tables -P INPUT ACCEPT 2>/dev/null
    su 2000 -c "settings put global private_dns_mode opportunistic" 2>/dev/null

    echo -e "${RED}[✖] Stopped. Network restored to default.${NC}"
}

check_status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${GREEN}[✔] Status: RUNNING (PID: $(cat "$PID_FILE"))${NC}"
        IP_INFO=$(curl -s --connect-timeout 5 https://ipify.org)
        if [ -n "$IP_INFO" ]; then
            echo -e "${CYAN}[i] Current Public IP: $IP_INFO${NC}"
        fi
    else
        echo -e "${RED}[✖] Status: STOPPED${NC}"
    fi
}

case "$1" in
    install) install_core ;;
    start)   start_bypass ;;
    stop)    stop_bypass ;;
    status)  check_status ;;
    *)
        echo -e "${CYAN}Root Network Unblocker v2.0${NC}"
        echo -e "Usage:"
        echo -e "  1. Install core (Once): ${YELLOW}su -c 'sh /data/local/tmp/unblock.sh install'${NC}"
        echo -e "  2. Start Unblocker:     ${GREEN}su -c 'sh /data/local/tmp/unblock.sh start'${NC}"
        echo -e "  3. Start + HTTP Proxy:  ${CYAN}su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 sh /data/local/tmp/unblock.sh start'${NC}"
        echo -e "  4. Check Status:        ${YELLOW}su -c 'sh /data/local/tmp/unblock.sh status'${NC}"
        echo -e "  5. Stop Unblocker:      ${RED}su -c 'sh /data/local/tmp/unblock.sh stop'${NC}"
        ;;
esac
