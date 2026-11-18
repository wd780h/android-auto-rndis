#!/system/bin/sh
# The hand-written SukiSU script and this module would both own the bridge.
if [ -f /data/adb/service.d/br77.sh ]; then
  mv /data/adb/service.d/br77.sh /data/adb/service.d/br77.sh.bak
  ui_print "Moved /data/adb/service.d/br77.sh aside so it does not run twice"
fi
