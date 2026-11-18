#!/system/bin/sh
# Magisk late_start. Blocking here delays boot, so the loop is detached.
MODDIR=${0%/*}
mkdir -p /data/adb/br77
if [ ! -f /data/adb/br77/config ]; then
  cp "$MODDIR/config.default" /data/adb/br77/config
fi
if ! pgrep -f "$MODDIR/br77-loop.sh" >/dev/null 2>&1; then
  setsid "$MODDIR/br77-loop.sh" "$MODDIR" >>/data/adb/br77/br77.log 2>&1 &
fi
