#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmd -- UniFi Hotspot Manager Daemon
#
# DESCRIPTION:
# Persistent systemd service for UniFi hotspot ACL management.
# Runs a full management cycle every POLL_INTERVAL seconds (set in
# uhm.env, default 20) with a persistent UniFi API session and CSRF
# token shared across all calls within a cycle.
#
# CONTROLLER TYPE (UNIFI_TYPE in uhm.env):
# Supports both "unifi-os" (UDM/UDM-Pro/UDR/Cloud Key Gen2+, login via
# /api/auth/login, TOKEN cookie, CSRF from the JWT payload) and "classic"
# (self-hosted UniFi Network Application, login via /api/login, unifises
# cookie, CSRF from the response header). _session_cookie_name() and
# unifi_login() branch on this value; api_path() branches the API prefix
# the same way.
#
# TLS (UNIFI_CERT_PIN in uhm.env):
# The UniFi controller normally uses a self-signed certificate, so every API
# call disables chain verification (curl -k). If UNIFI_CERT_PIN is set
# (computed by uhmsetup.sh at install time, format "sha256//<base64>"), it is
# passed as curl --pinnedpubkey alongside -k, so the connection is rejected
# outright if the controller's certificate is ever swapped for a different
# one (MITM or unexpected controller change). Empty/unset UNIFI_CERT_PIN
# falls back to -k with no pinning.
#
# Session tokens are persisted to TOKEN_STATE_FILE (/run/uhmd_session)
# so that re-authentication inside $(...) subshells propagates correctly to
# subsequent API calls in the same cycle.
#
# STARTUP LOGIN (main()):
# On startup, retries the initial UniFi login quietly (no ERROR log, no
# alert) every 10s for up to STARTUP_GRACE_SECONDS (set in uhm.env,
# default 120) before giving up -- the controller often boots alongside this
# host and isn't ready to answer for the first minute or two. Only exits
# (and logs a real ERROR) if the whole grace window elapses without a
# successful login. Re-authentication during normal operation (session
# expired mid-cycle) is unaffected and still alerts immediately on failure.
#
# MANAGED MACS (mac-*.txt):
# uhmd.sh never maintains its own uhm-auth.txt-style snapshot/cache of
# mac-*.txt devices -- they never enter uhm-auth.txt, are never treated as a
# voucher/guest session, and their fixed address/DHCP bypass is handled
# exclusively by uhmleases.sh on every reload (fixed-address host entries, or
# -- if their line is commented out -- the same "blockdhcp" deny class as
# blockdhcp.txt). uhmd.sh's own ACL responsibility stays limited to the lists
# under /etc/uhm/acl (uhm-auth.txt, uhm-grace.txt, uhm-queue.txt) plus
# blockdhcp.txt dedup.
#
# That DHCP/firewall-level bypass alone is NOT sufficient to skip UniFi's own
# captive portal: on any WLAN configured as Guest/Hotspot (see README UNIFI
# PRE-CONFIGURATION), the AP holds a client at the portal based on UniFi's own
# per-client "authorized" flag in stat/sta -- independent of DHCP/firewall
# state, and confirmed by direct API queries showing is_guest=true/
# authorized=false for a mac-*.txt device with an otherwise fully correct
# fixed IP. authorize_managed_macs (step, right after revoke) closes that gap:
# for every active mac-*.txt MAC currently reported unauthorized by stat/sta,
# it calls UniFi's authorize-guest so the AP stops holding it at the portal --
# this is the one place uhmd.sh does authorize a managed MAC in UniFi, and
# deliberately does NOT touch uhm-auth.txt or any local ACL when doing so.
#
# A few other narrow, deliberate exceptions touch mac-*.txt directly, none of
# them a numbered cycle step and none caching state across cycles beyond
# their own bookkeeping:
# - check_mac_lists_changed: a pure file hash (no MAC/status parsing) to
#   notice a change and get uhmleases.sh invoked promptly instead of waiting
#   for the safety-net reload.
# - is_managed_mac: a live, on-disk membership check (active or commented)
#   used as a guard in process_sessions/kick_newly_authorized, so a
#   stale or externally-granted UniFi guest authorization for a managed
#   device can never be promoted into uhm-auth.txt -- and in
#   process_new_leases (step 6), so a managed device's lease (kept alive
#   indefinitely in pydhcpd.leases by uhmleases.sh) is never mistaken for a
#   new/unclassified client and re-added to uhm-grace.txt every cycle.
# - list_managed_macs: the active-only (non-commented) enumeration used by
#   authorize_managed_macs above.
#
# CYCLE (every POLL_INTERVAL seconds, default 20, set in uhm.env):
# 1. VOUCHERS -- load voucher cache from UniFi (stat/voucher)
# 2. SNAPSHOT -- md5sum baseline of ACL files before processing (taken
# before DEDUP so its blockdhcp.txt changes are detected
# by RELOAD, step 9)
# 3. DEDUP -- cross-list consistency check, blockdhcp cleanup
# 4. SORT -- sort uhm-auth.txt by IP
# 5. EXPIRED -- remove expired uhm-auth entries (hotspot IPs freed);
# applies by voucher END_TIME_EPOCH regardless of active ("a;")
# or deactivated ("#a;") state -- unlike mac-*.txt, a uhm-auth.txt
# entry always has an expiry, comment state doesn't pause it
# 6. NEW LEASES -- scan pydhcpd.leases; any MAC not yet in uhm-auth/
# blockdhcp/uhm-grace/mac-*.txt (is_managed_mac) is written
# directly into uhm-grace.txt with a first-seen timestamp.
# No fixed hotspot-range IP is assigned and no lease
# removal is queued: grace clients keep their existing
# pydhcpd pool lease. Writing uhm-grace.txt is enough to
# trigger RELOAD (step 9), which invokes uhmleases.sh to
# do the actual classification/expiry/blocking of grace
# entries.
# 7. SESSIONS -- promote voucher-authenticated clients to uhm-auth, except
# a MAC revoked in an earlier cycle whose stat/guest session is
# still the same one it had when it was revoked (REVOKED_SESSIONS)
# 8. REVOKE -- remove UniFi-unauthorized clients from uhm-auth and record
# them in REVOKED_SESSIONS; an entry is dropped as soon as
# stat/sta stops reporting that MAC as authorized=false
# 9. RELOAD -- invoke UHM_RELOAD if ACLs changed, or once per
# RELOAD_SAFETY_INTERVAL_SECONDS regardless (safety net for
# idle networks -- grace->block promotion, firewall self-heal)
# 10. KICK -- force reassociation of newly-authorized clients still
# connected, so they pick up their new fixed IP right away
#
# stat/sta is queried once per cycle and shared across steps 8 and 10, plus
# authorize_managed_macs (see MANAGED MACS above), which runs right after
# step 8 (REVOKE) -- independent of the numbered steps and of uhm-auth.txt,
# it authorizes any active mac-*.txt MAC that stat/sta currently reports as
# unauthorized, so UniFi's own captive portal stops holding it.
#
# CONFIG: /etc/uhm/uhm.env
# LOG: /var/log/uhm.log -- written with a plain append, not the log()+tee
# pattern the rest of the project uses: as a systemd service, stdout is
# already captured by journald, so tee would duplicate every line into
# both the file and the journal.
# SERVICE: systemctl status uhmd
#
# LOCATION:
# Installed at /etc/uhm/core/uhmd.sh, alongside uhmd.service, uhmreload.sh,
# uhmleases.sh, and uhmwatch.sh -- these five are mandatory, either as the
# reload mechanism itself or (uhmwatch.sh) as the services watchdog (see
# its own header for why). /etc/uhm/tools/ holds independent, optional
# scripts (uhmaudit.sh, uhmcheck.sh, uhmmon.sh, uhmalert.sh, plus the
# admin-provided uhmiptables.sh) -- uhm runs fine without any of those. The reload
# script path itself is read from UHM_RELOAD in uhm.env
# (set by uhmsetup.sh, default /etc/uhm/core/uhmreload.sh) -- nothing here
# hardcodes it, so relocating core/ only requires updating that one value.
#
################################################################################

set -uo pipefail

# -- Logging -------------------------------------------------------------------
LOG_FILE="/var/log/uhm.log"
# _CYCLE_MARK_FILE tracks whether the delimiter line has already been printed
# for the current cycle. A file, not a variable, because several call sites
# (e.g. api_get's $(...) calls) invoke log() from inside a subshell -- a
# variable set there would be lost on subshell exit, but a file write
# persists. Absent at process start, so the very first log() call of the
# whole process (verify_installation's "Installation verified") prints the
# delimiter too -- covering daemon startup with the same mechanism, no
# special case needed. run_cycle() removes it at the start of every loop
# iteration, so a cycle with no activity produces no delimiter and no lines
# at all; a cycle with any activity gets exactly one delimiter, right before
# its first line.
_CYCLE_MARK_FILE="/run/uhmd_cycle_mark"
log() {
    if [[ ! -e "$_CYCLE_MARK_FILE" ]]; then
        echo "--------------------------------------------------------------------------------" >> "$LOG_FILE" 2>/dev/null || true
        : > "$_CYCLE_MARK_FILE" 2>/dev/null || true
    fi
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Same output format as log(), but never opens a delimiter block of its own.
# Used only for the shutdown notice (see cleanup_temp): that line closes out
# whatever was last logged in this process rather than starting a new one.
# The next process (a fresh uhmd start) still gets its own delimiter as
# usual, since _CYCLE_MARK_FILE lives under /run and is cleared on reboot.
log_raw() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

## root check
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root" >&2
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

# DEPENDENCIES
for dep in curl jq mawk coreutils util-linux grep sed systemd; do
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

# IPv4 <-> integer. Every octet is forced base 10 (10#) so a value like 010
# is never read as octal. Ranges are walked and compared as integers, so no
# step below assumes a particular netmask or a three-octet prefix.
_ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

_int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# True if $1 belongs to the LAN pydhcp serves (SERV_SUBNET/SERV_MASK).
_ip_in_lan() {
    local n
    n=$(_ip_to_int "$1")
    (( (n & _MASK_INT) == (_SUBNET_INT & _MASK_INT) ))
}

# CYCLE_LOCK is separate from SCRIPT_LOCK (the singleton instance guard, held
# for the daemon's entire lifetime). CYCLE_LOCK is only held while run_cycle
# is actively mutating ACL files (~1-3s), released during the sleep between
# cycles. A manual, standalone run of uhmleases.sh (UHM_RELOAD_ACTIVE
# unset) checks THIS lock, not SCRIPT_LOCK, so it only waits during the
# narrow window where a real race on the ACL files could occur -- not for
# the daemon's entire uptime.
CYCLE_LOCK="/var/lock/uhmd-cycle.lock"
exec 201>"$CYCLE_LOCK"

TEMP_FILES_TO_CLEAN=()
cleanup_temp() {
    local rc=$?
    local f
    for f in "${TEMP_FILES_TO_CLEAN[@]+"${TEMP_FILES_TO_CLEAN[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
    # Only skip the "done" announcement on an explicit error exit (exit 1) --
    # the ERROR line already logged is the signal that something happened.
    # A normal stop (systemctl stop sends SIGTERM, rc=143) is not that case
    # and must still log done. Uses log_raw, not log, so this line closes out
    # whatever was last logged instead of opening a delimiter block of its
    # own -- a raya must mark the start of a cycle/session, never a shutdown.
    if (( rc != 1 )) && declare -F log_raw &>/dev/null; then
        log_raw "INFO: uhmd done at: $(date)"
    fi
}
trap cleanup_temp EXIT

# -- Paths & constants ---------------------------------------------------------
# CONFIG_FILE is the one path that cannot itself live in uhm.env -- the
# daemon needs to know where that file is before it can be opened and read.
# Every other path below (UHM_MACAUTH, BLOCK_DHCP, ACL_MAC_PATH,
# UHM_QUEUE) is set inside load_config(), after uhm.env is
# loaded, with the same fallback default shown here.
CONFIG_FILE="/etc/uhm/uhm.env"

TOKEN_STATE_FILE="/run/uhmd_session"

AUTHORIZED_LEASE_TIME_DEFAULT=2592000

# -- Runtime state -------------------------------------------------------------
SESSION_TOKEN=""
CSRF_TOKEN=""
VOUCHER_CACHE=""
VOUCHER_COUNT=0
SESSIONS_AUTHORIZED=0
REVOKED=0
NEWLY_AUTHORIZED_MACS=()
declare -A REVOKED_SESSIONS=()
# Backend readiness tracking: the login endpoint can answer well before the
# UniFi Network application's data endpoints (stat/voucher, stat/guest,
# stat/sta) finish coming up -- common for a couple of minutes after a
# controller/host reboot. These flags capture the rc the cycle already
# computes for each, so run_cycle can log a single "backend ready" line on the
# not-ready -> ready transition (and re-arm it if the backend drops again).
_VOUCHERS_OK=0
_GUEST_OK=0
_STA_OK=0
_BACKEND_READY=0
_ACL_SNAPSHOT_HOTSPOT=""
_ACL_SNAPSHOT_BLOCK=""
_ACL_SNAPSHOT_QUEUE=""
_ACL_SNAPSHOT_GRACE=""
_RELOAD_OK=0
# mac-*.txt change watcher (see check_mac_lists_changed): independent of the
# ACL snapshot/reload mechanism above -- its own baseline and its own pending
# flag, never reusing uhm-queue.txt or the _ACL_SNAPSHOT_* machinery.
_MAC_LISTS_HASH_PREV=""
_MAC_RELOAD_PENDING=0
# Safety-net reload: forces UHM_RELOAD even without an ACL diff,
# on this cadence, so idle networks still get grace->block promotion and the
# firewall self-heals without depending on an external cron entry (see
# check_and_reload_if_changed). Default set in main(), alongside
# POLL_INTERVAL; overridable via RELOAD_SAFETY_INTERVAL_SECONDS in
# uhm.env. main() aborts below 3x (UHM_LEASES_TIMEOUT_SECONDS +
# UHM_IPTABLES_TIMEOUT_SECONDS), never below 600 -- both timeouts are
# themselves configurable, so the floor is computed, not fixed. The cadence
# is measured from the moment a reload starts, not when it ends, so at the
# floor the daemon still rests at least twice as long as the slowest reload
# the timeouts allow. Every reload stops and starts pydhcpd. Fallbacks 120
# and 60 must stay in sync with uhmreload.sh, which reads the same two
# values.
_LAST_RELOAD_EPOCH=0

# Loads only known KEY=VALUE pairs from CONFIG_FILE instead of sourcing it,
# so a tampered or maliciously replaced config file cannot execute code --
# same approach as uhmleases.sh's load_env_file().
load_env_file() {
    local file="$1" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
            value="${value:1:$((${#value}-2))}"
            value="${value//\\\"/\"}"
            value="${value//\\\$/\$}"
            value="${value//\\\`/\`}"
            value="${value//\\\\/\\}"
        fi
        case "$key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_TYPE|UNIFI_SITE|UNIFI_CERT_PIN|\
            SERVER_IP|SERV_SUBNET|SERV_MASK|UHM_PATH|\
            UHM_INI_RANGE|UHM_END_RANGE|\
            UHM_RELOAD|UHM_GRACE|UHM_MACAUTH|ACL_BLOCK_FILE|ACL_MAC_PATH|ACL_PATH|\
            UHM_QUEUE|PYDHCPD_LEASES|POLL_INTERVAL|STARTUP_GRACE_SECONDS|\
            RELOAD_SAFETY_INTERVAL_SECONDS|AUTHORIZED_LEASE_TIME|\
            UHM_LEASES_TIMEOUT_SECONDS|UHM_IPTABLES_TIMEOUT_SECONDS)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}

# -- Config --------------------------------------------------------------------
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

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: $CONFIG_FILE not found" >&2
        exit 1
    fi
    local _owner _perms _gdigit _odigit
    _owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
    _perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    _gdigit="${_perms: -2:1}"
    _odigit="${_perms: -1}"
    if [[ "$_owner" != "root" ]] || [[ "$_gdigit" != "0" ]] || [[ "$_odigit" != "0" ]]; then
        echo "ERROR: $CONFIG_FILE has unsafe owner/permissions (owner=$_owner perms=$_perms)" >&2
        echo "ERROR: must be owned by root with no group/other access (600)" >&2
        exit 1
    fi
    load_env_file "$CONFIG_FILE"

    # uhm's own ACL files (UHM_MACAUTH, UHM_GRACE, UHM_QUEUE) and
    # pydhcp's (BLOCK_DHCP, ACL_MAC_PATH) -- all configurable via uhm.env,
    # same fallback defaults as uhmleases.sh uses for the same variables.
    # uhm's own three hang off UHM_PATH so the install directory is
    # named once and never repeated per file.
    UHM_PATH="${UHM_PATH:-/etc/uhm}"
    ACL_PATH="${ACL_PATH:-/etc/acl}"
    PYDHCPD_LEASES="${PYDHCPD_LEASES:-/etc/pydhcp/pydhcpd.leases}"
    UHM_MACAUTH="${UHM_MACAUTH:-$UHM_PATH/acl/uhm-auth.txt}"
    BLOCK_DHCP="${ACL_BLOCK_FILE:-$ACL_PATH/acl_dhcp/blockdhcp.txt}"
    ACL_MAC_PATH="${ACL_MAC_PATH:-$ACL_PATH/acl_mac}"
    UHM_GRACE="${UHM_GRACE:-$UHM_PATH/acl/uhm-grace.txt}"
    UHM_QUEUE="${UHM_QUEUE:-$UHM_PATH/acl/uhm-queue.txt}"

    ensure_acl_lists "$UHM_MACAUTH" "$UHM_GRACE" "$UHM_QUEUE"

    local missing=()
    [[ -z "${UNIFI_CONTROLLER_URL:-}" ]] && missing+=("UNIFI_CONTROLLER_URL")
    [[ -z "${UNIFI_USERNAME:-}" ]] && missing+=("UNIFI_USERNAME")
    [[ -z "${UNIFI_PASSWORD:-}" ]] && missing+=("UNIFI_PASSWORD")
    [[ -z "${SERVER_IP:-}" ]] && missing+=("SERVER_IP")
    [[ -z "${SERV_SUBNET:-}" ]] && missing+=("SERV_SUBNET")
    [[ -z "${SERV_MASK:-}" ]] && missing+=("SERV_MASK")
    [[ -z "${UHM_INI_RANGE:-}" ]] && missing+=("UHM_INI_RANGE")
    [[ -z "${UHM_END_RANGE:-}" ]] && missing+=("UHM_END_RANGE")
    [[ -z "${UHM_RELOAD:-}" ]] && missing+=("UHM_RELOAD")
    [[ -z "${UNIFI_TYPE:-}" ]] && missing+=("UNIFI_TYPE")
    [[ -z "${UNIFI_SITE:-}" ]] && missing+=("UNIFI_SITE")

    if (( ${#missing[@]} > 0 )); then
        log "ERROR: missing variables in $CONFIG_FILE:"
        local _m
        for _m in "${missing[@]}"; do
            log "ERROR: $_m"
        done
        exit 1
    fi

    if ! [[ "$SERVER_IP" =~ $_UH_IPV4 ]]; then
        log "ERROR: SERVER_IP is not a valid IPv4 address in $CONFIG_FILE"
        log "ERROR: got: '$SERVER_IP'"
        exit 1
    fi

    if ! [[ "$SERV_SUBNET" =~ $_UH_IPV4 ]] || ! [[ "$SERV_MASK" =~ $_UH_NETMASK ]]; then
        log "ERROR: SERV_SUBNET/SERV_MASK are not a valid network in $CONFIG_FILE"
        log "ERROR: got: '$SERV_SUBNET'/'$SERV_MASK'"
        exit 1
    fi
    _SUBNET_INT=$(_ip_to_int "$SERV_SUBNET")
    _MASK_INT=$(_ip_to_int "$SERV_MASK")

    if [[ "${UNIFI_TYPE:-}" != "unifi-os" && "${UNIFI_TYPE:-}" != "classic" ]]; then
        log "ERROR: UNIFI_TYPE must be 'unifi-os' or 'classic'"
        log "ERROR: got: ${UNIFI_TYPE:-unset}"
        exit 1
    fi

    # UNIFI_SITE is interpolated directly into API URLs (api_path()) -- reject
    # anything outside the character set UniFi itself uses for site names.
    if [[ ! "$UNIFI_SITE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log "ERROR: UNIFI_SITE contains invalid characters: $UNIFI_SITE"
        exit 1
    fi

    if ! [[ "$UHM_INI_RANGE" =~ $_UH_IPV4 ]] || ! [[ "$UHM_END_RANGE" =~ $_UH_IPV4 ]]; then
        log "ERROR: hotspot range must be two valid IPv4 addresses"
        log "ERROR: UHM_INI_RANGE/UHM_END_RANGE in $CONFIG_FILE"
        log "ERROR: got: '$UHM_INI_RANGE'/'$UHM_END_RANGE'"
        exit 1
    fi

    _HOTSPOT_INI_INT=$(_ip_to_int "$UHM_INI_RANGE")
    _HOTSPOT_END_INT=$(_ip_to_int "$UHM_END_RANGE")
    if (( _HOTSPOT_INI_INT > _HOTSPOT_END_INT )); then
        log "ERROR: UHM_INI_RANGE ($UHM_INI_RANGE) is above"
        log "ERROR: UHM_END_RANGE ($UHM_END_RANGE)"
        exit 1
    fi

    if ! _ip_in_lan "$UHM_INI_RANGE" || ! _ip_in_lan "$UHM_END_RANGE"; then
        log "ERROR: hotspot range falls outside $SERV_SUBNET/$SERV_MASK"
        log "ERROR: got: $UHM_INI_RANGE-$UHM_END_RANGE"
        exit 1
    fi
}

# -- Installation check --------------------------------------------------------
verify_installation() {
    if [[ ! -f "${UHM_RELOAD:-}" ]]; then
        log "ERROR: UHM_RELOAD not found: ${UHM_RELOAD:-unset}"
        exit 1
    elif [[ ! -x "$UHM_RELOAD" ]]; then
        log "ERROR: UHM_RELOAD not executable: $UHM_RELOAD"
        exit 1
    fi
    # pydhcpd often boots alongside this host and may not be up yet -- give it
    # the same startup grace as the UniFi login below instead of failing
    # instantly.
    local _pydhcpd_start _pydhcpd_elapsed
    _pydhcpd_start=$(date +%s)
    until systemctl is-active --quiet pydhcpd 2>/dev/null; do
        _pydhcpd_elapsed=$(( $(date +%s) - _pydhcpd_start ))
        if (( _pydhcpd_elapsed >= STARTUP_GRACE_SECONDS )); then
            log "ERROR: pydhcpd is not active after ${STARTUP_GRACE_SECONDS}s"
            exit 1
        fi
        sleep 10
    done
    log "INFO: Installation verified"
}

# -- ACL file check --------------------------------------------------------------
# uhm's own three lists (UHM_MACAUTH/UHM_GRACE/UHM_QUEUE) are created
# on demand by ensure_acl_lists() in load_config(). BLOCK_DHCP belongs to pydhcp
# and is deployed by its own pysetup.sh -- this daemon writes to it but must
# never create it, so a missing one means a broken/partial pydhcp install.
init_acl_files() {
    if [ ! -f "$BLOCK_DHCP" ]; then
        log "ERROR: Missing ACL file: $BLOCK_DHCP"
        log "ERROR: run pydhcp's pysetup.sh to recreate it."
        exit 1
    fi
}

# -- UniFi API -----------------------------------------------------------------
# SESSION_TOKEN and CSRF_TOKEN are written to TOKEN_STATE_FILE after every
# login and after every API response that rotates them. Because api_get and
# api_post run inside $(...) subshells, variable updates inside those subshells
# are lost when the subshell exits. Writing to a file sidesteps that: the next
# subshell reads the file at entry and picks up the latest token, so a single
# reauth propagates correctly across all subsequent calls in the same cycle.

api_path() {
    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        echo "${UNIFI_CONTROLLER_URL}/proxy/network/api/s/${UNIFI_SITE}/${1}"
    else
        echo "${UNIFI_CONTROLLER_URL}/api/s/${UNIFI_SITE}/${1}"
    fi
}

# Session cookie name differs by controller type: classic uses "unifises",
# unifi-os uses "TOKEN" (a JWT).
_session_cookie_name() {
    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        echo "unifises"
    else
        echo "TOKEN"
    fi
}

_save_session() {
    ( umask 077; printf '%s\n%s\n' "$SESSION_TOKEN" "$CSRF_TOKEN" > "$TOKEN_STATE_FILE" ) 2>/dev/null || true
    chmod 600 "$TOKEN_STATE_FILE" 2>/dev/null || true
}

_load_session() {
    [[ ! -f "$TOKEN_STATE_FILE" ]] && return
    local tok csrf
    { IFS= read -r tok; IFS= read -r csrf; } < "$TOKEN_STATE_FILE" 2>/dev/null || return
    [[ -n "$tok" ]] && SESSION_TOKEN="$tok"
    [[ -n "$csrf" ]] && CSRF_TOKEN="$csrf"
}

_update_session_from_headers() {
    local hfile="$1"
    [[ ! -f "$hfile" ]] && return
    local new_tok new_csrf changed=0 cookie_name
    cookie_name=$(_session_cookie_name)
    new_tok=$(grep -iE "^set-cookie:[[:space:]]*${cookie_name}=" "$hfile" \
        | head -1 \
        | sed -E "s/^[^:]+:[[:space:]]*${cookie_name}=([^;]+).*/\1/" \
        | tr -d '\r\n' || true)
    new_csrf=$(grep -iE '^(x-updated-csrf-token|x-csrf-token):' "$hfile" | tail -1 \
        | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '\r\n' || true)
    if [[ -n "$new_tok" && "$new_tok" != "$SESSION_TOKEN" ]]; then SESSION_TOKEN="$new_tok"; changed=1; fi
    if [[ -n "$new_csrf" && "$new_csrf" != "$CSRF_TOKEN" ]]; then CSRF_TOKEN="$new_csrf"; changed=1; fi
    (( changed )) && _save_session
}

unifi_login() {
    local quiet="${1:-}"
    local login_url header_file http_code payload

    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
    else
        login_url="${UNIFI_CONTROLLER_URL}/api/login"
    fi

    header_file=$(mktemp)
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline). Environment is only readable by
    # the same user or root (/proc/<pid>/environ).
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    # Body goes to curl via stdin (--data-binary @-), not -d, for the same
    # reason: -d "$payload" would put the password in curl's argv too.
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${_tls_opts[@]}" \
        -D "$header_file" \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST "$login_url" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 10 --max-time 40 <<< "$payload" 2>/dev/null || true)
    http_code="${http_code:-000}"

    if [[ "$http_code" != "200" ]]; then
        if [[ "$quiet" == "quiet" ]]; then
            log "INFO: UniFi login attempt failed (HTTP $http_code)"
            log "INFO: still within startup grace window"
        else
            log "ERROR: UniFi login failed (HTTP $http_code)"
        fi
        rm -f "$header_file"
        return 1
    fi

    local new_csrf new_tok cookie_name
    cookie_name=$(_session_cookie_name)
    new_tok=$(grep -iE "^set-cookie:[[:space:]]*${cookie_name}=" "$header_file" \
        | head -1 \
        | sed -E "s/^[^:]+:[[:space:]]*${cookie_name}=([^;]+).*/\1/" \
        | tr -d '\r\n' || true)

    if [[ -z "$new_tok" ]]; then
        log "ERROR: Login OK but ${cookie_name} cookie not found"
        rm -f "$header_file"
        return 1
    fi

    SESSION_TOKEN="$new_tok"

    # UniFi OS embeds the CSRF token inside the JWT payload (csrfToken field).
    # Extract it from the second segment of the JWT (base64-encoded JSON).
    local jwt_payload pad padded
    jwt_payload=$(echo "$new_tok" | cut -d'.' -f2 | tr '_-' '/+')
    pad=$(( (4 - ${#jwt_payload} % 4) % 4 ))
    padded="$jwt_payload"
    if (( pad > 0 )); then
        padded="${jwt_payload}$(printf '%*s' "$pad" '' | tr ' ' '=')"
    fi
    new_csrf=$(echo "$padded" | base64 -d 2>/dev/null \
        | jq -r '.csrfToken // empty' 2>/dev/null || true)

    # Fallback: check response headers (classic UniFi controller).
    # Header file must still exist at this point -- do not delete it before here.
    if [[ -z "$new_csrf" ]]; then
        new_csrf=$(grep -iE '^(x-updated-csrf-token|x-csrf-token):' "$header_file" \
            | tail -1 | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '\r\n' || true)
    fi

    rm -f "$header_file"

    CSRF_TOKEN="$new_csrf"
    _save_session
    log "INFO: UniFi login OK"
}

api_get() {
    local url="$1"
    _load_session

    local hdr
    hdr=$(mktemp)

    local args=(-s -k -w "\n__CODE__:%{http_code}" -D "$hdr"
        -H "Cookie: $(_session_cookie_name)=${SESSION_TOKEN}")
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
    [[ -n "$CSRF_TOKEN" ]] && args+=(-H "x-csrf-token: $CSRF_TOKEN")

    local raw code body
    raw=$(curl --max-time 30 "${args[@]}" "$url" 2>/dev/null || true)
    code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    body=$(echo "$raw" | grep -v '__CODE__:')
    _update_session_from_headers "$hdr"

    if [[ "$code" == "401" ]]; then
        log "INFO: Session expired -- re-authenticating"
        if ! unifi_login; then
            log "ERROR: Re-authentication failed"
            rm -f "$hdr"
            echo "{}"
            return 1
        fi
        _load_session
        args=(-s -k -w "\n__CODE__:%{http_code}" -D "$hdr"
            -H "Cookie: $(_session_cookie_name)=${SESSION_TOKEN}")
        [[ -n "${UNIFI_CERT_PIN:-}" ]] && args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
        [[ -n "$CSRF_TOKEN" ]] && args+=(-H "x-csrf-token: $CSRF_TOKEN")
        raw=$(curl --max-time 30 "${args[@]}" "$url" 2>/dev/null || true)
        code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
        body=$(echo "$raw" | grep -v '__CODE__:')
        _update_session_from_headers "$hdr"
    fi

    rm -f "$hdr"

    if [[ -z "$code" ]]; then
        log "WARNING: API GET $url -> no response"
        log "WARNING: (timeout or network error)"
        echo "{}"
        return 0
    fi
    if [[ "$code" != "200" ]]; then
        log "WARNING: API GET $url -> HTTP $code"
        echo "{}"
        return 0
    fi

    echo "$body"
}

api_post() {
    local url="$1" payload="$2"
    _load_session

    local hdr
    hdr=$(mktemp)

    local args=(-s -k -w "\n__CODE__:%{http_code}" -D "$hdr"
        -X POST
        -H "Content-Type: application/json"
        -H "Cookie: $(_session_cookie_name)=${SESSION_TOKEN}")
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
    [[ -n "$CSRF_TOKEN" ]] && args+=(-H "x-csrf-token: $CSRF_TOKEN")

    local raw code
    raw=$(curl --max-time 30 "${args[@]}" -d "$payload" "$url" 2>/dev/null || true)
    code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    _update_session_from_headers "$hdr"

    if [[ "$code" == "401" ]]; then
        log "INFO: Session expired on POST -- re-authenticating"
        if ! unifi_login; then
            log "ERROR: Re-authentication failed on POST"
            rm -f "$hdr"
            echo "$code"
            return 1
        fi
        _load_session
        args=(-s -k -w "\n__CODE__:%{http_code}" -D "$hdr"
            -X POST
            -H "Content-Type: application/json"
            -H "Cookie: $(_session_cookie_name)=${SESSION_TOKEN}")
        [[ -n "${UNIFI_CERT_PIN:-}" ]] && args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
        [[ -n "$CSRF_TOKEN" ]] && args+=(-H "x-csrf-token: $CSRF_TOKEN")
        raw=$(curl --max-time 30 "${args[@]}" -d "$payload" "$url" 2>/dev/null || true)
        code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
        _update_session_from_headers "$hdr"
    fi

    rm -f "$hdr"
    echo "$code"
}

# -- Step 1: voucher cache -----------------------------------------------------
load_all_vouchers() {
    local url rc count
    url=$(api_path "stat/voucher")
    VOUCHER_CACHE=$(api_get "$url")
    rc=$(echo "$VOUCHER_CACHE" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    if [[ "$rc" != "ok" ]]; then
        _VOUCHERS_OK=0
        log "WARNING: Could not load vouchers (rc=${rc:-empty})"
        VOUCHER_CACHE=""
        VOUCHER_COUNT=0
        return
    fi
    _VOUCHERS_OK=1
    count=$(echo "$VOUCHER_CACHE" | jq '.data | length' 2>/dev/null || echo 0)
    VOUCHER_COUNT="$count"
}

# -- IP/hostname assignment ----------------------------------------------------
# NOTE: called inside $() subshells -- no log(), no side effects.
# Returns "IP;hostname" via stdout only. Guest number is derived from the
# candidate IP's position in the hotspot range, not parsed from hostnames.
assign_ip_and_hostname() {
    # Used IPs are collected once into a lookup table instead of one grep per
    # candidate IP -- O(range size) instead of O(range size * UHM_MACAUTH size).
    local -A used_ips=()
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && used_ips["$ip"]=1
    done < <(awk -F';' '{print $3}' "$UHM_MACAUTH" 2>/dev/null)

    # Defense-in-depth only (already validated in load_config()); must never
    # log() since this runs inside a $(...) subshell.
    if ! [[ "$UHM_INI_RANGE" =~ $_UH_IPV4 ]] || ! [[ "$UHM_END_RANGE" =~ $_UH_IPV4 ]]; then
        return 1
    fi

    local i candidate
    for (( i=_HOTSPOT_INI_INT; i<=_HOTSPOT_END_INT; i++ )); do
        candidate=$(_int_to_ip "$i")
        [[ -n "${used_ips[$candidate]+x}" ]] && continue
        echo "${candidate};guest$(( i - _HOTSPOT_INI_INT + 1 ))"
        return 0
    done
    return 1
}

# -- Lease removal queue -------------------------------------------------------
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
queue_lease_removal() {
    local mac="$1"
    local lc_mac
    lc_mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    if grep -qxF "$lc_mac" "$UHM_QUEUE" 2>/dev/null; then
        return 0
    fi
    if echo "$lc_mac" >> "$UHM_QUEUE" 2>/dev/null; then
        log "INFO: Queued lease removal for $lc_mac"
        return 0
    fi
    log "WARNING: failed to write $lc_mac"
    log "WARNING: to $UHM_QUEUE"
    return 1
}

# -- Independent mechanism: mac-*.txt change watcher ---------------------------
# NOT one of the numbered cycle steps and NOT part of the ACL snapshot/reload
# machinery above (_ACL_SNAPSHOT_*, uhm-queue.txt) -- deliberately separate, per
# the invariant that uhmd.sh never processes mac-*.txt content (only
# uhmleases.sh does). This only fingerprints the files (combined md5sum of
# path+content, so an add/remove/edit of any mac-*.txt all count) to detect
# that *something* changed, with zero parsing of MACs/status.
#
# A change detected this cycle does NOT reload immediately -- it only sets
# _MAC_RELOAD_PENDING for check_and_reload_if_changed to pick up next cycle,
# so it never causes a second, separate uhmreload.sh invocation in the same run
# as one already triggered by the uhm-auth/blockdhcp/queue/uhm-grace diff.
check_mac_lists_changed() {
    local cur_hash
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#mac_files[@]} > 0 )); then
        cur_hash=$(md5sum "${mac_files[@]}" 2>/dev/null | sort | md5sum | awk '{print $1}')
    else
        cur_hash="none"
    fi

    if [[ -n "$_MAC_LISTS_HASH_PREV" && "$cur_hash" != "$_MAC_LISTS_HASH_PREV" ]]; then
        _MAC_RELOAD_PENDING=1
        log "INFO: mac-*.txt changed -- reload scheduled for next cycle"
    fi
    _MAC_LISTS_HASH_PREV="$cur_hash"
}

# -- Live managed-MAC check (defense-in-depth) ---------------------------------
# True if $1 is listed in ANY mac-*.txt, active (a;) or deactivated (#a;).
# Reads fresh from disk on every call -- this is a narrow, deliberate exception
# to "uhmd never processes mac-*.txt content" (see MANAGED MACS note
# above): a managed device can still show up in stat/guest with a live guest
# authorization that has nothing to do with this daemon (a residual session
# from before uhmd stopped calling authorize-guest, one granted by hand
# in UniFi, or a voucher redeemed on that device before it was added to
# mac-*.txt). That must never be promoted into uhm-auth.txt regardless of
# what stat/guest reports -- used by process_sessions (step 7) and, as
# defense-in-depth, kick_newly_authorized (step 10).
is_managed_mac() {
    local m="${1,,}" f
    [[ -z "$m" ]] && return 1
    [[ "$m" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
    shopt -s nullglob
    local files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for f in "${files[@]}"; do
        grep -qiE "^#?a;${m};" "$f" 2>/dev/null && return 0
    done
    return 1
}

# All ACTIVE (not commented) MACs across mac-*.txt, lowercased, one per line.
# Used only by authorize_managed_macs() below -- a deactivated ("#a;...")
# entry has already lost its fixed address and joined the blockdhcp class
# (see uhmleases.sh), so it must never be granted a UniFi authorization either.
list_managed_macs() {
    shopt -s nullglob
    local files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    (( ${#files[@]} == 0 )) && return
    awk -F';' '/^a;/{print tolower($2)}' "${files[@]}" 2>/dev/null \
        | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u
}

# -- UniFi authorization for managed MACs (mac-*.txt) --------------------------
# On any WLAN configured as Guest/Hotspot (see README UNIFI PRE-CONFIGURATION),
# UniFi enforces its own captive-portal state per client via the "authorized"
# flag in stat/sta -- entirely independent of pydhcpd's fixed-address DHCP
# bypass or uhmiptables.sh's firewall rules. A mac-*.txt device is still held
# at the portal by the AP until UniFi itself marks it authorized, no matter
# how correct its DHCP/firewall state is. This reverses the previous
# assumption (see the old MANAGED MACS note) that DHCP-level bypass alone was
# sufficient -- confirmed false by direct stat/sta queries showing
# is_guest=true/authorized=false for a mac-*.txt device with a fully correct
# fixed IP.
#
# Only acts on a managed MAC currently reported by stat/sta with
# authorized=false (mirrors is_managed_mac's own on-disk-truth philosophy: no
# separate cache of "already authorized" is kept, so this is naturally
# idempotent and self-heals if UniFi's own authorization ever lapses).
# The duration is not a value of uhm's own: UniFi's authorize-guest takes
# minutes, so it is derived from AUTHORIZED_LEASE_TIME (uhm.env, pydhcp's
# own value in seconds, default 2592000 = 30 days) divided by 60. A
# mac-*.txt device already gets that lease time from pydhcpd, so its portal
# authorization follows the same policy instead of duplicating it under a
# second name and unit. It is renewed well before expiry simply by virtue of
# running every cycle and re-checking authorized==false -- a device is
# authorized again long before its previous grant would run out, so in
# practice it is never seen unauthorized.
authorize_managed_macs() {
    local sta_data="$1" rc mac authorized minutes url http_code
    rc=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$rc" != "ok" ]] && return

    minutes=$(( AUTHORIZED_LEASE_TIME / 60 ))
    (( minutes < 1 )) && minutes=1

    local managed_macs
    managed_macs=$(list_managed_macs)
    [[ -z "$managed_macs" ]] && return

    while IFS= read -r mac; do
        [[ -z "$mac" ]] && continue
        authorized=$(echo "$sta_data" | jq -r --arg m "$mac" '
            .data[] | select((.mac // "" | ascii_downcase) == $m) | .authorized
        ' 2>/dev/null | head -1)
        # Not currently connected (no stat/sta entry) -- nothing to authorize
        # yet; picked up automatically once it associates and appears there.
        [[ -z "$authorized" || "$authorized" == "null" ]] && continue
        [[ "$authorized" == "true" ]] && continue

        url=$(api_path "cmd/stamgr")
        http_code=$(api_post "$url" "{\"cmd\":\"authorize-guest\",\"mac\":\"${mac}\",\"minutes\":${minutes}}")
        if [[ "$http_code" == "200" ]]; then
            log "INFO: Authorized managed MAC $mac in UniFi"
            log "INFO: (minutes=$minutes)"
        else
            log "WARNING: Failed to authorize managed MAC $mac in UniFi"
            log "WARNING: (HTTP $http_code)"
        fi
    done <<< "$managed_macs"
}

# -- Step 3: MAC list deduplication -------------------------------------------
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
dedup_mac_lists() {
    local all_macs
    all_macs=$(
        awk -F';' '/^a;/{print tolower($2)}' "$UHM_MACAUTH" 2>/dev/null \
          | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
          | sort -u || true
    )

    local sanitized_block=0
    local discarded_block=0

    if [[ -f "$BLOCK_DHCP" ]]; then
        local tmp_block
        tmp_block=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${tmp_block}")
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            if [[ "$line" != "a;"* ]]; then
                echo "$line" >> "$tmp_block"
                continue
            fi
            local bmac bip bhostname field_count
            IFS=';' read -r _ bmac bip bhostname _ <<< "$line"
            bmac=$(echo "$bmac" | tr '[:upper:]' '[:lower:]')
            if echo "$all_macs" | grep -q "^${bmac}$"; then
                log "INFO: dedup -> removed $bmac from blockdhcp.txt"
                continue
            fi
            field_count=$(echo "$line" | tr -cd ';' | wc -c)
            if (( field_count != 4 )); then
                if [[ "$bmac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && \
                   [[ "$bip" =~ $_UH_IPV4 ]] && \
                   [[ "$bhostname" =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    echo "a;${bmac};${bip};${bhostname};" >> "$tmp_block"
                    (( sanitized_block++ )) || true
                else
                    log "WARNING: dedup -> discarding malformed blockdhcp.txt line"
                    log "WARNING: $line"
                    (( discarded_block++ )) || true
                fi
            else
                echo "$line" >> "$tmp_block"
            fi
        done < "$BLOCK_DHCP"
        local after_lines
        after_lines=$(wc -l < "$tmp_block" 2>/dev/null || echo -1)
        if (( after_lines < 0 )); then
            log "ERROR: failed to validate temp file"
            log "ERROR: skipping blockdhcp update"
            rm -f "$tmp_block"
        else
            mv "$tmp_block" "$BLOCK_DHCP" && chmod 600 "$BLOCK_DHCP"
        fi
    fi

    if (( sanitized_block > 0 )); then
        log "INFO: dedup -> sanitized $sanitized_block blockdhcp entries"
    fi
    if (( discarded_block > 0 )); then
        log "INFO: dedup discarded $discarded_block malformed entries"
    fi
}

# -- Step 4: sort ACL files by IP ---------------------------------------------
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
sort_acl_files() {
    local tmp

    if [[ -s "$UHM_MACAUTH" ]]; then
        tmp=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${tmp}")
        sort -t';' -k3,3V "$UHM_MACAUTH" | uniq > "$tmp"
        if [[ ! -s "$tmp" ]]; then
            log "ERROR: sorted output is empty"
            log "ERROR: skipping update of $UHM_MACAUTH"
            return
        fi
        mv "$tmp" "$UHM_MACAUTH" && chmod 600 "$UHM_MACAUTH"
    fi
}

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
add_mac_to_acl() {
    local mac="$1" ip="$2" hostname="$3" end_time="$4"

    if [[ ! "$mac" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]; then
        log "ERROR: bad MAC '$mac'"
        log "ERROR: not added"
        return 1
    fi

    if [[ "$ip" == *';'* || "$hostname" == *';'* || "$end_time" == *';'* ]]; then
        log "ERROR: Refusing ACL entry"
        log "ERROR: field contains ';' (mac=$mac)"
        return 1
    fi

    local new_line="a;${mac};${ip};${hostname};${end_time};"

    if grep -qi "^a;${mac};" "$UHM_MACAUTH" 2>/dev/null; then
        local existing_end
        existing_end=$(grep -i "^a;${mac};" "$UHM_MACAUTH" | head -1 | awk -F';' '{print $5}')
        if [[ "$end_time" != "$existing_end" ]]; then
            local escaped_line
            escaped_line=$(printf '%s' "$new_line" | sed -e 's/[\&|/]/\\&/g')
            if ! sed -i "s|^a;${mac};.*|${escaped_line}|I" "$UHM_MACAUTH"; then
                log "ERROR: Failed to update end_time for $mac"
                log "ERROR: (sed -i failed)"
                return 1
            fi
            log "INFO: Updated end_time for $mac"
            log "INFO: ($existing_end -> $end_time)"
        fi
    else
        queue_lease_removal "$mac"
        echo "$new_line" >> "$UHM_MACAUTH"
        local exp_human
        exp_human=$(date -d "@$end_time" 2>/dev/null || echo "$end_time")
        log "INFO: Authorized $mac"
        log "INFO: ip=$ip hostname=$hostname"
        log "INFO: expires=$exp_human"
    fi
}

expire_from_hotspot() {
    local mac="$1"
    # Release the hotspot-range IP. On reconnect, uhmleases.sh detects the
    # client via pydhcpd.leases and the client re-enters uhm-grace.txt with a
    # fresh grace timer, same as any other unclassified MAC.
    if ! queue_lease_removal "$mac"; then
        log "WARNING: Expire $mac"
        log "WARNING: failed to queue lease removal, will retry"
        return 1
    fi
    log "INFO: Expired $mac"
    log "INFO: released from uhm-auth.txt"
    return 0
}

# -- Step 5: clean expired MACs ------------------------------------------------
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
clean_expired_macs() {
    local now tmp
    now=$(date +%s)
    tmp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${tmp}")

    local before_count=0
    before_count=$(grep -c '^#\{0,1\}a;' "$UHM_MACAUTH" 2>/dev/null); before_count=$(( ${before_count:-0} + 0 ))
    local moved=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        # Unlike mac-*.txt (no expiry concept at all), a uhm-auth.txt entry is
        # keyed to a voucher's END_TIME_EPOCH regardless of active ("a;") or
        # deactivated ("#a;") state -- what matters is the MAC's voucher
        # lifecycle, not whether the admin happened to comment the line.
        # Active and commented entries are both checked here; only a line
        # that doesn't even look like an ACL entry passes through untouched.
        if [[ "$line" != "a;"* && "$line" != "#a;"* ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        local end_time mac
        end_time=$(echo "$line" | awk -F';' '{print $5}')
        mac=$(echo "$line" | awk -F';' '{print $2}')
        if [[ -z "$end_time" ]] || ! [[ "$end_time" =~ $_UH_UINT ]]; then
            if [[ -n "$end_time" ]]; then
                log "WARNING: malformed end_time"
                log "WARNING: $mac ($end_time) -- keeping entry"
            fi
            echo "$line" >> "$tmp"
        elif (( now <= end_time )); then
            echo "$line" >> "$tmp"
        else
            log "INFO: Expired $mac at $(date -d "@$end_time" 2>/dev/null || echo "$end_time")"
            if ! expire_from_hotspot "$mac"; then
                log "WARNING: keeping $mac"
                log "WARNING: will retry"
                echo "$line" >> "$tmp"
            else
                (( moved++ )) || true
            fi
        fi
    done < "$UHM_MACAUTH"

    local after_count
    after_count=$(grep -c '^#\{0,1\}a;' "$tmp" 2>/dev/null); after_count=$(( ${after_count:-0} + 0 ))
    if (( before_count - after_count != moved )); then
        log "ERROR: count mismatch"
        log "ERROR: (before=$before_count after=$after_count moved=$moved) -- skipping"
        rm -f "$tmp"
        return
    fi
    mv "$tmp" "$UHM_MACAUTH" && chmod 600 "$UHM_MACAUTH"
}

# -- Step 6: detect new clients in pydhcpd.leases ------------------------------
# Scans pydhcpd.leases for MACs that aren't yet known to any of uhmd's own
# ACL sources (uhm-auth, blockdhcp, uhm-grace) and writes them straight
# into uhm-grace.txt with a first-seen timestamp. Excludes mac-*.txt via
# is_managed_mac() (a live, on-disk check, same guard used in
# process_sessions/kick_newly_authorized): read_leases() in uhmleases.sh
# keeps a managed device's lease in pydhcpd.leases indefinitely (it's
# mac_authoritative), so that lease would otherwise match this step's own
# subnet check on every single cycle -- re-adding the MAC to
# uhm-grace.txt right after each reload's clean_grace_list removes it,
# forcing a new reload (and a pydhcpd/firewall restart) every
# POLL_INTERVAL, forever, for as long as the device stays connected.
#
# No fixed hotspot-range IP is assigned here and no lease removal is
# queued -- uhm-grace clients keep their existing pydhcpd pool lease until they
# enter a voucher or their grace timer expires (handled by uhmleases.sh).
# Writing uhm-grace.txt is enough to be picked up by the snapshot taken in
# step 2, so check_and_reload_if_changed (step 9) detects the change and
# triggers UHM_RELOAD, which runs uhmleases.sh to do the actual
# classification/expiry/blocking of grace entries.
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
process_new_leases() {
    local pydhcpd_leases="$PYDHCPD_LEASES"
    [[ ! -f "$pydhcpd_leases" ]] && return

    local added=0
    local current_lease="" lease_content=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^lease [0-9.]+ \{$'; then
            current_lease="$line"
            lease_content="$line"$'\n'
            continue
        fi
        [[ -n "$current_lease" ]] && lease_content+="$line"$'\n'

        if [[ "$line" == "}" && -n "$current_lease" ]]; then
            local mac ip host
            mac=$(echo "$lease_content" | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 | tr '[:upper:]' '[:lower:]')
            ip=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            host=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr ' ' '_')
            host=$(echo "$host" | tr -cd 'A-Za-z0-9._-' | cut -c1-63)
            [[ -z "$host" ]] && host="no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)"

            if [[ -n "$ip" ]] && ! [[ "$ip" =~ $_UH_IPV4 ]]; then
                log "WARNING: skipping lease"
                log "WARNING: invalid IP: $ip"
                ip=""
            fi

            if [[ -n "$mac" && -n "$ip" ]] \
               && _ip_in_lan "$ip" \
               && ! is_managed_mac "$mac" \
               && ! grep -qi "^a;${mac};" "$UHM_MACAUTH" 2>/dev/null \
               && ! grep -qi "^a;${mac};" "$BLOCK_DHCP" 2>/dev/null \
               && ! grep -qi "^a;${mac};" "$UHM_GRACE" 2>/dev/null; then
                echo "a;${mac};${ip};${host};$(date +%s);" >> "$UHM_GRACE"
                log "INFO: New client $mac ip=$ip"
                log "INFO: hostname=${host:0:30} -> grace"
                (( added++ )) || true
            elif [[ -n "$mac" && -n "$ip" ]] && ! _ip_in_lan "$ip"; then
                log "WARNING: new lease outside the LAN subnet"
                log "WARNING: ip=$ip mac=$mac"
                log "WARNING: subnet is $SERV_SUBNET/$SERV_MASK -- skipping"
            fi
            current_lease=""
            lease_content=""
        fi
    done < "$pydhcpd_leases"

    if (( added > 0 )); then
        chmod 600 "$UHM_GRACE" 2>/dev/null || true
        log "INFO: added $added new client(s)"
        log "INFO: add to uhm-grace"
    fi
}

# -- Step 7: process sessions --------------------------------------------------
# Queries stat/guest. Promotes voucher-authenticated clients to uhm-auth.txt.
# mac-*.txt devices are never authorized as a UniFi guest by this daemon (see
# the MANAGED MACS note above), so they never appear here from anything this
# daemon itself did -- but stat/guest can still report one with a guest
# authorization from outside this daemon (residual session, manual UniFi
# authorization, or a voucher redeemed before the device was added to
# mac-*.txt). is_managed_mac() is the live, on-disk barrier against that.
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
process_sessions() {
    local endpoint sessions_data rc added=0
    local now
    now=$(date +%s)

    endpoint=$(api_path "stat/guest")
    sessions_data=$(api_get "$endpoint")
    rc=$(echo "$sessions_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$rc" != "ok" ]] && { _GUEST_OK=0; log "INFO: stat/guest unavailable -- skipping sessions"; return; }
    _GUEST_OK=1

    # Single-pass voucher lookup: build an end_time -> voucher_code map once
    # instead of one `jq` call per session below. First vcode seen per
    # end_time wins, in case two vouchers share an end_time.
    local -A _voucher_by_end=()
    if [[ -n "$VOUCHER_CACHE" ]]; then
        while IFS=$'\t' read -r et vcode; do
            [[ -n "$et" && -z "${_voucher_by_end[$et]+x}" ]] && _voucher_by_end["$et"]="$vcode"
        done < <(echo "$VOUCHER_CACHE" | jq -r '
            .data[] | [(.end_time|tostring), (.code // "")] | join("\t")
        ' 2>/dev/null || true)
    fi

    while IFS=$'\t' read -r mac end_time api_voucher_code; do
        [[ -z "$mac" || "$mac" == "null" ]] && continue
        if ! [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            log "WARNING: malformed mac from API"
            log "WARNING: ($mac) -- skipping"
            continue
        fi
        [[ -z "$end_time" || "$end_time" == "null" ]] && continue
        if ! [[ "$end_time" =~ $_UH_UINT ]]; then
            log "WARNING: malformed end_time for $mac"
            log "WARNING: ($end_time) -- skipping"
            continue
        fi
        (( end_time <= now )) && continue

        # No log here, on purpose: uhmd.sh does not process mac-*.txt
        # (see MANAGED MACS note above) and a managed device having a live
        # UniFi guest authorization is not this daemon's concern to report --
        # the only mac-*.txt-related log line this daemon ever produces is
        # the change-watcher's, when the reload is actually invoked.
        is_managed_mac "$mac" && continue

        grep -qiE "^#[[:space:]]*a;${mac};" "$UHM_MACAUTH" 2>/dev/null && continue

        if grep -qi "^a;${mac};" "$UHM_MACAUTH" 2>/dev/null; then
            local existing_line existing_ip existing_hostname existing_end
            existing_line=$(grep -i "^a;${mac};" "$UHM_MACAUTH" | head -1)
            existing_ip=$(echo "$existing_line" | awk -F';' '{print $3}')
            existing_hostname=$(echo "$existing_line" | awk -F';' '{print $4}')
            existing_end=$(echo "$existing_line" | awk -F';' '{print $5}')
            [[ "$end_time" == "$existing_end" ]] && continue

            # Renewal of an already-authorized MAC (e.g. an admin manually
            # extended the voucher's end time from the UniFi UI, or any
            # other integration that updates an existing guest session).
            # The IP and hostname it was assigned when the voucher was
            # first redeemed must not change for as long as it stays
            # authorized -- only the expiration time is updated.
            # assign_ip_and_hostname() is never called here since no new
            # IP is needed.
            log "INFO: renewal detected for $mac"
            log "INFO: (end_time $existing_end -> $end_time)"
            log "INFO: keeping ip=$existing_ip for $mac"
            log "INFO: hostname=$existing_hostname"
            if add_mac_to_acl "$mac" "$existing_ip" "$existing_hostname" "$end_time"; then
                (( added++ )) || true
            fi
            continue
        fi

        if [[ "${REVOKED_SESSIONS[${mac,,}]:-}" == "$end_time" ]]; then
            continue
        fi

        local assigned_ip="" assigned_hostname=""
        local iph
        if ! iph=$(assign_ip_and_hostname); then
            log "WARNING: Range exhausted for $mac"
            log "WARNING: will retry next cycle"
            continue
        fi
        assigned_ip=$(echo "$iph" | cut -d';' -f1)
        assigned_hostname=$(echo "$iph" | cut -d';' -f2)

        local voucher_code
        if [[ -n "$api_voucher_code" && "$api_voucher_code" != "null" ]]; then
            voucher_code="$api_voucher_code"
        else
            voucher_code="${_voucher_by_end[$end_time]:-}"
        fi
        voucher_code=$(printf '%s' "$voucher_code" | tr -cd 'A-Za-z0-9._-')
        # Fallback guard: voucher_code is UniFi API data, with no length
        # guarantee from our side. uhmleases.sh's _normalize_acl_file()
        # rejects any uhm-auth.txt hostname over 63 chars (see README
        # Fallback section) and aborts normalization for the whole file --
        # not just this one client. No known UniFi version actually returns
        # a code long enough to trigger this (observed codes are short,
        # numeric), so this never fires in practice; if it ever did, the
        # code is simply omitted from the hostname (kept as plain "guestN")
        # instead of writing a line that would break the entire reload.
        if [[ -n "$voucher_code" ]]; then
            if (( ${#assigned_hostname} + 1 + ${#voucher_code} <= 63 )); then
                assigned_hostname="${assigned_hostname}-${voucher_code}"
            else
                log "WARNING: voucher code too long for hostname field"
                log "WARNING: ($mac) -- keeping plain guest hostname, code omitted"
            fi
        fi

        if ! add_mac_to_acl "$mac" "$assigned_ip" "$assigned_hostname" "$end_time"; then
            continue
        fi
        (( added++ )) || true
        # New fixed-address assignment (not a renewal) -- this MAC needs to be
        # kicked off the AP once the reload below applies the new IP, so it
        # reconnects with a clean DHCP DISCOVER instead of racing its old lease.
        NEWLY_AUTHORIZED_MACS+=("$mac")

    done < <(echo "$sessions_data" | jq -r '
        .data[]
        | select(.mac != null and .mac != "")
        | select(.end != null)
        | [(.mac | ascii_downcase), (.end | tostring), (.voucher_code // "")]
        | join("\t")
    ' 2>/dev/null || true)

    SESSIONS_AUTHORIZED=$added
}

# -- Step 8: revoke unauthorized -----------------------------------------------
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
revoke_unauthorized() {
    local sta_data="$1"
    local rc
    rc=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$rc" != "ok" ]] && { log "INFO: stat/sta unavailable -- skipping revoke"; return; }

    # Single-pass lookup: build a mac -> authorized map once instead of one
    # `jq` call per line of UHM_MACAUTH below. First match wins per MAC.
    local -A _sta_authorized=()
    while IFS=$'\t' read -r smac sauth; do
        [[ -n "$smac" && -z "${_sta_authorized[$smac]+x}" ]] && _sta_authorized["$smac"]="$sauth"
    done < <(echo "$sta_data" | jq -r '
        .data[] | [(.mac|ascii_downcase), (.authorized|tostring)] | join("\t")
    ' 2>/dev/null || true)

    local _rmac
    for _rmac in "${!REVOKED_SESSIONS[@]}"; do
        [[ "${_sta_authorized[$_rmac]:-}" != "false" ]] && unset "REVOKED_SESSIONS[$_rmac]"
    done

    local revoked=0
    local macs_to_revoke=()

    while IFS=';' read -r status mac ip hostname end_time _ || [[ -n "$status" ]]; do
        [[ "$status" != "a" ]] && continue
        [[ -z "$mac" ]] && continue

        # Skip MACs authorized earlier in this same cycle (process_sessions,
        # via stat/guest) -- UniFi can take a moment to propagate a fresh
        # voucher authorization into stat/sta, so checking it here right
        # away can still see a stale authorized=false and revoke what was
        # just granted, only to re-authorize and kick it again next cycle.
        local mac_lc="${mac,,}" _nm _skip=0
        for _nm in "${NEWLY_AUTHORIZED_MACS[@]+"${NEWLY_AUTHORIZED_MACS[@]}"}"; do
            [[ "${_nm,,}" == "$mac_lc" ]] && { _skip=1; break; }
        done
        (( _skip )) && continue

        local authorized="${_sta_authorized[$mac_lc]:-}"
        if [[ "$authorized" == "false" ]]; then
            macs_to_revoke+=("$mac")
            REVOKED_SESSIONS["$mac_lc"]="$end_time"
        fi
    done < "$UHM_MACAUTH"

    local mac
    for mac in "${macs_to_revoke[@]+"${macs_to_revoke[@]}"}"; do
        [[ -z "$mac" ]] && continue
        if [[ ! "$mac" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]; then
            log "ERROR: bad MAC '$mac'"
            log "ERROR: skipping"
            continue
        fi
        log "INFO: Revoking $mac"
        log "INFO: authorized=false in UniFi; releasing from uhm-auth"
        queue_lease_removal "$mac"
        if sed -i "/^a;${mac};/Id" "$UHM_MACAUTH" 2>/dev/null; then
            (( revoked++ )) || true
        else
            log "WARNING: sed failed to remove $mac"
            log "WARNING: from $UHM_MACAUTH -- will retry next cycle"
        fi
    done

    REVOKED=$revoked
}

# -- Step 2: ACL snapshot (baseline for reload detection) ---------------------
snapshot_acls() {
    _ACL_SNAPSHOT_HOTSPOT=$(md5sum "$UHM_MACAUTH" 2>/dev/null | awk '{print $1}')
    _ACL_SNAPSHOT_BLOCK=$(md5sum "$BLOCK_DHCP" 2>/dev/null | awk '{print $1}')
    _ACL_SNAPSHOT_QUEUE=$(md5sum "$UHM_QUEUE" 2>/dev/null | awk '{print $1}')
    _ACL_SNAPSHOT_GRACE=$(md5sum "$UHM_GRACE" 2>/dev/null | awk '{print $1}')
}

# -- Step 9: reload if ACLs changed -------------------------------------------
# Returns 0 if ACLs changed (reload attempted), 1 if unchanged (silent -- no
# log noise on the common no-change path). Callers use the return code to
# decide whether the per-cycle summary line is worth logging.
check_and_reload_if_changed() {
    local cur_hotspot cur_block cur_queue cur_grace rc now since_last acl_changed=0
    cur_hotspot=$(md5sum "$UHM_MACAUTH" 2>/dev/null | awk '{print $1}')
    cur_block=$(md5sum "$BLOCK_DHCP" 2>/dev/null | awk '{print $1}')
    cur_queue=$(md5sum "$UHM_QUEUE" 2>/dev/null | awk '{print $1}')
    cur_grace=$(md5sum "$UHM_GRACE" 2>/dev/null | awk '{print $1}')

    [[ "$cur_hotspot" != "$_ACL_SNAPSHOT_HOTSPOT" || "$cur_block" != "$_ACL_SNAPSHOT_BLOCK" || \
       "$cur_queue" != "$_ACL_SNAPSHOT_QUEUE" || "$cur_grace" != "$_ACL_SNAPSHOT_GRACE" ]] \
        && acl_changed=1

    # mac-*.txt change detected last cycle by check_mac_lists_changed (an
    # independent watcher, see above) folds into this same single reload
    # decision -- never a separate uhmreload.sh invocation of its own.
    local mac_reload_triggered=0
    if (( _MAC_RELOAD_PENDING == 1 )); then
        acl_changed=1
        mac_reload_triggered=1
    fi

    now=$(date +%s)
    since_last=$(( now - _LAST_RELOAD_EPOCH ))

    if (( acl_changed == 0 && since_last < RELOAD_SAFETY_INTERVAL_SECONDS )); then
        return 1
    fi

    if (( acl_changed == 1 )); then
        [[ "$cur_hotspot" != "$_ACL_SNAPSHOT_HOTSPOT" ]] && log "INFO: uhm-auth.txt changed"
        [[ "$cur_block" != "$_ACL_SNAPSHOT_BLOCK" ]] && log "INFO: blockdhcp.txt changed"
        [[ "$cur_queue" != "$_ACL_SNAPSHOT_QUEUE" ]] && log "INFO: lease removal queue changed"
        [[ "$cur_grace" != "$_ACL_SNAPSHOT_GRACE" ]] && log "INFO: uhm-grace.txt changed"
        (( mac_reload_triggered )) && log "INFO: mac-*.txt change from previous cycle -- reloading now"
    else
        log "INFO: ${RELOAD_SAFETY_INTERVAL_SECONDS}s since last reload -- forcing safety-net reload"
    fi

    _MAC_RELOAD_PENDING=0

    _RELOAD_OK=0
    if [[ -n "${UHM_RELOAD:-}" && -x "$UHM_RELOAD" ]]; then
        log "INFO: invoking $UHM_RELOAD"
        export UHM_RELOAD_ACTIVE=1
        if "$UHM_RELOAD" >/dev/null 2>>"$LOG_FILE"; then
            _RELOAD_OK=1
            _LAST_RELOAD_EPOCH=$now
        else
            rc=$?
            # Update the epoch on failure too, not just success: a persistent
            # failure (broken uhmleases.sh/uhmiptables.sh, timeout) would otherwise
            # keep since_last stuck below RELOAD_SAFETY_INTERVAL_SECONDS forever
            # relative to the last real success (or never even set for a
            # brand-new install), causing a retry -- and its WARNING alert and
            # trace file -- every single cycle instead of backing off to the
            # safety-net cadence. ACL-change-triggered reloads are unaffected:
            # they fire on the next real diff, not on this timer.
            _LAST_RELOAD_EPOCH=$now
            log "WARNING: $UHM_RELOAD exited with error (code $rc)"
            log "WARNING: backing off to safety-net cadence (${RELOAD_SAFETY_INTERVAL_SECONDS}s)"
            log "WARNING: will not retry every cycle"
        fi
        unset UHM_RELOAD_ACTIVE
    else
        # Same reasoning as the failure branch above: update the epoch here
        # too, so a misconfigured UHM_RELOAD (missing or not
        # executable) backs off to the safety-net cadence instead of
        # re-logging this WARNING -- and re-alerting via uhmalert.sh -- on
        # every single cycle.
        _LAST_RELOAD_EPOCH=$now
        if (( acl_changed == 1 )); then
            log "WARNING: ACLs changed but UHM_RELOAD is not set"
            log "WARNING: or not executable"
        else
            log "WARNING: safety-net reload due but no reload script set"
            log "WARNING: set or not executable"
        fi
        log "WARNING: backing off to safety-net cadence (${RELOAD_SAFETY_INTERVAL_SECONDS}s)"
        log "WARNING: will not retry every cycle"
    fi
    return 0
}

# -- Step 10: kick newly-authorized clients ------------------------------------
# A MAC that just got a new fixed hotspot IP (as opposed to a voucher renewal,
# which keeps the existing IP) may still be holding its old pool-range lease
# on the client side until its own DHCP renewal timer fires. Forcing a
# disassociation here -- only after the reload above has applied the new
# fixed-address mapping -- makes the client reconnect immediately with a clean
# DHCP DISCOVER, so it gets the correct IP from the start instead of racing
# its stale lease against the OS's own connectivity check.
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
kick_newly_authorized() {
    local sta_data="$1"
    local mac kick_url http_code on_sta rc
    rc=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    for mac in "${NEWLY_AUTHORIZED_MACS[@]}"; do
        # Defense-in-depth: process_sessions already excludes managed MACs via
        # is_managed_mac(), so this should never trigger. Logged loudly (not a
        # silent continue), unlike process_sessions' own routine/high-volume
        # skip above -- this one firing at all means something upstream let a
        # managed MAC slip through, which is itself worth surfacing.
        if is_managed_mac "$mac"; then
            log "WARNING: $mac"
            log "WARNING: in mac-*.txt but reached NEWLY_AUTHORIZED_MACS"
            log "WARNING: not kicking"
            log "WARNING: this should never happen"
            log "WARNING: process_sessions' own guard should exclude this"
            continue
        fi
        if [[ "$rc" == "ok" ]]; then
            on_sta=$(echo "$sta_data" | jq -r --arg mac "$mac" '
                .data[] | select((.mac | ascii_downcase) == $mac) | "yes"
            ' 2>/dev/null | head -1 || true)
            if [[ "$on_sta" != "yes" ]]; then
                log "INFO: skipping $mac"
                log "INFO: not currently connected, no kick needed"
                continue
            fi
        else
            log "INFO: stat/sta unavailable"
            log "INFO: kicking $mac without presence check"
        fi

        kick_url=$(api_path "cmd/stamgr")
        http_code=$(api_post "$kick_url" "{\"cmd\":\"kick-sta\",\"mac\":\"${mac}\"}")
        if [[ "$http_code" == "200" ]]; then
            log "INFO: kicked $mac"
            log "INFO: forcing reassociation with new fixed IP"
        else
            log "WARNING: failed to kick"
            log "WARNING: $mac (HTTP $http_code)"
            log "WARNING: client may keep its stale IP"
            log "WARNING: until its own DHCP renewal"
        fi
    done
}

# -- Full hotspot cycle --------------------------------------------------------
run_cycle() {
    rm -f "$_CYCLE_MARK_FILE" 2>/dev/null || true

    if ! flock -n 201; then
        log "WARNING: cycle lock held unexpectedly -- skipping this cycle"
        return
    fi

    SESSIONS_AUTHORIZED=0
    REVOKED=0
    NEWLY_AUTHORIZED_MACS=()

    load_all_vouchers
    snapshot_acls

    # Independent of the ACL steps below -- see check_mac_lists_changed.
    check_mac_lists_changed

    dedup_mac_lists
    sort_acl_files
    clean_expired_macs
    process_new_leases

    process_sessions

    # Fetched after process_sessions, not before: a voucher redeemed this
    # cycle is authorized via stat/guest inside process_sessions. A stat/sta
    # snapshot taken earlier would still show that MAC as unauthorized,
    # causing revoke_unauthorized (right below) to undo the authorization
    # in the same cycle it was granted.
    local sta_endpoint sta_data sta_rc
    sta_endpoint=$(api_path "stat/sta")
    sta_data=$(api_get "$sta_endpoint")
    sta_rc=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$sta_rc" == "ok" ]] && _STA_OK=1 || _STA_OK=0

    # Backend readiness marker: the login endpoint can respond while the data
    # endpoints are still initializing (typical right after a reboot). Log a
    # single line the first time all three data endpoints answer OK together,
    # and re-arm it if any drops later, so the log always shows exactly when
    # the UniFi backend became fully usable -- not just when login succeeded.
    if (( _VOUCHERS_OK && _GUEST_OK && _STA_OK )); then
        if (( _BACKEND_READY == 0 )); then
            _BACKEND_READY=1
            log "INFO: UniFi backend ready (voucher/guest/sta OK)"
        fi
    else
        _BACKEND_READY=0
    fi

    revoke_unauthorized "$sta_data"

    # Independent of the ACL steps above -- see authorize_managed_macs() for
    # why this is needed at all (UniFi's own per-client "authorized" state on
    # a Guest-type WLAN, not just DHCP/firewall bypass).
    authorize_managed_macs "$sta_data"

    # Summary line is only useful when something actually changed this cycle --
    # logging it unconditionally at POLL_INTERVAL cadence (default 20s) drowns
    # the log in identical lines during idle periods.
    if check_and_reload_if_changed; then
        local authorized_total grace_total
        authorized_total=$(grep -c "^a;" "$UHM_MACAUTH" 2>/dev/null || true)
        authorized_total=$(( ${authorized_total:-0} + 0 ))
        grace_total=$(grep -c "^a;" "$UHM_GRACE" 2>/dev/null || true)
        grace_total=$(( ${grace_total:-0} + 0 ))
        log "vouchers=$VOUCHER_COUNT|auth=$authorized_total|grace=$grace_total|new_auth=$SESSIONS_AUTHORIZED|revoked=$REVOKED"

        if [[ "$_RELOAD_OK" == "1" && ${#NEWLY_AUTHORIZED_MACS[@]} -gt 0 ]]; then
            kick_newly_authorized "$sta_data"
        fi
    fi

    local _f
    for _f in "${TEMP_FILES_TO_CLEAN[@]+"${TEMP_FILES_TO_CLEAN[@]}"}"; do
        rm -f "$_f" 2>/dev/null || true
    done
    TEMP_FILES_TO_CLEAN=()

    flock -u 201 2>/dev/null || log "WARNING: failed to release cycle lock (fd 201)"
}

# -- Main daemon loop ----------------------------------------------------------
main() {
    load_config
    POLL_INTERVAL="${POLL_INTERVAL:-20}"
    if ! [[ "$POLL_INTERVAL" =~ $_UH_UINT ]] || (( POLL_INTERVAL == 0 )); then
        log "WARNING: POLL_INTERVAL invalid ($POLL_INTERVAL) -- using default 20"
        POLL_INTERVAL=20
    fi
    STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-120}"
    if ! [[ "$STARTUP_GRACE_SECONDS" =~ $_UH_UINT ]]; then
        log "WARNING: STARTUP_GRACE_SECONDS invalid"
        log "WARNING: ($STARTUP_GRACE_SECONDS) -- using default 120"
        STARTUP_GRACE_SECONDS=120
    fi
    UHM_LEASES_TIMEOUT_SECONDS="${UHM_LEASES_TIMEOUT_SECONDS:-120}"
    if ! [[ "$UHM_LEASES_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || (( UHM_LEASES_TIMEOUT_SECONDS == 0 )); then
        UHM_LEASES_TIMEOUT_SECONDS=120
    fi
    UHM_IPTABLES_TIMEOUT_SECONDS="${UHM_IPTABLES_TIMEOUT_SECONDS:-60}"
    if ! [[ "$UHM_IPTABLES_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || (( UHM_IPTABLES_TIMEOUT_SECONDS == 0 )); then
        UHM_IPTABLES_TIMEOUT_SECONDS=60
    fi
    local _reload_floor=$(( 3 * (UHM_LEASES_TIMEOUT_SECONDS + UHM_IPTABLES_TIMEOUT_SECONDS) ))
    (( _reload_floor < 600 )) && _reload_floor=600
    RELOAD_SAFETY_INTERVAL_SECONDS="${RELOAD_SAFETY_INTERVAL_SECONDS:-3600}"
    if ! [[ "$RELOAD_SAFETY_INTERVAL_SECONDS" =~ $_UH_UINT ]] || (( RELOAD_SAFETY_INTERVAL_SECONDS < _reload_floor )); then
        log "ERROR: RELOAD_SAFETY_INTERVAL_SECONDS must be an integer >= ${_reload_floor}"
        log "ERROR: (3x UHM_LEASES_TIMEOUT_SECONDS + UHM_IPTABLES_TIMEOUT_SECONDS)"
        log "ERROR: got: $RELOAD_SAFETY_INTERVAL_SECONDS"
        exit 1
    fi
    if [[ -z "${AUTHORIZED_LEASE_TIME:-}" ]]; then
        log "WARNING: AUTHORIZED_LEASE_TIME not set in $CONFIG_FILE"
        log "WARNING: using default $AUTHORIZED_LEASE_TIME_DEFAULT"
        AUTHORIZED_LEASE_TIME="$AUTHORIZED_LEASE_TIME_DEFAULT"
    elif ! [[ "$AUTHORIZED_LEASE_TIME" =~ $_UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
        log "WARNING: AUTHORIZED_LEASE_TIME invalid ($AUTHORIZED_LEASE_TIME)"
        log "WARNING: using default $AUTHORIZED_LEASE_TIME_DEFAULT"
        AUTHORIZED_LEASE_TIME="$AUTHORIZED_LEASE_TIME_DEFAULT"
    fi
    verify_installation
    init_acl_files

    log "INFO: uhmd start..."

    # UniFi-OS can take a while to come back up after a reboot -- this host and
    # the controller often boot together. Retry quietly (INFO, no alert) for
    # up to STARTUP_GRACE_SECONDS before treating it as a real failure; a
    # controller that's simply still booting should never page anyone.
    local _login_start _login_elapsed
    _login_start=$(date +%s)
    until unifi_login "quiet"; do
        _login_elapsed=$(( $(date +%s) - _login_start ))
        if (( _login_elapsed >= STARTUP_GRACE_SECONDS )); then
            log "ERROR: Could not log in to UniFi after ${STARTUP_GRACE_SECONDS}s -- exiting"
            exit 1
        fi
        sleep 10
    done

    # iptables/ipset state does not survive a reboot, but the ACL files
    # themselves may be unchanged from before it -- check_and_reload_if_changed()
    # (used inside run_cycle) would then never trigger a reload, leaving the
    # firewall empty until the next ACL change or the safety-net interval.
    # Force one reload here, on every daemon start, regardless of ACL state.
    if [[ -n "${UHM_RELOAD:-}" && -x "$UHM_RELOAD" ]]; then
        log "INFO: Startup -- invoking uhmreload (ACLs + firewall)"
        export UHM_RELOAD_ACTIVE=1
        if "$UHM_RELOAD" >/dev/null 2>>"$LOG_FILE"; then
            _LAST_RELOAD_EPOCH=$(date +%s)
        else
            log "WARNING: startup reload failed"
            log "WARNING: firewall may be incomplete until next ACL change"
            _LAST_RELOAD_EPOCH=$(date +%s)
        fi
        unset UHM_RELOAD_ACTIVE
    else
        log "WARNING: UHM_RELOAD not set or not executable"
        log "WARNING: firewall not rebuilt at startup"
    fi

    while true; do
        run_cycle || log "WARNING: cycle ended with error -- continuing"
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
