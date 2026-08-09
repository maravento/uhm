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
# Runs from /etc/uhm/core/ and operates on pydhcpd
# data located in /etc/pydhcp (which must exist). Despite living next to
# uhmreload.sh/uhmd.sh under core/, this is not an auxiliary tool: it is
# the reconciliation step uhmreload.sh invokes on every reload, and its
# absence or failure aborts the whole reload chain (see uhmreload.sh).
#
# This script:
# - Drains the lease removal queue written by uhmd
# - Parses and cleans /etc/pydhcp/pydhcpd.leases
# - Detects unauthorized clients and adds them to block lists
# - Dynamically rebuilds /etc/pydhcp/pydhcpd.conf based on ACL sources
# - Applies static mappings (MAC -> IP) from ACL files
# - Removes duplicates and enforces consistency across data sources
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Concurrency guard (standalone mode only): waits up to 10s for the
# daemon's cycle lock, then skips gracefully (exit 0) if still held
# - Lease filtering and selective persistence
# - Automatic cleanup and normalization of ACL files
# - ACL conflict detection with fail-safe abort (duplicate MAC/IP/hostname,
# and mac-*.txt IPs landing inside a reserved range)
# - Configuration read from /etc/uhm/uhm.env (managed by uhmsetup.sh)
# - All paths, ACL files and network settings read from uhm.env
# - Optional WPAD/PAC support (see WPAD/PAC OPTION below)
# - UniFi Hotspot integration
# - Grace period for unknown MACs before blocking
# - Lease removal queue: drains /etc/uhm/acl/uhm-queue.txt
# (written by uhmd) during the safe stop->modify->start cycle
#
# LOCATION:
# Installed at /etc/uhm/core/uhmleases.sh
# Requires /etc/pydhcp to exist (pydhcpd backend)
# Configuration stored in /etc/uhm/uhm.env
#
# REQUIREMENTS:
# - pydhcpd installed and running (/etc/pydhcp must exist)
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
# - Configuration managed by uhmsetup.sh -- run uhmsetup.sh to reconfigure
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
# 2. Create virtual host on port 18100
# 3. Create wpad.pac file in Apache document root
# 4. Set WPAD_ENABLED=true in /etc/uhm/uhm.env
#
# NOTE on logging:
# - Writes to /var/log/uhm.log (shared with uhmreload.sh). Rotation
# (/etc/logrotate.d/uhm) is installed by uhmsetup.sh only.
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

# When triggered by the daemon (UHM_RELOAD_ACTIVE set), the daemon
# already holds CYCLE_LOCK for the duration of its run_cycle -- this script
# runs synchronously as its child, so no additional check is needed here
# (and attempting to flock the same lock from a child of the lock holder
# would deadlock).
#
# When run manually, not via the daemon (UHM_RELOAD_ACTIVE unset), acquire
# CYCLE_LOCK before doing any real work, waiting briefly for the daemon to
# finish its current cycle if one is in progress. The daemon only holds this
# lock for the ~1-3s of active ACL mutation within run_cycle, not its entire
# process lifetime, so this wait is short in practice -- unlike a check against
# the daemon's singleton lock (held for as long as the service is up), which
# would skip almost every time. The lock is held for the rest of this
# script's execution (through the stop->modify->start pydhcpd cycle) and is
# released automatically when the process exits.
if [[ -z "${UHM_RELOAD_ACTIVE:-}" ]]; then
    CYCLE_LOCK="/var/lock/uhmd-cycle.lock"
    exec 201>"$CYCLE_LOCK"
    if ! flock -w 10 201; then
        log "INFO: uhmd cycle in progress -- skipping this manual run"
        log "uhmleases done (skipped)"
        exit 0
    fi
fi

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
    log "ERROR: $ENV_FILE not found. Run uhmsetup.sh first."
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
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|HOTSPOT_PATH|\
            ACL_MAC_PROXY|ACL_MAC_UNLIMITED|UMACAUTH_FILE|ACL_BLOCK_FILE|\
            UGRACE_FILE|BLOCKDHCP_GRACE_SECONDS|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|QUARANTINE_DURATION|WPAD_ENABLED|PING_CHECK_ENABLED|\
            PING_TIMEOUT_SECONDS|LOCAL_USER|HOTSPOT_IP_RANGE|HOTSPOT_RANGE_START|HOTSPOT_RANGE_END|PYDHCPD_LEASES|\
            UQUEUE_FILE|DHCPDv4_CONF|DAEMON_USER|DAEMON_GROUP)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$ENV_FILE"

if [ -z "${SERVER_IP:-}" ]; then
    log "ERROR: SERVER_IP not set in $ENV_FILE"
    log "  re-run pysetup.sh or restore $ENV_FILE from backup"
    exit 1
fi

# Determine local user: prefer LOCAL_USER from uhm.env (the only reliable
# source when running from systemd without a TTY), then fall back to session detection.
local_user="${LOCAL_USER:-}"
if [ -z "$local_user" ] || ! id "$local_user" &>/dev/null 2>/dev/null; then
    local_user=$(detect_local_user) || local_user=""
fi
if [ -z "$local_user" ] || ! id "$local_user" &>/dev/null; then
    log "ERROR: Cannot determine a valid local user"
        log "  set LOCAL_USER in $ENV_FILE"
    exit 1
fi
log "Using local user: $local_user"

# DEPENDENCIES
for dep in python3 mawk coreutils util-linux; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: missing package '$dep'"
        log "  install it with: sudo apt install $dep"
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

# Defaults for variables that may not exist in older uhm.env installations.
# These match the values documented in README.md's Config Reference table.
HOTSPOT_IP_RANGE="${HOTSPOT_IP_RANGE:-$(echo "$SERVER_IP" | cut -d'.' -f1-3)}"
HOTSPOT_RANGE_START="${HOTSPOT_RANGE_START:-160}"
[[ "$HOTSPOT_RANGE_START" =~ $_UH_OCT ]] || { log "WARNING: HOTSPOT_RANGE_START invalid ($HOTSPOT_RANGE_START) -- using default 160"; HOTSPOT_RANGE_START=160; }
HOTSPOT_RANGE_END="${HOTSPOT_RANGE_END:-199}"
[[ "$HOTSPOT_RANGE_END" =~ $_UH_OCT ]] || { log "WARNING: HOTSPOT_RANGE_END invalid ($HOTSPOT_RANGE_END) -- using default 199"; HOTSPOT_RANGE_END=199; }
SERV_MASK="${SERV_MASK:-255.255.255.0}"
SERV_DNS="${SERV_DNS:-8.8.8.8,1.1.1.1}"
SERV_SUBNET="${SERV_SUBNET:-192.168.0.0}"
SERV_BROADCAST="${SERV_BROADCAST:-192.168.0.255}"
SERV_INI_RANGE_BLOCK="${SERV_INI_RANGE_BLOCK:-192.168.0.230}"
SERV_END_RANGE_BLOCK="${SERV_END_RANGE_BLOCK:-192.168.0.239}"

for _ip_var in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
    if ! [[ "${!_ip_var}" =~ $_UH_IPV4 ]]; then
        log "ERROR: $_ip_var is not a valid IPv4 address in $ENV_FILE"
        log "  got: '${!_ip_var}'"
        exit 1
    fi
done
unset _ip_var
if ! [[ "$SERV_MASK" =~ $_UH_NETMASK ]]; then
    log "ERROR: SERV_MASK is not a valid netmask in $ENV_FILE"
    log "  got: '$SERV_MASK'"
    exit 1
fi
if ! [[ "$SERV_DNS" =~ $_UH_DNS ]]; then
    log "ERROR: SERV_DNS is not a valid IPv4 list in $ENV_FILE"
    log "  got: '$SERV_DNS'"
    exit 1
fi
if ! [[ "${HOTSPOT_IP_RANGE}.0" =~ $_UH_IPV4 ]]; then
    log "ERROR: HOTSPOT_IP_RANGE invalid IPv4 prefix in $ENV_FILE"
    log "  got: '$HOTSPOT_IP_RANGE'"
    exit 1
fi

# Guard: none of the three IP ranges/points this script writes into
# pydhcpd.conf may overlap one another -- SERVER_IP, the block-pool range
# (SERV_INI_RANGE_BLOCK-SERV_END_RANGE_BLOCK) and the hotspot voucher range
# (HOTSPOT_IP_RANGE.HOTSPOT_RANGE_START-HOTSPOT_RANGE_END). pydhcpd.py only
# rejects the block-pool/SERVER_IP overlap, and only after this script has
# already stopped the daemon and rewritten pydhcpd.conf. Catching every
# combination here, before any destructive action, avoids leaving the daemon
# down over a config mistake that could have been caught up front.
HOTSPOT_START_IP="${HOTSPOT_IP_RANGE}.${HOTSPOT_RANGE_START}"
HOTSPOT_END_IP="${HOTSPOT_IP_RANGE}.${HOTSPOT_RANGE_END}"
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
" "$SERVER_IP" "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK" "$HOTSPOT_START_IP" "$HOTSPOT_END_IP" 2>/dev/null)
if [[ -n "$_range_conflict" ]]; then
    log "ERROR: $_range_conflict in $ENV_FILE -- refusing to proceed"
    log "  (SERVER_IP=$SERVER_IP, block-pool=$SERV_INI_RANGE_BLOCK-$SERV_END_RANGE_BLOCK)"
    log "  (hotspot=$HOTSPOT_START_IP-$HOTSPOT_END_IP)"
    exit 1
fi
unset _range_conflict

ACL_PATH="${ACL_PATH:-/etc/acl}"
ACL_MAC_PATH="${ACL_MAC_PATH:-/etc/acl/acl_mac}"
ACL_DHCP_PATH="${ACL_DHCP_PATH:-/etc/acl/acl_dhcp}"
HOTSPOT_PATH="${HOTSPOT_PATH:-/etc/uhm}"
ACL_MAC_PROXY="${ACL_MAC_PROXY:-/etc/acl/acl_mac/mac-proxy.txt}"
ACL_MAC_UNLIMITED="${ACL_MAC_UNLIMITED:-/etc/acl/acl_mac/mac-unlimited.txt}"
UMACAUTH_FILE="${UMACAUTH_FILE:-/etc/uhm/acl/uhm-auth.txt}"
ACL_BLOCK_FILE="${ACL_BLOCK_FILE:-/etc/acl/acl_dhcp/blockdhcp.txt}"
PYDHCPD_LEASES="${PYDHCPD_LEASES:-/etc/pydhcp/pydhcpd.leases}"
UGRACE_FILE="${UGRACE_FILE:-/etc/uhm/acl/uhm-grace.txt}"
BLOCKDHCP_GRACE_SECONDS="${BLOCKDHCP_GRACE_SECONDS:-86400}"
[[ "$BLOCKDHCP_GRACE_SECONDS" =~ $_UH_UINT ]] || { log "WARNING: BLOCKDHCP_GRACE_SECONDS invalid ($BLOCKDHCP_GRACE_SECONDS) -- using default 86400"; BLOCKDHCP_GRACE_SECONDS=86400; }
CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-60}"
AUTHORIZED_LEASE_TIME="${AUTHORIZED_LEASE_TIME:-2592000}"
QUARANTINE_DURATION="${QUARANTINE_DURATION:-60}"
WPAD_ENABLED="${WPAD_ENABLED:-false}"
PING_CHECK_ENABLED="${PING_CHECK_ENABLED:-true}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
UQUEUE_FILE="${UQUEUE_FILE:-/etc/uhm/acl/uhm-queue.txt}"

if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
    wpad_header="option wpad code 252 = text;"
    wpad_subnet="option wpad \"http://$SERVER_IP:18100/wpad.pac\";"
else
    wpad_header="#option wpad code 252 = text;"
    wpad_subnet="#option wpad \"http://$SERVER_IP:18100/wpad.pac\";"
fi

if [[ "${PING_CHECK_ENABLED:-true}" == "true" ]]; then
    ping_check_line="ping-check true;"
    ping_timeout_line="ping-timeout ${PING_TIMEOUT_SECONDS:-1};"
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
        log "ERROR: system user 'pydhcpd' does not exist"
        log "  is pydhcpd installed correctly?"
        exit 1
    fi
    if ! getent group pydhcpd &>/dev/null; then
        log "ERROR: system group 'pydhcpd' does not exist"
        log "  is pydhcpd installed correctly?"
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
    if [ ! -f "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}" ]; then
        log "ERROR: ${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf} does not exist"
        exit 1
    fi
    chmod 640 "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
    chown root:"${DAEMON_GROUP:-pydhcpd}" "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
}

verify_directories() {
    for dir in "$ACL_MAC_PATH" "$ACL_DHCP_PATH"; do
        if [ ! -d "$dir" ]; then
            log "ERROR: Directory $dir does not exist"
            exit 1
        fi
    done
    if [ ! -d "$HOTSPOT_PATH" ]; then
        log "ERROR: Directory $HOTSPOT_PATH does not exist"
        exit 1
    fi
    local acl_hotspot_dir
    acl_hotspot_dir="$(dirname "$UMACAUTH_FILE")"
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
        "$UMACAUTH_FILE" "$UGRACE_FILE" "$UQUEUE_FILE"
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
    local f="$1" pattern="${2:-}" n=0 line _nf_ip

    [ -f "$f" ] || return 0

    # Strip all whitespace within each line (leading, trailing, or between
    # the "#"/"a" marker and the ";"-delimited fields) so the format check
    # below never has to guess at spacing variants.
    sed -i 's/[[:space:]]//g' "$f"

    # Remove blank (now-empty) lines.
    sed -i '/^$/d' "$f"

    if [[ -n "$pattern" ]]; then
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            if ! [[ "$line" =~ $pattern ]]; then
                log "ERROR: malformed line $n in $(basename "$f"): $line"
                exit 1
            fi
            _nf_ip="$(printf '%s' "$line" | cut -d';' -f3)"
            if [[ -n "$_nf_ip" ]] && ! [[ "$_nf_ip" =~ $_UH_IPV4 ]]; then
                log "ERROR: invalid IP on line $n in $(basename "$f"): $_nf_ip"
                exit 1
            fi
        done < "$f"
    fi

    # Ensure a trailing newline. tail -c1 grabs the file's last byte;
    # command substitution strips a trailing \n from its output, so
    # a non-empty result here means the last byte was NOT a newline.
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
        log "normalize_acl_lists: adding missing trailing newline to $(basename "$f")"
        printf '\n' >> "$f"
    fi
}

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

    _normalize_acl_file "$UMACAUTH_FILE" "$commentable_epoch_pattern"
    _normalize_acl_file "$UGRACE_FILE" "$strict_epoch_pattern"
    [ -f "$UQUEUE_FILE" ] && _normalize_acl_file "$UQUEUE_FILE" "$bare_mac_pattern"
}

dedup_acl_mac_lines() {
    local f="$1" tmp before after
    [ -f "$f" ] || return 0
    before=$(wc -l < "$f")
    tmp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${tmp}")
    awk -F';' '
        /^a;/ {
            mac=tolower($2)
            if (mac in seen) next
            seen[mac]=1
        }
        { print }
    ' "$f" > "$tmp"
    after=$(wc -l < "$tmp")
    if (( after < before )); then
        mv "$tmp" "$f"
        chmod 600 "$f"
        log "dedup_acl_mac_lines: removed $(( before - after )) duplicate MAC line(s) from $(basename "$f")"
    fi
}

verify_dhcp_service
verify_dhcp_user
verify_dhcp_files
verify_dhcp_config
verify_directories
initialize_empty_files
normalize_acl_lists
dedup_acl_mac_lines "$UGRACE_FILE"
dedup_acl_mac_lines "$ACL_BLOCK_FILE"

function clean_hotspot_list() {
    local removed=0 patterns mac_files
    shopt -s nullglob
    mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#mac_files[@]} == 0 )); then
        log "ERROR: no mac-*.txt files found in $ACL_MAC_PATH"
        log "  check ACL_MAC_PROXY/ACL_MAC_UNLIMITED in uhm.env"
        exit 1
    fi
    patterns=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${patterns}")
    awk -F';' 'NF>=2 && $2!="" {print ";"tolower($2)";"}' "${mac_files[@]}" | sort -u > "$patterns"

    while IFS= read -r pat; do
        local mac_actual="${pat//;/}"
        if grep -qiF "$pat" "$UMACAUTH_FILE" 2>/dev/null; then
            log "clean_hotspot_list: removing $mac_actual from uhm-auth"
            log "  (found in mac-*.txt)"
            (( removed++ )) || true
        fi
    done < "$patterns"

    if (( removed > 0 )); then
        local _grep_rc=0
        grep -viFf "$patterns" "$UMACAUTH_FILE" > "$UMACAUTH_FILE".tmp || _grep_rc=$?
        if (( _grep_rc > 1 )); then
            log "ERROR: clean_hotspot_list: grep failed (rc=$_grep_rc)"
            log "  skipping update of uhm-auth"
            rm -f "$UMACAUTH_FILE".tmp
        else
            chmod 600 "$UMACAUTH_FILE".tmp
            TEMP_FILES_TO_CLEAN+=("${UMACAUTH_FILE}.tmp")
            mv "$UMACAUTH_FILE".tmp "$UMACAUTH_FILE"
        fi
    fi
    rm -f "$patterns"
    if (( removed > 0 )); then
        log "clean_hotspot_list: done (removed=$removed)"
    fi
}

function clean_grace_list() {
    [ ! -f "$UGRACE_FILE" ] && return
    local file_temp patterns
    file_temp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${file_temp}")
    patterns=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${patterns}")

    # Only remove from uhm-grace when MAC was promoted to an authoritative ACL
    # (mac-* or uhm-auth).
    {
        grep -h '^a;' "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null || true
        grep -h '^a;' "$UMACAUTH_FILE" 2>/dev/null || true
    } | awk -F';' '{print tolower($2)}' | sort -u > "$file_temp"

    local removed=0
    while IFS= read -r mac_actual; do
        [ -z "$mac_actual" ] && continue
        if ! [[ "$mac_actual" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            log "WARNING: skipping malformed mac from ACL source"
            log "  ($mac_actual)"
            continue
        fi
        if grep -qi "^a;${mac_actual};" "$UGRACE_FILE" 2>/dev/null; then
            local found_in=""
            grep -qhi "^a;${mac_actual};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null && found_in="acl_mac" || true
            grep -qi "^a;${mac_actual};" "$UMACAUTH_FILE" 2>/dev/null && found_in="${found_in:+$found_in/}hotspot" || true
            log "clean_grace_list: removing $mac_actual from uhm-grace"
            log "  (found in ${found_in:-unknown}, date=$(date))"
            printf '^a;%s;\n' "$mac_actual" >> "$patterns"
            (( removed++ )) || true
        fi
    done < "$file_temp"

    TEMP_FILES_TO_CLEAN+=("${UGRACE_FILE}.tmp")
    if (( removed > 0 )); then
        local _grep_rc=0
        grep -vif "$patterns" "$UGRACE_FILE" > "$UGRACE_FILE.tmp" || _grep_rc=$?
        if (( _grep_rc > 1 )); then
            log "ERROR: clean_grace_list: grep failed (rc=$_grep_rc)"
            log "  skipping update of uhm-grace"
            rm -f "$UGRACE_FILE.tmp"
        else
            chmod 600 "$UGRACE_FILE.tmp"
            mv "$UGRACE_FILE.tmp" "$UGRACE_FILE"
        fi
    fi
    rm -f "$file_temp" "$patterns"
}

function expire_grace_entries() {
    [ ! -f "$UGRACE_FILE" ] && return
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
            log "WARNING: expire_grace_entries: skipping malformed line"
            log "  (status=$status mac=$mac epoch=$epoch)"
            continue
        fi
        age=$(( now_epoch - epoch ))
        if (( age >= BLOCKDHCP_GRACE_SECONDS )); then
            log "expire_grace_entries: expired $mac"
            log "  (age=${age}s) -> blockdhcp"
            echo "a;${mac};${ip};${hostname};" >> "$ACL_BLOCK_FILE"
            # Queue lease removal so pydhcpd stops serving this MAC from the pool.
            if ! grep -qxF "$mac" "$UQUEUE_FILE" 2>/dev/null; then
                echo "$mac" >> "$UQUEUE_FILE"
                log "expire_grace_entries: queued removal for $mac"
            fi
        else
            echo "a;${mac};${ip};${hostname};${epoch};" >> "$file_temp"
        fi
    done < "$UGRACE_FILE"

    mv "$file_temp" "$UGRACE_FILE"
    chmod 600 "$UGRACE_FILE"
    chown root:root "$UGRACE_FILE"
}

function is_pydhcp() {
    dhcpd="$PYDHCPD_LEASES"
    dhcp_conf="${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX")
    TEMP_FILES_TO_CLEAN+=("$dhcp_conf_temp")

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
                    mac_address=$(echo "$lease_content" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 | tr 'A-F' 'a-f')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    host_candidate=$(echo "$host_candidate" | tr -cd 'A-Za-z0-9._-' | cut -c1-63)
                    host="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$ip_address" ]] && ! [[ "$ip_address" =~ $_UH_IPV4 ]]; then
                        log "read_leases: skipping lease with invalid IP: $ip_address"
                        ip_address=""
                    fi

                    if [[ -n "$mac_address" && -n "$ip_address" ]]; then
                        (( total_seen++ )) || true

                        # Authoritative: managed MAC (mac-*) or voucher-authenticated (uhm-auth).
                        mac_authoritative=""
                        grep -qi "^a;${mac_address};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null \
                            && mac_authoritative="yes" || true
                        if [[ -z "$mac_authoritative" ]]; then
                            grep -qi "^a;${mac_address};" "$UMACAUTH_FILE" 2>/dev/null \
                                && mac_authoritative="yes" || true
                        fi

                        if [[ -n "$mac_authoritative" ]]; then
                            echo "$lease_content" >> "$temp_leases"
                        elif grep -qi "^a;${mac_address};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                            (( dropped_blocked++ )) || true
                        elif grep -qi "^a;${mac_address};" "$UGRACE_FILE" 2>/dev/null; then
                            echo "$lease_content" >> "$temp_leases"
                        else
                            log "read_leases: $mac_address -> new -> uhm-grace"
                            log "  (ip=$ip_address host=$host epoch=$(date +%s))"
                            echo "a;${mac_address};${ip_address};${host};$(date +%s);" >> "$UGRACE_FILE"
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
                log "read_leases: all $total_seen lease(s) belong to blocked MACs"
                log "  clearing $dhcpd"
                echo "" > "$dhcpd"
                rm -f "$temp_leases"
            elif (( original_count > 0 )); then
                # Empty result NOT fully explained by blocked MACs (parsing
                # failure, unexpected code path, etc.) -- preserve the original
                # to avoid losing lease data on a transient/unknown failure.
                log "WARNING: read_leases: all $original_count lease(s) filtered out"
                log "  preserving original $dhcpd"
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

    function update_dhcp_conf {
        echo "# pydhcpd Configuration
authoritative;
cleanup-interval $CLEANUP_INTERVAL;
abandon-lease-time $QUARANTINE_DURATION;
$wpad_header
server-identifier $SERVER_IP;
deny duplicates;
one-lease-per-client true;
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
            "$UMACAUTH_FILE" 2>/dev/null || true)
        all_sources=$(printf '%s\n' "$acl_sources" "$hotspot_normalized" | sort -u)

        while IFS= read -r line; do
            wcstatus=$(echo "$line" | cut -d ';' -f 1)
            macsource=$(echo "$line" | cut -d ';' -f 2)
            ipsource=$(echo "$line" | cut -d ';' -f 3)
            usersource=$(echo "$line" | cut -d ';' -f 4)
            if [[ $wcstatus == "a" ]]; then
                if ! [[ $macsource =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                    log "update_dhcp_conf: skipping entry, invalid MAC: $macsource"
                    continue
                fi
                if ! [[ "$ipsource" =~ $_UH_IPV4 ]]; then
                    log "update_dhcp_conf: skipping entry, invalid IP: $ipsource"
                    continue
                fi
                if ! [[ $usersource =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "update_dhcp_conf: invalid hostname: $usersource"
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
            grep -h '^#a;' "$UMACAUTH_FILE" 2>/dev/null | cut -d ';' -f 2 || true
        } | grep -iE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | tr '[:upper:]' '[:lower:]' | sort -u \
          | while IFS= read -r macs; do
                printf ' subclass "blockdhcp" 1:%s;\n' "$macs" >>"$dhcp_conf_temp"
            done || true

        echo "" >>"$dhcp_conf_temp"

        echo "subnet $SERV_SUBNET netmask $SERV_MASK {
    $wpad_subnet
    option routers $SERVER_IP;
    option broadcast-address $SERV_BROADCAST;
    #option domain-name \"example.org\";
    option domain-name-servers $SERV_DNS;
    min-lease-time $AUTHORIZED_LEASE_TIME;
    default-lease-time $AUTHORIZED_LEASE_TIME;
    max-lease-time $AUTHORIZED_LEASE_TIME;
    pool {
        min-lease-time $CLEANUP_INTERVAL;
        default-lease-time $CLEANUP_INTERVAL;
        max-lease-time $CLEANUP_INTERVAL;
        deny members of \"blockdhcp\";
        range $SERV_INI_RANGE_BLOCK $SERV_END_RANGE_BLOCK;
    }
}
        " >>"$dhcp_conf_temp"

        # Keep a backup of the previous config in case the new one is faulty.
        [ -f "$dhcp_conf" ] && cp -f "$dhcp_conf" "${dhcp_conf}.bak"
        mv -f "$dhcp_conf_temp" "$dhcp_conf"
        chown root:"${DAEMON_GROUP:-pydhcpd}" "$dhcp_conf"
        chmod 640 "$dhcp_conf"
    }

    function clean_block_list {
        local removed=0 file_temp patterns
        file_temp=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${file_temp}")
        patterns=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${patterns}")
        grep -hiE '^a;[0-9a-fA-F:]+;' "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null | cut -d ";" -f2 | tr '[:upper:]' '[:lower:]' | sort -u >"$file_temp" || true

        while read -r mac_actual; do
            [ -z "$mac_actual" ] && continue
            if grep -qF ";${mac_actual};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                log "clean_block_list: removing $mac_actual from blockdhcp"
                log "  (found in acl_mac, date=$(date))"
                printf ';%s;\n' "$mac_actual" >> "$patterns"
                (( removed++ )) || true
            fi
        done <"$file_temp"

        if (( removed > 0 )); then
            local _grep_rc=0 block_tmp
            block_tmp=$(mktemp)
            TEMP_FILES_TO_CLEAN+=("${block_tmp}")
            grep -vFf "$patterns" "$ACL_BLOCK_FILE" > "$block_tmp" || _grep_rc=$?
            if (( _grep_rc > 1 )); then
                log "ERROR: clean_block_list: grep failed (rc=$_grep_rc)"
                log "  skipping update of blockdhcp"
                rm -f "$block_tmp"
            else
                chmod 600 "$block_tmp"
                mv "$block_tmp" "$ACL_BLOCK_FILE"
            fi
        fi
        rm -f "$file_temp" "$patterns"
        if (( removed > 0 )); then
            log "clean_block_list: done (removed=$removed)"
        fi
    }

    function clean_proxy_list {
        local removed=0 patterns
        patterns=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${patterns}")
        awk -F';' 'NF>=2 && $2!="" {print ";"tolower($2)";"}' "$ACL_MAC_UNLIMITED" | sort -u > "$patterns"

        while IFS= read -r pat; do
            local mac_actual="${pat//;/}"
            if grep -qiF "$pat" "$ACL_MAC_PROXY" 2>/dev/null; then
                log "clean_proxy_list: removing $mac_actual from mac-proxy"
                log "  (found in mac-unlimited)"
                (( removed++ )) || true
            fi
        done < "$patterns"

        if (( removed > 0 )); then
            local file_temp
            file_temp=$(mktemp)
            TEMP_FILES_TO_CLEAN+=("${file_temp}")
            local _grep_rc=0
            grep -viFf "$patterns" "$ACL_MAC_PROXY" > "$file_temp" || _grep_rc=$?
            if (( _grep_rc > 1 )); then
                log "ERROR: clean_proxy_list: grep failed (rc=$_grep_rc)"
                log "  skipping update of mac-proxy"
                rm -f "$file_temp"
            else
                chmod 600 "$file_temp"
                mv "$file_temp" "$ACL_MAC_PROXY"
            fi
        fi
        rm -f "$patterns"
        if (( removed > 0 )); then
            log "clean_proxy_list: done (removed=$removed)"
        fi
    }

    function clean_acl {
        log "clean_acl: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_PROXY"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
        sed '/^$/d' -i "$UMACAUTH_FILE"
        sed '/^$/d' -i "$UGRACE_FILE"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
        sort -t';' -k3,3V "$UMACAUTH_FILE" -o "$UMACAUTH_FILE"
        sort -V "$UGRACE_FILE" -o "$UGRACE_FILE"
    }

    clean_grace_list
    expire_grace_entries

    clean_acl
    clean_block_list
    clean_proxy_list
    clean_hotspot_list
    log "Stopping pydhcpd"
    trap 'rm -f "${TEMP_FILES_TO_CLEAN[@]}" 2>/dev/null; systemctl reset-failed pydhcpd 2>/dev/null; systemctl is-active --quiet pydhcpd || systemctl start pydhcpd' EXIT
    systemctl stop pydhcpd
    drain_lease_queue
    log "Processing leases"
    read_leases
    log "Sorting ACL files"
    order_files_acl
    log "Rebuilding pydhcpd.conf"
    update_dhcp_conf
    log "Starting pydhcpd"
    systemctl reset-failed pydhcpd 2>/dev/null || true
    systemctl start pydhcpd || true
    sleep 1
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd failed to start after config rebuild"
        log "  attempting backup config restore"
        if [ -f "${dhcp_conf}.bak" ]; then
            cp -f "${dhcp_conf}.bak" "$dhcp_conf"
            log "Restored ${dhcp_conf}.bak -- retrying pydhcpd start"
            systemctl reset-failed pydhcpd 2>/dev/null || true
            systemctl start pydhcpd || true
            sleep 1
            if ! systemctl is-active --quiet pydhcpd; then
                log "ERROR: pydhcpd failed to start even with backup config"
            else
                log "pydhcpd recovered with backup config"
            fi
        else
            log "ERROR: No backup config found"
        fi
    fi
    trap cleanup_temp EXIT
}

drain_lease_queue() {
    [[ ! -s "$UQUEUE_FILE" ]] && return
    local dhcpd_leases="$PYDHCPD_LEASES"
    [[ ! -f "$dhcpd_leases" ]] && { : > "$UQUEUE_FILE"; return; }

    local tmp removed=0
    tmp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${tmp}")
    local queue_macs
    queue_macs=$(tr '[:upper:]' '[:lower:]' < "$UQUEUE_FILE" | sort -u)

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
                    log "drain_lease_queue: removing $lmac from leases"
                    log "  (date=$(date))"
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
        log "ERROR: drain_lease_queue: count mismatch"
        log "  (before=$before_leases after=$after_leases removed=$removed)"
        log "ERROR: drain_lease_queue: skipping update of $dhcpd_leases"
        rm -f "$tmp"
        return
    fi
    mv "$tmp" "$dhcpd_leases"
    chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd_leases"
    chmod 640 "$dhcpd_leases"
    if ! : > "$UQUEUE_FILE" 2>/dev/null; then
        log "WARNING: drain_lease_queue: cannot truncate $UQUEUE_FILE"
        log "  (permissions?) -- queue will be reprocessed next run"
    fi

    if (( removed > 0 )); then
        log "drain_lease_queue: removed $removed lease(s)"
    fi
}

function check_acl_conflicts() {
    local has_error=0 sources=()
    shopt -s nullglob
    sources=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    sources+=("$UMACAUTH_FILE")

    local field field_name dups dup locations
    local -a _locations
    for field in 2 3 4; do
        case $field in 2) field_name="MAC" ;; 3) field_name="IP" ;; 4) field_name="hostname" ;; esac
        if [[ "$field" == "2" ]]; then
            dups=$(awk -F';' '/^a;/{print tolower($2)}' "${sources[@]}" 2>/dev/null | sort | uniq -d)
        else
            dups=$(awk -F';' '/^a;/' "${sources[@]}" 2>/dev/null | cut -d';' -f${field} | sort | uniq -d)
        fi
        if [[ -n "$dups" ]]; then
            while IFS= read -r dup; do
                [[ -z "$dup" ]] && continue
                mapfile -t _locations < <( { grep -liF ";${dup};" "${sources[@]}" 2>/dev/null || true; } )
                locations="${_locations[*]}"

                if [[ "$field" == "2" ]]; then
                    # A MAC duplicated between exactly one mac-*.txt file and
                    # uhm-auth.txt is not a misconfiguration -- mac-*.txt
                    # always wins (see uhmd.sh's MANAGED MACS note) and
                    # uhm-auth.txt's copy is a stale/residual entry. Resolve
                    # it here instead of aborting, generalizing what
                    # clean_hotspot_list already does for mac-unlimited
                    # specifically to any mac-*.txt file. A MAC duplicated
                    # between two or more mac-*.txt files still aborts below
                    # -- that is a genuine misconfiguration, not this case.
                    local mac_txt_hits=0 hotspot_hit=0 _loc
                    for _loc in "${_locations[@]}"; do
                        if [[ "$_loc" == "$UMACAUTH_FILE" ]]; then
                            hotspot_hit=1
                        else
                            (( mac_txt_hits++ )) || true
                        fi
                    done
                    if (( mac_txt_hits == 1 && hotspot_hit == 1 )); then
                        if sed -i "/^a;${dup};/Id" "$UMACAUTH_FILE"; then
                            log "INFO: duplicate MAC '$dup' -- removed from $(basename "$UMACAUTH_FILE") (present in mac-*.txt)"
                            continue
                        else
                            log "ERROR: failed to auto-resolve duplicate MAC '$dup'"
                        log "  aborting"
                        fi
                    fi
                fi

                log "ERROR: duplicate $field_name '$dup' in: $locations"
                has_error=1
            done <<< "$dups"
        fi
    done

    # mac-*.txt IPs are administrator-assigned, with no dedicated range in
    # uhm.env (see README) -- only HOTSPOT_RANGE_START/END (uhm-auth.txt)
    # and SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK (blockdhcp/uhm-grace pool) are
    # defined there. A mac-*.txt IP landing inside either range is always a
    # misconfiguration, regardless of whether a client currently holds it.
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if [[ ${#mac_files[@]} -gt 0 ]]; then
        local block_prefix="${SERV_INI_RANGE_BLOCK%.*}" block_start="${SERV_INI_RANGE_BLOCK##*.}" block_end="${SERV_END_RANGE_BLOCK##*.}"
        local mac ip prefix octet status
        while IFS=';' read -r status mac ip _; do
            [[ "$status" != "a" || -z "$ip" ]] && continue
            prefix="${ip%.*}"
            octet="${ip##*.}"
            [[ "$octet" =~ $_UH_OCT ]] || continue
            if [[ "$prefix" == "$HOTSPOT_IP_RANGE" ]] && (( octet >= HOTSPOT_RANGE_START && octet <= HOTSPOT_RANGE_END )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "  inside hotspot range ${HOTSPOT_IP_RANGE}.${HOTSPOT_RANGE_START}-${HOTSPOT_RANGE_END}"
                log "ERROR: mac-*.txt IP conflict: reserved for uhm-auth.txt"
                log "  move $mac outside it"
                has_error=1
            elif [[ "$prefix" == "$block_prefix" ]] && (( octet >= block_start && octet <= block_end )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "  inside the blockdhcp pool range ${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}"
                log "ERROR: mac-*.txt IP conflict: reserved for"
                log "  uhm-grace/blockdhcp -- move $mac outside it"
                has_error=1
            fi
        done < <(cat "${mac_files[@]}" 2>/dev/null)
    fi

    if (( has_error == 0 )); then
        is_pydhcp
    else
        log "ACL configuration error detected -- aborting"
        exit 1
    fi
}
check_acl_conflicts

# Final summary
_count() { local c=0; c=$(grep -c '^a;' "$1" 2>/dev/null) || c=0; echo "$c"; }
log "ACL: blockdhcp=$(_count "$ACL_BLOCK_FILE") | proxy=$(_count "$ACL_MAC_PROXY") | unlimited=$(_count "$ACL_MAC_UNLIMITED") | hotspot=$(_count "$UMACAUTH_FILE") | grace=$(_count "$UGRACE_FILE")"

# End
log "uhmleases done at: $(date)"
