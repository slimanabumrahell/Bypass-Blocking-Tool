#!/system/bin/sh
# Stop the unblocker and restore your normal network settings.
#
#   sh stop.sh          -> stop everything (WARP + proxy); also repairs a crashed tunnel
#   sh stop.sh all      -> same
#   sh stop.sh warp     -> stop only WARP  (proxy keeps running if it was chained)
#   sh stop.sh proxy    -> stop only the proxy (WARP keeps running if it was chained)

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
  command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
  exec su -c "sh '$HERE/stop.sh' $*"
fi

[ -f "$SELF" ] || { echo "[x] $SELF not found - nothing to stop."; exit 1; }

case "$1" in
  warp)  exec sh "$SELF" warp off ;;
  proxy) exec sh "$SELF" proxy off ;;
  *)     exec sh "$SELF" all off ;;
esac
