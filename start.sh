#!/system/bin/sh
# Start / layer wrapper for Root Network Unblocker

SELF="/data/local/tmp/unblock.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

if [ "$(id -u)" -ne 0 ]; then
  command -v su >/dev/null 2>&1 || { echo "[x] 'su' not found - root is required."; exit 1; }
  exec su -c "sh '$HERE/start.sh' $*"
fi

if [ -f "$HERE/unblock.sh" ] && ! cmp -s "$HERE/unblock.sh" "$SELF" 2>/dev/null; then
  cp "$HERE/unblock.sh" "$SELF" && chmod 755 "$SELF"
fi
[ -f "$SELF" ] || { echo "[x] $SELF not found."; exit 1; }

case "$1" in
  warp|proxy|all)      _m="$1"; shift; exec sh "$SELF" "$_m" on "$@" ;;
  status|logs|doctor)  exec sh "$SELF" "$@" ;;
  *)                   exec sh "$SELF" start "$@" ;;
esac
