#!/bin/bash
# maravento.com

################################################################################
# THIS IS AN EXAMPLE SCRIPT -- DO NOT USE IN PRODUCTION
# Adapt interface names, IPs, and ACL paths to your environment.
# See the full reference implementation and README at:
# https://github.com/maravento/uhm
################################################################################

################################################################################
#
# Iptables/Ipset Firewall O(1) -- Iptables script
#
# DESCRIPTION:
## Verify: iptables -L -n / iptables -nvL / iptables -Ln -t mangle / iptables -Ln -t nat
## Sockets: ss -ltuna
# Ports: /etc/services
# ============================
# Ports 0-1023: "Well-known ports" (System/Privileged)
# - Require superuser privileges to bind
# - Standard services: HTTP(80), HTTPS(443), SSH(22), DNS(53)
# - FTP(21), Telnet(23), SMTP(25), etc.
# Ports 1024-49151: "Registered ports" (IANA Assigned)
# - Assigned by Internet Assigned Numbers Authority
# - User/application services without root privileges
# - Examples: MySQL(3306), PostgreSQL(5432), Skype(1000-10000)
# Ports 49152-65535: "Dynamic/Private ports" (Ephemeral)
# - Available for any use, not registered by IANA
# - Used for temporary/outbound connections
# - Client-side dynamic port assignments
# REFERENCES:
# - https://gutl.jovenclub.cu/wiki/doku.php?id=definiciones:puertos_tcp_udp
# - https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers
# - RFC 6335 - Internet Assigned Numbers Authority (IANA) Procedures
# - https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.txt
#
################################################################################

set -euo pipefail

# logging
log_file="/var/log/uhm.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

## root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "Script $(basename "$0") is already running"
    exit 1
fi

# DEPENDENCIES
for dep in iptables ipset arptables ebtables kmod procps util-linux ulogd2; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency '$dep' is not installed."
        exit 1
    fi
done

# VALIDATION -- one variable per thing validated; use directly with =~
_UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
_UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
_UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
_UH_UINT='^(0|[1-9][0-9]*)$'
_UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# Start
log "uiptables start..."

# VARIABLES ##

# MAC/IP validation before feeding external ACL data into ipset
is_valid_mac() {
    [[ "$1" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]
}

is_valid_ip() {
    [[ "$1" =~ $_UH_IPV4 ]]
}

# Load all configuration from uhm.env (network, paths, interfaces).
# Safe key=value parsing - file is never sourced to prevent code execution.
_UHM_CONF="/etc/uhm/uhm.env"

_load_conf() {
    local file="$1" key value line
    [[ ! -f "$file" ]] && { log "WARNING: $file not found - using built-in defaults"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            WAN_IF|INTERFACESv4|\
            SERVER_IP|SERV_SUBNET|SERV_MASK|SERV_DNS|\
            ACL_MAC_PATH|ACL_DHCP_PATH|HOTSPOT_PATH|\
            ACL_MAC_PROXY|ACL_MAC_UNLIMITED|UGRACE_FILE)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}

_load_conf "$_UHM_CONF" || true

wan="${WAN_IF:-eth0}"
lan="${INTERFACESv4:-eth1}"
localnet="${SERV_SUBNET:-192.168.0.0}"
serverip="${SERVER_IP:-192.168.0.10}"
SERV_DNS="${SERV_DNS:-$serverip}"
# squid proxy port
squid_port=3128
# squid intercept port (NAT-redirected HTTP, not exposed to explicit proxy clients)
squid_intercept_port=3129
_uh_mask="${SERV_MASK:-255.255.255.0}"
if [[ " $_UH_PREFIX " =~ [[:space:]]${_uh_mask//./\\.}:([0-9]+)[[:space:]] ]]; then
    netmask="${BASH_REMATCH[1]}"
else
    log "ERROR: SERV_MASK is not a valid netmask: '$_uh_mask'"
    exit 1
fi

acl_mac_path="${ACL_MAC_PATH:-/etc/acl/acl_mac}"
acl_path="${acl_mac_path%/acl_mac}"
acl_ipt_path="${acl_path}/acl_ipt"
hotspot_path="${HOTSPOT_PATH:-/etc/uhm}"
UGRACE_FILE="${UGRACE_FILE:-${hotspot_path}/acl/uhm-grace.txt}"

# ACL/config files used by this script (existence verified below)
mac_proxy_file="${ACL_MAC_PROXY:-$acl_mac_path/mac-proxy.txt}"
mac_unlimited_file="${ACL_MAC_UNLIMITED:-$acl_mac_path/mac-unlimited.txt}"
dhcp_conf="/etc/pydhcp/pydhcpd.conf"
path_ips="$acl_ipt_path/dhcp_ip.txt"
path_macs="$acl_ipt_path/dhcp_mac.txt"

for f in "$mac_proxy_file" "$mac_unlimited_file" "$dhcp_conf"; do
    if [ ! -f "$f" ]; then
        log "ERROR: required file not found: $f"
        exit 1
    fi
done
if [ ! -d "$acl_mac_path" ] || [ -z "$(ls -A "$acl_mac_path" 2>/dev/null)" ]; then
    log "ERROR: acl_mac_path missing or empty: $acl_mac_path"
    exit 1
fi
if [ ! -d "$acl_ipt_path" ]; then
    log "ERROR: acl_ipt_path missing: $acl_ipt_path"
    exit 1
fi

### KERNEL RULES ###

## Zero all packets and counters
# Reset tables (IPv4)
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true
iptables -t raw -X 2>/dev/null || true
iptables -t security -F 2>/dev/null || true
iptables -t security -X 2>/dev/null || true
# Reset counters (IPv4)
iptables -Z 2>/dev/null || true
iptables -t nat -Z 2>/dev/null || true
iptables -t mangle -Z 2>/dev/null || true
# Reset tables (IPv6)
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
# Reset counters (IPv6)
ip6tables -Z 2>/dev/null || true
# Clear ARP and bridge
arptables -F 2>/dev/null || true
arptables -X 2>/dev/null || true
ebtables -F 2>/dev/null || true
ebtables -X 2>/dev/null || true
# Conntrack (Optional)
#conntrack -F 2>/dev/null || true

# Default-deny while the ruleset below is being (re)built -- if this script
# fails partway, the gateway stays closed instead of wide open. INPUT/FORWARD
# only: the ruleset's own final rules (see END, below) explicitly DROP
# anything not already matched by an earlier ACCEPT, so this is a no-op in a
# successfully completed run -- it only matters during a partial failure.
iptables -P INPUT DROP
iptables -P FORWARD DROP

## IPv4
# SYSTEM OPTIMIZATION
sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true
sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
# CONNECTION TRACKING
# nf_conntrack_max/buckets only exist under /proc/sys once the nf_conntrack
# kernel module is loaded. On a cold boot this script can run before
# anything else has triggered that module to load, so sysctl -w would
# silently no-op on those two keys until the module loads on its own.
# Force the module to load first so tuning takes effect immediately,
# instead of depending on boot timing.
modprobe -q nf_conntrack 2>/dev/null || true
# Increase connection tracking table size for high concurrency
sysctl -w net.netfilter.nf_conntrack_max=524288 >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_buckets=131072 >/dev/null 2>&1 || true
# SECURITY & NETWORK HARDENING
# Disable IP source routing (prevents IP spoofing and routing attacks)
sysctl -w net.ipv4.conf.all.accept_source_route=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_source_route=0 >/dev/null 2>&1 || true
# Disable secure redirects (protects against malicious router advertisements)
# If you experience LAN routing issues, you can temporarily set this to 1.
sysctl -w net.ipv4.conf.all.secure_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.secure_redirects=0 >/dev/null 2>&1 || true
# Log packets with impossible or spoofed source addresses ("martians")
sysctl -w net.ipv4.conf.all.log_martians=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.log_martians=1 >/dev/null 2>&1 || true
# Enable strict reverse path filtering (drops packets with spoofed source IPs)
sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null 2>&1 || true

## NETWORK PERFORMANCE & TCP PROTECTION
# Optimized TCP/IP parameters for high-performance and secure routing
# Enable TCP SYN cookies (protects against SYN flood attacks)
sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true
# Increase SYN backlog queue and tune retries (helps prevent SYN flood)
sysctl -w net.ipv4.tcp_max_syn_backlog=20000 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_syn_retries=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_synack_retries=2 >/dev/null 2>&1 || true
# Enable RFC1337 fix (protects against TCP TIME-WAIT assassination)
sysctl -w net.ipv4.tcp_rfc1337=1 >/dev/null 2>&1 || true
# Expand available local port range (default: 32768-60999)
sysctl -w net.ipv4.ip_local_port_range="10000 65535" >/dev/null 2>&1 || true
# Reduce TCP FIN timeout (faster cleanup for orphaned sockets)
sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null 2>&1 || true
# TCP keepalive settings (balance connection stability and resource usage)
sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_intvl=15 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1 || true
# Enable TCP Fast Open (reduces latency for repeated connections)
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
# Enable TCP performance features
sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1 || true
# Increase socket buffers
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_default=262144 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_default=262144 >/dev/null 2>&1 || true
# TCP buffer auto-tuning
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1 || true
# Enable PMTU discovery (recommended: automatic MTU adjustment)
sysctl -w net.ipv4.ip_no_pmtu_disc=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
# Increase network queue size (handles bursts of incoming packets)
sysctl -w net.core.netdev_max_backlog=20000 >/dev/null 2>&1 || true
# Increase TIME_WAIT socket capacity (important for busy NAT or proxy servers)
sysctl -w net.ipv4.tcp_max_tw_buckets=1000000 >/dev/null 2>&1 || true
# Allow safe TIME_WAIT socket reuse (improves connection efficiency)
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true

## ROUTING & FORWARDING
# Enable packet forwarding (required for NAT/routing)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

## ARP OPTIMIZATION
# Enable ARP filtering (prevents incorrect replies when multiple interfaces exist)
sysctl -w net.ipv4.conf.all.arp_filter=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_filter=1 >/dev/null 2>&1 || true
# ARP announce mode - only reply for local addresses
sysctl -w net.ipv4.conf.all.arp_announce=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_announce=2 >/dev/null 2>&1 || true
# ARP ignore mode - only respond to ARPs for IPs on receiving interface
sysctl -w net.ipv4.conf.all.arp_ignore=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_ignore=1 >/dev/null 2>&1 || true
# ARP cache tuning: reduce broadcast frequency and improve efficiency
sysctl -w net.ipv4.neigh.default.gc_stale_time=300 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.gc_thresh1=128 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.gc_thresh2=512 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.gc_thresh3=1024 >/dev/null 2>&1 || true
# Reduce ARP broadcast retries (limits ARP noise in large LANs)
sysctl -w net.ipv4.neigh.default.ucast_solicit=3 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.mcast_solicit=2 >/dev/null 2>&1 || true
# Base reachable time for neighbor entries
sysctl -w net.ipv4.neigh.default.base_reachable_time_ms=300000 >/dev/null 2>&1 || true

## KERNEL & FILESYSTEM HARDENING
# Enable full ASLR (Address Space Layout Randomization)
sysctl -w kernel.randomize_va_space=2 >/dev/null 2>&1 || true
# Protect hardlinks (prevents privilege escalation attacks)
sysctl -w fs.protected_hardlinks=1 >/dev/null 2>&1 || true
# Protect symlinks (prevents unauthorized link access in shared directories)
sysctl -w fs.protected_symlinks=1 >/dev/null 2>&1 || true

## ICMP
# Disable sending ICMP redirects (prevents MITM via route manipulation)
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null 2>&1 || true
# Disable accepting ICMP redirects from other hosts (security hardening)
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_redirects=0 >/dev/null 2>&1 || true
# Allow normal ICMP echo requests (ping)
sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || true
# Ignore ICMP echo requests sent to broadcast addresses (Smurf attack prevention)
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1 >/dev/null 2>&1 || true
# Ignore bogus or malformed ICMP error responses
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1 >/dev/null 2>&1 || true
# Rate limit ICMP message generation (100 ms minimum interval)
sysctl -w net.ipv4.icmp_ratelimit=100 >/dev/null 2>&1 || true

# WAN IPv6
sysctl -w "net.ipv6.conf.${wan}.disable_ipv6=0" >/dev/null 2>&1 || true
# LAN IPv6
sysctl -w "net.ipv6.conf.${lan}.disable_ipv6=1" >/dev/null 2>&1 || true
# Essential ICMPv6 (NDP, SLAAC, Path MTU)
ip6tables -A OUTPUT -o "$wan" -p ipv6-icmp -j ACCEPT || true
# DHCPv6
ip6tables -A OUTPUT -o "$wan" -p udp --sport 546 --dport 547 -j ACCEPT || true
# Established traffic
ip6tables -A INPUT -i "$wan" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true

### GLOBAL RULES ###

# Global Policies IPv4
# INPUT/FORWARD already set to DROP right after the flush, above -- not
# reset to ACCEPT here, so the gateway stays closed if anything below fails.
iptables -P OUTPUT ACCEPT
# Global Policies IPv6
ip6tables -P INPUT DROP || true
ip6tables -P FORWARD DROP || true
ip6tables -P OUTPUT DROP || true
# LOOPBACK
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT || true
ip6tables -A OUTPUT -o lo -j ACCEPT || true
iptables -A INPUT -s 127.0.0.0/8 ! -i lo -j DROP
iptables -A FORWARD -s 127.0.0.0/8 ! -i lo -j DROP
# WAN DROP: Local Ports (reduce noise) (Optional)
# 25 TCP - Postfix SMTP (master)
# 80 TCP - HTTP
# 3128 TCP - Squid proxy
# 3129 TCP - Squid proxy (intercept)
# 4330 TCP - PCP pmlogger (Performance Co-Pilot)
# 5005 TCP - UniFi/Podman (pasta userspace network)
# 5636 TCP - UniFi/Podman (pasta userspace network)
# 5671 TCP - UniFi/Podman AMQP (pasta userspace network)
# 6789 TCP - UniFi speed test (pasta userspace network)
# 8443 TCP - UniFi HTTPS GUI (pasta userspace network)
# 8444 TCP - UniFi OS HTTPS GUI (pasta userspace network)
# 9543 TCP - UniFi/Podman (pasta userspace network)
# 10000 TCP - Webmin
# 11084 TCP - UniFi/Podman (pasta userspace network)
# 11443 TCP - UniFi OS self-hosted GUI (pasta userspace network)
# 18100 TCP - PAC proxy
# 18080 TCP - Internal HTTP
# 18081 TCP - Warning page (bandata)
# 18082 TCP - Internal HTTP alternate
# 44321 TCP - PCP pmcd (Performance Co-Pilot daemon)
# 44322 TCP - PCP pmproxy
# 44323 TCP - PCP pmproxy HTTPS
iptables -A INPUT -i "$wan" -p tcp -m multiport --dports 25,80,$squid_port,$squid_intercept_port,4330,5005,5636,5671,6789,8443,8444,9543,10000,11084,11443,18100 -j DROP
iptables -A INPUT -i "$wan" -p tcp -m multiport --dports 18080,18081,18082,44321,44322,44323 -j DROP
iptables -A INPUT -i "$wan" -p udp --dport 5353 -j DROP
# DHCP
iptables -t mangle -A PREROUTING -i "$lan" -p udp --dport 67 -j ACCEPT
iptables -A OUTPUT -o "$wan" -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A INPUT -i "$wan" -p udp --sport 67 --dport 68 -j ACCEPT
iptables -A INPUT -i "$lan" -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A OUTPUT -o "$lan" -p udp --sport 67 --dport 68 -j ACCEPT
# MASQUERADE: NAT for LAN to share dynamic WAN IP
iptables -t nat -A POSTROUTING -s "$localnet/$netmask" -o "$wan" -j MASQUERADE
#
# SNAT example for static WAN IP (more efficient)
# wan_ip=$(ip -4 -o addr show dev "$wan" | awk '{print $4}' | cut -d/ -f1)
# iptables -t nat -A POSTROUTING -s "$localnet/$netmask" -o "$wan" -j SNAT --to-source "$wan_ip"
# LAN ---> PROXY <--- WAN
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
# Squid proxy outbound traffic
iptables -A OUTPUT -o "$wan" -m owner --uid-owner proxy -j ACCEPT

# Invalid and fragmented packets
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -f -j DROP
# TCP scans / malformed packets
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
# Invalid NEW connections with SYN+ACK
iptables -A INPUT -p tcp --tcp-flags SYN,ACK SYN,ACK -m conntrack --ctstate NEW -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,ACK SYN,ACK -m conntrack --ctstate NEW -j DROP

# DNS (Global Policy)
# Applies to all lan sources regardless of MAC list -- no list (macgrace,
# macunlimited, macports, etc.) gets a free pass on bypassing the resolver or
# flooding it. Placed before MACUNLIMITED's blanket ACCEPT-all further down,
# so that rule never gets a chance to short-circuit this one.
# Burst limit
iptables -A FORWARD -i "$lan" -p udp --dport 53 -m state --state NEW -m recent --set --name DNS_DROPPER
iptables -A FORWARD -i "$lan" -p udp --dport 53 -m state --state NEW -m recent --update --seconds 1 --hitcount 15 --name DNS_DROPPER -j DROP
for dnsip in ${SERV_DNS//,/ }; do
    for protocol in tcp udp; do
        iptables -A INPUT -i "$lan" -d "$dnsip" -p "$protocol" --dport 53 -j ACCEPT
        iptables -A FORWARD -i "$lan" -d "$dnsip" -p "$protocol" --dport 53 -j ACCEPT
    done
done
for protocol in tcp udp; do
    iptables -A FORWARD -i "$lan" -p "$protocol" --dport 53 -m hashlimit --hashlimit-name dns-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip -j NFLOG --nflog-prefix "DNS-DROP: "
    iptables -A FORWARD -i "$lan" -p "$protocol" --dport 53 -j DROP
done

### UNIFI PORTS ###
# https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference

## UNIFI WAN
# STUN responses from Ubiquiti (3478) and Google (19302) - needed for APs behind NAT
iptables -A INPUT -i "$wan" -p udp -m multiport --sports 3478,19302 -j ACCEPT
# Device discovery from management LAN via WAN interface
iptables -A INPUT -i "$wan" -p udp --dport 10001 -j ACCEPT
## UNIFI LAN
# Uncomment if using Ubiquiti remote access cloud service
# iptables -A INPUT -i "$wan" -p tcp -s 66.203.125.0/24 --sport 443 -d "$wan" -j ACCEPT
# LAN Unifi - ports required for LAN clients and APs to communicate with self-hosted controller
# 8080 TCP - AP to controller communication
# 8880 TCP - captive portal HTTP
# 8881 TCP - captive portal HTTP alternate
# 8882 TCP - captive portal HTTP alternate
# 8843 TCP - captive portal HTTPS
# 6789 TCP - UniFi speed test / throughput measurement (Podman/pasta userspace network)
# 3478 UDP - STUN for APs
# 53 UDP - DNS (local on gateway)
# 123 UDP - NTP
# 10001 UDP - device discovery
# Removed (administrative/internal only):
# 8443 TCP - GUI/API admin access
# 8444 TCP - UniFi OS HTTPS GUI admin
# 11443 TCP - UniFi OS self-hosted GUI admin
# 27117 TCP - MongoDB internal database
# 1900 UDP - UPnP optional discovery
unifi_tcp="8080,6789"
unifi_udp_local="10001"
unifi_udp_wan="3478,123"
iptables -t mangle -A PREROUTING -i "$lan" -p tcp -m multiport --dports "$unifi_tcp" -j ACCEPT
iptables -t mangle -A PREROUTING -i "$lan" -p udp -m multiport --dports "$unifi_udp_local,$unifi_udp_wan" -j ACCEPT
iptables -A INPUT -i "$lan" -p tcp -m multiport --dports "$unifi_tcp" -j ACCEPT
iptables -A INPUT -i "$lan" -p udp --dport "$unifi_udp_local" -j ACCEPT
iptables -A FORWARD -i "$lan" -o "$wan" -p udp -m multiport --dports "$unifi_udp_wan" -j ACCEPT

# Unifi Portal Acess
# Optional https: 8843
cpd_tcp="8880,8881,8882"

# MAC grace rules
# Create ipsets
if ! ipset list macgrace &>/dev/null; then
    ipset create macgrace hash:mac -exist
else
    ipset flush macgrace
fi

# Populate ipsets
if [ -f "$UGRACE_FILE" ]; then
    for mac in $(awk -F";" 'NF>=2 && $1 == "a" && $2 != "" {print $2}' "$UGRACE_FILE"); do
        is_valid_mac "$mac" && ipset add macgrace "$mac" -exist
    done
else
    log "WARNING: $UGRACE_FILE not found -- skipping macgrace"
fi
# HTTP
iptables -t mangle -A PREROUTING -i "$lan" -m set --match-set macgrace src -p tcp --dport 80 -j ACCEPT
iptables -t nat -A PREROUTING -i "$lan" -m set --match-set macgrace src -p tcp --dport 80 -j REDIRECT --to-port 8880
iptables -A INPUT -i "$lan" -m set --match-set macgrace src -p tcp --dport 8880 -j ACCEPT
# CDP
iptables -t mangle -A PREROUTING -i "$lan" -m set --match-set macgrace src -p tcp -m multiport --dports "$cpd_tcp" -j ACCEPT
iptables -A INPUT -i "$lan" -m set --match-set macgrace src -p tcp -m multiport --dports "$cpd_tcp" -j ACCEPT

# mac2ip
mac2ip=$(awk '
    /host [^{]+ \{/ { in_block=1; mac=""; ip="" }
    in_block && /hardware ethernet/ { mac=$3; gsub(/;/, "", mac) }
    in_block && /fixed-address/ { ip=$2; gsub(/;/, "", ip) }
    in_block && /\}/ {
        if (mac != "" && ip != "") print mac, ip
        in_block=0
    }
' "$dhcp_conf")
# rule mac2ip
if ! ipset list macip &>/dev/null; then
    ipset create macip hash:ip,mac -exist
else
    ipset flush macip
fi
create_acl() {
    local ips macs mac ip
    ips="# ips"
    macs="# macs"
    while (( $# >= 2 )); do
        mac="$1"
        shift
        ip="$1"
        shift
        # Add MAC+IP to set
        is_valid_mac "$mac" && is_valid_ip "$ip" && ipset add macip "$ip,$mac" -exist
        ips="$ips\n$ip"
        macs="$macs\n$mac"
    done
    echo -e "$ips" > "$path_ips"
    echo -e "$macs" > "$path_macs"
}
if [ -n "$mac2ip" ]; then
    # create_acl expects a flat MAC IP MAC IP ... arg list (it shifts two at a
    # time). $mac2ip is one "mac ip" pair per line, so it must still be split
    # into individual args -- but building that list explicitly (instead of
    # relying on bare unquoted word-splitting) avoids any accidental glob
    # expansion of a token.
    mac2ip_args=()
    while IFS=' ' read -r _m2i_mac _m2i_ip; do
        [[ -n "$_m2i_mac" ]] && mac2ip_args+=("$_m2i_mac")
        [[ -n "$_m2i_ip" ]] && mac2ip_args+=("$_m2i_ip")
    done <<< "$mac2ip"
    create_acl "${mac2ip_args[@]}"
    iptables -t mangle -N MACCHECK 2>/dev/null
    iptables -t mangle -F MACCHECK
    iptables -t mangle -A PREROUTING -i "$lan" -j MACCHECK
    iptables -t mangle -A MACCHECK -m set --match-set macip src,src -j RETURN
    iptables -t mangle -A MACCHECK -j DROP

    # ARP binding: drop ARP claiming a registered static IP from any MAC other
    # than the one it's leased to. iptables/ipset only see the IP layer, not
    # how that IP got resolved to a MAC on the wire -- this closes that gap.
    for ((_arp_i=0; _arp_i<${#mac2ip_args[@]}; _arp_i+=2)); do
        _arp_mac="${mac2ip_args[_arp_i]}"
        _arp_ip="${mac2ip_args[_arp_i+1]}"
        is_valid_mac "$_arp_mac" && is_valid_ip "$_arp_ip" && \
            { arptables -A INPUT -i "$lan" --source-ip "$_arp_ip" ! --source-mac "$_arp_mac" -j DROP || true; }
    done
else
    log "WARNING: No static DHCP entries found in $dhcp_conf; macip binding skipped"
fi

# MACUNLIMITED (MAC + IP for Access Points, Switch, etc.)
if ! ipset list macunlimited &>/dev/null; then
    ipset create macunlimited hash:mac -exist
else
    ipset flush macunlimited
fi
for mac in $(awk -F";" '$1 == "a" && $2 != "" {print $2}' "$mac_unlimited_file" 2>/dev/null); do
    is_valid_mac "$mac" && ipset add macunlimited "$mac" -exist
done
iptables -t nat -A PREROUTING -i "$lan" -m set --match-set macunlimited src -j ACCEPT
iptables -t mangle -A PREROUTING -i "$lan" -m set --match-set macunlimited src -j ACCEPT
# Unlimited devices never use the proxy -- block PAC access so DHCP option 252
# (WPAD, if enabled) has no effect on them, since pydhcpd is ACL-agnostic and
# sends it to every client regardless of classification.
iptables -A INPUT -i "$lan" -p tcp -m multiport --dports $squid_port,18100 -m set --match-set macunlimited src -j DROP
for chain in INPUT FORWARD; do
    iptables -A "$chain" -i "$lan" -m set --match-set macunlimited src -j ACCEPT
done

### PORT RULES ###

# MAC Ports
if ! ipset list macports &>/dev/null; then
    ipset create macports hash:mac -exist
else
    ipset flush macports
fi
for mac in $(awk -F";" '$1 == "a" && $2 != "" {print $2}' "$acl_mac_path"/mac-*.txt 2>/dev/null); do
    is_valid_mac "$mac" && ipset add macports "$mac" -exist
done
if [ -f "$hotspot_path/acl/uhm-auth.txt" ]; then
    for mac in $(awk -F";" '$1 == "a" && $2 != "" {print $2}' "$hotspot_path/acl/uhm-auth.txt"); do
        is_valid_mac "$mac" && ipset add macports "$mac" -exist
    done
else
    log "WARNING: $hotspot_path/acl/uhm-auth.txt not found -- skipping macports"
fi

# NTP
iptables -A INPUT -i "$lan" -p udp --dport 123 -s "$localnet/$netmask" -m set --match-set macports src -j ACCEPT
iptables -A FORWARD -i "$lan" -p udp --dport 123 -s "$localnet/$netmask" -m set --match-set macports src -j ACCEPT

### SECURITY RULES ###

# Block 6to4 (IPv6-in-IPv4 tunneling) - prevents LAN clients from bypassing
# IPv4-based firewall rules via IPv6 tunnel encapsulation
iptables -A FORWARD -i "$lan" -p 41 -j DROP
# NETBIOS NMBD (disabled in smb.conf)
for chain in INPUT FORWARD; do
    iptables -A "$chain" -i "$lan" -p udp -m multiport --dports 137,138 -j DROP
    iptables -A "$chain" -i "$lan" -p tcp --dport 139 -j DROP
done
# CoAP/CoAPs 5683/5684
for chain in INPUT FORWARD; do
    iptables -A "$chain" -i "$lan" -p udp -m multiport --dports 5683,5684 -j DROP
done
# syncflood
iptables -N syn_flood
iptables -A INPUT -i "$wan" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
iptables -A INPUT -i "$lan" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
iptables -A FORWARD -i "$wan" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
iptables -A FORWARD -i "$lan" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
iptables -A syn_flood -i "$wan" -m limit --limit 50/s --limit-burst 200 -j RETURN
iptables -A syn_flood -i "$lan" -m limit --limit 200/s --limit-burst 500 -j RETURN
iptables -A syn_flood -m limit --limit 1/min -j NFLOG --nflog-prefix "SYNFLOOD: "
iptables -A syn_flood -j DROP
# Windows Update Delivery Optimization (WUDO)
# Allow peer-to-peer update sharing within the local network.
# Block outbound WUDO traffic to WAN and direct connections to the firewall.
for proto in tcp udp; do
    iptables -A FORWARD -i "$lan" -p "$proto" --dport 7680 -s "$localnet/$netmask" -d "$localnet/$netmask" -j ACCEPT
done
for chain in INPUT FORWARD; do
    for proto in tcp udp; do
        iptables -A "$chain" -i "$lan" -p "$proto" --dport 7680 -j DROP
    done
done
# Block GRE (Generic Routing Encapsulation) protocol 47
for chain in INPUT FORWARD; do
    iptables -A "$chain" -i "$lan" -p 47 -j DROP
done
# Block Windows Mobile Hotspot sharing
iptables -A FORWARD -i "$lan" -d 192.168.137.0/24 -j DROP
# Block WS-Discovery unicast to server (Windows clients noise)
iptables -A INPUT -i "$lan" -p udp --sport 3702 -d "$serverip" -j DROP
# KMS Windows activation noise
iptables -A INPUT -i "$lan" -p tcp --dport 1688 -j ACCEPT
iptables -A FORWARD -i "$lan" -o "$wan" -p tcp --dport 1688 -j ACCEPT
# Spotify LAN sync broadcast noise
iptables -A INPUT -i "$lan" -p udp --dport 57621 -j DROP
# Cisco IP phones discovery noise
iptables -A INPUT -i "$lan" -p udp -m multiport --dports 2007,2008 -j DROP
# SAP broadcast noise (Optional)
iptables -A INPUT -i "$lan" -p udp --dport 3289 -j DROP
# Dropbox LAN sync broadcast noise
iptables -A INPUT -i "$lan" -p udp --dport 17500 -j DROP
# ICMP (ping) (Optional)
# WARNING:
# You need to change the following kernel parameter in the header of this script:
# sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
# NOTE: For nmap scans, increase limit to 100/second or use -Pn in nmap options
#iptables -A INPUT -p icmp -m limit --limit 10/second -j ACCEPT
#iptables -A FORWARD -p icmp -m limit --limit 10/second -j ACCEPT
#iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
# Silence ICMP forward noise
iptables -A FORWARD -i "$lan" -o "$wan" -p icmp -j DROP

### MAC RULES ###

# MACPROXY (PAC 18100 - Opcion 252 DHCP, HTTP 80 -> Squid intercept port)
if ! ipset list macproxy &>/dev/null; then
    ipset create macproxy hash:mac -exist
else
    ipset flush macproxy
fi
for mac in $(awk -F";" '$1 == "a" && $2 != "" {print $2}' "$mac_proxy_file" 2>/dev/null); do
    is_valid_mac "$mac" && ipset add macproxy "$mac" -exist
done
iptables -t mangle -A PREROUTING -i "$lan" -m set --match-set macproxy src -p tcp -m multiport --dports 18100,80,$squid_port -j ACCEPT
iptables -t nat -A PREROUTING -i "$lan" -p tcp --dport 80 -m set --match-set macproxy src -j REDIRECT --to-port "$squid_intercept_port"
iptables -A INPUT -i "$lan" -p tcp --dport "$squid_intercept_port" -m set --match-set macproxy src -m conntrack --ctstate DNAT -j ACCEPT
iptables -A INPUT -i "$lan" -p tcp -m multiport --dports 18100,$squid_port -m set --match-set macproxy src -j ACCEPT

# MACHOTSPOT (PAC 18100 - Opcion 252 DHCP, HTTP 80 -> Squid intercept port)
if ! ipset list machotspot &>/dev/null; then
    ipset create machotspot hash:mac -exist
else
    ipset flush machotspot
fi
if [ -f "$hotspot_path/acl/uhm-auth.txt" ]; then
    for mac in $(awk -F";" '$1 == "a" && $2 != "" {print $2}' "$hotspot_path/acl/uhm-auth.txt"); do
        is_valid_mac "$mac" && ipset add machotspot "$mac" -exist
    done
else
    log "WARNING: $hotspot_path/acl/uhm-auth.txt not found -- skipping machotspot"
fi
# UNIFI PORTAL ACCESS + PAC (18100)
iptables -t mangle -A PREROUTING -i "$lan" -m set --match-set machotspot src -p tcp -m multiport --dports "$cpd_tcp,18100,80,$squid_port" -j ACCEPT
# NAT
iptables -t nat -A PREROUTING -i "$lan" -p tcp --dport 80 -m set --match-set machotspot src -j REDIRECT --to-port "$squid_intercept_port"
iptables -A INPUT -i "$lan" -p tcp --dport "$squid_intercept_port" -m set --match-set machotspot src -m conntrack --ctstate DNAT -j ACCEPT
iptables -A INPUT -i "$lan" -p tcp -m multiport --dports "$cpd_tcp,18100,$squid_port" -m set --match-set machotspot src -j ACCEPT

## END ##
iptables -A INPUT -m hashlimit --hashlimit-name input-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip,dstport -j NFLOG --nflog-prefix "FINAL-INPUT DROP: "
iptables -A INPUT -j DROP
iptables -A FORWARD -m hashlimit --hashlimit-name forward-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip,dstport -j NFLOG --nflog-prefix "FINAL-FORWARD DROP: "
iptables -A FORWARD -j DROP

# End
log "uiptables done at: $(date)"
