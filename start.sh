#!/system/bin/sh
# Start the unblocker.
#
#   sh start.sh warp     -> WARP only      (device -> WARP)
#   sh start.sh proxy    -> proxy only     (device -> proxy)
#   sh start.sh all      -> WARP + proxy   (device -> WARP -> proxy)
#   sh start.sh          -> classic: asks whether to use a proxy
#   sh start.sh --no-ask -> no questions, uses saved settings
#
# Keep this file next to unblock.sh. Works from Termux (uses su) or as root.

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
  command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
  exec su -c "sh '$HERE/start.sh' $*"
fi

# keep the installed copy in sync with the one next to this file
if [ -f "$HERE/unblock.sh" ] && ! cmp -s "$HERE/unblock.sh" "$SELF" 2>/dev/null; then
  cp "$HERE/unblock.sh" "$SELF" && chmod 755 "$SELF"
fi
[ -f "$SELF" ] || { echo "[x] $SELF not found. Put unblock.sh next to start.sh."; exit 1; }

case "$1" in
  warp|proxy|all) _m="$1"; shift; exec sh "$SELF" "$_m" on "$@" ;;
  *)              exec sh "$SELF" start "$@" ;;
esac
