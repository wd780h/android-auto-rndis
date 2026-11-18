#!/system/bin/sh
# Stop the module and remove the rules it adds. The global filter policy is
# left as it is: this script does not know what it was before install.
pkill -f /data/adb/modules/br77/br77d 2>/dev/null
pkill -f /data/adb/modules/br77/br77-loop.sh 2>/dev/null
ip link del br77 2>/dev/null

while ip rule del pref 21000 2>/dev/null; do :; done
while ip -6 rule del pref 21000 2>/dev/null; do :; done

CFG=/data/adb/br77/config
ADDR=192.168.77.1
PREFIX=24
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi
net=$(echo "$ADDR" | awk -F. -v p="$PREFIX" '{printf "%s.%s.%s.0/%s", $1, $2, $3, p}')

ip route show table all 2>/dev/null | while read -r line; do
  case "$line" in
    "$net "*)
      table=$(echo "$line" | awk '{
        for (i = 1; i <= NF; i++) if ($i == "table") { print $(i+1); exit }
      }')
      [ -n "$table" ] || table=main
      ip route del "$net" table "$table" 2>/dev/null
      ;;
  esac
done

ip -6 route show table all 2>/dev/null | while read -r line; do
  case "$line" in
    */128*)
      echo "$line" | grep -q 'dev rndis\|dev usb\|dev ncm\|dev br77' || continue
      dest=$(echo "$line" | awk '{print $1}')
      dev=$(echo "$line" | awk '{
        for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }
      }')
      table=$(echo "$line" | awk '{
        for (i = 1; i <= NF; i++) if ($i == "table") { print $(i+1); exit }
      }')
      [ -n "$table" ] || table=main
      [ -n "$dev" ] && ip -6 route del "$dest" dev "$dev" table "$table" 2>/dev/null
      ;;
  esac
done

for ifc in br77 rndis0 rndis1 usb0 usb1 ncm0 ncm1; do
  iptables -D FORWARD -i "$ifc" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -o "$ifc" -j ACCEPT 2>/dev/null
  ip6tables -D FORWARD -i "$ifc" -j ACCEPT 2>/dev/null
  ip6tables -D FORWARD -o "$ifc" -j ACCEPT 2>/dev/null
  iptables -D tetherctrl_FORWARD -i "$ifc" -j RETURN 2>/dev/null
  iptables -D tetherctrl_FORWARD -o "$ifc" -j RETURN 2>/dev/null
  ip6tables -D tetherctrl_FORWARD -i "$ifc" -j RETURN 2>/dev/null
  ip6tables -D tetherctrl_FORWARD -o "$ifc" -j RETURN 2>/dev/null
  iptables -t raw -D PREROUTING -i "$ifc" -j ACCEPT 2>/dev/null
  for proto in udp tcp; do
    iptables -t nat -D PREROUTING -i "$ifc" -p "$proto" --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -D PREROUTING -i "$ifc" -p "$proto" --dport 53 -j DNAT --to-destination 127.0.0.1:53 2>/dev/null
    iptables -t mangle -D PREROUTING -i "$ifc" -p "$proto" --dport 53 -j MARK --set-mark 0xf0063 2>/dev/null
  done
  for dir in -i -o; do
    iptables -t mangle -D FORWARD "$dir" "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    ip6tables -t mangle -D FORWARD "$dir" "$ifc" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
  done
done

iptables -t nat -S POSTROUTING 2>/dev/null | sed -n 's/^-A POSTROUTING //p' | while read -r rule; do
  case "$rule" in
    -s\ "$net"\ -j\ MASQUERADE|-s\ "$net"\ *\ -j\ MASQUERADE)
      # shellcheck disable=SC2086
      iptables -t nat -D POSTROUTING $rule 2>/dev/null
      ;;
  esac
done
