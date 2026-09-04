#!/bin/bash
# maravento.com
#
################################################################################
#
# Minimal firewall template for uhm
#
# DESCRIPTION:
# Enables IPv4 forwarding and NAT -- neither is on by default in Ubuntu, and
# without them LAN clients get a lease but reach nothing. Nothing else: no
# proxy redirect, no port filtering, no ipsets. Client classification and the
# captive portal do not depend on this file.
#
# For the full ruleset, copy uhmiptables_example.txt over this file and
# adapt it to your network.
#
# Rules live in UHM_NAT, flushed and rebuilt on every run so they never
# accumulate. Nothing outside that chain is touched.
#
# DEPENDENCIES: iptables, procps (sysctl), iproute2
#
# Runs as root -- it writes kernel settings and firewall rules.
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "uhmiptables.sh: this script must be run as root -- abort" >&2
    exit 1
fi

# dependencies
for dep_pkg in iptables procps iproute2; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        echo "uhmiptables.sh: missing dependency '$dep_pkg' -- abort" >&2
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_UINT='^(0|[1-9][0-9]*)$'
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# Load all configuration from pydhcp.env/uhm.env (network, paths, interfaces).
# Two files, one per owner: pydhcp.env holds pydhcp's network and ACL values,
# uhm.env holds uhm's own. pydhcp.env is read first and uhm.env after, so
# uhm's keys win if a name ever collides. This minimal ruleset only uses
# $wan_iface, but every iptables flavor uhm ships (this file and
# uhmiptables_example.txt) loads the same set of variables for
# consistency. Safe env_key=value parsing -- files are never
# sourced to prevent code execution.
pydhcp_conf="/etc/pydhcp/pydhcp.env"
uhm_conf="/etc/uhm/uhm.env"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

load_conf() {
    local conf_file="$1" env_key env_value env_line
    [[ ! -f "$conf_file" ]] && { echo "uhmiptables.sh: WARNING: $conf_file not found -- fallback" >&2; return 1; }
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ "$env_line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        env_value="${env_value%\"}"
        env_value="${env_value#\"}"
        case "$env_key" in
            INTERFACESv4|\
            SERVER_IP|SERV_SUBNET|SERV_MASK|SERV_DNS|\
            ACL_MAC_PATH|ACL_DHCP_PATH|UHM_PATH|\
            ACL_MAC_LIMITED|ACL_MAC_UNLIMITED|UHM_GRACE|WPAD_PORT)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}

if [ ! -r "$pydhcp_conf" ]; then
    echo "uhmiptables.sh: ERROR: cannot read $pydhcp_conf -- abort" >&2
    exit 1
fi
load_conf "$pydhcp_conf" || true
load_conf "$uhm_conf" || true

# wan is a placeholder: uhmsetup.sh replaces it with sed -i during the
# setup wizard, after asking and listing available interfaces.
wan_iface="eth0"
lan_iface="${INTERFACESv4:-eth1}"
local_subnet="${SERV_SUBNET:-192.168.0.0}"
server_addr="${SERVER_IP:-192.168.0.10}"
SERV_DNS="${SERV_DNS:-$server_addr}"
squid_port=3128
squid_intercept_port=3129
wpad_port="${WPAD_PORT:-18100}"
[[ "$wpad_port" =~ $UH_UINT ]] && (( wpad_port >= 1 && wpad_port <= 65535 )) \
    || { echo "uhmiptables.sh: ERROR: WPAD_PORT is not a valid port -- abort" >&2; exit 1; }
uh_mask="${SERV_MASK:-255.255.255.0}"
if [[ " $UH_PREFIX " =~ [[:space:]]${uh_mask//./\\.}:([0-9]+)[[:space:]] ]]; then
    netmask_int="${BASH_REMATCH[1]}"
else
    echo "uhmiptables.sh: ERROR: SERV_MASK is not a valid netmask -- abort" >&2
    exit 1
fi
acl_mac_path="${ACL_MAC_PATH:-/etc/acl/mac}"
acl_path="${acl_mac_path%/mac}"
acl_ipt_path="${acl_path}/ipt"
hotspot_path="${UHM_PATH:-/etc/uhm}"
UHM_GRACE="${UHM_GRACE:-${hotspot_path}/acl/uhm-grace.txt}"

ip link show "$wan_iface" >/dev/null 2>&1 || {
    echo "uhmiptables.sh: interface '$wan_iface' does not exist -- abort" >&2
    exit 1
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
# Not a tuning value: without forwarding this host stops routing, and LAN
# clients get a lease that reaches nothing. Verified by its resulting
# state, not by sysctl's exit code, so a value already set by another
# means is accepted.
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    echo "uhmiptables.sh: IPv4 forwarding is off, LAN cannot route -- abort" >&2
    exit 1
fi

# A rule that fails here leaves the LAN without NAT, so every step below
# reports it instead of letting the script exit 0 and pass as a good reload.
fail() { echo "uhmiptables.sh: $1 -- abort" >&2; exit 1; }

iptables -t nat -N UHM_NAT 2>/dev/null || true
iptables -t nat -F UHM_NAT || fail "cannot flush UHM_NAT"
iptables -t nat -C POSTROUTING -j UHM_NAT 2>/dev/null \
    || iptables -t nat -A POSTROUTING -j UHM_NAT \
    || fail "cannot hook UHM_NAT into POSTROUTING"
iptables -t nat -A UHM_NAT -o "$wan_iface" -j MASQUERADE \
    || fail "cannot add MASQUERADE on $wan_iface"
