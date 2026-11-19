#!/system/bin/sh
# Magisk late_start. Blocking here delays boot, so the loop is detached.
MODDIR=${0%/*}
mkdir -p /data/adb/br77
if [ ! -f /data/adb/br77/config ]; then
  cp "$MODDIR/config.default" /data/adb/br77/config
fi
# The loop has died on this phone and then a replug stayed on adb.
# Keep restarting it so plug-in can still switch to rndis.
if ! pgrep -f "$MODDIR/br77-keeper" >/dev/null 2>&1; then
  setsid sh -c '
    while true; do
      "$1/br77-loop.sh" "$1"
      echo "loop exit $? $(date)" >> /data/adb/br77/br77.log
      sleep 2
    done
  ' "$MODDIR/br77-keeper" "$MODDIR" >>/data/adb/br77/br77.log 2>&1 < /dev/null &
fi
