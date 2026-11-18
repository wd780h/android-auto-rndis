#!/system/bin/sh
pkill -f /data/adb/modules/br77/br77d 2>/dev/null
pkill -f /data/adb/modules/br77/br77-loop.sh 2>/dev/null
ip link del br77 2>/dev/null
ip -6 rule del iif br77 pref 21000 2>/dev/null
