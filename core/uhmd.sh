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
# cookie, CSRF from the response header). session_cookie_name() and
# unifi_login() branch on this value; api_path() branches the API prefix
# the same way.
#
# TLS (UNIFI_CERT_PIN in uhm.env):
# The UniFi controller normally uses a self-signed certificate, so every API
# call disables chain verification (curl -k). If UNIFI_CERT_PIN is set
# (format "sha256//<base64>"), it is passed as curl --pinnedpubkey alongside
# -k, so the connection is rejected outright if the controller's certificate
# is ever swapped for a different one (MITM or unexpected controller
# change). Empty/unset UNIFI_CERT_PIN falls back to -k with no pinning.
#
# Session tokens are persisted to token_state_file so that re-authentication
# inside $(...) subshells propagates correctly to subsequent API calls in
# the same cycle.
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
# captive portal: on any WLAN configured as Guest/Hotspot (check README UNIFI
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
# 0. MALFORMED -- before any other step opens an ACL list, check each list
# against its own line format. In uhm-grace.txt, blockdhcp.txt and
# uhm-queue.txt a bad line is deleted and the cycle continues:
# they authorize nothing. In uhm-auth.txt it is only reported
# (WARNING) and left in place -- deleting it would revoke a
# guest's access with nothing on record but its disappearance,
# so it is left for uhmleases.sh to abort on. mac-*.txt is never
# touched here at all.
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
# 7. SESSIONS -- promote voucher-authenticated clients to uhm-auth. Only a
# session UniFi reports as authorized_by=voucher qualifies: stat/guest
# also lists authorize-guest grants (authorized_by=api), which are not
# voucher redemptions and never belong in uhm-auth. Also excludes
# a MAC revoked in an earlier cycle whose stat/guest session is
# still the same one it had when it was revoked (revoked_sessions)
# 8. REVOKE -- remove UniFi-unauthorized clients from uhm-auth and record
# them in revoked_sessions; an entry is dropped as soon as
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
# GLOBALS BY DESIGN:
# subnet_int, mask_int, hotspot_ini_int and hotspot_end_int are set once in
# load_config() and read by ip_in_lan() and assign_ip_and_hostname(). new_token
# is handed between unifi_login() and update_session_from_headers(). None of
# them can be declared local.
#
# The reload script path is read from UHM_RELOAD in uhm.env (set by
# uhmsetup.sh, default /etc/uhm/core/uhmreload.sh) -- nothing here hardcodes
# it, so relocating the reload script only requires updating that one value.
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# LOGGING
# Shared log with uhmreload.sh and uhmleases.sh
log_file="/var/log/uhm.log"
# cycle_mark_file tracks whether the delimiter line has already been printed
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
cycle_mark_file="/run/uhmd_cycle_mark"
log() {
    if [[ ! -e "$cycle_mark_file" ]]; then
        echo "--------------------------------------------------------------------------------" >> "$log_file" 2>/dev/null || true
        : > "$cycle_mark_file" 2>/dev/null || true
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$log_file" 2>/dev/null || true
}

# Same output format as log(), but never opens a delimiter block of its own.
# Used only for the shutdown notice (see cleanup_temp): that line closes out
# whatever was last logged in this process rather than starting a new one.
# The next process (a fresh uhmd start) still gets its own delimiter as
# usual, since cycle_mark_file lives under /run and is cleared on reboot.
log_raw() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root -- abort" >&2
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

# dependencies
for dep_pkg in curl jq mawk coreutils util-linux grep sed systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

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

# IPv4 <-> integer. Callers validate with UH_IPV4 before calling, which
# rejects leading zeros. Ranges are walked and compared as integers, so no
# step below assumes a particular netmask or a three-octet prefix.
ip_to_int() {
    local octet_1 octet_2 octet_3 octet_4
    IFS='.' read -r octet_1 octet_2 octet_3 octet_4 <<< "$1"
    echo $(( (octet_1 << 24) + (octet_2 << 16) + (octet_3 << 8) + octet_4 ))
}

int_to_ip() {
    local ip_int="$1"
    echo "$(( (ip_int >> 24) & 255 )).$(( (ip_int >> 16) & 255 )).$(( (ip_int >> 8) & 255 )).$(( ip_int & 255 ))"
}

# True if $1 belongs to the LAN pydhcp serves (SERV_SUBNET/SERV_MASK).
ip_in_lan() {
    local ip_int
    ip_int=$(ip_to_int "$1")
    (( (ip_int & mask_int) == (subnet_int & mask_int) ))
}

# cycle_lock is separate from script_lock (the singleton instance guard, held
# for the daemon's entire lifetime). cycle_lock is the mechanism lock: it is
# only held while ACL files are actively being mutated (~1-3s), released
# during the sleep between cycles, and released again before delegating to
# uhmreload.sh so uhmleases.sh can acquire it with its own descriptor. Every
# script that writes acquires THIS lock, not script_lock, so they only wait
# during the narrow window where a real race on the ACL files could occur --
# not for the daemon's entire uptime.
cycle_lock="/var/lock/uhmd-cycle.lock"
exec 201>"$cycle_lock"

temp_files=()
cleanup_temp() {
    local exit_code=$?
    local temp_file
    for temp_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$temp_file" 2>/dev/null || true
    done
    # Only skip the "done" announcement on an explicit error exit (exit 1) --
    # the ERROR line already logged is the signal that something happened.
    # A normal stop (systemctl stop sends SIGTERM, rc=143) is not that case
    # and must still log done. Uses log_raw, not log, so this line closes out
    # whatever was last logged instead of opening a delimiter block of its
    # own -- a raya must mark the start of a cycle/session, never a shutdown.
    if (( exit_code != 1 )) && declare -F log_raw &>/dev/null; then
        log_raw "uhmd done at: $(date)"
    fi
}
trap cleanup_temp EXIT

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PATHS AND CONSTANTS
# The only path that cannot live in uhm.env, plus fixed values
# config_file is the one path that cannot itself live in uhm.env -- the
# daemon needs to know where that file is before it can be opened and read.
# Every other path below (UHM_MACAUTH, ACL_BLOCK_FILE, ACL_MAC_PATH,
# UHM_QUEUE) is set inside load_config(), after uhm.env is
# loaded, with the same fallback default shown here.
pydhcp_env="/etc/pydhcp/pydhcp.env"
config_file="/etc/uhm/uhm.env"

token_state_file="/run/uhmd_session"

default_lease_time=2592000

# RUNTIME STATE
# Counters and caches reset on every cycle
session_token=""
csrf_token=""
voucher_cache=""
voucher_count=0
sessions_authorized=0
revoked_total=0
newly_authorized_macs=()
declare -A revoked_sessions=()
# Backend readiness tracking: the login endpoint can answer well before the
# UniFi Network application's data endpoints (stat/voucher, stat/guest,
# stat/sta) finish coming up -- common for a couple of minutes after a
# controller/host reboot. These flags capture the rc the cycle already
# computes for each, so run_cycle can log a single "backend ready" line on the
# not-ready -> ready transition (and re-arm it if the backend drops again).
vouchers_ok=0
guest_ok=0
sta_ok=0
backend_ready=0
acl_snapshot_hotspot=""
acl_snapshot_block=""
acl_snapshot_queue=""
acl_snapshot_grace=""
reload_ok=0
# mac-*.txt change watcher (see check_mac_lists_changed): independent of the
# ACL snapshot/reload mechanism above -- its own baseline and its own pending
# flag, never reusing uhm-queue.txt or the acl_snapshot_* machinery.
mac_lists_hash_prev=""
mac_reload_pending=0
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
last_reload_epoch=0

# Loads only known KEY=VALUE pairs from config_file instead of sourcing it,
# so a tampered or maliciously replaced config file cannot execute code --
# same approach as uhmleases.sh's load_env_file().
load_env_file() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
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
            env_value="${env_value//\\\"/\"}"
            env_value="${env_value//\\\$/\$}"
            env_value="${env_value//\\\`/\`}"
            env_value="${env_value//\\\\/\\}"
        fi
        case "$env_key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_TYPE|UNIFI_SITE|UNIFI_CERT_PIN|\
            SERVER_IP|SERV_SUBNET|SERV_MASK|UHM_PATH|\
            UHM_INI_RANGE|UHM_END_RANGE|\
            UHM_RELOAD|UHM_GRACE|UHM_MACAUTH|ACL_BLOCK_FILE|ACL_MAC_PATH|ACL_PATH|\
            UHM_QUEUE|PYDHCPD_LEASES|POLL_INTERVAL|STARTUP_GRACE_SECONDS|\
            RELOAD_SAFETY_INTERVAL_SECONDS|AUTHORIZED_LEASE_TIME|\
            UHM_LEASES_TIMEOUT_SECONDS|UHM_IPTABLES_TIMEOUT_SECONDS)
                printf -v "$env_key" '%s' "$env_value"
                ;;
            *)
                ;;
        esac
    done < "$conf_file"
}

# CONFIG
# Reads pydhcp.env first, then uhm.env, and validates every key
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

load_config() {
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: $config_file not found" >&2
        exit 1
    fi
    local file_owner file_perms
    file_owner=$(stat -c '%U' "$config_file" 2>/dev/null)
    file_perms=$(stat -c '%a' "$config_file" 2>/dev/null)
    if [[ "$file_owner" != "root" ]] || [[ "$file_perms" != "600" ]]; then
        if chown root:root "$config_file" 2>/dev/null && chmod 600 "$config_file" 2>/dev/null; then
            log "WARNING: uhm.env perms fixed -- alert"
        else
            log "ERROR: cannot fix uhm.env perms -- abort"
            exit 1
        fi
    fi
    # pydhcp.env first: it owns the network, ACL and lease values, and is
    # the single source of truth for them. uhm.env is read after, so uhm's
    # own keys win if a name ever collides.
    if [[ ! -r "$pydhcp_env" ]]; then
        log "ERROR: cannot read $pydhcp_env -- abort"
        log "ERROR: uhm reads pydhcp's network and ACL values from it"
        exit 1
    fi
    load_env_file "$pydhcp_env"
    load_env_file "$config_file"

    # uhm's own ACL files (UHM_MACAUTH, UHM_GRACE, UHM_QUEUE) and
    # pydhcp's (ACL_BLOCK_FILE, ACL_MAC_PATH) -- all configurable via uhm.env,
    # same fallback defaults as uhmleases.sh uses for the same variables.
    # uhm's own three hang off UHM_PATH so the install directory is
    # named once and never repeated per file.
    UHM_PATH="${UHM_PATH:-/etc/uhm}"
    ACL_PATH="${ACL_PATH:-/etc/acl}"
    PYDHCPD_LEASES="${PYDHCPD_LEASES:-/etc/pydhcp/core/pydhcpd.leases}"
    UHM_MACAUTH="${UHM_MACAUTH:-$UHM_PATH/acl/uhm-auth.txt}"
    ACL_BLOCK_FILE="${ACL_BLOCK_FILE:-/etc/pydhcp/acl/blockdhcp.txt}"
    ACL_MAC_PATH="${ACL_MAC_PATH:-$ACL_PATH/mac}"
    UHM_GRACE="${UHM_GRACE:-$UHM_PATH/acl/uhm-grace.txt}"
    UHM_QUEUE="${UHM_QUEUE:-$UHM_PATH/acl/uhm-queue.txt}"

    ensure_acl_lists "$UHM_MACAUTH" "$UHM_GRACE" "$UHM_QUEUE"

    local missing_keys=()
    [[ -z "${UNIFI_CONTROLLER_URL:-}" ]] && missing_keys+=("UNIFI_CONTROLLER_URL")
    [[ -z "${UNIFI_USERNAME:-}" ]] && missing_keys+=("UNIFI_USERNAME")
    [[ -z "${UNIFI_PASSWORD:-}" ]] && missing_keys+=("UNIFI_PASSWORD")
    [[ -z "${SERVER_IP:-}" ]] && missing_keys+=("SERVER_IP")
    [[ -z "${SERV_SUBNET:-}" ]] && missing_keys+=("SERV_SUBNET")
    [[ -z "${SERV_MASK:-}" ]] && missing_keys+=("SERV_MASK")
    [[ -z "${UHM_INI_RANGE:-}" ]] && missing_keys+=("UHM_INI_RANGE")
    [[ -z "${UHM_END_RANGE:-}" ]] && missing_keys+=("UHM_END_RANGE")
    [[ -z "${UHM_RELOAD:-}" ]] && missing_keys+=("UHM_RELOAD")
    [[ -z "${UNIFI_TYPE:-}" ]] && missing_keys+=("UNIFI_TYPE")
    [[ -z "${UNIFI_SITE:-}" ]] && missing_keys+=("UNIFI_SITE")

    if (( ${#missing_keys[@]} > 0 )); then
        log "ERROR: missing variables in uhm.env:"
        local missing_key
        for missing_key in "${missing_keys[@]}"; do
            log "ERROR: $missing_key"
        done
        log "ERROR: restore uhm.env or re-run uhmsetup.sh -- abort"
        exit 1
    fi

    if ! [[ "$SERVER_IP" =~ $UH_IPV4 ]]; then
        log "ERROR: SERVER_IP is not valid IPv4 in uhm.env -- abort"
        exit 1
    fi

    if ! [[ "$SERV_SUBNET" =~ $UH_IPV4 ]] || ! [[ "$SERV_MASK" =~ $UH_NETMASK ]]; then
        log "ERROR: SERV_SUBNET/SERV_MASK invalid in uhm.env -- abort"
        exit 1
    fi
    subnet_int=$(ip_to_int "$SERV_SUBNET")
    mask_int=$(ip_to_int "$SERV_MASK")

    if [[ "${UNIFI_TYPE:-}" != "unifi-os" && "${UNIFI_TYPE:-}" != "classic" ]]; then
        log "ERROR: UNIFI_TYPE must be 'unifi-os' or 'classic' -- abort"
        exit 1
    fi

    # UNIFI_SITE is interpolated directly into API URLs (api_path()) -- reject
    # anything outside the character set UniFi itself uses for site names.
    if [[ ! "$UNIFI_SITE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log "ERROR: UNIFI_SITE has invalid characters -- abort"
        exit 1
    fi

    if ! [[ "$UHM_INI_RANGE" =~ $UH_IPV4 ]] || ! [[ "$UHM_END_RANGE" =~ $UH_IPV4 ]]; then
        log "ERROR: hotspot range must be two valid IPv4 addresses"
        log "ERROR: UHM_INI_RANGE/UHM_END_RANGE in uhm.env -- abort"
        exit 1
    fi

    hotspot_ini_int=$(ip_to_int "$UHM_INI_RANGE")
    hotspot_end_int=$(ip_to_int "$UHM_END_RANGE")
    if (( hotspot_ini_int > hotspot_end_int )); then
        log "ERROR: UHM_INI_RANGE is above UHM_END_RANGE -- abort"
        exit 1
    fi

    if ! ip_in_lan "$UHM_INI_RANGE" || ! ip_in_lan "$UHM_END_RANGE"; then
        log "ERROR: hotspot range falls outside the LAN subnet"
        log "ERROR: subnet is $SERV_SUBNET/$SERV_MASK -- abort"
        exit 1
    fi
}

ensure_executable() {
    local check_file="$1" script_name="$2" expected_mode="$3"
    [[ -f "$check_file" ]] || return 1
    local file_owner file_perms
    file_owner=$(stat -c '%U' "$check_file" 2>/dev/null)
    file_perms=$(stat -c '%a' "$check_file" 2>/dev/null)
    if [[ "$file_owner" != "root" || "$file_perms" != "$expected_mode" ]]; then
        if chown root:root "$check_file" 2>/dev/null && chmod "$expected_mode" "$check_file" 2>/dev/null; then
            log "WARNING: $script_name perms fixed -- alert"
        else
            log "WARNING: cannot fix $script_name perms -- alert"
        fi
    fi
    return 0
}

# INSTALLATION CHECK
# Refuses to run if the deployed files are missing or wrong
verify_installation() {
    if [[ ! -f "${UHM_RELOAD:-}" ]]; then
        log "ERROR: UHM_RELOAD not found -- abort"
        exit 1
    fi
    # pydhcpd often boots alongside this host and may not be up yet -- give it
    # the same startup grace as the UniFi login below instead of failing
    # instantly.
    local pydhcpd_start pydhcpd_elapsed
    pydhcpd_start=$(date +%s)
    until systemctl is-active --quiet pydhcpd 2>/dev/null; do
        pydhcpd_elapsed=$(( $(date +%s) - pydhcpd_start ))
        if (( pydhcpd_elapsed >= STARTUP_GRACE_SECONDS )); then
            log "ERROR: pydhcpd down after ${STARTUP_GRACE_SECONDS}s -- abort"
            exit 1
        fi
        sleep 10
    done
    log "INFO: Installation verified"
}

# ACL FILE CHECK
# Creates uhm's own lists when absent, never pydhcp's
# uhm's own three lists (UHM_MACAUTH/UHM_GRACE/UHM_QUEUE) are created
# on demand by ensure_acl_lists() in load_config(). ACL_BLOCK_FILE belongs to pydhcp
# and is deployed by its own pysetup.sh -- this daemon writes to it but must
# never create it, so a missing one means a broken/partial pydhcp install.
init_acl_files() {
    if [ ! -f "$ACL_BLOCK_FILE" ]; then
        log "ERROR: $ACL_BLOCK_FILE missing -- abort"
        exit 1
    fi
}

# UNIFI API
# Login, session persistence and the GET/POST helpers
# session_token and csrf_token are written to token_state_file after every
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
session_cookie_name() {
    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        echo "unifises"
    else
        echo "TOKEN"
    fi
}

save_session() {
    ( umask 077; printf '%s\n%s\n' "$session_token" "$csrf_token" > "$token_state_file" ) 2>/dev/null || true
    chmod 600 "$token_state_file" 2>/dev/null || true
}

load_session() {
    [[ ! -f "$token_state_file" ]] && return
    local session_tok csrf_tok
    { IFS= read -r session_tok; IFS= read -r csrf_tok; } < "$token_state_file" 2>/dev/null || return
    [[ -n "$session_tok" ]] && session_token="$session_tok"
    [[ -n "$csrf_tok" ]] && csrf_token="$csrf_tok"
}

update_session_from_headers() {
    local header_file="$1"
    [[ ! -f "$header_file" ]] && return
    local new_token new_csrf token_changed=0 cookie_name
    cookie_name=$(session_cookie_name)
    new_token=$(grep -iE "^set-cookie:[[:space:]]*${cookie_name}=" "$header_file" \
        | head -1 \
        | sed -E "s/^[^:]+:[[:space:]]*${cookie_name}=([^;]+).*/\1/" \
        | tr -d '\r\n' || true)
    new_csrf=$(grep -iE '^(x-updated-csrf-token|x-csrf-token):' "$header_file" | tail -1 \
        | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '\r\n' || true)
    if [[ -n "$new_token" && "$new_token" != "$session_token" ]]; then session_token="$new_token"; token_changed=1; fi
    if [[ -n "$new_csrf" && "$new_csrf" != "$csrf_token" ]]; then csrf_token="$new_csrf"; token_changed=1; fi
    (( token_changed )) && save_session
}

unifi_login() {
    local quiet_mode="${1:-}"
    local login_url header_file http_code login_payload

    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
    else
        login_url="${UNIFI_CONTROLLER_URL}/api/login"
    fi

    header_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline). Environment is only readable by
    # the same user or root (/proc/<pid>/environ).
    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    # Body goes to curl via stdin (--data-binary @-), not -d, for the same
    # reason: -d "$login_payload" would put the password in curl's argv too.
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${tls_opts[@]}" \
        -D "$header_file" \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST "$login_url" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 10 --max-time 40 <<< "$login_payload" 2>/dev/null || true)
    http_code="${http_code:-000}"

    if [[ "$http_code" != "200" ]]; then
        if [[ "$quiet_mode" == "quiet" ]]; then
            log "INFO: UniFi login failed (HTTP $http_code), retry in grace"
        else
            log "INFO: UniFi login failed (HTTP $http_code) -- skip"
        fi
        rm -f "$header_file"
        return 1
    fi

    local new_csrf new_token cookie_name
    cookie_name=$(session_cookie_name)
    new_token=$(grep -iE "^set-cookie:[[:space:]]*${cookie_name}=" "$header_file" \
        | head -1 \
        | sed -E "s/^[^:]+:[[:space:]]*${cookie_name}=([^;]+).*/\1/" \
        | tr -d '\r\n' || true)

    if [[ -z "$new_token" ]]; then
        log "INFO: login OK but ${cookie_name} cookie not found -- skip"
        rm -f "$header_file"
        return 1
    fi

    session_token="$new_token"

    # UniFi OS embeds the CSRF token inside the JWT payload (csrfToken field).
    # Extract it from the second segment of the JWT (base64-encoded JSON).
    local jwt_payload pad_len padded_jwt
    jwt_payload=$(echo "$new_token" | cut -d'.' -f2 | tr '_-' '/+')
    pad_len=$(( (4 - ${#jwt_payload} % 4) % 4 ))
    padded_jwt="$jwt_payload"
    if (( pad_len > 0 )); then
        padded_jwt="${jwt_payload}$(printf '%*s' "$pad_len" '' | tr ' ' '=')"
    fi
    new_csrf=$(echo "$padded_jwt" | base64 -d 2>/dev/null \
        | jq -r '.csrfToken // empty' 2>/dev/null || true)

    # Fallback: check response headers (classic UniFi controller).
    # Header file must still exist at this point -- do not delete it before here.
    if [[ -z "$new_csrf" ]]; then
        new_csrf=$(grep -iE '^(x-updated-csrf-token|x-csrf-token):' "$header_file" \
            | tail -1 | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '\r\n' || true)
    fi

    rm -f "$header_file"

    csrf_token="$new_csrf"
    save_session
    log "INFO: UniFi login OK"
}

api_get() {
    local api_url="$1"
    load_session

    local header_file
    header_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }

    local curl_args=(-s -k -w "\n__CODE__:%{http_code}" -D "$header_file"
        -H "Cookie: $(session_cookie_name)=${session_token}")
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && curl_args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
    [[ -n "$csrf_token" ]] && curl_args+=(-H "x-csrf-token: $csrf_token")

    local raw_response http_code response_body
    raw_response=$(curl --max-time 30 "${curl_args[@]}" "$api_url" 2>/dev/null || true)
    http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    response_body=$(echo "$raw_response" | grep -v '__CODE__:')
    update_session_from_headers "$header_file"

    if [[ "$http_code" == "401" ]]; then
        log "INFO: session expired, re-authenticating"
        if ! unifi_login; then
            log "INFO: re-authentication failed -- skip"
            rm -f "$header_file"
            echo "{}"
            return 1
        fi
        load_session
        curl_args=(-s -k -w "\n__CODE__:%{http_code}" -D "$header_file"
            -H "Cookie: $(session_cookie_name)=${session_token}")
        [[ -n "${UNIFI_CERT_PIN:-}" ]] && curl_args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
        [[ -n "$csrf_token" ]] && curl_args+=(-H "x-csrf-token: $csrf_token")
        raw_response=$(curl --max-time 30 "${curl_args[@]}" "$api_url" 2>/dev/null || true)
        http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
        response_body=$(echo "$raw_response" | grep -v '__CODE__:')
        update_session_from_headers "$header_file"
    fi

    rm -f "$header_file"

    if [[ -z "$http_code" ]]; then
        log "INFO: API GET ${api_url##*/${UNIFI_SITE}/} timeout -- skip"
        echo "{}"
        return 0
    fi
    if [[ "$http_code" != "200" ]]; then
        log "INFO: API GET ${api_url##*/${UNIFI_SITE}/} -> HTTP $http_code -- skip"
        echo "{}"
        return 0
    fi

    echo "$response_body"
}

api_post() {
    local api_url="$1" login_payload="$2"
    load_session

    local header_file
    header_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }

    local curl_args=(-s -k -w "\n__CODE__:%{http_code}" -D "$header_file"
        -X POST
        -H "Content-Type: application/json"
        -H "Cookie: $(session_cookie_name)=${session_token}")
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && curl_args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
    [[ -n "$csrf_token" ]] && curl_args+=(-H "x-csrf-token: $csrf_token")

    local raw_response http_code
    raw_response=$(curl --max-time 30 "${curl_args[@]}" -d "$login_payload" "$api_url" 2>/dev/null || true)
    http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    update_session_from_headers "$header_file"

    if [[ "$http_code" == "401" ]]; then
        log "INFO: session expired on POST, re-authenticating"
        if ! unifi_login; then
            log "INFO: re-authentication failed on POST -- skip"
            rm -f "$header_file"
            echo "$http_code"
            return 1
        fi
        load_session
        curl_args=(-s -k -w "\n__CODE__:%{http_code}" -D "$header_file"
            -X POST
            -H "Content-Type: application/json"
            -H "Cookie: $(session_cookie_name)=${session_token}")
        [[ -n "${UNIFI_CERT_PIN:-}" ]] && curl_args+=(--pinnedpubkey "$UNIFI_CERT_PIN")
        [[ -n "$csrf_token" ]] && curl_args+=(-H "x-csrf-token: $csrf_token")
        raw_response=$(curl --max-time 30 "${curl_args[@]}" -d "$login_payload" "$api_url" 2>/dev/null || true)
        http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
        update_session_from_headers "$header_file"
    fi

    rm -f "$header_file"
    echo "$http_code"
}

# STEP 1: VOUCHER CACHE
# Fetches every voucher once per cycle
load_all_vouchers() {
    local api_url exit_code voucher_total
    api_url=$(api_path "stat/voucher")
    voucher_cache=$(api_get "$api_url")
    exit_code=$(echo "$voucher_cache" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    if [[ "$exit_code" != "ok" ]]; then
        vouchers_ok=0
        log "INFO: Could not load vouchers (rc=${exit_code:-empty}) -- skip"
        voucher_cache=""
        voucher_count=0
        return
    fi
    vouchers_ok=1
    voucher_total=$(echo "$voucher_cache" | jq '.data | length' 2>/dev/null || echo 0)
    voucher_count="$voucher_total"
}

# IP AND HOSTNAME ASSIGNMENT
# Picks a free address from the hotspot range
# NOTE: called inside $() subshells -- no log(), no side effects.
# Returns "IP;hostname" via stdout only. Guest number is derived from the
# candidate IP's position in the hotspot range, not parsed from hostnames.
assign_ip_and_hostname() {
    # Used IPs are collected once into a lookup table instead of one grep per
    # candidate IP -- O(range size) instead of O(range size * UHM_MACAUTH size).
    local -A used_ips=()
    local client_ip
    while IFS= read -r client_ip; do
        [[ -n "$client_ip" ]] && used_ips["$client_ip"]=1
    done < <(awk -F';' '{print $3}' "$UHM_MACAUTH" 2>/dev/null)

    # Defense-in-depth only (already validated in load_config()); must never
    # log() since this runs inside a $(...) subshell.
    if ! [[ "$UHM_INI_RANGE" =~ $UH_IPV4 ]] || ! [[ "$UHM_END_RANGE" =~ $UH_IPV4 ]]; then
        return 1
    fi

    local candidate_int candidate_ip
    for (( candidate_int=hotspot_ini_int; candidate_int<=hotspot_end_int; candidate_int++ )); do
        candidate_ip=$(int_to_ip "$candidate_int")
        [[ -n "${used_ips[$candidate_ip]+x}" ]] && continue
        echo "${candidate_ip};guest$(( candidate_int - hotspot_ini_int + 1 ))"
        return 0
    done
    return 1
}

# LEASE REMOVAL QUEUE
# Records which leases uhmleases.sh must drop
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
queue_lease_removal() {
    local mac_addr="$1"
    local lc_mac
    lc_mac="${mac_addr,,}"
    if grep -qxF "$lc_mac" "$UHM_QUEUE" 2>/dev/null; then
        return 0
    fi
    if echo "$lc_mac" >> "$UHM_QUEUE" 2>/dev/null; then
        log "INFO: Queued lease removal for $lc_mac"
        return 0
    fi
    log "INFO: queue write failed for $lc_mac -- skip"
    return 1
}

# MAC LIST WATCHER
# Not a cycle step: flags a reload when a mac-*.txt changes
# NOT one of the numbered cycle steps and NOT part of the ACL snapshot/reload
# machinery above (acl_snapshot_*, uhm-queue.txt) -- deliberately separate, per
# the invariant that uhmd.sh never processes mac-*.txt content (only
# uhmleases.sh does). This only fingerprints the files (combined md5sum of
# path+content, so an add/remove/edit of any mac-*.txt all count) to detect
# that *something* changed, with zero parsing of MACs/status.
#
# A change detected this cycle does NOT reload immediately -- it only sets
# mac_reload_pending for check_and_reload_if_changed to pick up next cycle,
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

    if [[ -n "$mac_lists_hash_prev" && "$cur_hash" != "$mac_lists_hash_prev" ]]; then
        mac_reload_pending=1
        log "INFO: mac-*.txt changed, reload next cycle"
    fi
    mac_lists_hash_prev="$cur_hash"
}

# MANAGED MAC CHECK
# Answers whether a MAC is listed in any mac-*.txt
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
    local list_mac="${1,,}" mac_file
    [[ -z "$list_mac" ]] && return 1
    [[ "$list_mac" =~ $UH_MAC ]] || return 1
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for mac_file in "${mac_files[@]}"; do
        grep -qiE "^#?a;${list_mac};" "$mac_file" 2>/dev/null && return 0
    done
    return 1
}

# All ACTIVE (not commented) MACs across mac-*.txt, lowercased, one per line.
# Used only by authorize_managed_macs() below -- a deactivated ("#a;...")
# entry has already lost its fixed address and joined the blockdhcp class
# (see uhmleases.sh), so it must never be granted a UniFi authorization either.
list_managed_macs() {
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    (( ${#mac_files[@]} == 0 )) && return
    awk -F';' '/^a;/{print tolower($2)}' "${mac_files[@]}" 2>/dev/null \
        | grep -E "$UH_MAC" | sort -u
}

# MANAGED MAC AUTHORIZATION
# Authorizes managed devices via the API, never with a voucher
# On any WLAN configured as Guest/Hotspot (check README UNIFI PRE-CONFIGURATION),
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
    local sta_data="$1" exit_code mac_addr is_authorized auth_minutes api_url http_code
    exit_code=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$exit_code" != "ok" ]] && return

    auth_minutes=$(( AUTHORIZED_LEASE_TIME / 60 ))
    (( auth_minutes < 1 )) && auth_minutes=1

    local managed_macs
    managed_macs=$(list_managed_macs)
    [[ -z "$managed_macs" ]] && return

    while IFS= read -r mac_addr; do
        [[ -z "$mac_addr" ]] && continue
        is_authorized=$(echo "$sta_data" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac // "" | ascii_downcase) == $m) | .authorized
        ' 2>/dev/null | head -1)
        # Not currently connected (no stat/sta entry) -- nothing to authorize
        # yet; picked up automatically once it associates and appears there.
        [[ -z "$is_authorized" || "$is_authorized" == "null" ]] && continue
        [[ "$is_authorized" == "true" ]] && continue

        api_url=$(api_path "cmd/stamgr")
        http_code=$(api_post "$api_url" "{\"cmd\":\"authorize-guest\",\"mac\":\"${mac_addr}\",\"minutes\":${auth_minutes}}")
        if [[ "$http_code" == "200" ]]; then
            log "INFO: Authorized managed MAC $mac_addr in UniFi"
        else
            log "INFO: $mac_addr authorize failed (HTTP $http_code) -- skip"
        fi
    done <<< "$managed_macs"
}

# STEP 0: MALFORMED LINES
# Drops or reports lines that do not match the ACL format
# First thing in every cycle, before any step opens an ACL list. The temporary
# lists this daemon owns are cleaned here. The two authorization lists are not:
# mac-*.txt is never touched at all, and uhm-auth.txt is only reported --
# deleting a line there would revoke access with nothing on record but its
# disappearance, so it is left for uhmleases.sh to abort on.
check_malformed() {
    local check_file="$1" line_pattern="$2" check_ip="${3:-1}" on_malformed="${4:-drop}"
    [[ -f "$check_file" ]] || return 0
    local tmp_file env_line client_ip dropped_count=0
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("$tmp_file")
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ -z "$env_line" ]] && continue
        if ! [[ "$env_line" =~ $line_pattern ]]; then
            if [[ "$on_malformed" == "report" ]]; then
                log "WARNING: malformed line in $(basename "$check_file") -- alert"
            else
                log "INFO: malformed line dropped from $(basename "$check_file")"
            fi
            (( dropped_count++ )) || true
            continue
        fi
        if (( check_ip )); then
            client_ip=$(printf '%s' "$env_line" | cut -d';' -f3)
            if ! [[ "$client_ip" =~ $UH_IPV4 ]]; then
                if [[ "$on_malformed" == "report" ]]; then
                    log "WARNING: invalid IP in $(basename "$check_file") -- alert"
                else
                    log "INFO: invalid IP dropped from $(basename "$check_file")"
                fi
                (( dropped_count++ )) || true
                continue
            fi
        fi
        printf '%s\n' "$env_line" >> "$tmp_file"
    done < "$check_file"
    if [[ "$on_malformed" == "report" ]]; then
        rm -f "$tmp_file"
        return 0
    fi
    if (( dropped_count > 0 )); then
        mv -f "$tmp_file" "$check_file" && chmod 600 "$check_file"
    else
        rm -f "$tmp_file"
    fi
}

check_malformed_lines() {
    local mac_re="$UH_MAC_RE"
    local ip_re='[0-9.]+'
    local host_re='[A-Za-z0-9._-]{1,63}'
    check_malformed "$UHM_MACAUTH" "^#?a;${mac_re};${ip_re};${host_re};[0-9]+;$" 1 report
    check_malformed "$UHM_GRACE"   "^a;${mac_re};${ip_re};${host_re};[0-9]+;$"
    check_malformed "$ACL_BLOCK_FILE"  "^a;${mac_re};${ip_re};${host_re};$"
    check_malformed "$UHM_QUEUE"   "^${mac_re}$" 0
}

# STEP 3: MAC LIST DEDUPLICATION
# Removes a MAC repeated across the ACL files
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
dedup_mac_lists() {
    local all_macs
    all_macs=$(
        awk -F';' '/^a;/{print tolower($2)}' "$UHM_MACAUTH" 2>/dev/null \
          | grep -E "$UH_MAC" \
          | sort -u || true
    )

    local sanitized_block=0
    local discarded_block=0

    if [[ -f "$ACL_BLOCK_FILE" ]]; then
        local tmp_block
        tmp_block=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("${tmp_block}")
        while IFS= read -r env_line || [[ -n "$env_line" ]]; do
            [[ -z "$env_line" ]] && continue
            if [[ "$env_line" != "a;"* ]]; then
                echo "$env_line" >> "$tmp_block"
                continue
            fi
            local block_mac block_ip block_name field_count
            IFS=';' read -r _ block_mac block_ip block_name _ <<< "$env_line"
            block_mac="${block_mac,,}"
            if echo "$all_macs" | grep -q "^${block_mac}$"; then
                log "INFO: dedup -> removed $block_mac from blockdhcp.txt"
                continue
            fi
            field_count=$(echo "$env_line" | tr -cd ';' | wc -c)
            if (( field_count != 4 )); then
                if [[ "$block_mac" =~ $UH_MAC ]] && \
                   [[ "$block_ip" =~ $UH_IPV4 ]] && \
                   [[ "$block_name" =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    echo "a;${block_mac};${block_ip};${block_name};" >> "$tmp_block"
                    (( sanitized_block++ )) || true
                else
                    log "INFO: malformed blockdhcp line -- skip"
                    (( discarded_block++ )) || true
                fi
            else
                echo "$env_line" >> "$tmp_block"
            fi
        done < "$ACL_BLOCK_FILE"
        local after_lines
        after_lines=$(wc -l < "$tmp_block" 2>/dev/null || echo -1)
        if (( after_lines < 0 )); then
            log "INFO: blockdhcp update not applied -- skip"
            rm -f "$tmp_block"
        else
            mv "$tmp_block" "$ACL_BLOCK_FILE" && chmod 600 "$ACL_BLOCK_FILE"
        fi
    fi

    if (( sanitized_block > 0 )); then
        log "INFO: dedup -> sanitized $sanitized_block blockdhcp entries"
    fi
    if (( discarded_block > 0 )); then
        log "INFO: dedup discarded $discarded_block malformed entries"
    fi
}

# STEP 4: SORT ACL FILES
# Rewrites each list ordered by IP
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
sort_acl_files() {
    local tmp_file

    if [[ -s "$UHM_MACAUTH" ]]; then
        tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("${tmp_file}")
        sort -t';' -k3,3V "$UHM_MACAUTH" | uniq > "$tmp_file"
        if [[ ! -s "$tmp_file" ]]; then
            log "INFO: sorted output is empty, update -- skip"
            log "INFO: $UHM_MACAUTH"
            return
        fi
        mv "$tmp_file" "$UHM_MACAUTH" && chmod 600 "$UHM_MACAUTH"
    fi
}

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
add_mac_to_acl() {
    local mac_addr="$1" client_ip="$2" client_name="$3" end_time="$4"

    if [[ ! "$mac_addr" =~ $UH_MAC ]]; then
        log "INFO: bad MAC '$mac_addr' -- skip"
        return 1
    fi

    if [[ "$client_ip" == *';'* || "$client_name" == *';'* || "$end_time" == *';'* ]]; then
        log "INFO: ';' in ACL field, mac=$mac_addr -- skip"
        return 1
    fi

    local new_line="a;${mac_addr};${client_ip};${client_name};${end_time};"

    if grep -qi "^a;${mac_addr};" "$UHM_MACAUTH" 2>/dev/null; then
        local existing_end
        existing_end=$(grep -i "^a;${mac_addr};" "$UHM_MACAUTH" | head -1 | awk -F';' '{print $5}')
        if [[ "$end_time" != "$existing_end" ]]; then
            local escaped_line
            escaped_line=$(printf '%s' "$new_line" | sed -e 's/[\&|/]/\\&/g')
            if ! sed -i "s|^a;${mac_addr};.*|${escaped_line}|I" "$UHM_MACAUTH"; then
                log "INFO: end_time update failed for $mac_addr -- skip"
                return 1
            fi
            log "INFO: updated end_time for $mac_addr"
            log "INFO: new end_time $existing_end -> $end_time"
        fi
    else
        queue_lease_removal "$mac_addr"
        echo "$new_line" >> "$UHM_MACAUTH"
        local exp_human
        exp_human=$(date -d "@$end_time" 2>/dev/null || echo "$end_time")
        log "INFO: Authorized $mac_addr"
        log "INFO: ip=$client_ip"
        log "INFO: hostname=${client_name:0:30}"
        log "INFO: expires=$exp_human"
    fi
}

expire_from_hotspot() {
    local mac_addr="$1"
    # Release the hotspot-range IP. On reconnect, uhmleases.sh detects the
    # client via pydhcpd.leases and the client re-enters uhm-grace.txt with a
    # fresh grace timer, same as any other unclassified MAC.
    if ! queue_lease_removal "$mac_addr"; then
        log "INFO: $mac_addr expire failed, will retry -- skip"
        return 1
    fi
    log "INFO: expired $mac_addr, released from uhm-auth.txt"
    return 0
}

# STEP 5: CLEAN EXPIRED MACS
# Removes entries whose authorization time is over
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
clean_expired_macs() {
    local now_epoch tmp_file
    now_epoch=$(date +%s)
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${tmp_file}")

    local before_count=0
    before_count=$(grep -c '^#\{0,1\}a;' "$UHM_MACAUTH" 2>/dev/null); before_count=$(( ${before_count:-0} + 0 ))
    local moved_count=0

    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ -z "$env_line" ]] && continue
        # Unlike mac-*.txt (no expiry concept at all), a uhm-auth.txt entry is
        # keyed to a voucher's END_TIME_EPOCH regardless of active ("a;") or
        # deactivated ("#a;") state -- what matters is the MAC's voucher
        # lifecycle, not whether the admin happened to comment the line.
        # Active and commented entries are both checked here; only a line
        # that doesn't even look like an ACL entry passes through untouched.
        # An unreadable END_TIME_EPOCH is released like an expired one: with
        # no known expiry the entry cannot be sustained, and keeping it would
        # hold a hotspot IP forever whenever the client never reassociates
        # (the revoke step only ever sees MACs stat/sta currently reports).
        # It repairs itself: a client whose voucher is still valid is promoted
        # again next cycle by process_sessions, with an end_time from UniFi.
        if [[ "$env_line" != "a;"* && "$env_line" != "#a;"* ]]; then
            echo "$env_line" >> "$tmp_file"
            continue
        fi
        local end_time mac_addr
        end_time=$(echo "$env_line" | awk -F';' '{print $5}')
        mac_addr=$(echo "$env_line" | awk -F';' '{print $2}')
        if [[ -z "$end_time" ]] || ! [[ "$end_time" =~ $UH_UINT ]]; then
            log "WARNING: malformed end_time in uhm-auth.txt"
            log "WARNING: $mac_addr released, no expiry -- alert"
            if ! expire_from_hotspot "$mac_addr"; then
                log "INFO: keeping $mac_addr, will retry -- skip"
                echo "$env_line" >> "$tmp_file"
            else
                (( moved_count++ )) || true
            fi
        elif (( now_epoch <= end_time )); then
            echo "$env_line" >> "$tmp_file"
        else
            log "INFO: Expired $mac_addr at $(date -d "@$end_time" 2>/dev/null || echo "$end_time")"
            if ! expire_from_hotspot "$mac_addr"; then
                log "INFO: keeping $mac_addr, will retry -- skip"
                echo "$env_line" >> "$tmp_file"
            else
                (( moved_count++ )) || true
            fi
        fi
    done < "$UHM_MACAUTH"

    local after_count
    after_count=$(grep -c '^#\{0,1\}a;' "$tmp_file" 2>/dev/null); after_count=$(( ${after_count:-0} + 0 ))
    if (( before_count - after_count != moved_count )); then
        log "INFO: count mismatch ($before_count/$after_count/$moved_count) -- skip"
        rm -f "$tmp_file"
        return
    fi
    mv "$tmp_file" "$UHM_MACAUTH" && chmod 600 "$UHM_MACAUTH"
}

# STEP 6: DETECT NEW CLIENTS
# Reads pydhcpd.leases and queues what it has not seen
# Scans pydhcpd.leases for MACs that aren't yet known to any of uhmd's own
# ACL sources (uhm-auth, blockdhcp, uhm-grace) and writes them straight
# into uhm-grace.txt with a first-seen timestamp. Excludes mac-*.txt via
# is_managed_mac() (a live, on-disk check, same guard used in
# process_sessions/kick_newly_authorized): read_leases() in uhmleases.sh
# keeps a managed device's lease in pydhcpd.leases indefinitely (it's
# mac_authoritative), so that lease would otherwise match this step's own
# subnet check on every single cycle -- re-adding the MAC to
# uhm-grace.txt right after each reload's check_duplicate() removes it,
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

    local added_count=0
    local current_lease="" lease_content=""

    while IFS= read -r env_line; do
        if echo "$env_line" | grep -qE '^lease [0-9.]+ \{$'; then
            current_lease="$env_line"
            lease_content="$env_line"$'\n'
            continue
        fi
        [[ -n "$current_lease" ]] && lease_content+="$env_line"$'\n'

        if [[ "$env_line" == "}" && -n "$current_lease" ]]; then
            local mac_addr client_ip client_name
            mac_addr=$(echo "$lease_content" | grep -oiE "$UH_MAC_RE" | head -1 | tr '[:upper:]' '[:lower:]')
            client_ip=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            client_name=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr ' ' '_')
            client_name=$(echo "$client_name" | tr -cd 'A-Za-z0-9._-' | cut -c1-63)
            [[ -z "$client_name" ]] && client_name="no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)"

            if [[ -n "$client_ip" ]] && ! [[ "$client_ip" =~ $UH_IPV4 ]]; then
                log "INFO: invalid lease IP $client_ip -- skip"
                client_ip=""
            fi

            if [[ -n "$mac_addr" && -n "$client_ip" ]] \
               && ip_in_lan "$client_ip" \
               && ! is_managed_mac "$mac_addr" \
               && ! grep -qi "^a;${mac_addr};" "$UHM_MACAUTH" 2>/dev/null \
               && ! grep -qi "^a;${mac_addr};" "$ACL_BLOCK_FILE" 2>/dev/null \
               && ! grep -qi "^a;${mac_addr};" "$UHM_GRACE" 2>/dev/null; then
                echo "a;${mac_addr};${client_ip};${client_name};$(date +%s);" >> "$UHM_GRACE"
                log "INFO: new client $mac_addr -> grace"
                log "INFO: ip=$client_ip hostname=${client_name:0:30}"
                (( added_count++ )) || true
            elif [[ -n "$mac_addr" && -n "$client_ip" ]] && ! ip_in_lan "$client_ip"; then
                log "INFO: new lease outside the LAN subnet"
                log "INFO: ip=$client_ip mac=$mac_addr"
                log "INFO: subnet is $SERV_SUBNET/$SERV_MASK -- skip"
            fi
            current_lease=""
            lease_content=""
        fi
    done < "$pydhcpd_leases"

    if (( added_count > 0 )); then
        chmod 600 "$UHM_GRACE" 2>/dev/null || true
        log "INFO: added $added_count new client(s) to uhm-grace"
    fi
}

# STEP 7: PROCESS SESSIONS
# Turns each authorized portal session into an ACL entry
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
    local api_endpoint sessions_data exit_code added_count=0
    local now_epoch
    now_epoch=$(date +%s)

    api_endpoint=$(api_path "stat/guest")
    sessions_data=$(api_get "$api_endpoint")
    exit_code=$(echo "$sessions_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$exit_code" != "ok" ]] && { guest_ok=0; log "INFO: sessions step, stat/guest unavailable -- skip"; return; }
    guest_ok=1

    # Single-pass voucher lookup: build an end_time -> voucher_code map once
    # instead of one `jq` call per session below. First vcode seen per
    # end_time wins, in case two vouchers share an end_time.
    local -A voucher_by_end=()
    if [[ -n "$voucher_cache" ]]; then
        while IFS=$'\t' read -r end_epoch voucher_code; do
            [[ -n "$end_epoch" && -z "${voucher_by_end[$end_epoch]+x}" ]] && voucher_by_end["$end_epoch"]="$voucher_code"
        done < <(echo "$voucher_cache" | jq -r '
            .data[] | [(.end_time|tostring), (.code // "")] | join("\t")
        ' 2>/dev/null || true)
    fi

    while IFS='|' read -r mac_addr end_time api_authorized_by api_voucher_code; do
        [[ -z "$mac_addr" || "$mac_addr" == "null" ]] && continue
        if ! [[ "$mac_addr" =~ $UH_MAC ]]; then
            log "INFO: malformed MAC from API"
            continue
        fi
        [[ -z "$end_time" || "$end_time" == "null" ]] && continue
        if ! [[ "$end_time" =~ $UH_UINT ]]; then
            log "INFO: malformed line $mac_addr -- skip"
            continue
        fi
        (( end_time <= now_epoch )) && continue

        # uhm-auth.txt is the voucher list: only a client that actually
        # redeemed one belongs here. stat/guest reports every guest
        # authorization regardless of origin, and UniFi records that origin
        # per session in authorized_by -- "voucher" for a redeemed voucher,
        # "api" for a cmd/stamgr authorize-guest (this daemon's
        # authorize_managed_macs, the UniFi UI, or any external integration).
        # Only the former belongs in this list; the latter carries whatever
        # duration that other grant chose and no voucher backs it.
        # authorized_by is stored on the session itself, so it stays valid
        # even after UniFi auto-purges the voucher on quota exhaustion.
        [[ "$api_authorized_by" != "voucher" ]] && continue

        # No log here, on purpose: uhmd.sh does not process mac-*.txt
        # (see MANAGED MACS note above) and a managed device having a live
        # UniFi guest authorization is not this daemon's concern to report --
        # the only mac-*.txt-related log line this daemon ever produces is
        # the change-watcher's, when the reload is actually invoked.
        is_managed_mac "$mac_addr" && continue

        grep -qiE "^#[[:space:]]*a;${mac_addr};" "$UHM_MACAUTH" 2>/dev/null && continue

        if grep -qi "^a;${mac_addr};" "$UHM_MACAUTH" 2>/dev/null; then
            local existing_line existing_ip existing_hostname existing_end
            existing_line=$(grep -i "^a;${mac_addr};" "$UHM_MACAUTH" | head -1)
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
            log "INFO: renewal for $mac_addr"
            log "INFO: end_time $existing_end -> $end_time"
            log "INFO: keeping ip=$existing_ip for $mac_addr"
            log "INFO: hostname=${existing_hostname:0:30}"
            if add_mac_to_acl "$mac_addr" "$existing_ip" "$existing_hostname" "$end_time"; then
                (( added_count++ )) || true
            fi
            continue
        fi

        if [[ "${revoked_sessions[${mac_addr,,}]:-}" == "$end_time" ]]; then
            continue
        fi

        local assigned_ip="" assigned_hostname=""
        local ip_and_host
        if ! ip_and_host=$(assign_ip_and_hostname); then
            log "INFO: range exhausted for $mac_addr -- skip"
            continue
        fi
        assigned_ip=$(echo "$ip_and_host" | cut -d';' -f1)
        assigned_hostname=$(echo "$ip_and_host" | cut -d';' -f2)

        local voucher_code
        if [[ -n "$api_voucher_code" && "$api_voucher_code" != "null" ]]; then
            voucher_code="$api_voucher_code"
        else
            voucher_code="${voucher_by_end[$end_time]:-}"
        fi
        voucher_code=$(printf '%s' "$voucher_code" | tr -cd 'A-Za-z0-9._-')
        # Plain "guestN" (no "-code" suffix) is written whenever voucher_code
        # ends up empty here -- not just from the length guard below.
        # voucher_code is empty when neither source above had it: the API
        # didn't return api_voucher_code AND voucher_by_end[$end_time] had
        # no match, which happens whenever voucher_cache was empty for this
        # cycle (load_all_vouchers() failed, e.g. stat/voucher not yet ready
        # right after a restart -- see the startup grace loop in main()).
        # The length guard below (uhmleases.sh's normalize_acl_file() rejects
        # any uhm-auth.txt hostname over 63 chars and aborts normalization for
        # the whole file) is the second, much rarer way to land here: no known
        # UniFi version actually returns a code long enough to trigger it
        # (observed codes are short, numeric).
        if [[ -n "$voucher_code" ]]; then
            if (( ${#assigned_hostname} + 1 + ${#voucher_code} <= 63 )); then
                assigned_hostname="${assigned_hostname}-${voucher_code}"
            else
                log "INFO: voucher code too long, hostname without it -- degraded"
            fi
        fi

        if ! add_mac_to_acl "$mac_addr" "$assigned_ip" "$assigned_hostname" "$end_time"; then
            continue
        fi
        (( added_count++ )) || true
        # New fixed-address assignment (not a renewal) -- this MAC needs to be
        # kicked off the AP once the reload below applies the new IP, so it
        # reconnects with a clean DHCP DISCOVER instead of racing its old lease.
        newly_authorized_macs+=("$mac_addr")

    done < <(echo "$sessions_data" | jq -r '
        .data[]
        | select(.mac != null and .mac != "")
        | select(.end != null)
        | [(.mac | ascii_downcase), (.end | tostring), (.authorized_by // ""), (.voucher_code // "")]
        | join("|")
    ' 2>/dev/null || true)

    sessions_authorized=$added_count
}

# STEP 8: REVOKE UNAUTHORIZED
# Removes what the controller no longer reports as authorized
# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
revoke_unauthorized() {
    local sta_data="$1"
    local exit_code
    exit_code=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    [[ "$exit_code" != "ok" ]] && { log "INFO: revoke step, stat/sta unavailable -- skip"; return; }

    # Single-pass lookup: build a mac -> authorized map once instead of one
    # `jq` call per line of UHM_MACAUTH below. First match wins per MAC.
    local -A sta_authorized=()
    while IFS=$'\t' read -r sta_mac sta_auth; do
        [[ -n "$sta_mac" && -z "${sta_authorized[$sta_mac]+x}" ]] && sta_authorized["$sta_mac"]="$sta_auth"
    done < <(echo "$sta_data" | jq -r '
        .data[] | [(.mac|ascii_downcase), (.authorized|tostring)] | join("\t")
    ' 2>/dev/null || true)

    local revoked_mac
    for revoked_mac in "${!revoked_sessions[@]}"; do
        [[ "${sta_authorized[$revoked_mac]:-}" != "false" ]] && unset "revoked_sessions[$revoked_mac]"
    done

    local revoked_count=0
    local macs_to_revoke=()

    while IFS=';' read -r acl_status mac_addr client_ip client_name end_time _ || [[ -n "$acl_status" ]]; do
        [[ "$acl_status" != "a" ]] && continue
        [[ -z "$mac_addr" ]] && continue

        # Skip MACs authorized earlier in this same cycle (process_sessions,
        # via stat/guest) -- UniFi can take a moment to propagate a fresh
        # voucher authorization into stat/sta, so checking it here right
        # away can still see a stale authorized=false and revoke what was
        # just granted, only to re-authorize and kick it again next cycle.
        local mac_lc="${mac_addr,,}" newly_mac skip_revoke=0
        for newly_mac in "${newly_authorized_macs[@]+"${newly_authorized_macs[@]}"}"; do
            [[ "${newly_mac,,}" == "$mac_lc" ]] && { skip_revoke=1; break; }
        done
        (( skip_revoke )) && continue

        local is_authorized="${sta_authorized[$mac_lc]:-}"
        if [[ "$is_authorized" == "false" ]]; then
            macs_to_revoke+=("$mac_addr")
            revoked_sessions["$mac_lc"]="$end_time"
        fi
    done < "$UHM_MACAUTH"

    local mac_addr
    for mac_addr in "${macs_to_revoke[@]+"${macs_to_revoke[@]}"}"; do
        [[ -z "$mac_addr" ]] && continue
        if [[ ! "$mac_addr" =~ $UH_MAC ]]; then
            log "WARNING: bad MAC '$mac_addr' -- alert"
            continue
        fi
        log "INFO: Revoking $mac_addr"
        log "INFO: authorized=false in UniFi; releasing from uhm-auth"
        queue_lease_removal "$mac_addr"
        if sed -i "/^a;${mac_addr};/Id" "$UHM_MACAUTH" 2>/dev/null; then
            (( revoked_count++ )) || true
        else
            log "INFO: remove failed for $mac_addr -- skip"
        fi
    done

    revoked_total=$revoked_count
}

# STEP 2: ACL SNAPSHOT
# Baseline used later to decide whether a reload is needed
snapshot_acls() {
    acl_snapshot_hotspot=$(md5sum "$UHM_MACAUTH" 2>/dev/null | awk '{print $1}')
    acl_snapshot_block=$(md5sum "$ACL_BLOCK_FILE" 2>/dev/null | awk '{print $1}')
    acl_snapshot_queue=$(md5sum "$UHM_QUEUE" 2>/dev/null | awk '{print $1}')
    acl_snapshot_grace=$(md5sum "$UHM_GRACE" 2>/dev/null | awk '{print $1}')
}

# STEP 9: RELOAD IF CHANGED
# Runs uhmreload.sh when the snapshot no longer matches
# Returns 0 if ACLs changed (reload attempted), 1 if unchanged (silent -- no
# log noise on the common no-change path). Callers use the return code to
# decide whether the per-cycle summary line is worth logging.
check_and_reload_if_changed() {
    local cur_hotspot cur_block cur_queue cur_grace exit_code now_epoch since_last acl_changed=0
    cur_hotspot=$(md5sum "$UHM_MACAUTH" 2>/dev/null | awk '{print $1}')
    cur_block=$(md5sum "$ACL_BLOCK_FILE" 2>/dev/null | awk '{print $1}')
    cur_queue=$(md5sum "$UHM_QUEUE" 2>/dev/null | awk '{print $1}')
    cur_grace=$(md5sum "$UHM_GRACE" 2>/dev/null | awk '{print $1}')

    [[ "$cur_hotspot" != "$acl_snapshot_hotspot" || "$cur_block" != "$acl_snapshot_block" || \
       "$cur_queue" != "$acl_snapshot_queue" || "$cur_grace" != "$acl_snapshot_grace" ]] \
        && acl_changed=1

    # mac-*.txt change detected last cycle by check_mac_lists_changed (an
    # independent watcher, see above) folds into this same single reload
    # decision -- never a separate uhmreload.sh invocation of its own.
    local mac_reload_triggered=0
    if (( mac_reload_pending == 1 )); then
        acl_changed=1
        mac_reload_triggered=1
    fi

    now_epoch=$(date +%s)
    since_last=$(( now_epoch - last_reload_epoch ))

    if (( acl_changed == 0 && since_last < RELOAD_SAFETY_INTERVAL_SECONDS )); then
        return 1
    fi

    if (( acl_changed == 1 )); then
        [[ "$cur_hotspot" != "$acl_snapshot_hotspot" ]] && log "INFO: uhm-auth.txt changed"
        [[ "$cur_block" != "$acl_snapshot_block" ]] && log "INFO: blockdhcp.txt changed"
        [[ "$cur_queue" != "$acl_snapshot_queue" ]] && log "INFO: lease removal queue changed"
        [[ "$cur_grace" != "$acl_snapshot_grace" ]] && log "INFO: uhm-grace.txt changed"
        (( mac_reload_triggered )) && log "INFO: mac-*.txt changed, reloading now"
    else
        log "INFO: ${RELOAD_SAFETY_INTERVAL_SECONDS}s since last reload"
        log "INFO: forcing safety-net reload"
    fi

    mac_reload_pending=0

    reload_ok=0
    if ensure_executable "${UHM_RELOAD:-}" "UHM_RELOAD" 755; then
        log "INFO: invoking $UHM_RELOAD"
        # Release the mechanism lock before delegating: uhmleases.sh acquires
        # it itself, with its own descriptor, and cannot do so while this
        # daemon still holds it. Reacquired below for the rest of the cycle.
        flock -u 201 2>/dev/null || log "INFO: failed to release cycle lock -- skip"
        if "$UHM_RELOAD" >/dev/null 2>>"$log_file"; then
            reload_ok=1
            last_reload_epoch=$now_epoch
        else
            exit_code=$?
            # Update the epoch on failure too, not just success: a persistent
            # failure (broken uhmleases.sh/uhmiptables.sh, timeout) would otherwise
            # keep since_last stuck below RELOAD_SAFETY_INTERVAL_SECONDS forever
            # relative to the last real success (or never even set for a
            # brand-new install), causing a retry -- and its WARNING alert and
            # trace file -- every single cycle instead of backing off to the
            # safety-net cadence. ACL-change-triggered reloads are unaffected:
            # they fire on the next real diff, not on this timer.
            last_reload_epoch=$now_epoch
            log "WARNING: uhmreload.sh failed (code $exit_code), backing off -- alert"
        fi
        flock -n 201 || log "INFO: cycle lock not reacquired after reload -- skip"
    else
        # Same reasoning as the failure branch above: update the epoch here
        # too, so a misconfigured UHM_RELOAD (missing or not
        # executable) backs off to the safety-net cadence instead of
        # re-logging this WARNING -- and re-alerting via uhmalert.sh -- on
        # every single cycle.
        last_reload_epoch=$now_epoch
        if (( acl_changed == 1 )); then
            log "WARNING: ACLs changed but UHM_RELOAD not found"
        else
            log "WARNING: safety-net reload due but UHM_RELOAD not found"
        fi
        log "WARNING: backing off, will not retry -- alert"
    fi
    return 0
}

# STEP 10: KICK NEW CLIENTS
# Forces a reconnect so the client picks up its new address
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
    local mac_addr kick_url http_code on_sta exit_code
    exit_code=$(echo "$sta_data" | jq -r '.meta.rc // empty' 2>/dev/null || true)
    for mac_addr in "${newly_authorized_macs[@]}"; do
        # Defense-in-depth: process_sessions already excludes managed MACs via
        # is_managed_mac(), so this should never trigger. Logged loudly (not a
        # silent continue), unlike process_sessions' own routine/high-volume
        # skip above -- this one firing at all means something upstream let a
        # managed MAC slip through, which is itself worth surfacing.
        if is_managed_mac "$mac_addr"; then
            log "WARNING: $mac_addr is in mac-*.txt -- skip"
            log "WARNING: not kicked, it is a managed device"
            log "WARNING: $mac_addr bypassed guard -- alert"
            continue
        fi
        if [[ "$exit_code" == "ok" ]]; then
            on_sta=$(echo "$sta_data" | jq -r --arg mac "$mac_addr" '
                .data[] | select((.mac | ascii_downcase) == $mac) | "yes"
            ' 2>/dev/null | head -1 || true)
            if [[ "$on_sta" != "yes" ]]; then
                log "INFO: $mac_addr not connected, no kick -- skip"
                continue
            fi
        else
            log "INFO: stat/sta unavailable"
            log "INFO: kicking $mac_addr without presence check"
        fi

        kick_url=$(api_path "cmd/stamgr")
        http_code=$(api_post "$kick_url" "{\"cmd\":\"kick-sta\",\"mac\":\"${mac_addr}\"}")
        if [[ "$http_code" == "200" ]]; then
            log "INFO: kicked $mac_addr, forcing reassociation"
        else
            log "INFO: failed to kick $mac_addr (HTTP $http_code) -- skip"
        fi
    done
}

# HOTSPOT CYCLE
# Runs the ten steps above in order, under the cycle lock
run_cycle() {
    rm -f "$cycle_mark_file" 2>/dev/null || true

    if ! flock -n 201; then
        log "INFO: cycle lock held unexpectedly -- skip"
        return
    fi

    sessions_authorized=0
    revoked_total=0
    newly_authorized_macs=()

    check_malformed_lines

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
    [[ "$sta_rc" == "ok" ]] && sta_ok=1 || sta_ok=0

    # Backend readiness marker: the login endpoint can respond while the data
    # endpoints are still initializing (typical right after a reboot). Log a
    # single line the first time all three data endpoints answer OK together,
    # and re-arm it if any drops later, so the log always shows exactly when
    # the UniFi backend became fully usable -- not just when login succeeded.
    if (( vouchers_ok && guest_ok && sta_ok )); then
        if (( backend_ready == 0 )); then
            backend_ready=1
            log "INFO: UniFi backend ready (voucher/guest/sta OK)"
        fi
    else
        backend_ready=0
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
        log "vouchers=$voucher_count|auth=$authorized_total|grace=$grace_total|new_auth=$sessions_authorized|revoked_count=$revoked_total"

        if [[ "$reload_ok" == "1" && ${#newly_authorized_macs[@]} -gt 0 ]]; then
            kick_newly_authorized "$sta_data"
        fi
    fi

    local check_file
    for check_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$check_file" 2>/dev/null || true
    done
    temp_files=()

    flock -u 201 2>/dev/null || log "INFO: failed to release cycle lock -- skip"
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# Logs in once and then repeats the cycle every POLL_INTERVAL
main() {
    load_config
    POLL_INTERVAL="${POLL_INTERVAL:-20}"
    if ! [[ "$POLL_INTERVAL" =~ $UH_UINT ]] || (( POLL_INTERVAL == 0 )); then
        log "WARNING: POLL_INTERVAL invalid -- fallback"
        POLL_INTERVAL=20
    fi
    STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-120}"
    if ! [[ "$STARTUP_GRACE_SECONDS" =~ $UH_UINT ]]; then
        log "WARNING: STARTUP_GRACE_SECONDS invalid -- fallback"
        STARTUP_GRACE_SECONDS=120
    fi
    UHM_LEASES_TIMEOUT_SECONDS="${UHM_LEASES_TIMEOUT_SECONDS:-120}"
    if ! [[ "$UHM_LEASES_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( UHM_LEASES_TIMEOUT_SECONDS == 0 )); then
        log "WARNING: UHM_LEASES_TIMEOUT_SECONDS invalid -- fallback"
        UHM_LEASES_TIMEOUT_SECONDS=120
    fi
    UHM_IPTABLES_TIMEOUT_SECONDS="${UHM_IPTABLES_TIMEOUT_SECONDS:-60}"
    if ! [[ "$UHM_IPTABLES_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( UHM_IPTABLES_TIMEOUT_SECONDS == 0 )); then
        log "WARNING: UHM_IPTABLES_TIMEOUT_SECONDS invalid -- fallback"
        UHM_IPTABLES_TIMEOUT_SECONDS=60
    fi
    local reload_floor=$(( 3 * (UHM_LEASES_TIMEOUT_SECONDS + UHM_IPTABLES_TIMEOUT_SECONDS) ))
    (( reload_floor < 600 )) && reload_floor=600
    RELOAD_SAFETY_INTERVAL_SECONDS="${RELOAD_SAFETY_INTERVAL_SECONDS:-3600}"
    if ! [[ "$RELOAD_SAFETY_INTERVAL_SECONDS" =~ $UH_UINT ]] || (( RELOAD_SAFETY_INTERVAL_SECONDS < reload_floor )); then
        log "ERROR: RELOAD_SAFETY_INTERVAL_SECONDS too low"
        log "ERROR: minimum is $reload_floor seconds -- abort"
        exit 1
    fi
    if [[ -z "${AUTHORIZED_LEASE_TIME:-}" ]]; then
        log "WARNING: AUTHORIZED_LEASE_TIME not set -- fallback"
        AUTHORIZED_LEASE_TIME="$default_lease_time"
    elif ! [[ "$AUTHORIZED_LEASE_TIME" =~ $UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
        log "WARNING: AUTHORIZED_LEASE_TIME invalid -- fallback"
        AUTHORIZED_LEASE_TIME="$default_lease_time"
    fi
    verify_installation
    init_acl_files

    log "uhmd start..."

    # UniFi-OS can take a while to come back up after a reboot -- this host and
    # the controller often boot together. Retry quietly (INFO, no alert) for
    # up to STARTUP_GRACE_SECONDS before treating it as a real failure; a
    # controller that's simply still booting should never page anyone.
    local login_start login_elapsed
    login_start=$(date +%s)
    until unifi_login "quiet"; do
        login_elapsed=$(( $(date +%s) - login_start ))
        if (( login_elapsed >= STARTUP_GRACE_SECONDS )); then
            log "ERROR: no UniFi login in ${STARTUP_GRACE_SECONDS}s -- abort"
            exit 1
        fi
        sleep 10
    done

    # stat/voucher can still fail right after login even though the login
    # endpoint itself just answered -- UniFi-OS brings its subsystems up
    # gradually after a reboot. Without this, a guest authorized by the
    # very first run_cycle() would get its hostname written without the
    # voucher-code suffix (process_sessions() falls back to plain "guestN"
    # when voucher_cache is empty), and that hostname is never
    # recomputed later. Same grace pattern as unifi_login above, but a
    # persistent failure only logs a warning and continues instead of
    # exiting -- the daemon can still authorize/revoke without vouchers.
    local voucher_start voucher_elapsed
    voucher_start=$(date +%s)
    load_all_vouchers
    while (( vouchers_ok == 0 )); do
        voucher_elapsed=$(( $(date +%s) - voucher_start ))
        if (( voucher_elapsed >= STARTUP_GRACE_SECONDS )); then
            log "INFO: no vouchers at startup, names without code -- degraded"
            break
        fi
        sleep 10
        load_all_vouchers
    done

    # iptables/ipset state does not survive a reboot, but the ACL files
    # themselves may be unchanged from before it -- check_and_reload_if_changed()
    # (used inside run_cycle) would then never trigger a reload, leaving the
    # firewall empty until the next ACL change or the safety-net interval.
    # Force one reload here, on every daemon start, regardless of ACL state.
    if ensure_executable "${UHM_RELOAD:-}" "UHM_RELOAD" 755; then
        log "INFO: startup, invoking uhmreload"
        if "$UHM_RELOAD" >/dev/null 2>>"$log_file"; then
            last_reload_epoch=$(date +%s)
        else
            log "WARNING: startup reload failed"
            log "WARNING: firewall may be incomplete -- alert"
            last_reload_epoch=$(date +%s)
        fi
    else
        log "WARNING: UHM_RELOAD not found"
        log "WARNING: firewall not rebuilt at startup -- alert"
    fi

    while true; do
        run_cycle || log "WARNING: cycle ended with error -- alert"
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
