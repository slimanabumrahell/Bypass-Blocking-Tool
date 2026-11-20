#!/system/bin/sh
# Stop wrapper for Root Network Unblocker & Suite

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
  command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
  exec su -c "sh '$HERE/stop.sh' $*"
fi

[ -f "$SELF" ] || { echo "[x] $SELF not found - nothing to stop."; exit 1; }

case "${1:-}" in
  warp)  exec sh "$SELF" warp off ;;
  proxy) exec sh "$SELF" proxy off ;;
  dpi)   exec sh "$SELF" dpi off ;;
  *)     exec sh "$SELF" stop ;;
esac
