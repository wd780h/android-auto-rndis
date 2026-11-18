#!/system/bin/sh
# Fixed subnet on the USB gadget only. The Wi-Fi hotspot stays with the system.
# Started by Magisk/KernelSU service.sh. Argument: module directory.
MODDIR=$1
[ -n "$MODDIR" ] || MODDIR=$(dirname "$0")
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
CFG=/data/adb/br77/config
LOG=/data/adb/br77/br77.log
DAEMON=$MODDIR/br77d
STATE=/data/adb/br77/daemon.args
mkdir -p /data/adb/br77
if [ -f "$LOG" ]; then
  bytes=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$bytes" -gt 262144 ]; then
    mv "$LOG" "$LOG.1" 2>/dev/null
  fi
fi
exec >>"$LOG" 2>&1
echo "=== br77 start $(date) ==="

if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi
BRIDGE=${BRIDGE:-br77}
ADDR=${ADDR:-192.168.77.1}
PREFIX=${PREFIX:-24}
DHCP_START=${DHCP_START:-192.168.77.10}
DHCP_END=${DHCP_END:-192.168.77.200}
PORTS=${PORTS:-auto}
AUTO_USB=${AUTO_USB:-1}
IPV6=${IPV6:-1}

is_up() {
  ip -o link show "$1" 2>/dev/null | grep -q 'UP'
}

master_of() {
  ip -o link show "$1" | awk '{
    for (i = 1; i <= NF; i++) if ($i == "master") { print $(i+1); exit }
  }'
}

route_dev() {
  # $1 is empty or -6. $2 is the probe address.
  # shellcheck disable=SC2086
  ip $1 route get "$2" 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }
  }'
}

# Android keeps the default route in a per-interface table. The table name is
# not always the same as the device name.
route_table() {
  fam=$1
  dev=$2
  # shellcheck disable=SC2086
  ip $fam route show table all 2>/dev/null | awk -v d="$dev" '
    $1 == "default" {
      dev = ""; tbl = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") dev = $(i + 1)
        if ($i == "table") tbl = $(i + 1)
      }
      if (dev == d && tbl != "") { print tbl; exit }
    }'
}

have() {
  for x in $found; do
    [ "$x" = "$1" ] && return 0
  done
  return 1
}

add_port() {
  ifc=$1
  [ -n "$ifc" ] || return 0
  [ "$ifc" = "$BRIDGE" ] && return 0
  [ "$ifc" = "$UP4" ] && return 0
  [ "$ifc" = "$UP6" ] && return 0
  have "$ifc" && return 0
  ip link show "$ifc" >/dev/null 2>&1 || return 0
  is_up "$ifc" || return 0
  found="$found $ifc"
}

discover_ports() {
  found=""
  if [ "$PORTS" != auto ]; then
    for ifc in $PORTS; do
      add_port "$ifc"
    done
    echo "$found"
    return 0
  fi
  ip -o link | awk -F': ' '{print $2}' | cut -d@ -f1 | while read -r ifc; do
    case "$ifc" in
      ""|lo|dummy*|rmnet*|r_rmnet*|ccmni*|wwan*|p2p*|wifi-aware*|tun*|gre*|sit*|ipsec*|teql*|ifb*|bond*|v4-*)
        continue
        ;;
      rndis*|usb*|ncm*)
        echo "$ifc"
        continue
        ;;
    esac
  done | while read -r ifc; do
    add_port "$ifc"
    echo "$found"
  done | tail -1
}

net4() {
  echo "$ADDR" | awk -F. -v p="$PREFIX" '{printf "%s.%s.%s.0/%s", $1, $2, $3, p}'
}

# Policies ACCEPT, and the bridge is accepted before tetherctrl's trailing DROP.
# Rules are not tied to an upstream name: a new rmnet still matches.
open_firewall() {
  iptables -P INPUT ACCEPT 2>/dev/null
  iptables -P FORWARD ACCEPT 2>/dev/null
  iptables -P OUTPUT ACCEPT 2>/dev/null
  ip6tables -P INPUT ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -P OUTPUT ACCEPT 2>/dev/null
  iptables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$BRIDGE" -j ACCEPT
  iptables -C FORWARD -o "$BRIDGE" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -o "$BRIDGE" -j ACCEPT
  ip6tables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null \
    || ip6tables -I FORWARD 1 -i "$BRIDGE" -j ACCEPT
  ip6tables -C FORWARD -o "$BRIDGE" -j ACCEPT 2>/dev/null \
    || ip6tables -I FORWARD 1 -o "$BRIDGE" -j ACCEPT
  if iptables -S tetherctrl_FORWARD >/dev/null 2>&1; then
    iptables -D tetherctrl_FORWARD -j DROP 2>/dev/null || true
    iptables -C tetherctrl_FORWARD -i "$BRIDGE" -j RETURN 2>/dev/null \
      || iptables -I tetherctrl_FORWARD 1 -i "$BRIDGE" -j RETURN
    iptables -C tetherctrl_FORWARD -o "$BRIDGE" -j RETURN 2>/dev/null \
      || iptables -I tetherctrl_FORWARD 1 -o "$BRIDGE" -j RETURN
  fi
  if ip6tables -S tetherctrl_FORWARD >/dev/null 2>&1; then
    ip6tables -D tetherctrl_FORWARD -j DROP 2>/dev/null || true
    ip6tables -C tetherctrl_FORWARD -i "$BRIDGE" -j RETURN 2>/dev/null \
      || ip6tables -I tetherctrl_FORWARD 1 -i "$BRIDGE" -j RETURN
    ip6tables -C tetherctrl_FORWARD -o "$BRIDGE" -j RETURN 2>/dev/null \
      || ip6tables -I tetherctrl_FORWARD 1 -o "$BRIDGE" -j RETURN
  fi
  iptables -t raw -C PREROUTING -i "$BRIDGE" -j ACCEPT 2>/dev/null \
    || iptables -t raw -I PREROUTING 1 -i "$BRIDGE" -j ACCEPT
  # Upstream routes are often 1400 while the bridge stays 1500. Without this,
  # TCP sends full segments and the transfer stalls.
  for dir in -i -o; do
    iptables -t mangle -C FORWARD "$dir" "$BRIDGE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
      || iptables -t mangle -I FORWARD 1 "$dir" "$BRIDGE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -t mangle -C FORWARD "$dir" "$BRIDGE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
      || ip6tables -t mangle -I FORWARD 1 "$dir" "$BRIDGE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  done
  echo 1 > /proc/sys/net/ipv4/ip_forward
}

# One MASQUERADE for the whole LAN, not "-o rmnet_dataX". The first matching
# rule must be this one, or tetherctrl NATs without a conntrack entry.
ensure_nat() {
  net=$(net4)
  first=$(iptables -t nat -S POSTROUTING 2>/dev/null | awk 'NR==2{print}')
  want="-A POSTROUTING -s $net -j MASQUERADE"
  if [ "$first" != "$want" ]; then
    iptables -t nat -S POSTROUTING 2>/dev/null | sed -n 's/^-A POSTROUTING //p' | while read -r rule; do
      case "$rule" in
        -s\ "$net"\ -j\ MASQUERADE|-s\ "$net"\ *\ -j\ MASQUERADE)
          # shellcheck disable=SC2086
          iptables -t nat -D POSTROUTING $rule 2>/dev/null
          ;;
      esac
    done
    iptables -t nat -I POSTROUTING 1 -s "$net" -j MASQUERADE
  fi
  # Hand the bridge's port 53 to the phone's tether dnsmasq. It only accepts
  # packets marked with the --listen-mark netd gave it, and it listens on 127.0.0.1.
  mark=$(phone_dns_mark)
  if [ -n "$mark" ]; then
    echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet
    echo 1 > /proc/sys/net/ipv4/conf/"$BRIDGE"/route_localnet 2>/dev/null
    for proto in udp tcp; do
      iptables -t mangle -C PREROUTING -i "$BRIDGE" -p "$proto" --dport 53 -j MARK --set-mark "$mark" 2>/dev/null \
        || iptables -t mangle -I PREROUTING 1 -i "$BRIDGE" -p "$proto" --dport 53 -j MARK --set-mark "$mark"
      iptables -t nat -C PREROUTING -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 127.0.0.1:53 2>/dev/null \
        || iptables -t nat -I PREROUTING 1 -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 127.0.0.1:53
      while iptables -t nat -D PREROUTING -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null; do
        :
      done
    done
  else
    for proto in udp tcp; do
      iptables -t nat -C PREROUTING -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null \
        || iptables -t nat -I PREROUTING 1 -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 8.8.8.8:53
      while iptables -t nat -D PREROUTING -i "$BRIDGE" -p "$proto" --dport 53 -j DNAT --to-destination 127.0.0.1:53 2>/dev/null; do
        :
      done
    done
  fi
}

phone_dns_mark() {
  pid=$(pidof dnsmasq 2>/dev/null | awk '{print $1}')
  [ -n "$pid" ] || return 0
  [ -r "/proc/$pid/cmdline" ] || return 0
  tr '\0' '\n' < "/proc/$pid/cmdline" | awk 'p { print; exit } $0 == "--listen-mark" { p = 1 }'
}

# pref 21000 used to name one rmnet table. After a 5G drop the new PDP has
# another table, and lookups of the old one have no default route.
sync_lookup() {
  fam=$1
  tbl=$2
  [ -n "$tbl" ] || return 0
  if [ "$fam" = -6 ]; then
    bin="ip -6"
  else
    bin="ip"
  fi
  # shellcheck disable=SC2086
  n=$($bin rule show pref 21000 2>/dev/null | grep -c .)
  # shellcheck disable=SC2086
  hit=$($bin rule show pref 21000 2>/dev/null | grep -c "iif $BRIDGE lookup $tbl")
  if [ "$n" = 1 ] && [ "$hit" = 1 ]; then
    return 0
  fi
  # shellcheck disable=SC2086
  while $bin rule del pref 21000 2>/dev/null; do :; done
  # shellcheck disable=SC2086
  $bin rule add iif "$BRIDGE" lookup "$tbl" pref 21000
}

ensure_forward() {
  up=$1
  [ -n "$up" ] || return 0
  [ "$up" = "$BRIDGE" ] && return 0
  net=$(net4)
  ensure_nat
  tbl=$(route_table -4 "$up")
  # Unmarked forwarded replies use legacy_system (fwmark 0), not main.
  # The upstream table is what locally generated replies use (iif lo).
  for rt in main legacy_system legacy_network local_network $tbl; do
    [ -n "$rt" ] || continue
    ip route replace "$net" dev "$BRIDGE" table "$rt" 2>/dev/null
  done
  sync_lookup -4 "$tbl"
}

# Stock tether clsact programs NAT without conntrack. Replies then come back
# as ICMP unreachable. Settings "hardware offload" stays untouched; only these
# filters are removed, and netd puts them back, so this runs every pass.
drop_tether_bpf() {
  for ifc in "$@"; do
    [ -n "$ifc" ] || continue
    tc filter del dev "$ifc" ingress 2>/dev/null
  done
}

ensure_v6() {
  [ "$IPV6" = 1 ] || return 0
  ip link show "$BRIDGE" >/dev/null 2>&1 || return 0
  up6=$(route_dev -6 2001:4860:4860::8888)
  [ -n "$up6" ] || return 0
  [ "$up6" = "$BRIDGE" ] && return 0
  echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
  echo 1 > /proc/sys/net/ipv6/conf/all/proxy_ndp
  # Android turns IPv6 off on a USB iface it is not tethering. Then there is
  # no link-local and router advertisements never leave.
  echo 0 > /proc/sys/net/ipv6/conf/"$BRIDGE"/disable_ipv6 2>/dev/null
  # SLAAC on the USB iface steals the carrier /64. Clients use that prefix via proxy NDP.
  echo 0 > /proc/sys/net/ipv6/conf/"$BRIDGE"/accept_ra 2>/dev/null
  echo 0 > /proc/sys/net/ipv6/conf/"$BRIDGE"/autoconf 2>/dev/null
  ip -6 addr flush dev "$BRIDGE" scope global 2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/"$BRIDGE"/forwarding 2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/"$BRIDGE"/proxy_ndp 2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/"$up6"/forwarding 2>/dev/null
  echo 1 > /proc/sys/net/ipv6/conf/"$up6"/proxy_ndp 2>/dev/null
  tbl=$(route_table -6 "$up6")
  [ -n "$tbl" ] || tbl=$up6
  sync_lookup -6 "$tbl"
  ip -6 neigh show dev "$BRIDGE" 2>/dev/null | awk '{print $1}' | while read -r addr; do
    case "$addr" in
      fe80:*|::*) continue ;;
    esac
    # Same /64 as the carrier is on-link on the upstream. A /128 via the
    # bridge is what lets the reply leave the legacy_system lookup.
    for rt in main legacy_system legacy_network local_network $tbl; do
      [ -n "$rt" ] || continue
      ip -6 route replace "$addr/128" dev "$BRIDGE" table "$rt" 2>/dev/null
    done
    ip -6 neigh replace proxy "$addr" dev "$up6" 2>/dev/null
  done
  echo "$up6"
}

daemon_args() {
  idx=$(cat /sys/class/net/"$BRIDGE"/ifindex 2>/dev/null)
  mac=$(ip -o link show "$BRIDGE" | awk '{
    for (i = 1; i <= NF; i++) if ($i == "link/ether") { print $(i+1); exit }
  }')
  pref="-"
  if [ "$IPV6" = 1 ]; then
    up6=$1
    if [ -n "$up6" ]; then
      raw=$(ip -6 addr show dev "$up6" scope global 2>/dev/null | awk '/inet6/{print $2; exit}')
      raw=${raw%%/*}
      pref=$(echo "$raw" | awk -F: 'NF >= 4 {printf "%s:%s:%s:%s::", $1, $2, $3, $4}')
    fi
  fi
  if [ -n "$(phone_dns_mark)" ]; then
    dns=$ADDR
  else
    dns=""
    for p in net.dns1 net.dns2; do
      cand=$(getprop "$p" 2>/dev/null)
      case "$cand" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) dns=$cand; break ;;
      esac
    done
    [ -n "$dns" ] || dns=8.8.8.8
  fi
  echo "--if $BRIDGE --ifindex $idx --addr $ADDR --start $DHCP_START --end $DHCP_END --dns $dns --prefix ${pref:-"-"} --mac $mac --leases /data/adb/br77/leases"
}

ensure_daemon() {
  up6=$1
  args=$(daemon_args "$up6")
  case "$args" in
    *"--ifindex "[0-9]*) ;;
    *) return 0 ;;
  esac
  old=$(cat "$STATE" 2>/dev/null)
  if [ "$old" != "$args" ] || ! pgrep -f "$DAEMON --if " >/dev/null 2>&1; then
    pkill -f "$DAEMON --if " 2>/dev/null
    sleep 1
    echo "$args" > "$STATE"
    # shellcheck disable=SC2086
    setsid "$DAEMON" $args >>/data/adb/br77/br77d.log 2>&1 &
    echo "daemon $args"
  fi
}

# Drop the system IpServer for this interface. It keeps writing its own
# prefix (10.255.179.0/24 on this phone) and that reset takes the USB data
# pipe down. The netdev stays; we bring it back up and bridge it ourselves.
release_system_tether() {
  ifc=$1
  dumpsys tethering 2>/dev/null | grep -q "$ifc - TetheredState - lastError" || return 0
  service call tethering 2 s16 "$ifc" s16 com.android.shell s16 br77 null >/dev/null 2>&1
  ip link set "$ifc" up
  echo "untether $ifc"
}

apply() {
  UP4=$(route_dev "" 1.1.1.1)
  UP6=$(route_dev -6 2001:4860:4860::8888)
  want=$(discover_ports)
  [ -n "$want" ] || return 0
  # One USB gadget. Leave any Wi-Fi AP alone, and remove the old bridge.
  ifc=${want# }
  ifc=${ifc%% *}
  ip link del br77 2>/dev/null && echo "del br77" || true
  BRIDGE=$ifc
  release_system_tether "$ifc"
  ip link set "$ifc" nomaster 2>/dev/null
  ip link set "$ifc" up
  if ip -4 addr show dev "$ifc" | grep -q 'inet ' && ! ip -4 addr show dev "$ifc" | grep -q "inet $ADDR/$PREFIX"; then
    ip addr flush dev "$ifc"
    echo "flush $ifc"
  fi
  if ! ip -4 addr show dev "$BRIDGE" | grep -q "inet $ADDR/$PREFIX"; then
    ip addr replace "$ADDR/$PREFIX" dev "$BRIDGE"
    echo "addr $BRIDGE $ADDR/$PREFIX"
  fi
  open_firewall
  ensure_forward "$UP4"
  # shellcheck disable=SC2086
  drop_tether_bpf "$BRIDGE"
  up6=$(ensure_v6)
  ensure_daemon "$up6"
}

usb_configured() {
  found=0
  for f in /sys/class/android_usb/android0/state /sys/class/android_usb/android1/state; do
    [ -r "$f" ] || continue
    found=1
    case "$(cat "$f")" in
      CONFIGURED|CONNECTED) return 0 ;;
    esac
  done
  if [ "$found" = 1 ]; then
    return 1
  fi
  st=$(getprop sys.usb.state)
  [ -n "$st" ] && [ "$st" != none ]
}

# A computer enumerates the gadget. A dumb charger usually stops before this.
# Xiaomi charge-only can leave android0 DISCONNECTED while the UDC is already
# configured, so the plug-in check has to look here too.
host_present() {
  for d in /sys/class/udc/*; do
    [ -r "$d/state" ] || continue
    [ "$(cat "$d/state" 2>/dev/null)" = configured ] && return 0
  done
  usb_configured
}

# 0 when an rndis/usb/ncm iface exists and none of them has a carrier.
gadget_carrier_down() {
  saw=0
  for ifc in /sys/class/net/rndis* /sys/class/net/usb* /sys/class/net/ncm*; do
    [ -r "$ifc/carrier" ] || continue
    saw=1
    [ "$(cat "$ifc/carrier" 2>/dev/null)" = 1 ] && return 1
  done
  [ "$saw" = 1 ]
}

usb_kick() {
  fn=$1
  why=$2
  now=$(date +%s)
  last=0
  [ -f /data/adb/br77/usb-try.ts ] && last=$(cat /data/adb/br77/usb-try.ts)
  if [ $((now - last)) -lt 20 ]; then
    return 0
  fi
  echo "$now" > /data/adb/br77/usb-try.ts
  echo "usb fn=$fn -> rndis ($why)"
  setsid svc usb setFunctions rndis </dev/null >/data/adb/br77/usb-once.log 2>&1 &
}

usb_auto() {
  [ "$AUTO_USB" = 1 ] || return 0
  host_present || return 0
  fn=$(getprop sys.usb.state)
  case "$fn" in
    *rndis*|*ncm*)
      if gadget_carrier_down; then
        now=$(date +%s)
        since=0
        [ -f /data/adb/br77/carrier-down.ts ] && since=$(cat /data/adb/br77/carrier-down.ts)
        if [ "$since" -eq 0 ]; then
          echo "$now" > /data/adb/br77/carrier-down.ts
          return 0
        fi
        if [ $((now - since)) -ge 15 ]; then
          usb_kick "$fn" "carrier down"
          rm -f /data/adb/br77/carrier-down.ts
        fi
      else
        rm -f /data/adb/br77/carrier-down.ts
      fi
      return 0
      ;;
  esac
  rm -f /data/adb/br77/carrier-down.ts
  usb_kick "$fn" "not rndis"
}

while true; do
  usb_auto
  apply
  sleep 2
done
