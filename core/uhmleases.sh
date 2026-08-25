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
# lower-priority list, aborts only when mac-*.txt conflicts with itself
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Concurrency guard (always, whoever invoked it): waits up to 10s for the
# mechanism lock, then skips gracefully (exit 0) if still held
# - Lease filtering and selective persistence
# - Automatic cleanup and normalization of ACL files
# - check_duplicate(): the single guard against duplicate ACL entries
# (priority mac-*.txt > uhm-auth.txt > uhm-grace.txt > blockdhcp.txt),
# called at the start and end of the run
# - check_mac_ip_ranges(): separate guard, mac-*.txt IPs landing inside a
# reserved range, called alongside check_duplicate()
# - Configuration read from uhm.env
# - All paths, ACL files and network settings read from uhm.env
# - Optional WPAD/PAC support (see WPAD/PAC OPTION below)
# - UniFi Hotspot integration
# - Grace period for unknown MACs before blocking
# - Lease removal queue: drains the queue file written by uhmd during the
# safe stop->modify->start cycle
#
# REQUIREMENTS:
# - pydhcpd installed and running
# - ACL directories and files as defined in uhm.env
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
# leading character is malformed and aborts parsing (see
# normalize_acl_lists() below). There is no opposite value: to deactivate
# an entry, comment out the whole line with "#" instead of editing the "a" --
# but only in mac-*.txt and uhm-auth.txt, the only two lists that ever
# produce a fixed-address host{} block in pydhcpd.conf (a commented entry
# there joins the blockdhcp deny class instead). blockdhcp.txt (already
# terminal), uhm-grace.txt (purely temporary) and the lease removal queue
# (a working list, no a;/#a; syntax at all) reject a leading "#" as
# malformed, same as any other invalid line.
#
# NOTES:
# - Designed for environments enforcing DHCP-based access control
# - Incorrect ACL data may disrupt IP assignments
#
# UNIFI HOTSPOT MODULE:
# Integration layer that:
# - Classifies pydhcpd.leases entries: managed (mac-proxy.txt, mac-unlimited.txt),
# voucher-authorized (uhm-auth), blocked (blockdhcp), grace-period
# (uhm-grace), or new
# - New and uhm-grace clients keep their pydhcpd pool lease (no fixed-address
# injection). Only uhm-auth clients receive a fixed hotspot-range IP.
# - Grace period (BLOCKDHCP_GRACE_SECONDS): any MAC detected in pydhcpd.leases
# that is not in an authoritative ACL is added to uhm-grace.txt with a
# timestamp. Regardless of reconnections, once the timer expires the MAC
# moves permanently to blockdhcp.txt. The only exit is manual removal or
# addition to mac-*.
#
# WPAD/PAC OPTION (option 252)
# If you need WPAD/PAC for proxy auto-configuration:
# 1. Install and configure Apache2
# 2. Create virtual host on the WPAD_PORT of uhm.env (default 18100)
# 3. Create wpad.pac file in Apache document root
# 4. Set WPAD_ENABLED=true in uhm.env
# The lines are only written if http://SERVER_IP:WPAD_PORT/wpad.pac answers 200
#
# NOTE on logging:
# - Writes to a log file shared with the rest of the reload chain.
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
    log "WARNING: script $(basename "$0") is already running"
    exit 1
fi

# LOCAL USER detection (fallback when LOCAL_USER isn't set in uhm.env)
detect_local_user() {
    local uid_min uid_max
    local user uid best_user="" best_uid=999999

    uid_min=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_max=$(awk '/^UID_MAX/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    uid_max=${uid_max:-60000}

    while IFS=: read -r user _ uid _ _ _ shell; do
        [ "$user" = "root" ] && continue
        [ -z "$uid" ] && continue
        [ "$uid" -lt "$uid_min" ] && continue
        [ "$uid" -gt "$uid_max" ] && continue

        case "$shell" in
            */false|*/nologin) continue ;;
        esac

        id -nG "$user" 2>/dev/null | grep -qw sudo || continue

        if [ "$uid" -lt "$best_uid" ]; then
            best_uid="$uid"
            best_user="$user"
        fi
    done </etc/passwd

    [ -n "$best_user" ] || return 1
    echo "$best_user"
}

# Start
log "uhmleases start..."

# CYCLE_LOCK is the mechanism lock, distinct from SCRIPT_LOCK above (which
# only prevents a second copy of this same script). It is acquired here
# unconditionally, whoever invoked this script -- the daemon's cycle, its
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
# Held for the rest of this script's execution, covering the whole
# stop->modify->start pydhcpd window, and released automatically on exit.
# uhmwatch.sh probes this same lock before deciding pydhcpd is OFFLINE, so
# holding it here is what tells the watchdog that the DHCP daemon is down on
# purpose and must not be restarted.
CYCLE_LOCK="/var/lock/uhmd-cycle.lock"
exec 201>"$CYCLE_LOCK"
if ! flock -w 10 201; then
    log "INFO: mechanism busy -- skipping this run"
    log "uhmleases done (skipped)"
    exit 0
fi

# Set by is_pydhcp() if pydhcpd fails to start (even after the backup-config
# restore attempt) -- checked at the very end of the script so this script's
# own exit code reflects the real outcome instead of always returning 0.
# Without this, uhmreload.sh/uhmd.sh treat a completed-but-DHCP-down reload
# as a success and never alert.
PYDHCPD_START_FAILED=0

TEMP_FILES_TO_CLEAN=()
cleanup_temp() {
    local f
    for f in "${TEMP_FILES_TO_CLEAN[@]+"${TEMP_FILES_TO_CLEAN[@]}"}"; do
        rm -f "$f" 2>/dev/null
    done
    # Lockfile is NOT removed: deleting it creates a TOCTOU race
    # where two processes could flock different inodes of the same path.
}
trap cleanup_temp EXIT

ENV_FILE="/etc/uhm/uhm.env"
if [ ! -f "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE not found -- run uhmsetup.sh first"
    exit 1
fi

# Load only known KEY=VALUE pairs from ENV_FILE instead of sourcing it,
# so a tampered or maliciously replaced env file cannot execute code.
load_env_file() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
            value="${value:1:$((${#value}-2))}"
        fi
        case "$key" in
            SERVER_IP|SERV_SUBNET|SERV_BROADCAST|SERV_MASK|SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK|SERV_DNS|\
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|UHM_PATH|\
            ACL_MAC_PROXY|ACL_MAC_UNLIMITED|UHM_MACAUTH|ACL_BLOCK_FILE|\
            UHM_GRACE|BLOCKDHCP_GRACE_SECONDS|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|QUARANTINE_DURATION|WPAD_ENABLED|WPAD_PORT|PING_CHECK_ENABLED|\
            PING_TIMEOUT_SECONDS|LOCAL_USER|UHM_INI_RANGE|UHM_END_RANGE|PYDHCPD_LEASES|\
            UHM_QUEUE|DHCPDv4_CONF|DAEMON_USER|DAEMON_GROUP)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$ENV_FILE"

if [ -z "${SERVER_IP:-}" ]; then
    log "ERROR: SERVER_IP not set -- restore $ENV_FILE or re-run uhmsetup.sh"
    exit 1
fi

# Determine local user: prefer LOCAL_USER from uhm.env (the only reliable
# source when running from systemd without a TTY), then fall back to session detection.
local_user="${LOCAL_USER:-}"
if [ -z "$local_user" ] || ! id "$local_user" &>/dev/null 2>/dev/null; then
    local_user=$(detect_local_user) || local_user=""
fi
if [ -z "$local_user" ] || ! id "$local_user" &>/dev/null; then
    log "ERROR: cannot determine valid local user, set LOCAL_USER in $ENV_FILE"
    exit 1
fi
log "INFO: Using local user: $local_user"

# DEPENDENCIES
for dep in python3 mawk coreutils util-linux curl grep sed systemd libc-bin; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: missing package '$dep' -- install with: apt install $dep"
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
_UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
_UH_MAC='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
_UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# IPv4 <-> integer. Callers validate with _UH_IPV4 before calling, which
# rejects leading zeros. Ranges are compared as integers, so nothing below
# assumes a particular netmask or a three-octet prefix.
_ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Defaults for variables that may not exist in older uhm.env installations.
# These match the values documented in README.md's Config Reference table.
for _r_var in UHM_INI_RANGE UHM_END_RANGE; do
    if [ -z "${!_r_var:-}" ]; then
        log "ERROR: $_r_var not set -- restore $ENV_FILE"
        exit 1
    fi
done
unset _r_var
SERV_MASK="${SERV_MASK:-255.255.255.0}"
SERV_DNS="${SERV_DNS:-8.8.8.8,1.1.1.1}"
SERV_SUBNET="${SERV_SUBNET:-192.168.0.0}"
SERV_BROADCAST="${SERV_BROADCAST:-192.168.0.255}"
SERV_INI_RANGE_BLOCK="${SERV_INI_RANGE_BLOCK:-192.168.0.230}"
SERV_END_RANGE_BLOCK="${SERV_END_RANGE_BLOCK:-192.168.0.239}"

for _ip_var in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
    if ! [[ "${!_ip_var}" =~ $_UH_IPV4 ]]; then
        log "ERROR: $_ip_var is not a valid IPv4 address -- check $ENV_FILE"
        exit 1
    fi
done
unset _ip_var
if ! [[ "$SERV_MASK" =~ $_UH_NETMASK ]]; then
    log "ERROR: SERV_MASK is not a valid netmask -- check $ENV_FILE"
    exit 1
fi
if ! [[ "$SERV_DNS" =~ $_UH_DNS ]]; then
    log "ERROR: SERV_DNS is not a valid IPv4 list -- check $ENV_FILE"
    exit 1
fi
for _r_var in UHM_INI_RANGE UHM_END_RANGE; do
    if ! [[ "${!_r_var}" =~ $_UH_IPV4 ]]; then
        log "ERROR: $_r_var is not a valid IPv4 address -- check $ENV_FILE"
        exit 1
    fi
done
unset _r_var
if (( $(_ip_to_int "$UHM_INI_RANGE") > $(_ip_to_int "$UHM_END_RANGE") )); then
    log "ERROR: hotspot range reversed: UHM_INI_RANGE > UHM_END_RANGE"
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
_range_conflict=$(python3 -c "
import ipaddress, sys
server = ipaddress.IPv4Address(sys.argv[1])
pool_s = ipaddress.IPv4Address(sys.argv[2])
pool_e = ipaddress.IPv4Address(sys.argv[3])
hot_s = ipaddress.IPv4Address(sys.argv[4])
hot_e = ipaddress.IPv4Address(sys.argv[5])
if pool_s <= server <= pool_e:
    print('SERVER_IP overlaps the block-pool range')
elif hot_s <= server <= hot_e:
    print('SERVER_IP overlaps the hotspot range')
elif pool_s <= hot_e and hot_s <= pool_e:
    print('the block-pool range overlaps the hotspot range')
" "$SERVER_IP" "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK" "$UHM_INI_RANGE" "$UHM_END_RANGE" 2>/dev/null)
if [[ -n "$_range_conflict" ]]; then
    log "ERROR: $_range_conflict in $ENV_FILE"
    log "ERROR: SERVER_IP=$SERVER_IP"
    log "ERROR: block-pool=$SERV_INI_RANGE_BLOCK-$SERV_END_RANGE_BLOCK"
    log "ERROR: hotspot=$UHM_INI_RANGE-$UHM_END_RANGE overlaps pool"
    exit 1
fi
unset _range_conflict

# Every fallback below is composed from the directory above it, so each base
# path is named once instead of being repeated in full per file.
ACL_PATH="${ACL_PATH:-/etc/acl}"
ACL_MAC_PATH="${ACL_MAC_PATH:-$ACL_PATH/acl_mac}"
ACL_DHCP_PATH="${ACL_DHCP_PATH:-$ACL_PATH/acl_dhcp}"
UHM_PATH="${UHM_PATH:-/etc/uhm}"
ACL_MAC_PROXY="${ACL_MAC_PROXY:-$ACL_MAC_PATH/mac-proxy.txt}"
ACL_MAC_UNLIMITED="${ACL_MAC_UNLIMITED:-$ACL_MAC_PATH/mac-unlimited.txt}"
UHM_MACAUTH="${UHM_MACAUTH:-$UHM_PATH/acl/uhm-auth.txt}"
ACL_BLOCK_FILE="${ACL_BLOCK_FILE:-$ACL_DHCP_PATH/blockdhcp.txt}"
PYDHCPD_LEASES="${PYDHCPD_LEASES:-/etc/pydhcp/pydhcpd.leases}"
DHCPDv4_CONF="${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
UHM_GRACE="${UHM_GRACE:-$UHM_PATH/acl/uhm-grace.txt}"
BLOCKDHCP_GRACE_SECONDS="${BLOCKDHCP_GRACE_SECONDS:-86400}"
if ! [[ "$BLOCKDHCP_GRACE_SECONDS" =~ $_UH_UINT ]]; then
    log "WARNING: BLOCKDHCP_GRACE_SECONDS invalid -- fallback"
    BLOCKDHCP_GRACE_SECONDS=86400
fi
CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-60}"
if ! [[ "$CLEANUP_INTERVAL" =~ $_UH_UINT ]] || (( CLEANUP_INTERVAL == 0 )); then
    log "WARNING: CLEANUP_INTERVAL invalid -- fallback"
    CLEANUP_INTERVAL=60
fi
AUTHORIZED_LEASE_TIME="${AUTHORIZED_LEASE_TIME:-2592000}"
if ! [[ "$AUTHORIZED_LEASE_TIME" =~ $_UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
    log "WARNING: AUTHORIZED_LEASE_TIME invalid -- fallback"
    AUTHORIZED_LEASE_TIME=2592000
fi
QUARANTINE_DURATION="${QUARANTINE_DURATION:-60}"
if ! [[ "$QUARANTINE_DURATION" =~ $_UH_UINT ]] || (( QUARANTINE_DURATION == 0 )); then
    log "WARNING: QUARANTINE_DURATION invalid -- fallback"
    QUARANTINE_DURATION=60
fi
WPAD_ENABLED="${WPAD_ENABLED:-false}"
WPAD_PORT="${WPAD_PORT:-18100}"
if ! [[ "$WPAD_PORT" =~ $_UH_UINT ]] ||
   (( WPAD_PORT < 1 || WPAD_PORT > 65535 )); then
    log "WARNING: WPAD_PORT invalid -- fallback"
    WPAD_PORT=18100
fi
PING_CHECK_ENABLED="${PING_CHECK_ENABLED:-true}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
if ! [[ "$PING_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || (( PING_TIMEOUT_SECONDS == 0 )); then
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
        log "WARNING: WPAD_ENABLED=true but $wpad_url not served"
        log "WARNING: set WPAD_ENABLED=false in $ENV_FILE, see README"
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
        log "ERROR: pydhcpd is not running"
        exit 1
    fi
}

# Verifies the pydhcpd system user/group exist before any chown relies on
# them. Without this, a missing "pydhcpd" account (e.g. package removed or
# reinstalled without recreating its system user) would make chown fail
# with a raw, uncaught error instead of the script's usual clean
# "log + exit 1" pattern.
verify_dhcp_user() {
    if ! getent passwd pydhcpd &>/dev/null; then
        log "ERROR: system user 'pydhcpd' missing -- is pydhcpd installed?"
        exit 1
    fi
    if ! getent group pydhcpd &>/dev/null; then
        log "ERROR: system group 'pydhcpd' missing -- is pydhcpd installed?"
        exit 1
    fi
}

verify_dhcp_files() {
    if [ ! -d /etc/pydhcp ]; then
        log "ERROR: /etc/pydhcp does not exist. Is pydhcpd installed?"
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
        log "ERROR: $DHCPDv4_CONF does not exist"
        exit 1
    fi
    chmod 640 "$DHCPDv4_CONF"
    chown root:"${DAEMON_GROUP:-pydhcpd}" "$DHCPDv4_CONF"
}

verify_directories() {
    for dir in "$ACL_MAC_PATH" "$ACL_DHCP_PATH"; do
        if [ ! -d "$dir" ]; then
            log "ERROR: Directory $dir does not exist"
            exit 1
        fi
    done
    if [ ! -d "$UHM_PATH" ]; then
        log "ERROR: Directory $UHM_PATH does not exist"
        exit 1
    fi
    local acl_hotspot_dir
    acl_hotspot_dir="$(dirname "$UHM_MACAUTH")"
    if [ ! -d "$acl_hotspot_dir" ]; then
        log "ERROR: Directory $acl_hotspot_dir does not exist"
        exit 1
    fi
}

ensure_acl_lists() {
    local f
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            touch "$f"
            chmod 600 "$f"
            chown root:root "$f"
        fi
    done
}

initialize_empty_files() {
    ensure_acl_lists "$ACL_BLOCK_FILE" "$ACL_MAC_PROXY" "$ACL_MAC_UNLIMITED" \
        "$UHM_MACAUTH" "$UHM_GRACE" "$UHM_QUEUE"
}

# Guard: initialize_empty_files() above always creates mac-proxy.txt and
# mac-unlimited.txt if missing, so this should never trigger -- kept as a
# defensive assertion in case ACL_MAC_PATH is repointed to a location that
# assumption doesn't hold for. Must run after initialize_empty_files().
verify_mac_files() {
    local mac_files
    shopt -s nullglob
    mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#mac_files[@]} == 0 )); then
        log "ERROR: no mac-*.txt files found in $ACL_MAC_PATH"
        log "ERROR: check ACL_MAC_PROXY/ACL_MAC_UNLIMITED in uhm.env"
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
_normalize_acl_file() {
    local f="$1" pattern="${2:-}" validate_ip="${3:-1}" n=0 line _nf_ip

    [ -f "$f" ] || return 0

    # Remove blank (now-empty) lines.
    sed -i '/^$/d' "$f"

    if [[ -n "$pattern" ]]; then
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            if ! [[ "$line" =~ $pattern ]]; then
                log "ERROR: malformed line $n in $(basename "$f"): $line"
                exit 1
            fi
            if [[ "$validate_ip" == "1" ]]; then
                _nf_ip="$(printf '%s' "$line" | cut -d';' -f3)"
                if [[ -n "$_nf_ip" ]] && ! [[ "$_nf_ip" =~ $_UH_IPV4 ]]; then
                    log "ERROR: invalid IP on line $n in $(basename "$f"): $_nf_ip"
                    exit 1
                fi
            fi
        done < "$f"
    fi

    # Ensure a trailing newline. tail -c1 grabs the file's last byte;
    # command substitution strips a trailing \n from its output, so
    # a non-empty result here means the last byte was NOT a newline.
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
        log "INFO: adding trailing newline to $(basename "$f")"
        printf '\n' >> "$f"
    fi
}

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
normalize_acl_lists() {
    local mac_files=() f
    local mac_re='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
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
    for f in "${mac_files[@]}"; do
        _normalize_acl_file "$f" "$commentable_no_epoch_pattern"
    done
    _normalize_acl_file "$ACL_BLOCK_FILE" "$strict_no_epoch_pattern"

    _normalize_acl_file "$UHM_MACAUTH" "$commentable_epoch_pattern"
    _normalize_acl_file "$UHM_GRACE" "$strict_epoch_pattern"
    [ -f "$UHM_QUEUE" ] && _normalize_acl_file "$UHM_QUEUE" "$bare_mac_pattern" 0
}

# -- Duplicate guard -----------------------------------------------------------
# check_duplicate() is the single guard against duplicate ACL entries. Called
# twice: right after normalize_acl_lists (precondition -- catches a
# manually-edited/corrupt file before anything touches it) and again at the
# very end of the script (postcondition -- catches a bug in the script's own
# processing in between). Priority order: mac-*.txt (admin-owned, fatal on
# conflict) > uhm-auth.txt > uhm-grace.txt > blockdhcp.txt (owned by pydhcp,
# least relevant -- loses against any other list). No other function in this
# script does duplicate detection/removal -- everything related lives here.

# Silent self-defense: removes any active line from $1 whose MAC (field 2)
# either repeats within $1 itself or is already claimed by a higher-priority
# source among $3.. -- one pass, both checks share the same "seen" set.
_dedup_mac_vs() {
    local f="$1" label="$2"; shift 2
    [ -f "$f" ] || return 0
    local other_macs=""
    if (( $# > 0 )); then
        other_macs=$( { grep -hE '^#?a;' "$@" 2>/dev/null || true; } | awk -F';' '{print tolower($2)}' | sort -u )
    fi
    local tmp dropped mac
    tmp=$(mktemp); TEMP_FILES_TO_CLEAN+=("${tmp}")
    dropped=$(mktemp); TEMP_FILES_TO_CLEAN+=("${dropped}")
    awk -F';' -v others="$other_macs" -v outfile="$tmp" -v dropfile="$dropped" '
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
    ' "$f"
    if [[ -s "$dropped" ]]; then
        if mv "$tmp" "$f"; then
            chmod 600 "$f"
            while IFS= read -r mac; do
                log "INFO: dup MAC '$mac' removed from $label"
            done < "$dropped"
        else
            while IFS= read -r mac; do
                log "WARNING: dup MAC '$mac' unresolved -- cause unknown"
            done < "$dropped"
        fi
    fi
    rm -f "$tmp" "$dropped"
}

# uhm-auth.txt is the one list checked on 3 fields (MAC/IP/hostname) against
# itself, plus a MAC-only check against mac-*.txt (which always wins).
_dedup_uhm_auth() {
    [ -f "$UHM_MACAUTH" ] || return 0
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    local mac_wins=""
    if (( ${#acl_mac_files[@]} > 0 )); then
        mac_wins=$( { grep -hE '^#?a;' "${acl_mac_files[@]}" 2>/dev/null || true; } | awk -F';' '{print tolower($2)}' | sort -u )
    fi
    local tmp dropped mac
    tmp=$(mktemp); TEMP_FILES_TO_CLEAN+=("${tmp}")
    dropped=$(mktemp); TEMP_FILES_TO_CLEAN+=("${dropped}")
    awk -F';' -v macwins_list="$mac_wins" -v outfile="$tmp" -v dropfile="$dropped" '
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
    if [[ -s "$dropped" ]]; then
        if mv "$tmp" "$UHM_MACAUTH"; then
            chmod 600 "$UHM_MACAUTH"
            while IFS= read -r mac; do
                log "INFO: dup MAC '$mac' removed from uhm-auth.txt"
            done < "$dropped"
        else
            while IFS= read -r mac; do
                log "WARNING: dup MAC '$mac' unresolved -- cause unknown"
            done < "$dropped"
        fi
    fi
    rm -f "$tmp" "$dropped"
}

function check_duplicate() {
    # -- mac-*.txt vs itself: fatal, admin must fix by hand ------------------
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#acl_mac_files[@]} > 0 )); then
        local field field_name dups dup locations has_error=0
        for field in 2 3 4; do
            case $field in 2) field_name="MAC" ;; 3) field_name="IP" ;; 4) field_name="hostname" ;; esac
            if [[ "$field" == "2" ]]; then
                dups=$(cut -d';' -f2 "${acl_mac_files[@]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
            else
                dups=$(cut -d';' -f${field} "${acl_mac_files[@]}" 2>/dev/null | sort | uniq -d)
            fi
            if [[ -n "$dups" ]]; then
                while IFS= read -r dup; do
                    [[ -z "$dup" ]] && continue
                    locations=$(grep -liF ";${dup};" "${acl_mac_files[@]}" 2>/dev/null | tr '\n' ' ')
                    log "ERROR: duplicate $field_name '$dup' in: $locations"
                    has_error=1
                done <<< "$dups"
            fi
        done
        if (( has_error )); then
            log "ERROR: ACL configuration error detected -- abort"
            exit 1
        fi
    fi

    # -- uhm-auth.txt vs itself (MAC/IP/hostname) and vs mac-*.txt (MAC) -----
    _dedup_uhm_auth

    # -- uhm-grace.txt vs itself, mac-*.txt, uhm-auth.txt (MAC only) ---------
    _dedup_mac_vs "$UHM_GRACE" "uhm-grace.txt" "${acl_mac_files[@]}" "$UHM_MACAUTH"

    # -- blockdhcp.txt vs itself and every other list (MAC only) -------------
    _dedup_mac_vs "$ACL_BLOCK_FILE" "blockdhcp.txt" "${acl_mac_files[@]}" "$UHM_MACAUTH" "$UHM_GRACE"
}

# -- IP range guard --------------------------------------------------------
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
    local _hot_i _hot_e _pool_i _pool_e _ip_n _srv_n _mask_n _net_n _bcast_n has_error=0
    _hot_i=$(_ip_to_int "$UHM_INI_RANGE"); _hot_e=$(_ip_to_int "$UHM_END_RANGE")
    _pool_i=$(_ip_to_int "$SERV_INI_RANGE_BLOCK"); _pool_e=$(_ip_to_int "$SERV_END_RANGE_BLOCK")
    _srv_n=$(_ip_to_int "$SERVER_IP"); _mask_n=$(_ip_to_int "$SERV_MASK")
    _net_n=$(( $(_ip_to_int "$SERV_SUBNET") & _mask_n ))
    _bcast_n=$(( _net_n | (0xFFFFFFFF ^ _mask_n) ))
    local mac ip status
    while IFS=';' read -r status mac ip _; do
        [[ "$status" != "a" || -z "$ip" ]] && continue
        [[ "$ip" =~ $_UH_IPV4 ]] || continue
        _ip_n=$(_ip_to_int "$ip")
        if (( (_ip_n & _mask_n) != _net_n )); then
            log "ERROR: mac-*.txt IP conflict: $mac outside subnet"
            has_error=1
        elif (( _ip_n == _net_n || _ip_n == _bcast_n )); then
            log "ERROR: mac-*.txt IP conflict: $mac is net/broadcast"
            has_error=1
        elif (( _ip_n == _srv_n )); then
            log "ERROR: mac-*.txt IP conflict: $mac same as SERVER_IP"
            has_error=1
        elif (( _ip_n >= _hot_i && _ip_n <= _hot_e )); then
            log "ERROR: mac-*.txt IP conflict: $mac inside hotspot range"
            has_error=1
        elif (( _ip_n >= _pool_i && _ip_n <= _pool_e )); then
            log "ERROR: mac-*.txt IP conflict: $mac inside blockdhcp pool"
            has_error=1
        fi
    done < <(cat "${mac_files[@]}" 2>/dev/null)
    if (( has_error )); then
        log "ERROR: ACL configuration error detected -- abort"
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

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
function expire_grace_entries() {
    [ ! -f "$UHM_GRACE" ] && return
    local file_temp now_epoch age status mac ip hostname epoch
    file_temp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${file_temp}")
    now_epoch=$(date +%s)
    # Malformed lines (bad status/MAC/epoch) are discarded here, not kept --
    # the opposite of clean_expired_macs() in uhmd.sh, which keeps
    # malformed lines in uhm-auth.txt (a permanent-authorization list,
    # where erring toward not revoking a real client is the safer default).
    # uhm-grace.txt is temporary and self-healing instead: its writers
    # (process_new_leases() in uhmd.sh and read_leases() here) always
    # write a fresh, valid epoch, so a MAC dropped here just gets re-added
    # correctly on its next DHCP lease renewal -- keeping the malformed line
    # would instead block that self-repair, since the MAC-match check in
    # those writers would see it as "already tracked" and never re-add a
    # valid entry for it.
    while IFS= read -r _line; do
        IFS=';' read -r status mac ip hostname epoch _ <<< "$_line"
        if [[ "$status" != "a" || -z "$mac" || -z "$epoch" ]] || ! [[ "$epoch" =~ $_UH_UINT ]]; then
            log "WARNING: malformed line $mac -- skip"
            continue
        fi
        age=$(( now_epoch - epoch ))
        if (( age >= BLOCKDHCP_GRACE_SECONDS )); then
            log "INFO: $mac expired (age=${age}s)"
            log "INFO: add $mac to blockdhcp"
            if ! grep -qi "^a;${mac};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                echo "a;${mac};${ip};${hostname};" >> "$ACL_BLOCK_FILE"
            fi
            # Queue lease removal so pydhcpd stops serving this MAC from the pool.
            if ! grep -qxF "$mac" "$UHM_QUEUE" 2>/dev/null; then
                echo "$mac" >> "$UHM_QUEUE"
                log "INFO: queued removal for $mac"
            fi
        else
            echo "a;${mac};${ip};${hostname};${epoch};" >> "$file_temp"
        fi
    done < "$UHM_GRACE"

    mv "$file_temp" "$UHM_GRACE"
    chmod 600 "$UHM_GRACE"
    chown root:root "$UHM_GRACE"
}

function is_pydhcp() {
    dhcpd="$PYDHCPD_LEASES"
    dhcp_conf="$DHCPDv4_CONF"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX")
    TEMP_FILES_TO_CLEAN+=("$dhcp_conf_temp")

    # Log lines below do not carry this function's name -- they use short,
    # generic phrasing instead.
    function read_leases() {
        # grep returns exit 1 on no-match, which is legitimate here and must
        # not abort the script. Disable pipefail for the duration of this
        # function and restore it on return -- restore only if it was
        # actually on before (a plain "set -o pipefail" would wrongly
        # re-enable it for a caller that had it off).
        local _pipefail_was_on=0
        [[ "$(set +o | grep -c 'set -o pipefail')" == "1" ]] && _pipefail_was_on=1
        set +o pipefail

        local temp_leases
        temp_leases=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("$temp_leases")
        local current_lease=""
        local lease_content=""
        local total_seen=0
        local dropped_blocked=0

        while IFS= read -r line; do
            if echo "$line" | grep -qE '^lease [0-9.]+ \{$'; then
                current_lease="$line"
                lease_content="$line"$'\n'
                continue
            fi

            if [ -n "$current_lease" ]; then
                lease_content+="$line"$'\n'
            fi

            if echo "$line" | grep -q '^}$'; then
                if [ -n "$current_lease" ]; then
                    mac_address=$(echo "$lease_content" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 | tr '[:upper:]' '[:lower:]')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    host_candidate=$(echo "$host_candidate" | tr -cd 'A-Za-z0-9._-' | cut -c1-63)
                    host="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$ip_address" ]] && ! [[ "$ip_address" =~ $_UH_IPV4 ]]; then
                        log "WARNING: skipping lease with invalid IP: $ip_address"
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
                            log "INFO: ip=$ip_address host=${host:0:30}"
                            echo "a;${mac_address};${ip_address};${host};$(date +%s);" >> "$UHM_GRACE"
                            echo "$lease_content" >> "$temp_leases"
                        fi
                    fi
                    current_lease=""
                    lease_content=""
                fi
            fi
        done < "$dhcpd"

        if [[ -s "$temp_leases" ]]; then
            mv -f "$temp_leases" "$dhcpd"
        else
            local original_count=0
            original_count=$(grep -c '^lease ' "$dhcpd" 2>/dev/null) || original_count=0
            if (( total_seen > 0 )) && (( total_seen == dropped_blocked )); then
                # Every lease block was successfully parsed and every single one
                # belongs to a MAC that is now in blockdhcp.txt -- a legitimately
                # empty result, not a parsing failure. Safe to clear.
                log "INFO: all $total_seen lease(s) belong to blocked MACs"
                log "INFO: clearing $dhcpd"
                echo "" > "$dhcpd"
                rm -f "$temp_leases"
            elif (( original_count > 0 )); then
                # Empty result NOT fully explained by blocked MACs (parsing
                # failure, unexpected code path, etc.) -- preserve the original
                # to avoid losing lease data on a transient/unknown failure.
                log "WARNING: all $original_count lease(s) filtered out"
                log "WARNING: preserving original $dhcpd"
                rm -f "$temp_leases"
            else
                echo "" > "$dhcpd"
            fi
        fi
        chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd"
        chmod 640 "$dhcpd"

        # Restore pipefail to whatever it was before entering this function.
        # Explicit "if" + "return 0" so this function's own success doesn't
        # depend on _pipefail_was_on's value being truthy.
        if (( _pipefail_was_on )); then
            set -o pipefail
        fi
        return 0
    }

    # Log lines below do not carry this function's name -- they use short,
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

        while IFS= read -r line; do
            wcstatus=$(echo "$line" | cut -d ';' -f 1)
            macsource=$(echo "$line" | cut -d ';' -f 2)
            ipsource=$(echo "$line" | cut -d ';' -f 3)
            usersource=$(echo "$line" | cut -d ';' -f 4)
            if [[ $wcstatus == "a" ]]; then
                if ! [[ $macsource =~ $_UH_MAC ]]; then
                    log "WARNING: skipping entry, invalid MAC: $macsource"
                    continue
                fi
                if ! [[ "$ipsource" =~ $_UH_IPV4 ]]; then
                    log "WARNING: skipping entry, invalid IP: $ipsource"
                    continue
                fi
                if ! [[ $usersource =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "WARNING: invalid hostname: $usersource"
                    continue
                fi
                echo "
host $usersource {
    hardware ethernet $macsource;
    fixed-address $ipsource;
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
        } | grep -E "$_UH_MAC" | tr '[:upper:]' '[:lower:]' | sort -u \
          | while IFS= read -r macs; do
                printf 'subclass "blockdhcp" 1:%s;\n' "$macs" >>"$dhcp_conf_temp"
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

    # Log lines below do not carry this function's name -- they use short,
    # generic phrasing instead.
    function clean_acl {
        log "INFO: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_PROXY"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
        sed '/^$/d' -i "$UHM_MACAUTH"
        sed '/^$/d' -i "$UHM_GRACE"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
        sort -t';' -k3,3V "$UHM_MACAUTH" -o "$UHM_MACAUTH"
        sort -V "$UHM_GRACE" -o "$UHM_GRACE"
        # mac-*.txt: sorted by IP (field 3), same key as UHM_MACAUTH above.
        # Purely cosmetic -- update_dhcp_conf() and pydhcpd.py's host{} parsing
        # are both order-independent.
        shopt -s nullglob
        local _order_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        local _omf
        for _omf in "${_order_mac_files[@]}"; do
            sort -t';' -k3,3V "$_omf" -o "$_omf"
        done
    }

    expire_grace_entries

    clean_acl
    log "INFO: stopping pydhcpd"
    trap 'rm -f "${TEMP_FILES_TO_CLEAN[@]}" 2>/dev/null; systemctl reset-failed pydhcpd 2>/dev/null; systemctl is-active --quiet pydhcpd || systemctl start pydhcpd' EXIT
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
        log "WARNING: pydhcpd failed to start after rebuild -- restoring backup"
        if [ -f "${dhcp_conf}.bak" ]; then
            cp -f "${dhcp_conf}.bak" "$dhcp_conf"
            log "INFO: restored ${dhcp_conf}.bak -- retry start"
            systemctl reset-failed pydhcpd 2>/dev/null || true
            systemctl start pydhcpd || true
            sleep 1
            if ! systemctl is-active --quiet pydhcpd; then
                log "ERROR: pydhcpd failed to start even with backup config"
                PYDHCPD_START_FAILED=1
            else
                log "INFO: pydhcpd recovered with backup config"
            fi
        else
            log "ERROR: No backup config found"
            PYDHCPD_START_FAILED=1
        fi
    fi
    trap cleanup_temp EXIT
}

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
drain_lease_queue() {
    [[ ! -s "$UHM_QUEUE" ]] && return
    local dhcpd_leases="$PYDHCPD_LEASES"
    [[ ! -f "$dhcpd_leases" ]] && { : > "$UHM_QUEUE"; return; }

    local tmp removed=0
    tmp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${tmp}")
    local queue_macs
    queue_macs=$(tr '[:upper:]' '[:lower:]' < "$UHM_QUEUE" | sort -u)

    local in_block=0 block=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^lease [0-9.]+ \{$'; then
            in_block=1; block="$line"$'\n'; continue
        fi
        if [[ $in_block -eq 1 ]]; then
            block+="$line"$'\n'
            if echo "$line" | grep -q '^}$'; then
                in_block=0
                local lmac
                lmac=$(echo "$block" | { grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' || true; } | head -1 | tr '[:upper:]' '[:lower:]')
                if [[ -n "$lmac" ]] && echo "$queue_macs" | grep -qxF "$lmac"; then
                    log "INFO: removing $lmac from leases"
                    (( removed++ )) || true
                else
                    printf '%s' "$block" >> "$tmp"
                fi
                block=""
            fi
            continue
        fi
        echo "$line" >> "$tmp"
    done < "$dhcpd_leases"

    local before_leases after_leases
    before_leases=$(grep -c '^lease ' "$dhcpd_leases" 2>/dev/null) || before_leases=0
    after_leases=$(grep -c '^lease ' "$tmp" 2>/dev/null) || after_leases=0
    if (( before_leases - after_leases != removed )); then
        log "WARNING: count mismatch ($before_leases/$after_leases), skip"
        rm -f "$tmp"
        return
    fi
    mv "$tmp" "$dhcpd_leases"
    chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd_leases"
    chmod 640 "$dhcpd_leases"
    if ! : > "$UHM_QUEUE" 2>/dev/null; then
        log "WARNING: cannot truncate $UHM_QUEUE, reprocessed next run"
    fi

    if (( removed > 0 )); then
        log "INFO: removed $removed lease(s)"
    fi
}

is_pydhcp

check_duplicate
check_mac_ip_ranges

# Final summary
_count() { local c=0; c=$(grep -c '^a;' "$1" 2>/dev/null) || c=0; echo "$c"; }
log "blockdhcp=$(_count "$ACL_BLOCK_FILE")|proxy=$(_count "$ACL_MAC_PROXY")|unlimited=$(_count "$ACL_MAC_UNLIMITED")|hotspot=$(_count "$UHM_MACAUTH")|grace=$(_count "$UHM_GRACE")"

# End
log "uhmleases done at: $(date)"

if (( PYDHCPD_START_FAILED )); then
    log "ERROR: pydhcpd is down -- reporting failure to caller"
    exit 1
fi
