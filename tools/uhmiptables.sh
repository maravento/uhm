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
# DEPENDENCIES: iptables, procps (sysctl), sed, coreutils (tail)
#
# Runs as root -- it writes kernel settings and firewall rules.
#
################################################################################

set -uo pipefail

## root check
if [ "$(id -u)" != "0" ]; then
    echo "uhmiptables.sh: this script must be run as root -- abort" >&2
    exit 1
fi

# DEPENDENCIES
for dep in iptables procps sed coreutils iproute2; do
    if ! dpkg -s "$dep" &>/dev/null; then
        echo "uhmiptables.sh: missing dependency '$dep' -- abort" >&2
        exit 1
    fi
done

wan=$(sed -n 's/^WAN_IF="\?\([^"]*\)"\?$/\1/p' /etc/uhm/uhm.env 2>/dev/null | tail -1)
[ -n "$wan" ] || { echo "uhmiptables.sh: WAN_IF not found in /etc/uhm/uhm.env" >&2; exit 1; }
ip link show "$wan" >/dev/null 2>&1 || {
    echo "uhmiptables.sh: interface '$wan' does not exist -- abort" >&2
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
iptables -t nat -A UHM_NAT -o "$wan" -j MASQUERADE \
    || fail "cannot add MASQUERADE on $wan"
