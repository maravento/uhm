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
################################################################################

set -uo pipefail

wan=$(sed -n 's/^WAN_IF="\?\([^"]*\)"\?$/\1/p' /etc/uhm/uhm.env 2>/dev/null | tail -1)
[ -n "$wan" ] || { echo "uhmiptables.sh: WAN_IF not found in /etc/uhm/uhm.env" >&2; exit 1; }

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

iptables -t nat -N UHM_NAT 2>/dev/null || true
iptables -t nat -F UHM_NAT
iptables -t nat -C POSTROUTING -j UHM_NAT 2>/dev/null || iptables -t nat -A POSTROUTING -j UHM_NAT
iptables -t nat -A UHM_NAT -o "$wan" -j MASQUERADE
