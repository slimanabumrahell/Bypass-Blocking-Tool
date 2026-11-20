#!/system/bin/sh
# Stop wrapper for Root Network Unblocker & DPI Bypass Suite
# Usage: sh stop.sh [warp|dpi|proxy|all]      (no argument = stop everything)

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
    command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
    exec su -c "sh '$HERE/stop.sh' $*"
fi

[ -f "$SELF" ] || { echo "[x] $SELF not found - nothing to stop."; exit 1; }

case "$1" in
    warp|dpi|proxy|all) exec sh "$SELF" "$1" off ;;
    *) exec sh "$SELF" stop ;;
esac
