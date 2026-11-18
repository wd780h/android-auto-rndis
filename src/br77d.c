/* DHCP (v4) and router advertisements for the br77 bridge.
 * Freestanding: built without libc, talks to the kernel with syscalls.
 */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long u64;
typedef long i64;

#define SYS_read 63
#define SYS_write 64
#define SYS_close 57
#define SYS_openat 56
#define SYS_exit 93
#define SYS_nanosleep 101
#define SYS_socket 198
#define SYS_bind 200
#define SYS_sendto 206
#define SYS_recvfrom 207
#define SYS_setsockopt 208

#define AF_INET 2
#define AF_INET6 10
#define SOCK_DGRAM 2
#define SOCK_RAW 3
#define IPPROTO_ICMPV6 58
#define IPPROTO_IPV6 41
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_BROADCAST 6
#define SO_BINDTODEVICE 25
#define IPV6_MULTICAST_HOPS 18

static i64 syscall(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
  register i64 x8 __asm__("x8") = n;
  register i64 x0 __asm__("x0") = a;
  register i64 x1 __asm__("x1") = b;
  register i64 x2 __asm__("x2") = c;
  register i64 x3 __asm__("x3") = d;
  register i64 x4 __asm__("x4") = e;
  register i64 x5 __asm__("x5") = f;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
  return x0;
}

static void xexit(int code) { syscall(SYS_exit, code, 0, 0, 0, 0, 0); }

static int xwrite(int fd, const void *buf, int n) {
  return (int)syscall(SYS_write, fd, (i64)buf, n, 0, 0, 0);
}

static void logstr(const char *s) {
  int n = 0;
  while (s[n]) n++;
  xwrite(2, s, n);
}

static int str_eq(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}

static int str_len(const char *s) {
  int n = 0;
  while (s[n]) n++;
  return n;
}

static int parse_u32(const char *s, u32 *out) {
  u32 v = 0;
  if (!*s) return 0;
  while (*s) {
    if (*s < '0' || *s > '9') return 0;
    v = v * 10u + (u32)(*s - '0');
    s++;
  }
  *out = v;
  return 1;
}

static int parse_v4(const char *s, u32 *out) {
  u32 ip = 0;
  for (int i = 0; i < 4; i++) {
    u32 o = 0;
    int digits = 0;
    while (*s >= '0' && *s <= '9') {
      o = o * 10u + (u32)(*s - '0');
      if (o > 255) return 0;
      s++;
      digits++;
    }
    if (!digits) return 0;
    ip = (ip << 8) | o;
    if (i < 3) {
      if (*s != '.') return 0;
      s++;
    }
  }
  if (*s) return 0;
  *out = ip;
  return 1;
}

static void put_be32(u8 *p, u32 v) {
  p[0] = (u8)(v >> 24);
  p[1] = (u8)(v >> 16);
  p[2] = (u8)(v >> 8);
  p[3] = (u8)v;
}

static int parse_mac(const char *s, u8 mac[6]) {
  for (int i = 0; i < 6; i++) {
    int v = 0;
    for (int k = 0; k < 2; k++) {
      char c = *s++;
      int d;
      if (c >= '0' && c <= '9') d = c - '0';
      else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
      else return 0;
      v = (v << 4) | d;
    }
    mac[i] = (u8)v;
    if (i < 5) {
      if (*s != ':') return 0;
      s++;
    }
  }
  return *s == 0;
}

/* Compress an IPv6 text address into 16 bytes. Accepts a trailing :: */
static int parse_v6(const char *s, u8 out[16]) {
  u8 tmp[16];
  for (int i = 0; i < 16; i++) tmp[i] = 0;
  int part[8];
  int npart = 0;
  int compress = -1;
  const char *p = s;
  if (*p == ':' && p[1] == ':') {
    compress = 0;
    p += 2;
  }
  while (*p && npart < 8) {
    if (*p == ':') return 0;
    u32 v = 0;
    int digits = 0;
    while ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')) {
      char c = *p++;
      int d = (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' ? c - 'a' + 10 : c - 'A' + 10);
      v = (v << 4) | (u32)d;
      if (v > 0xffff || ++digits > 4) return 0;
    }
    if (!digits) return 0;
    part[npart++] = (int)v;
    if (*p == ':') {
      p++;
      if (*p == ':') {
        if (compress >= 0) return 0;
        compress = npart;
        p++;
        if (!*p) break;
      } else if (!*p) return 0;
    }
  }
  if (*p) return 0;
  int tail = npart - (compress < 0 ? npart : compress);
  int zeros = 8 - npart;
  if (compress < 0) {
    if (npart != 8) return 0;
    zeros = 0;
    compress = npart;
    tail = 0;
  }
  if (zeros < 0) return 0;
  int idx = 0;
  for (int i = 0; i < compress; i++) {
    tmp[idx++] = (u8)(part[i] >> 8);
    tmp[idx++] = (u8)part[i];
  }
  idx += zeros * 2;
  for (int i = 0; i < tail; i++) {
    int v = part[compress + i];
    tmp[idx++] = (u8)(v >> 8);
    tmp[idx++] = (u8)v;
  }
  if (idx != 16) return 0;
  for (int i = 0; i < 16; i++) out[i] = tmp[i];
  return 1;
}

struct lease {
  u8 mac[6];
  u32 ip;
  int used;
};

#define MAX_LEASE 190

static struct lease leases[MAX_LEASE];
static u32 next_host;
static u32 host_lo, host_hi, server_ip, netmask, dns_ip;
static const char *lease_path;

static int xopen(const char *path, int flags) {
  return (int)syscall(SYS_openat, -100, (i64)path, flags, 0644, 0, 0);
}

static int mac_eq(const u8 *a, const u8 *b) {
  for (int i = 0; i < 6; i++) if (a[i] != b[i]) return 0;
  return 1;
}

static int ip_taken(u32 ip) {
  for (int i = 0; i < MAX_LEASE; i++)
    if (leases[i].used && leases[i].ip == ip) return 1;
  return 0;
}

static void put_hex2(char *p, u8 v) {
  const char *h = "0123456789abcdef";
  p[0] = h[v >> 4];
  p[1] = h[v & 0xf];
}

static void put_dec(char *p, int *n, u32 v) {
  char tmp[10];
  int i = 0;
  if (v == 0) tmp[i++] = '0';
  while (v) { tmp[i++] = (char)('0' + (v % 10)); v /= 10; }
  while (i > 0) p[(*n)++] = tmp[--i];
}

static void save_leases(void) {
  if (!lease_path || !lease_path[0]) return;
  int fd = xopen(lease_path, 1 | 64 | 512);
  if (fd < 0) return;
  for (int i = 0; i < MAX_LEASE; i++) {
    if (!leases[i].used) continue;
    char line[64];
    int n = 0;
    for (int k = 0; k < 6; k++) {
      put_hex2(line + n, leases[i].mac[k]);
      n += 2;
      if (k < 5) line[n++] = ':';
    }
    line[n++] = ' ';
    u32 ip = leases[i].ip;
    put_dec(line, &n, (ip >> 24) & 0xff);
    line[n++] = '.';
    put_dec(line, &n, (ip >> 16) & 0xff);
    line[n++] = '.';
    put_dec(line, &n, (ip >> 8) & 0xff);
    line[n++] = '.';
    put_dec(line, &n, ip & 0xff);
    line[n++] = '\n';
    xwrite(fd, line, n);
  }
  syscall(SYS_close, fd, 0, 0, 0, 0, 0);
}

static void load_leases(void) {
  if (!lease_path || !lease_path[0]) return;
  int fd = xopen(lease_path, 0);
  if (fd < 0) return;
  char buf[8192];
  int n = (int)syscall(SYS_read, fd, (i64)buf, sizeof buf, 0, 0, 0);
  syscall(SYS_close, fd, 0, 0, 0, 0, 0);
  if (n <= 0) return;
  int i = 0;
  while (i < n) {
    int start = i;
    while (i < n && buf[i] != '\n') i++;
    buf[i] = 0;
    char *sp = buf + start;
    while (*sp && *sp != ' ') sp++;
    if (*sp == ' ') {
      *sp = 0;
      u8 mac[6];
      u32 ip = 0;
      if (parse_mac(buf + start, mac) && parse_v4(sp + 1, &ip)) {
        u32 host = ip & 0xffu;
        if (host >= host_lo && host <= host_hi && !ip_taken(ip)) {
          for (int s = 0; s < MAX_LEASE; s++) {
            if (leases[s].used) continue;
            leases[s].used = 1;
            for (int k = 0; k < 6; k++) leases[s].mac[k] = mac[k];
            leases[s].ip = (server_ip & netmask) | host;
            break;
          }
        }
      }
    }
    if (i < n) i++;
  }
  u32 nxt = host_lo;
  for (int s = 0; s < MAX_LEASE; s++) {
    if (!leases[s].used) continue;
    u32 host = leases[s].ip & 0xffu;
    if (host >= nxt) nxt = host + 1;
  }
  next_host = (nxt > host_hi) ? host_lo : nxt;
}

static u32 lease_for(const u8 mac[6]) {
  for (int i = 0; i < MAX_LEASE; i++) {
    if (leases[i].used && mac_eq(leases[i].mac, mac)) return leases[i].ip;
  }
  int span = (int)(host_hi - host_lo + 1);
  for (int n = 0; n < span; n++) {
    if (next_host > host_hi) next_host = host_lo;
    u32 host = next_host;
    next_host++;
    if (next_host > host_hi) next_host = host_lo;
    u32 ip = (server_ip & netmask) | host;
    if (ip_taken(ip)) continue;
    for (int i = 0; i < MAX_LEASE; i++) {
      if (!leases[i].used) {
        leases[i].used = 1;
        for (int k = 0; k < 6; k++) leases[i].mac[k] = mac[k];
        leases[i].ip = ip;
        save_leases();
        return ip;
      }
    }
  }
  return (server_ip & netmask) | host_lo;
}

static int dhcp_opt(u8 *p, u8 code, const u8 *data, int n) {
  p[0] = code;
  p[1] = (u8)n;
  for (int i = 0; i < n; i++) p[2 + i] = data[i];
  return 2 + n;
}

static void serve(const char *ifname, int ifindex, const u8 *prefix, const u8 *mac, int do_v6) {
  int udp = (int)syscall(SYS_socket, AF_INET, SOCK_DGRAM, 0, 0, 0, 0);
  if (udp < 0) { logstr("br77d: udp socket failed\n"); xexit(1); }
  int one = 1;
  syscall(SYS_setsockopt, udp, SOL_SOCKET, SO_REUSEADDR, (i64)&one, 4, 0);
  syscall(SYS_setsockopt, udp, SOL_SOCKET, SO_BROADCAST, (i64)&one, 4, 0);
  char ifn[16];
  int ilen = str_len(ifname);
  if (ilen > 14) ilen = 14;
  for (int i = 0; i < ilen; i++) ifn[i] = ifname[i];
  ifn[ilen] = 0;
  syscall(SYS_setsockopt, udp, SOL_SOCKET, SO_BINDTODEVICE, (i64)ifn, ilen + 1, 0);
  u8 sin[16];
  for (int i = 0; i < 16; i++) sin[i] = 0;
  sin[0] = AF_INET; /* little-endian family in the first byte on Linux aarch64? */
  /* sockaddr_in: sa_family_t is 16-bit. aarch64 is little endian, so family at [0]. */
  sin[0] = AF_INET & 0xff;
  sin[1] = 0;
  sin[2] = 0;
  sin[3] = 67; /* port 67 big endian */
  if (syscall(SYS_bind, udp, (i64)sin, 16, 0, 0, 0) < 0) {
    logstr("br77d: bind :67 failed\n");
    xexit(1);
  }

  int raw = -1;
  u8 ra[128];
  int ra_len = 0;
  if (do_v6) {
    raw = (int)syscall(SYS_socket, AF_INET6, SOCK_RAW, IPPROTO_ICMPV6, 0, 0, 0);
    if (raw < 0) { logstr("br77d: icmpv6 socket failed\n"); xexit(1); }
    int hops = 255;
    syscall(SYS_setsockopt, raw, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, (i64)&hops, 4, 0);
    syscall(SYS_setsockopt, raw, SOL_SOCKET, SO_BINDTODEVICE, (i64)ifn, ilen + 1, 0);
    /* Router Advertisement, autonomous prefix, not on-link. */
    ra[0] = 134; ra[1] = 0; ra[2] = 0; ra[3] = 0;
    ra[4] = 64; ra[5] = 0;
    ra[6] = 0; ra[7] = 300 >> 8; /* lifetime 300, fix below */
    ra[6] = (u8)(300 >> 8); ra[7] = (u8)(300 & 0xff);
    for (int i = 8; i < 16; i++) ra[i] = 0;
    ra[16] = 1; ra[17] = 1;
    for (int i = 0; i < 6; i++) ra[18 + i] = mac[i];
    ra[24] = 3; ra[25] = 4; ra[26] = 64; ra[27] = 0x40;
    put_be32(ra + 28, 7200);
    put_be32(ra + 32, 3600);
    put_be32(ra + 36, 0);
    for (int i = 0; i < 16; i++) ra[40 + i] = prefix[i];
    ra_len = 56;
    logstr("br77d: dhcp+ra\n");
  } else {
    logstr("br77d: dhcp\n");
  }

  u8 buf[1500];
  u8 reply[512];
  int tick = 0;
  for (;;) {
    /* Wake about every 3 seconds so router ads keep going even with no DHCP. */
    struct { i64 sec; i64 nsec; } ts;
    ts.sec = 0; ts.nsec = 500000000L;
    /* poll via recv with no timeout: interleave by trying recv after a short sleep when idle.
       Use a 3s sleep only when building RA cadence: do a nonblocking-less approach.
       recvfrom blocks. Send one RA first, then block. A side alarm isn't available
       without extra syscalls, so send RA, then recv with the socket left blocking,
       and also send RA again each time we loop after a datagram OR after we
       periodically... Blocking recv starves RA. Set SO_RCVTIMEO. */
    struct { i64 sec; i64 usec; } tv;
    tv.sec = 3; tv.usec = 0;
    /* SO_RCVTIMEO is 20 */
    syscall(SYS_setsockopt, udp, SOL_SOCKET, 20, (i64)&tv, 16, 0);

    if (do_v6 && (tick % 1) == 0) {
      u8 dst[28];
      for (int i = 0; i < 28; i++) dst[i] = 0;
      dst[0] = AF_INET6;
      /* port unused */
      dst[8] = 0xff; dst[9] = 0x02; /* ff02::1 */
      dst[23] = 1;
      dst[24] = (u8)(ifindex);
      dst[25] = (u8)(ifindex >> 8);
      dst[26] = (u8)(ifindex >> 16);
      dst[27] = (u8)(ifindex >> 24);
      syscall(SYS_sendto, raw, (i64)ra, ra_len, 0, (i64)dst, 28);
    }
    tick++;

    i64 n = syscall(SYS_recvfrom, udp, (i64)buf, sizeof buf, 0, 0, 0);
    if (n < 240) continue;
    if (buf[236] != 0x63 || buf[237] != 0x82 || buf[238] != 0x53 || buf[239] != 0x63) continue;
    int mtype = -1;
    int i = 240;
    while (i < n) {
      u8 t = buf[i];
      if (t == 255) break;
      if (t == 0) { i++; continue; }
      if (i + 1 >= n) break;
      int ln = buf[i + 1];
      if (t == 53 && ln >= 1 && i + 2 < n) mtype = buf[i + 2];
      i += 2 + ln;
    }
    if (mtype != 1 && mtype != 3) continue;
    u32 yi = lease_for(buf + 28);
    for (int k = 0; k < 512; k++) reply[k] = 0;
    reply[0] = 2; reply[1] = 1; reply[2] = 6;
    for (int k = 0; k < 4; k++) reply[4 + k] = buf[4 + k];
    reply[10] = buf[10]; reply[11] = buf[11];
    put_be32(reply + 16, yi);
    put_be32(reply + 20, server_ip);
    for (int k = 0; k < 16; k++) reply[28 + k] = buf[28 + k];
    reply[236] = 0x63; reply[237] = 0x82; reply[238] = 0x53; reply[239] = 0x63;
    int o = 240;
    u8 tmp[4];
    tmp[0] = (mtype == 1) ? 2 : 5;
    o += dhcp_opt(reply + o, 53, tmp, 1);
    put_be32(tmp, server_ip);
    o += dhcp_opt(reply + o, 54, tmp, 4);
    put_be32(tmp, 7u * 24u * 3600u);
    o += dhcp_opt(reply + o, 51, tmp, 4);
    put_be32(tmp, netmask);
    o += dhcp_opt(reply + o, 1, tmp, 4);
    put_be32(tmp, server_ip);
    o += dhcp_opt(reply + o, 3, tmp, 4);
    put_be32(tmp, dns_ip);
    o += dhcp_opt(reply + o, 6, tmp, 4);
    reply[o++] = 255;

    u8 dest[16];
    for (int k = 0; k < 16; k++) dest[k] = 0;
    dest[0] = AF_INET;
    dest[2] = 0; dest[3] = 68;
    dest[4] = dest[5] = dest[6] = dest[7] = 255;
    syscall(SYS_sendto, udp, (i64)reply, o, 0, (i64)dest, 16);
  }
}

static const char *need(int argc, char **argv, const char *key) {
  for (int i = 1; i + 1 < argc; i++) if (str_eq(argv[i], key)) return argv[i + 1];
  logstr("br77d: missing ");
  logstr(key);
  logstr("\n");
  xexit(2);
  return 0;
}

int main(int argc, char **argv) {
  const char *ifname = need(argc, argv, "--if");
  u32 ifindex = 0;
  if (!parse_u32(need(argc, argv, "--ifindex"), &ifindex)) xexit(2);
  if (!parse_v4(need(argc, argv, "--addr"), &server_ip)) xexit(2);
  dns_ip = server_ip;
  for (int i = 1; i + 1 < argc; i++) {
    if (str_eq(argv[i], "--dns") && !parse_v4(argv[i + 1], &dns_ip)) xexit(2);
  }
  u32 start_ip, end_ip;
  if (!parse_v4(need(argc, argv, "--start"), &start_ip)) xexit(2);
  if (!parse_v4(need(argc, argv, "--end"), &end_ip)) xexit(2);
  netmask = 0xffffff00u;
  host_lo = start_ip & 0xffu;
  host_hi = end_ip & 0xffu;
  if (host_lo < 2) host_lo = 2;
  if (host_hi < host_lo) host_hi = host_lo;
  next_host = host_lo;

  const char *pref_txt = 0;
  const char *mac_txt = 0;
  for (int i = 1; i + 1 < argc; i++) {
    if (str_eq(argv[i], "--prefix")) pref_txt = argv[i + 1];
    if (str_eq(argv[i], "--mac")) mac_txt = argv[i + 1];
    if (str_eq(argv[i], "--leases")) lease_path = argv[i + 1];
  }
  load_leases();
  u8 prefix[16], mac[6];
  int do_v6 = 0;
  if (pref_txt && mac_txt && !str_eq(pref_txt, "-") && parse_v6(pref_txt, prefix) && parse_mac(mac_txt, mac))
    do_v6 = 1;
  serve(ifname, (int)ifindex, prefix, mac, do_v6);
  return 0;
}

__attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "ldr x0, [sp]\n"
      "add x1, sp, #8\n"
      "bl main\n"
      "mov x8, #93\n"
      "svc #0\n");
}
