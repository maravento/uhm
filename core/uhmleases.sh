#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmleases -- DHCP Leases & ACL Manager for pydhcpd (UniFi Hotspot edition)
#
# Reimplementation of pyleases.sh with extended directives and built-in
# UniFi Hotspot integration. Operates exclusively with pydhcpd as backend.
# Not compatible with isc-dhcp-server or any other DHCP daemon.
#
# DESCRIPTION:
# Operates on pydhcpd data. This is the reconciliation step, and its
# absence or failure aborts the whole reload chain.
#
# This script:
# - Drains the lease removal queue written by uhmd
# - Parses and cleans pydhcpd.leases
# - Detects unauthorized clients and adds them to block lists
# - Dynamically rebuilds pydhcpd.conf based on ACL sources
# - Applies static mappings (MAC -> IP) from ACL files
# - Detects duplicate entries across ACL sources: silently repairs the
#   lower-priority list, aborts only when mac-*.txt conflicts with itself
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Concurrency guard (always, whoever invoked it): waits up to 10s for the
#   mechanism lock, then skips gracefully (exit 0) if still held
# - Lease filtering and selective persistence
# - Automatic cleanup and normalization of ACL files
# - check_duplicate(): the single guard against duplicate ACL entries
#   (priority mac-*.txt > uhm-auth.txt > uhm-grace.txt > blockdhcp.txt),
#   called at the start and end of the run
# - check_mac_ip_ranges(): separate guard, mac-*.txt IPs landing inside a
#   reserved range, called alongside check_duplicate()
# - Configuration read from pydhcp.env (network, ACL paths, lease values)
#   and uhm.env (the uhm keys), in that order
# - Optional WPAD/PAC support (see WPAD/PAC OPTION below)
# - UniFi Hotspot integration
# - Grace period for unknown MACs before blocking
# - Lease removal queue: drains the queue file written by uhmd during the
#   safe stop->modify->start cycle
#
# REQUIREMENTS:
# - pydhcpd installed and running
# - ACL directories and files as defined in pydhcp.env
# - Root privileges
#
# ACL FORMATS:
# Standard (mac-*.txt, blockdhcp.txt):
# a;MAC;IP;HOSTNAME;
#
# Hotspot voucher (uhm-auth.txt):
# a;MAC;IP;HOSTNAME;END_TIME_EPOCH;
#
# Grace (uhm-grace.txt):
# a;MAC;IP;HOSTNAME;FIRST_SEEN_EPOCH;
#
# The leading "a" means "active" and marks a well-formed entry -- any other
# leading character is malformed (see normalize_acl_lists() below). There is
# no opposite value: to deactivate an entry, comment out the whole line with
# "#" instead of editing the "a" -- but only in mac-*.txt and uhm-auth.txt,
# the only two lists that ever produce a fixed-address host{} block in
# pydhcpd.conf (a commented entry there joins the blockdhcp deny class
# instead). blockdhcp.txt (already terminal), uhm-grace.txt (purely
# temporary) and uhm-queue.txt (a working list, no a;/#a; syntax at all)
# reject a leading "#" as malformed, same as any other invalid line.
#
# MALFORMED LINES:
# A malformed line in mac-*.txt or uhm-auth.txt aborts the run, naming the
# file and the line number. In blockdhcp.txt, uhm-grace.txt and
# uhm-queue.txt it is dropped from the file and the run continues.
#
# NOTES:
# - Designed for environments enforcing DHCP-based access control
# - Incorrect ACL data may disrupt IP assignments
#
# UNIFI HOTSPOT MODULE:
# Integration layer that:
# - Classifies pydhcpd.leases entries: managed (mac-limited.txt,
#   mac-unlimited.txt), voucher-authorized (uhm-auth), blocked (blockdhcp),
#   grace-period (uhm-grace), or new
# - New and uhm-grace clients keep their pydhcpd pool lease (no fixed-address
#   injection). Only uhm-auth clients receive a fixed hotspot-range IP.
# - Grace period (BLOCKDHCP_GRACE_SECONDS): any MAC detected in
#   pydhcpd.leases that is not in an authoritative ACL is added to
#   uhm-grace.txt with a timestamp. Regardless of reconnections, once the
#   timer expires the MAC moves permanently to blockdhcp.txt. The only exit
#   is manual removal or addition to mac-*.
#
# WPAD/PAC OPTION (option 252)
# If you need WPAD/PAC for proxy auto-configuration:
# 1. Install and configure Apache2
# 2. Create virtual host on the WPAD_PORT of pydhcp.env (default 18100)
# 3. Create wpad.pac file in Apache document root
# 4. Set WPAD_ENABLED=true in pydhcp.env
# The lines are only written if http://SERVER_IP:WPAD_PORT/wpad.pac answers 200
#
# NOTE on logging:
# - Writes to a log file shared with the rest of the reload chain.
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# logging
log_file="/var/log/uhm.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# log file perms (as installed by uhmsetup.sh)
log_stat=$(stat -c '%U %G %a' "$log_file" 2>/dev/null || true)
case "$log_stat" in
    ""|"root adm 640"|"root root 640") ;;
    *)
        if { chown root:adm "$log_file" 2>/dev/null || chown root:root "$log_file" 2>/dev/null; } &&
           chmod 640 "$log_file" 2>/dev/null; then
            log "WARNING: uhm.log perms fixed -- alert"
        else
            log "WARNING: cannot fix uhm.log perms -- alert"
        fi
        ;;
esac
unset log_stat

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# start
log "uhmleases start..."

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# CYCLE_LOCK is the mechanism lock, distinct from SCRIPT_LOCK above (which
# only prevents a second copy of this same script). It is acquired here
# unconditionally, whoever invoked this script -- the daemon cycle, its
# startup reload, uhmreload.sh, or a manual run -- because the protection
# belongs to the script that writes, not to whoever calls it. uhmreload.sh
# is a convenience wrapper around uhmleases.sh and uhmiptables.sh and may be
# replaced by two direct invocations at any time, so it must not be the one
# holding the guard.
#
# The descriptor is always opened here rather than reusing an inherited one:
# a lock taken on a descriptor the caller also holds open would not be
# released when this script exits, leaving the caller holding it silently.
# The daemon releases this lock before delegating, so opening it here never
# competes with a caller that still holds it.
#
# Held for the rest of the script execution, covering the whole
# stop->modify->start pydhcpd window, and released automatically on exit.
# uhmwatch.sh probes this same lock before deciding pydhcpd is OFFLINE, so
# holding it here is what tells the watchdog that the DHCP daemon is down on
# purpose and must not be restarted.
cycle_lock="/var/lock/uhmd-cycle.lock"
exec 201>"$cycle_lock"
if ! flock -w 10 201; then
    log "INFO: mechanism busy -- skip"
    log "uhmleases done at: $(date)"
    exit 0
fi

# Set by is_pydhcp() if pydhcpd fails to start (even after the backup-config
# restore attempt) -- checked at the very end of the script so the script
# own exit code reflects the real outcome instead of always returning 0.
# Without this, uhmreload.sh/uhmd.sh treat a completed-but-DHCP-down reload
# as a success and never alert.
pydhcpd_start_failed=0

temp_files=()
cleanup_temp() {
    local check_file
    for check_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$check_file" 2>/dev/null
    done
    # Lockfile is NOT removed: deleting it creates a TOCTOU race
    # where two processes could flock different inodes of the same path.
}
trap cleanup_temp EXIT

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

pydhcp_env="/etc/pydhcp/pydhcp.env"
env_file="/etc/uhm/uhm.env"
if [ ! -f "$env_file" ]; then
    log "ERROR: uhm.env not found, run uhmsetup.sh -- abort"
    exit 1
fi

env_owner=$(stat -c '%U' "$env_file" 2>/dev/null)
env_perms=$(stat -c '%a' "$env_file" 2>/dev/null)
if [[ "$env_owner" != "root" ]] || [[ "$env_perms" != "600" ]]; then
    if chown root:root "$env_file" 2>/dev/null && chmod 600 "$env_file" 2>/dev/null; then
        log "WARNING: uhm.env perms fixed -- alert"
    else
        log "ERROR: cannot fix uhm.env perms -- abort"
        exit 1
    fi
fi
unset env_owner env_perms

# Load only known KEY=VALUE pairs from ENV_FILE instead of sourcing it,
# so a tampered or maliciously replaced env file cannot execute code.
load_env_file() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        raw_key="$env_key" raw_value="$env_value"
        env_key="${env_key#"${env_key%%[![:space:]]*}"}"
        env_key="${env_key%"${env_key##*[![:space:]]}"}"
        env_value="${env_value#"${env_value%%[![:space:]]*}"}"
        env_value="${env_value%"${env_value##*[![:space:]]}"}"
        if [[ "$env_key" != "$raw_key" || "$env_value" != "$raw_value" ]]; then
            log "WARNING: stray whitespace fixed -- alert"
            log "WARNING: key $env_key"
        fi
        if [[ "$env_value" == \"*\" && "$env_value" == *\" && ${#env_value} -ge 2 ]]; then
            env_value="${env_value:1:$((${#env_value}-2))}"
        fi
        case "$env_key" in
            SERVER_IP|SERV_SUBNET|SERV_BROADCAST|SERV_MASK|SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK|SERV_DNS|\
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|UHM_PATH|\
            ACL_MAC_LIMITED|ACL_MAC_UNLIMITED|UHM_MACAUTH|ACL_BLOCK_FILE|\
            UHM_GRACE|BLOCKDHCP_GRACE_SECONDS|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|QUARANTINE_DURATION|WPAD_ENABLED|WPAD_PORT|PING_CHECK_ENABLED|\
            PING_TIMEOUT_SECONDS|UHM_INI_RANGE|UHM_END_RANGE|PYDHCPD_LEASES|\
            UHM_QUEUE|DHCPDv4_CONF|DAEMON_USER|DAEMON_GROUP)
                printf -v "$env_key" '%s' "$env_value"
                ;;
            *)
                ;;
        esac
    done < "$conf_file"
}
# pydhcp.env first: it owns the network, ACL and lease values, and is the
# single source of truth for them. uhm.env is read after, so the uhm keys
# win if a name ever collides.
if [ ! -r "$pydhcp_env" ]; then
    log "ERROR: cannot read $pydhcp_env -- abort"
    log "ERROR: uhm reads pydhcp's network and ACL values from it"
    exit 1
fi
load_env_file "$pydhcp_env"
load_env_file "$env_file"

if [ -z "${SERVER_IP:-}" ]; then
    log "ERROR: SERVER_IP not set -- abort"
    exit 1
fi

# dependencies
for dep_pkg in python3 mawk coreutils util-linux curl grep sed systemd libc-bin; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# IPv4 <-> integer. Callers validate with UH_IPV4 before calling, which
# rejects leading zeros. Ranges are compared as integers, so nothing below
# assumes a particular netmask or a three-octet prefix.
ip_to_int() {
    local octet_1 octet_2 octet_3 octet_4
    IFS='.' read -r octet_1 octet_2 octet_3 octet_4 <<< "$1"
    echo $(( (octet_1 << 24) + (octet_2 << 16) + (octet_3 << 8) + octet_4 ))
}

# Defaults for variables that may not exist in older uhm.env installations.
# These match the values documented in the README.md Config Reference table.
for range_var_name in UHM_INI_RANGE UHM_END_RANGE; do
    if [ -z "${!range_var_name:-}" ]; then
        log "ERROR: $range_var_name not set -- abort"
        exit 1
    fi
done
unset range_var_name
# Network values have no safe default: inventing one would rebuild
# pydhcpd.conf for a network that is not this one, and the DHCP server
# would hand out addresses nobody can reach. pysetup.sh always writes
# them, so a missing key means pydhcp.env was edited or truncated.
for required_key in SERV_MASK SERV_DNS SERV_SUBNET SERV_BROADCAST \
          SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERVER_IP; do
    if [ -z "${!required_key:-}" ]; then
        log "ERROR: $required_key not set in pydhcp.env"
        log "ERROR: re-run pydhcp pysetup.sh, or restore it -- abort"
        exit 1
    fi
done
unset required_key

for ip_var_name in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
    if ! [[ "${!ip_var_name}" =~ $UH_IPV4 ]]; then
        log "ERROR: $ip_var_name invalid IPv4 -- abort"
        exit 1
    fi
done
unset ip_var_name
if ! [[ "$SERV_MASK" =~ $UH_NETMASK ]]; then
    log "ERROR: SERV_MASK is not a valid netmask -- abort"
    exit 1
fi
if ! [[ "$SERV_DNS" =~ $UH_DNS ]]; then
    log "ERROR: SERV_DNS is not a valid IPv4 list -- abort"
    exit 1
fi
for range_var_name in UHM_INI_RANGE UHM_END_RANGE; do
    if ! [[ "${!range_var_name}" =~ $UH_IPV4 ]]; then
        log "ERROR: $range_var_name invalid IPv4 -- abort"
        exit 1
    fi
done
unset range_var_name
if (( $(ip_to_int "$UHM_INI_RANGE") > $(ip_to_int "$UHM_END_RANGE") )); then
    log "ERROR: UHM_INI_RANGE is above UHM_END_RANGE -- abort"
    exit 1
fi

# Guard: none of the three IP ranges/points this script writes into
# pydhcpd.conf may overlap one another -- SERVER_IP, the block-pool range
# (SERV_INI_RANGE_BLOCK-SERV_END_RANGE_BLOCK) and the hotspot voucher range
# (UHM_INI_RANGE-UHM_END_RANGE). pydhcpd.py only
# rejects the block-pool/SERVER_IP overlap, and only after this script has
# already stopped the daemon and rewritten pydhcpd.conf. Catching every
# combination here, before any destructive action, avoids leaving the daemon
# down over a config mistake that could have been caught up front.
range_conflict=$(python3 -c "
import ipaddress, sys
server_ip = ipaddress.IPv4Address(sys.argv[1])
pool_start = ipaddress.IPv4Address(sys.argv[2])
pool_end = ipaddress.IPv4Address(sys.argv[3])
hotspot_start = ipaddress.IPv4Address(sys.argv[4])
hotspot_end = ipaddress.IPv4Address(sys.argv[5])
if pool_start <= server_ip <= pool_end:
    print('SERVER_IP overlaps the block-pool range')
elif hotspot_start <= server_ip <= hotspot_end:
    print('SERVER_IP overlaps the hotspot range')
elif pool_start <= hotspot_end and hotspot_start <= pool_end:
    print('the block-pool range overlaps the hotspot range')
" "$SERVER_IP" "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK" "$UHM_INI_RANGE" "$UHM_END_RANGE" 2>/dev/null)
if [[ -n "$range_conflict" ]]; then
    log "ERROR: $range_conflict"
    log "ERROR: SERVER_IP=$SERVER_IP"
    log "ERROR: block-pool=$SERV_INI_RANGE_BLOCK-$SERV_END_RANGE_BLOCK"
    log "ERROR: hotspot=$UHM_INI_RANGE-$UHM_END_RANGE -- abort"
    exit 1
fi
unset range_conflict

# Every fallback below is composed from the directory above it, so each base
# path is named once instead of being repeated in full per file.
if [ -z "${ACL_PATH:-}" ]; then
    log "WARNING: no ACL_PATH in pydhcp.env -- fallback"
    ACL_PATH="/etc/acl"
fi
if [ -z "${ACL_MAC_PATH:-}" ]; then
    log "WARNING: no ACL_MAC_PATH in pydhcp.env -- fallback"
    ACL_MAC_PATH="$ACL_PATH/mac"
fi
if [ -z "${ACL_DHCP_PATH:-}" ]; then
    log "WARNING: no ACL_DHCP_PATH in pydhcp.env -- fallback"
    ACL_DHCP_PATH="/etc/pydhcp/acl"
fi
UHM_PATH="${UHM_PATH:-/etc/uhm}"
if [ -z "${ACL_MAC_LIMITED:-}" ]; then
    log "WARNING: no ACL_MAC_LIMITED in pydhcp.env -- fallback"
    ACL_MAC_LIMITED="$ACL_MAC_PATH/mac-limited.txt"
fi
if [ -z "${ACL_MAC_UNLIMITED:-}" ]; then
    log "WARNING: no ACL_MAC_UNLIMITED in pydhcp.env -- fallback"
    ACL_MAC_UNLIMITED="$ACL_MAC_PATH/mac-unlimited.txt"
fi
UHM_MACAUTH="${UHM_MACAUTH:-$UHM_PATH/acl/uhm-auth.txt}"
if [ -z "${ACL_BLOCK_FILE:-}" ]; then
    log "WARNING: no ACL_BLOCK_FILE in pydhcp.env -- fallback"
    ACL_BLOCK_FILE="$ACL_DHCP_PATH/blockdhcp.txt"
fi
if [ -z "${PYDHCPD_LEASES:-}" ]; then
    log "WARNING: no PYDHCPD_LEASES in pydhcp.env -- fallback"
    PYDHCPD_LEASES="/etc/pydhcp/core/pydhcpd.leases"
fi
DHCPDv4_CONF="${DHCPDv4_CONF:-/etc/pydhcp/core/pydhcpd.conf}"
UHM_GRACE="${UHM_GRACE:-$UHM_PATH/acl/uhm-grace.txt}"
BLOCKDHCP_GRACE_SECONDS="${BLOCKDHCP_GRACE_SECONDS:-86400}"
if ! [[ "$BLOCKDHCP_GRACE_SECONDS" =~ $UH_UINT ]]; then
    log "WARNING: BLOCKDHCP_GRACE_SECONDS invalid -- fallback"
    BLOCKDHCP_GRACE_SECONDS=86400
fi
if [ -z "${CLEANUP_INTERVAL:-}" ]; then
    log "WARNING: no CLEANUP_INTERVAL in pydhcp.env -- fallback"
    CLEANUP_INTERVAL="60"
fi
if ! [[ "$CLEANUP_INTERVAL" =~ $UH_UINT ]] || (( CLEANUP_INTERVAL == 0 )); then
    log "WARNING: CLEANUP_INTERVAL invalid -- fallback"
    CLEANUP_INTERVAL=60
fi
if [ -z "${AUTHORIZED_LEASE_TIME:-}" ]; then
    log "WARNING: no AUTHORIZED_LEASE_TIME in pydhcp.env -- fallback"
    AUTHORIZED_LEASE_TIME="2592000"
fi
if ! [[ "$AUTHORIZED_LEASE_TIME" =~ $UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
    log "WARNING: AUTHORIZED_LEASE_TIME invalid -- fallback"
    AUTHORIZED_LEASE_TIME=2592000
fi
if [ -z "${QUARANTINE_DURATION:-}" ]; then
    log "WARNING: no QUARANTINE_DURATION in pydhcp.env -- fallback"
    QUARANTINE_DURATION="60"
fi
if ! [[ "$QUARANTINE_DURATION" =~ $UH_UINT ]] || (( QUARANTINE_DURATION == 0 )); then
    log "WARNING: QUARANTINE_DURATION invalid -- fallback"
    QUARANTINE_DURATION=60
fi
if [ -z "${WPAD_ENABLED:-}" ]; then
    log "WARNING: no WPAD_ENABLED in pydhcp.env -- fallback"
    WPAD_ENABLED="false"
fi
if [ -z "${WPAD_PORT:-}" ]; then
    log "WARNING: no WPAD_PORT in pydhcp.env -- fallback"
    WPAD_PORT="18100"
fi
if ! [[ "$WPAD_PORT" =~ $UH_UINT ]] ||
   (( WPAD_PORT < 1 || WPAD_PORT > 65535 )); then
    log "WARNING: WPAD_PORT invalid -- fallback"
    WPAD_PORT=18100
fi
if [ -z "${PING_CHECK_ENABLED:-}" ]; then
    log "WARNING: no PING_CHECK_ENABLED in pydhcp.env -- fallback"
    PING_CHECK_ENABLED="true"
fi
if [ -z "${PING_TIMEOUT_SECONDS:-}" ]; then
    log "WARNING: no PING_TIMEOUT_SECONDS in pydhcp.env -- fallback"
    PING_TIMEOUT_SECONDS="1"
fi
if ! [[ "$PING_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( PING_TIMEOUT_SECONDS == 0 )); then
    log "WARNING: PING_TIMEOUT_SECONDS invalid -- fallback"
    PING_TIMEOUT_SECONDS=1
fi
UHM_QUEUE="${UHM_QUEUE:-$UHM_PATH/acl/uhm-queue.txt}"

wpad_url="http://$SERVER_IP:$WPAD_PORT/wpad.pac"
wpad_ready=0
if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
    if curl -fsS --noproxy '*' --max-time 5 -o /dev/null "$wpad_url"; then
        wpad_ready=1
    else
        log "WARNING: WPAD_ENABLED=true but not served -- fallback"
    fi
fi

if (( wpad_ready )); then
    wpad_header="option wpad code 252 = text;"
    wpad_subnet="option wpad \"$wpad_url\";"
else
    wpad_header="#option wpad code 252 = text;"
    wpad_subnet="#option wpad \"$wpad_url\";"
fi

if [[ "${PING_CHECK_ENABLED:-true}" == "true" ]]; then
    ping_check_line="ping-check true;"
    ping_timeout_line="ping-timeout ${PING_TIMEOUT_SECONDS};"
else
    ping_check_line="ping-check false;"
    ping_timeout_line=""
fi

verify_dhcp_service() {
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd is not running -- abort"
        exit 1
    fi
}

# Verifies the pydhcpd system user/group exist before any chown relies on
# them. Without this, a missing "pydhcpd" account (e.g. package removed or
# reinstalled without recreating its system user) would make chown fail
# with a raw, uncaught error instead of the usual clean
# "log + exit 1" pattern.
verify_dhcp_user() {
    if ! getent passwd pydhcpd &>/dev/null; then
        log "ERROR: system user 'pydhcpd' missing -- abort"
        exit 1
    fi
    if ! getent group pydhcpd &>/dev/null; then
        log "ERROR: system group 'pydhcpd' missing -- abort"
        exit 1
    fi
}

verify_dhcp_files() {
    if [ ! -d /etc/pydhcp ]; then
        log "ERROR: /etc/pydhcp does not exist -- abort"
        exit 1
    fi
    if [ ! -f "$PYDHCPD_LEASES" ]; then
        touch "$PYDHCPD_LEASES"
    fi
    chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$PYDHCPD_LEASES"
    chmod 640 "$PYDHCPD_LEASES"
}

verify_dhcp_config() {
    if [ ! -f "$DHCPDv4_CONF" ]; then
        log "ERROR: config file not found -- abort"
        exit 1
    fi
    chmod 640 "$DHCPDv4_CONF"
    chown root:"${DAEMON_GROUP:-pydhcpd}" "$DHCPDv4_CONF"
}

verify_directories() {
    for check_dir in "$ACL_MAC_PATH" "$ACL_DHCP_PATH"; do
        if [ ! -d "$check_dir" ]; then
            log "ERROR: directory $check_dir does not exist -- abort"
            exit 1
        fi
    done
    if [ ! -d "$UHM_PATH" ]; then
        log "ERROR: directory $UHM_PATH does not exist -- abort"
        exit 1
    fi
    local acl_hotspot_dir
    acl_hotspot_dir="$(dirname "$UHM_MACAUTH")"
    if [ ! -d "$acl_hotspot_dir" ]; then
        log "ERROR: directory $acl_hotspot_dir does not exist -- abort"
        exit 1
    fi
}

ensure_acl_lists() {
    local check_file file_owner file_perms
    for check_file in "$@"; do
        if [ ! -f "$check_file" ]; then
            touch "$check_file"
            chmod 600 "$check_file"
            chown root:root "$check_file"
            continue
        fi
        file_owner=$(stat -c '%U' "$check_file" 2>/dev/null)
        file_perms=$(stat -c '%a' "$check_file" 2>/dev/null)
        if [[ "$file_owner" != "root" ]] || [[ "$file_perms" != "600" ]]; then
            if chown root:root "$check_file" 2>/dev/null && chmod 600 "$check_file" 2>/dev/null; then
                log "WARNING: $(basename "$check_file") perms fixed -- alert"
            else
                log "ERROR: cannot fix $(basename "$check_file") perms -- abort"
                exit 1
            fi
        fi
    done
}

initialize_empty_files() {
    shopt -s nullglob
    local mac_lists=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    ensure_acl_lists "$ACL_BLOCK_FILE" "$ACL_MAC_LIMITED" "$ACL_MAC_UNLIMITED" \
        "$UHM_MACAUTH" "$UHM_GRACE" "$UHM_QUEUE" \
        "${mac_lists[@]+"${mac_lists[@]}"}"
}

# Guard: initialize_empty_files() above always creates mac-limited.txt and
# mac-unlimited.txt if missing, so this should never trigger -- kept as a
# defensive assertion in case ACL_MAC_PATH is repointed to a location that
# assumption does not hold for. Must run after initialize_empty_files().
verify_mac_files() {
    local mac_files
    shopt -s nullglob
    mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#mac_files[@]} == 0 )); then
        log "ERROR: no mac-*.txt in ACL_MAC_PATH -- abort"
        exit 1
    fi
}

# Normalizes every ACL list file before any parsing happens, then enforces
# the exact line format for that file. A malformed line there (stray
# character instead of "#", missing field, garbage MAC/IP) must never be
# silently skipped or half-applied -- it aborts the whole reload chain with
# the offending file/line/content, the same fail-safe-abort posture already
# used for ACL conflict detection.
#
# Only the two fixed-address lists -- mac-*.txt and uhm-auth.txt -- accept a
# leading "#" to deactivate an entry (see ACL FORMATS above): they are the
# only lists that ever produce a `host { fixed-address ... }` block in
# pydhcpd.conf, so "commented out" has a real meaning there (drop the fixed
# address, fall back to blockdhcp treatment). Every other list already means
# something final or purely temporary, where a "#" has no meaning and is
# therefore treated as a malformed line like any other:
# - blockdhcp.txt: already a terminal deny state -- nothing to deactivate.
# - uhm-grace.txt: purely temporary, self-expiring -- nothing to deactivate.
# - the lease removal queue: working list, single MAC per line, no
#   "a;"/"#a;" syntax at all.
#
# mac-*.txt / blockdhcp.txt: 4 fields, no epoch.
# uhm-auth.txt / uhm-grace.txt: 5 fields, epoch is the expiry/first-seen timestamp.
# lease removal queue: one bare MAC per line, no delimiters.
normalize_acl_file() {
    local acl_file="$1" line_pattern="${2:-}" validate_ip="${3:-1}" on_bad="${4:-abort}"
    local line_number=0 acl_line malformed_ip line_error tmp_file dropped_count=0

    [ -f "$acl_file" ] || return 0

    # Remove blank (now-empty) lines.
    sed -i '/^$/d' "$acl_file"

    if [[ -n "$line_pattern" ]]; then
        tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("$tmp_file")
        while IFS= read -r acl_line || [ -n "$acl_line" ]; do
            line_number=$((line_number + 1))
            line_error=""
            if ! [[ "$acl_line" =~ $line_pattern ]]; then
                line_error="malformed line $line_number"
            elif [[ "$validate_ip" == "1" ]]; then
                malformed_ip="$(printf '%s' "$acl_line" | cut -d';' -f3)"
                if [[ -n "$malformed_ip" ]] && ! [[ "$malformed_ip" =~ $UH_IPV4 ]]; then
                    line_error="invalid IP on line $line_number"
                fi
            fi
            if [[ -z "$line_error" ]]; then
                printf '%s\n' "$acl_line" >> "$tmp_file"
                continue
            fi
            if [[ "$on_bad" == "abort" ]]; then
                log "ERROR: $line_error in $(basename "$acl_file") -- abort"
                exit 1
            fi
            log "INFO: $line_error in $(basename "$acl_file") -- skip"
            dropped_count=$((dropped_count + 1))
        done < "$acl_file"
        if (( dropped_count > 0 )); then
            mv -f "$tmp_file" "$acl_file"
            chmod 600 "$acl_file"
            chown root:root "$acl_file"
        else
            rm -f "$tmp_file"
        fi
    fi

    # Ensure a trailing newline. tail -c1 grabs the last byte;
    # command substitution strips a trailing \n from its output, so
    # a non-empty result here means the last byte was NOT a newline.
    if [ -s "$acl_file" ] && [ -n "$(tail -c1 "$acl_file" 2>/dev/null)" ]; then
        log "INFO: adding trailing newline to $(basename "$acl_file")"
        printf '\n' >> "$acl_file"
    fi
}

# Log lines below do not carry the function name -- they use short,
# generic phrasing instead.
normalize_acl_lists() {
    local mac_files=() check_file
    local mac_re="$UH_MAC_RE"
    local ip_re='[0-9.]+'
    local host_re='[A-Za-z0-9._-]{1,63}'
    # Fixed-address lists: "#" is a valid way to deactivate an entry.
    local commentable_no_epoch_pattern="^#?a;${mac_re};${ip_re};${host_re};\$"
    local commentable_epoch_pattern="^#?a;${mac_re};${ip_re};${host_re};[0-9]+;\$"
    # Everything else: no "#" variant -- a leading "#" is malformed there.
    local strict_no_epoch_pattern="^a;${mac_re};${ip_re};${host_re};\$"
    local strict_epoch_pattern="^a;${mac_re};${ip_re};${host_re};[0-9]+;\$"
    local bare_mac_pattern="^${mac_re}\$"

    shopt -s nullglob
    mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for check_file in "${mac_files[@]}"; do
        normalize_acl_file "$check_file" "$commentable_no_epoch_pattern"
    done
    normalize_acl_file "$ACL_BLOCK_FILE" "$strict_no_epoch_pattern" 1 drop

    normalize_acl_file "$UHM_MACAUTH" "$commentable_epoch_pattern"
    normalize_acl_file "$UHM_GRACE" "$strict_epoch_pattern" 1 drop
    [ -f "$UHM_QUEUE" ] && normalize_acl_file "$UHM_QUEUE" "$bare_mac_pattern" 0 drop
}

# DUPLICATE GUARD
# Aborts if the same MAC is listed in more than one ACL file
# check_duplicate() is the single guard against duplicate ACL entries. Called
# twice: right after normalize_acl_lists (precondition -- catches a
# manually-edited/corrupt file before anything touches it) and again at the
# very end of the script (postcondition -- catches a bug in the processing
# done in between). Priority order: mac-*.txt (admin-owned, fatal on
# conflict) > uhm-auth.txt > uhm-grace.txt > blockdhcp.txt (owned by pydhcp,
# least relevant -- loses against any other list). No other function in this
# script does duplicate detection/removal -- everything related lives here.

# Silent self-defense: removes any active line from $1 whose MAC (field 2)
# either repeats within $1 itself or is already claimed by a higher-priority
# source among $3.. -- one pass, both checks share the same "seen" set.
dedup_mac_vs() {
    local acl_file="$1" acl_label="$2"; shift 2
    [ -f "$acl_file" ] || return 0
    local other_macs=""
    if (( $# > 0 )); then
        other_macs=$( { grep -hE '^#?a;' "$@" 2>/dev/null || true; } | awk -F';' '{print tolower($2)}' | sort -u )
    fi
    local tmp_file dropped_count mac_addr
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${tmp_file}")
    dropped_count=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${dropped_count}")
    awk -F';' -v others="$other_macs" -v outfile="$tmp_file" -v dropfile="$dropped_count" '
        BEGIN {
            n = split(others, arr, "\n")
            for (i = 1; i <= n; i++) if (arr[i] != "") seen[arr[i]] = 1
        }
        {
            if ($0 ~ /^a;/) {
                mac = tolower($2)
                if (mac in seen) { print mac >> dropfile; next }
                seen[mac] = 1
            }
            print >> outfile
        }
    ' "$acl_file"
    if [[ -s "$dropped_count" ]]; then
        if mv "$tmp_file" "$acl_file"; then
            chmod 600 "$acl_file"
            while IFS= read -r mac_addr; do
                log "INFO: dup MAC '$mac_addr' removed from $acl_label"
            done < "$dropped_count"
        else
            while IFS= read -r mac_addr; do
                log "WARNING: dup MAC '$mac_addr' write failed -- alert"
            done < "$dropped_count"
        fi
    fi
    rm -f "$tmp_file" "$dropped_count"
}

# uhm-auth.txt is the one list checked on 3 fields (MAC/IP/hostname) against
# itself, plus a MAC-only check against mac-*.txt (which always wins).
dedup_uhm_auth() {
    [ -f "$UHM_MACAUTH" ] || return 0
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    local mac_wins=""
    if (( ${#acl_mac_files[@]} > 0 )); then
        mac_wins=$( { grep -hE '^#?a;' "${acl_mac_files[@]}" 2>/dev/null || true; } | awk -F';' '{print tolower($2)}' | sort -u )
    fi
    local tmp_file dropped_count mac_addr
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${tmp_file}")
    dropped_count=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${dropped_count}")
    awk -F';' -v macwins_list="$mac_wins" -v outfile="$tmp_file" -v dropfile="$dropped_count" '
        BEGIN {
            n = split(macwins_list, arr, "\n")
            for (i = 1; i <= n; i++) if (arr[i] != "") macwins[arr[i]] = 1
        }
        {
            if ($0 ~ /^a;/) {
                mac = tolower($2)
                if (mac in macwins) { print mac >> dropfile; next }
                key = mac ";" $3 ";" tolower($4)
                if (key in seen) { print mac >> dropfile; next }
                seen[key] = 1
            }
            print >> outfile
        }
    ' "$UHM_MACAUTH"
    if [[ -s "$dropped_count" ]]; then
        if mv "$tmp_file" "$UHM_MACAUTH"; then
            chmod 600 "$UHM_MACAUTH"
            while IFS= read -r mac_addr; do
                log "INFO: dup MAC '$mac_addr' removed from uhm-auth.txt"
            done < "$dropped_count"
        else
            while IFS= read -r mac_addr; do
                log "WARNING: dup MAC '$mac_addr' write failed -- alert"
            done < "$dropped_count"
        fi
    fi
    rm -f "$tmp_file" "$dropped_count"
}

function check_duplicate() {
    # -- mac-*.txt vs itself: fatal, admin must fix by hand ------------------
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#acl_mac_files[@]} > 0 )); then
        local field_count field_name dup_macs dup_mac has_error=0
        for field_count in 2 3 4; do
            case $field_count in 2) field_name="MAC" ;; 3) field_name="IP" ;; 4) field_name="hostname" ;; esac
            if [[ "$field_count" == "2" ]]; then
                dup_macs=$(cut -d';' -f2 "${acl_mac_files[@]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
            else
                dup_macs=$(cut -d';' -f${field_count} "${acl_mac_files[@]}" 2>/dev/null | sort | uniq -d)
            fi
            if [[ -n "$dup_macs" ]]; then
                while IFS= read -r dup_mac; do
                    [[ -z "$dup_mac" ]] && continue
                    log "ERROR: duplicate $field_name ${dup_mac:0:20}"
                    has_error=1
                done <<< "$dup_macs"
            fi
        done
        if (( has_error )); then
            log "ERROR: mac-*.txt duplicate entry -- abort"
            exit 1
        fi
    fi

    # -- uhm-auth.txt vs itself (MAC/IP/hostname) and vs mac-*.txt (MAC) -----
    dedup_uhm_auth

    # -- uhm-grace.txt vs itself, mac-*.txt, uhm-auth.txt (MAC only) ---------
    dedup_mac_vs "$UHM_GRACE" "uhm-grace.txt" "${acl_mac_files[@]}" "$UHM_MACAUTH"

    # -- blockdhcp.txt vs itself and every other list (MAC only) -------------
    dedup_mac_vs "$ACL_BLOCK_FILE" "blockdhcp.txt" "${acl_mac_files[@]}" "$UHM_MACAUTH" "$UHM_GRACE"
}

# IP RANGE GUARD
# Aborts if the configured ranges overlap or fall outside the subnet
# mac-*.txt IPs are administrator-assigned, with no dedicated range in
# uhm.env (check README) -- only UHM_INI_RANGE/UHM_END_RANGE (uhm-auth.txt)
# and SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK (blockdhcp/uhm-grace pool)
# are defined there. A mac-*.txt IP landing inside either range is always a
# misconfiguration, regardless of whether a client currently holds it. This
# is unrelated to duplicate detection -- kept as its own guard, called
# alongside check_duplicate but never merged into it.
function check_mac_ip_ranges() {
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    [[ ${#mac_files[@]} -eq 0 ]] && return
    local hotspot_start_int hotspot_end_int pool_start_int pool_end_int client_ip_int server_ip_int netmask_int network_int broadcast_int has_error=0
    hotspot_start_int=$(ip_to_int "$UHM_INI_RANGE"); hotspot_end_int=$(ip_to_int "$UHM_END_RANGE")
    pool_start_int=$(ip_to_int "$SERV_INI_RANGE_BLOCK"); pool_end_int=$(ip_to_int "$SERV_END_RANGE_BLOCK")
    server_ip_int=$(ip_to_int "$SERVER_IP"); netmask_int=$(ip_to_int "$SERV_MASK")
    network_int=$(( $(ip_to_int "$SERV_SUBNET") & netmask_int ))
    broadcast_int=$(( network_int | (0xFFFFFFFF ^ netmask_int) ))
    local mac_addr client_ip acl_status
    while IFS=';' read -r acl_status mac_addr client_ip _; do
        [[ "$acl_status" != "a" || -z "$client_ip" ]] && continue
        [[ "$client_ip" =~ $UH_IPV4 ]] || continue
        client_ip_int=$(ip_to_int "$client_ip")
        if (( (client_ip_int & netmask_int) != network_int )); then
            log "ERROR: $mac_addr: IP outside subnet"
            has_error=1
        elif (( client_ip_int == network_int || client_ip_int == broadcast_int )); then
            log "ERROR: $mac_addr: IP is net/broadcast"
            has_error=1
        elif (( client_ip_int == server_ip_int )); then
            log "ERROR: $mac_addr: IP same as SERVER_IP"
            has_error=1
        elif (( client_ip_int >= hotspot_start_int && client_ip_int <= hotspot_end_int )); then
            log "ERROR: $mac_addr: IP inside hotspot range"
            has_error=1
        elif (( client_ip_int >= pool_start_int && client_ip_int <= pool_end_int )); then
            log "ERROR: $mac_addr: IP inside blockdhcp pool"
            has_error=1
        fi
    done < <(cat "${mac_files[@]}" 2>/dev/null)
    if (( has_error )); then
        log "ERROR: mac-*.txt IP conflict -- abort"
        exit 1
    fi
}

verify_dhcp_service
verify_dhcp_user
verify_dhcp_files
verify_dhcp_config
verify_directories
initialize_empty_files
verify_mac_files

normalize_acl_lists
check_duplicate
check_mac_ip_ranges

# Log lines below do not carry the function name -- they use short,
# generic phrasing instead.
function expire_grace_entries() {
    [ ! -f "$UHM_GRACE" ] && return
    local file_temp now_epoch lease_age acl_status mac_addr client_ip client_name entry_epoch
    file_temp=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${file_temp}")
    now_epoch=$(date +%s)
    # Malformed lines (bad status/MAC/epoch) are discarded here, not kept --
    # same posture clean_expired_macs() in uhmd.sh takes with an unreadable
    # END_TIME_EPOCH in uhm-auth.txt: a line whose timer cannot be read has
    # no expiry, so it is dropped rather than kept forever.
    # uhm-grace.txt is temporary and self-healing: its writers
    # (process_new_leases() in uhmd.sh and read_leases() here) always
    # write a fresh, valid epoch, so a MAC dropped here just gets re-added
    # correctly on its next DHCP lease renewal -- keeping the malformed line
    # would instead block that self-repair, since the MAC-match check in
    # those writers would see it as "already tracked" and never re-add a
    # valid entry for it.
    while IFS= read -r env_line; do
        IFS=';' read -r acl_status mac_addr client_ip client_name entry_epoch _ <<< "$env_line"
        if [[ "$acl_status" != "a" || -z "$mac_addr" || -z "$entry_epoch" ]] || ! [[ "$entry_epoch" =~ $UH_UINT ]]; then
            continue
        fi
        lease_age=$(( now_epoch - entry_epoch ))
        if (( lease_age >= BLOCKDHCP_GRACE_SECONDS )); then
            log "INFO: $mac_addr expired (age=${lease_age}s)"
            log "INFO: add $mac_addr to blockdhcp"
            if ! grep -qi "^a;${mac_addr};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                echo "a;${mac_addr};${client_ip};${client_name};" >> "$ACL_BLOCK_FILE"
            fi
            # Queue lease removal so pydhcpd stops serving this MAC from the pool.
            if ! grep -qxF "$mac_addr" "$UHM_QUEUE" 2>/dev/null; then
                echo "$mac_addr" >> "$UHM_QUEUE"
                log "INFO: queued removal for $mac_addr"
            fi
        else
            echo "a;${mac_addr};${client_ip};${client_name};${entry_epoch};" >> "$file_temp"
        fi
    done < "$UHM_GRACE"

    mv "$file_temp" "$UHM_GRACE"
    chmod 600 "$UHM_GRACE"
    chown root:root "$UHM_GRACE"
}

function is_pydhcp() {
    leases_file="$PYDHCPD_LEASES"
    dhcp_conf="$DHCPDv4_CONF"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX") || { log "ERROR: cannot create temp file in /etc/pydhcp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("$dhcp_conf_temp")

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function read_leases() {
        # grep returns exit 1 on no-match, which is legitimate here and must
        # not abort the script. Disable pipefail for the duration of this
        # function and restore it on return -- restore only if it was
        # actually on before (a plain "set -o pipefail" would wrongly
        # re-enable it for a caller that had it off).
        local pipefail_was_on=0
        [[ "$(set +o | grep -c 'set -o pipefail')" == "1" ]] && pipefail_was_on=1
        set +o pipefail

        local temp_leases
        temp_leases=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("$temp_leases")
        local current_lease=""
        local lease_content=""
        local total_seen=0
        local dropped_blocked=0

        while IFS= read -r acl_line; do
            if echo "$acl_line" | grep -qE '^lease [0-9.]+ \{$'; then
                current_lease="$acl_line"
                lease_content="$acl_line"$'\n'
                continue
            fi

            if [ -n "$current_lease" ]; then
                lease_content+="$acl_line"$'\n'
            fi

            if echo "$acl_line" | grep -q '^}$'; then
                if [ -n "$current_lease" ]; then
                    mac_address=$(echo "$lease_content" | grep -oE "$UH_MAC_RE" | head -1 | tr '[:upper:]' '[:lower:]')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    host_candidate=$(echo "$host_candidate" | tr -cd 'A-Za-z0-9._-' | cut -c1-63)
                    client_name="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$ip_address" ]] && ! [[ "$ip_address" =~ $UH_IPV4 ]]; then
                        log "INFO: invalid lease IP $ip_address -- skip"
                        ip_address=""
                    fi

                    if [[ -n "$mac_address" && -n "$ip_address" ]]; then
                        (( total_seen++ )) || true

                        # Authoritative: managed MAC (mac-*) or voucher-authenticated (uhm-auth).
                        mac_authoritative=""
                        grep -qi "^a;${mac_address};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null \
                            && mac_authoritative="yes" || true
                        if [[ -z "$mac_authoritative" ]]; then
                            grep -qi "^a;${mac_address};" "$UHM_MACAUTH" 2>/dev/null \
                                && mac_authoritative="yes" || true
                        fi

                        mac_deactivated=""
                        grep -qi "^#a;${mac_address};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null \
                            && mac_deactivated="yes" || true
                        if [[ -z "$mac_deactivated" ]]; then
                            grep -qi "^#a;${mac_address};" "$UHM_MACAUTH" 2>/dev/null \
                                && mac_deactivated="yes" || true
                        fi

                        if [[ -n "$mac_authoritative" ]]; then
                            echo "$lease_content" >> "$temp_leases"
                        elif [[ -n "$mac_deactivated" ]]; then
                            (( dropped_blocked++ )) || true
                        elif grep -qi "^a;${mac_address};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                            (( dropped_blocked++ )) || true
                        elif grep -qi "^a;${mac_address};" "$UHM_GRACE" 2>/dev/null; then
                            echo "$lease_content" >> "$temp_leases"
                        else
                            log "INFO: add $mac_address to uhm-grace"
                            log "INFO: ip=$ip_address hostname=${client_name:0:30}"
                            echo "a;${mac_address};${ip_address};${client_name};$(date +%s);" >> "$UHM_GRACE"
                            echo "$lease_content" >> "$temp_leases"
                        fi
                    fi
                    current_lease=""
                    lease_content=""
                fi
            fi
        done < "$leases_file"

        if [[ -s "$temp_leases" ]]; then
            mv -f "$temp_leases" "$leases_file"
        else
            local original_count=0
            original_count=$(grep -c '^lease ' "$leases_file" 2>/dev/null) || original_count=0
            if (( total_seen > 0 )) && (( total_seen == dropped_blocked )); then
                # Every lease block was successfully parsed and every single one
                # belongs to a MAC that is now in blockdhcp.txt -- a legitimately
                # empty result, not a parsing failure. Safe to clear.
                log "INFO: all $total_seen lease(s) belong to blocked MACs"
                log "INFO: clearing pydhcpd.leases"
                echo "" > "$leases_file"
                rm -f "$temp_leases"
            elif (( original_count > 0 )); then
                # Empty result NOT fully explained by blocked MACs (parsing
                # failure, unexpected code path, etc.) -- preserve the original
                # to avoid losing lease data on a transient/unknown failure.
                log "WARNING: pydhcpd.leases unreadable, file untouched -- alert"
                rm -f "$temp_leases"
            else
                echo "" > "$leases_file"
            fi
        fi
        chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$leases_file"
        chmod 640 "$leases_file"

        # Restore pipefail to whatever it was before entering this function.
        # Explicit "if" + "return 0" so the function success does not
        # depend on the pipefail_was_on value being truthy.
        if (( pipefail_was_on )); then
            set -o pipefail
        fi
        return 0
    }

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function update_dhcp_conf {
        echo "# pydhcpd Configuration
authoritative;
cleanup-interval $CLEANUP_INTERVAL;
abandon-lease-time $QUARANTINE_DURATION;
$wpad_header
server-identifier $SERVER_IP;
deny duplicates;
deny declines;
$ping_check_line
$ping_timeout_line
" >"$dhcp_conf_temp"

        shopt -s nullglob
        acl_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        if [ ${#acl_files[@]} -gt 0 ]; then
            acl_sources=$(cat "${acl_files[@]}")
        else
            acl_sources=""
        fi

        hotspot_normalized=$(awk -F';' 'NF>=5 && $2!="" && $3!=""{print $1";"$2";"$3";"$4";"}' \
            "$UHM_MACAUTH" 2>/dev/null || true)
        all_sources=$(printf '%s\n' "$acl_sources" "$hotspot_normalized" | sort -u)

        while IFS= read -r acl_line; do
            acl_status=$(echo "$acl_line" | cut -d ';' -f 1)
            mac_source=$(echo "$acl_line" | cut -d ';' -f 2)
            ip_source=$(echo "$acl_line" | cut -d ';' -f 3)
            user_source=$(echo "$acl_line" | cut -d ';' -f 4)
            if [[ $acl_status == "a" ]]; then
                # Validate every field before writing it into the config so an
                # ACL entry cannot inject arbitrary dhcpd directives.
                if ! [[ $mac_source =~ $UH_MAC ]]; then
                    log "INFO: invalid MAC $mac_source -- skip"
                    continue
                fi
                if ! [[ "$ip_source" =~ $UH_IPV4 ]]; then
                    log "INFO: invalid IP $ip_source -- skip"
                    continue
                fi
                if ! [[ $user_source =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "INFO: invalid hostname ${user_source:0:20} -- skip"
                    continue
                fi
                echo "
host $user_source {
    hardware ethernet $mac_source;
    fixed-address $ip_source;
}" >>"$dhcp_conf_temp"
            fi
        done <<< "$all_sources"

        # uhm-grace clients retain
        # their pydhcpd pool lease and need no fixed-address entry here.

        echo '
class "blockdhcp" {
    match pick-first-value (option dhcp-client-identifier, hardware);
}' >>"$dhcp_conf_temp"

        # Deactivated fixed-address entries -- commented "#a;mac;..." lines in
        # mac-*.txt or uhm-auth.txt, the only two lists that ever produce a
        # fixed-address host{} block above -- join blockdhcp.txt entries in
        # the same "blockdhcp" class: pydhcpd denies them a lease outright,
        # exactly like a blocked MAC.
        {
            cut -d ';' -f 2 "$ACL_BLOCK_FILE" 2>/dev/null
            grep -h '^#a;' "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null | cut -d ';' -f 2 || true
            grep -h '^#a;' "$UHM_MACAUTH" 2>/dev/null | cut -d ';' -f 2 || true
        } | grep -E "$UH_MAC" | tr '[:upper:]' '[:lower:]' | sort -u \
          | while IFS= read -r mac_list; do
                printf 'subclass "blockdhcp" 1:%s;\n' "$mac_list" >>"$dhcp_conf_temp"
            done || true

        echo "" >>"$dhcp_conf_temp"

        echo "subnet $SERV_SUBNET netmask $SERV_MASK {
    $wpad_subnet
    option routers $SERVER_IP;
    option broadcast-address $SERV_BROADCAST;
    option domain-name-servers $SERV_DNS;
    min-lease-time $AUTHORIZED_LEASE_TIME;
    default-lease-time $AUTHORIZED_LEASE_TIME;
    max-lease-time $AUTHORIZED_LEASE_TIME;
    # Pool for unknown clients only — a blocked MAC gets no IP at all, and
    # authorized hosts use the fixed-address reservations above
    pool {
        min-lease-time $CLEANUP_INTERVAL;
        default-lease-time $CLEANUP_INTERVAL;
        max-lease-time $CLEANUP_INTERVAL;
        deny members of \"blockdhcp\";
        range $SERV_INI_RANGE_BLOCK $SERV_END_RANGE_BLOCK;
    }
}" >>"$dhcp_conf_temp"

        # Keep a backup of the previous config in case the new one is faulty.
        [ -f "$dhcp_conf" ] && cp -f "$dhcp_conf" "${dhcp_conf}.bak"
        mv -f "$dhcp_conf_temp" "$dhcp_conf"
        chown root:"${DAEMON_GROUP:-pydhcpd}" "$dhcp_conf"
        chmod 640 "$dhcp_conf"
    }

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function clean_acl {
        log "INFO: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_LIMITED"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
        sed '/^$/d' -i "$UHM_MACAUTH"
        sed '/^$/d' -i "$UHM_GRACE"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
        sort -t';' -k3,3V "$UHM_MACAUTH" -o "$UHM_MACAUTH"
        sort -V "$UHM_GRACE" -o "$UHM_GRACE"
        # mac-*.txt: sorted by IP (field 3), same key as UHM_MACAUTH above.
        # Purely cosmetic -- update_dhcp_conf() and the pydhcpd.py host{} parsing
        # are both order-independent.
        shopt -s nullglob
        local order_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        local normalize_file
        for normalize_file in "${order_mac_files[@]}"; do
            sort -t';' -k3,3V "$normalize_file" -o "$normalize_file"
        done
    }

    expire_grace_entries

    clean_acl
    log "INFO: stopping pydhcpd"
    trap 'rm -f "${temp_files[@]}" 2>/dev/null; systemctl reset-failed pydhcpd 2>/dev/null; systemctl is-active --quiet pydhcpd || systemctl start pydhcpd' EXIT
    systemctl stop pydhcpd
    drain_lease_queue
    log "INFO: processing leases"
    read_leases
    log "INFO: sorting ACL files"
    order_files_acl
    log "INFO: rebuilding pydhcpd.conf"
    update_dhcp_conf
    log "INFO: starting pydhcpd"
    systemctl reset-failed pydhcpd 2>/dev/null || true
    systemctl start pydhcpd || true
    sleep 1
    if ! systemctl is-active --quiet pydhcpd; then
        log "WARNING: pydhcpd failed to start after rebuild -- fallback"
        if [ -f "${dhcp_conf}.bak" ]; then
            cp -f "${dhcp_conf}.bak" "$dhcp_conf"
            log "INFO: restored backup config, retrying start"
            systemctl reset-failed pydhcpd 2>/dev/null || true
            systemctl start pydhcpd || true
            sleep 1
            if ! systemctl is-active --quiet pydhcpd; then
                log "WARNING: pydhcpd down even with backup config -- alert"
                pydhcpd_start_failed=1
            else
                log "INFO: pydhcpd recovered with backup config"
            fi
        else
            log "WARNING: no backup config found -- alert"
            pydhcpd_start_failed=1
        fi
    fi
    trap cleanup_temp EXIT
}

# Log lines below do not carry the function name -- they use short,
# generic phrasing instead.
drain_lease_queue() {
    [[ ! -s "$UHM_QUEUE" ]] && return
    local dhcpd_leases="$PYDHCPD_LEASES"
    [[ ! -f "$dhcpd_leases" ]] && { : > "$UHM_QUEUE"; return; }

    local tmp_file removed_count=0
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${tmp_file}")
    local queue_macs
    queue_macs=$(tr '[:upper:]' '[:lower:]' < "$UHM_QUEUE" | sort -u)

    local in_block=0 block_line=""
    while IFS= read -r acl_line; do
        if echo "$acl_line" | grep -qE '^lease [0-9.]+ \{$'; then
            in_block=1; block_line="$acl_line"$'\n'; continue
        fi
        if [[ $in_block -eq 1 ]]; then
            block_line+="$acl_line"$'\n'
            if echo "$acl_line" | grep -q '^}$'; then
                in_block=0
                local lease_mac
                lease_mac=$(echo "$block_line" | { grep -oiE "$UH_MAC_RE" || true; } | head -1 | tr '[:upper:]' '[:lower:]')
                if [[ -n "$lease_mac" ]] && echo "$queue_macs" | grep -qxF "$lease_mac"; then
                    log "INFO: removing $lease_mac from leases"
                    (( removed_count++ )) || true
                else
                    printf '%s' "$block_line" >> "$tmp_file"
                fi
                block_line=""
            fi
            continue
        fi
        echo "$acl_line" >> "$tmp_file"
    done < "$dhcpd_leases"

    local before_leases after_leases
    before_leases=$(grep -c '^lease ' "$dhcpd_leases" 2>/dev/null) || before_leases=0
    after_leases=$(grep -c '^lease ' "$tmp_file" 2>/dev/null) || after_leases=0
    if (( before_leases - after_leases != removed_count )); then
        log "INFO: lease count mismatch ($before_leases/$after_leases) -- skip"
        rm -f "$tmp_file"
        return
    fi
    mv "$tmp_file" "$dhcpd_leases"
    chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd_leases"
    chmod 640 "$dhcpd_leases"
    if ! : > "$UHM_QUEUE" 2>/dev/null; then
        log "WARNING: cannot empty uhm-queue.txt -- alert"
    fi

    if (( removed_count > 0 )); then
        log "INFO: removed $removed_count lease(s)"
    fi
}

is_pydhcp

check_duplicate
check_mac_ip_ranges

# Final summary
count_active() { local active_count=0; active_count=$(grep -c '^a;' "$1" 2>/dev/null) || active_count=0; echo "$active_count"; }
log "blockdhcp=$(count_active "$ACL_BLOCK_FILE")|limited=$(count_active "$ACL_MAC_LIMITED")|unlimited=$(count_active "$ACL_MAC_UNLIMITED")|hotspot=$(count_active "$UHM_MACAUTH")|grace=$(count_active "$UHM_GRACE")"

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "uhmleases done at: $(date)"

if (( pydhcpd_start_failed )); then
    log "ERROR: pydhcpd is down -- abort"
    exit 1
fi
