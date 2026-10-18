#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmiptables -- firewall placeholder for uhm
#
# USAGE:
# uhmiptables.sh    (no arguments; normally invoked by uhmreload.sh)
#
# LOG: /var/log/uhm.log
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# logging
log_file="/var/log/uhm.log"
log() {
    local log_msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$log_msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then
        echo "$log_msg" >&2
    else
        echo "$log_msg"
    fi
}

# dependencies
for dep_pkg in iptables procps iproute2; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
pydhcp_env="/etc/pydhcp/pydhcp.env"
env_specs=("$pydhcp_env root:pydhcpd 640")
for env_spec in "${env_specs[@]}"; do
    read -r env_path env_owner_want env_perms_want <<< "$env_spec"
    if [ ! -f "$env_path" ]; then
        log "ERROR: $(basename "$env_path") not found -abort"
        exit 1
    fi
    env_owner=$(stat -c '%U:%G' "$env_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_path" 2>/dev/null)
    if [[ "$env_owner" != "$env_owner_want" ]] \
       || [[ "$env_perms" != "$env_perms_want" ]]; then
        if chown "$env_owner_want" "$env_path" 2>/dev/null \
           && chmod "$env_perms_want" "$env_path" 2>/dev/null; then
            log "INFO: $(basename "$env_path") perms fixed -fixed"
        else
            log "ERROR: cannot fix $(basename "$env_path") perms -abort"
            exit 1
        fi
    fi
done
unset env_specs env_spec env_path env_owner_want env_perms_want
unset env_owner env_perms

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/uhmenv.sh"
env_keys='WAN_IFACE'

# LOAD
# WAN_IFACE is the only value this ruleset needs. pydhcp's installer writes it
# into pydhcp.env as a shared key, and every project that needs it reads it
# from there. Safe key=value parsing -- the file is never sourced to prevent
# code execution.
load_uhm_env "$pydhcp_env" "$env_keys" line || true

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
key_errors=()
for env_key in WAN_IFACE; do
    if ! grep -q "^${env_key}=" "$pydhcp_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "ERROR: $key_error -abort"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$pydhcp_env") -abort"
    exit 1
fi
unset key_errors key_error env_key

# KEY GUARD
# The MASQUERADE rule below names this interface. A value that no longer
# matches the host produces a LAN without NAT instead of an error.
if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    log "ERROR: WAN_IFACE '$WAN_IFACE' does not exist on this host -abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

log "uhmiptables start..."

# A rule that fails here leaves the LAN without NAT, so every step reports it
# instead of letting the script exit 0 and pass as a good reload.
fail() { log "ERROR: $1 -abort"; exit 1; }

# FORWARDING
# Not a tuning value: without forwarding this host stops routing, and LAN
# clients get a lease that reaches nothing. Verified by its resulting state,
# not by sysctl's exit code, so a value already set by another means is
# accepted.
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    log "ERROR: IPv4 forwarding is off, LAN cannot route -abort"
    exit 1
fi

# NAT
# Masquerades the LAN behind the WAN address, in its own UHM_NAT chain
iptables -t nat -N UHM_NAT 2>/dev/null || true
iptables -t nat -F UHM_NAT || fail "cannot flush UHM_NAT"
iptables -t nat -C POSTROUTING -j UHM_NAT 2>/dev/null \
    || iptables -t nat -A POSTROUTING -j UHM_NAT \
    || fail "cannot hook UHM_NAT into POSTROUTING"
iptables -t nat -A UHM_NAT -o "$WAN_IFACE" -j MASQUERADE \
    || fail "cannot add MASQUERADE on $WAN_IFACE"

# FORWARD RULES
# ip_forward only enables routing in the kernel. If the FORWARD policy is
# DROP, set by another firewall or by a previous ruleset, traffic still dies.
# These two accept the LAN's way out and the replies coming back, without
# naming the LAN interface and without touching any policy.
iptables -N UHM_FWD 2>/dev/null || true
iptables -F UHM_FWD || fail "cannot flush UHM_FWD"
iptables -C FORWARD -j UHM_FWD 2>/dev/null \
    || iptables -A FORWARD -j UHM_FWD \
    || fail "cannot hook UHM_FWD into FORWARD"
iptables -A UHM_FWD -o "$WAN_IFACE" -j ACCEPT \
    || fail "cannot accept LAN traffic out $WAN_IFACE"
iptables -A UHM_FWD -i "$WAN_IFACE" -m conntrack \
    --ctstate ESTABLISHED,RELATED -j ACCEPT \
    || fail "cannot accept replies in on $WAN_IFACE"

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "uhmiptables done at: $(date '+%Y-%m-%d %H:%M:%S')"
