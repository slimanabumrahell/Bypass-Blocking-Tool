#!/system/bin/sh
# Start wrapper for Root Network Unblocker & DPI Bypass Suite
# Usage: sh start.sh [warp|dpi|proxy|all]      (no argument = auto)
#        sh start.sh status | logs | doctor | renew

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
    command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
    exec su -c "sh '$HERE/start.sh' $*"
fi

# refresh the installed copy when a newer unblock.sh sits next to this wrapper
if [ -f "$HERE/unblock.sh" ] && ! cmp -s "$HERE/unblock.sh" "$SELF" 2>/dev/null; then
    cp "$HERE/unblock.sh" "$SELF" && chmod 755 "$SELF"
fi
[ -f "$SELF" ] || { echo "[x] $SELF not found. Run the install command from the README first."; exit 1; }

case "$1" in
    warp|dpi|proxy|all) _m="$1"; shift; exec sh "$SELF" "$_m" on "$@" ;;
    status|logs|doctor|renew|selfcheck) exec sh "$SELF" "$@" ;;
    *) exec sh "$SELF" start "$@" ;;
esac
