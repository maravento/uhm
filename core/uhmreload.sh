#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmreload -- Reload wrapper
# FILE: core/uhmreload.sh
#
# USAGE:
# uhmreload.sh    (no arguments)
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

# log file perms (as installed by uhmsetup.sh)
log_stat=$(stat -c '%U %G %a' "$log_file" 2>/dev/null || true)
case "$log_stat" in
    ""|"root adm 640"|"root root 640") ;;
    *)
        if { chown root:adm "$log_file" 2>/dev/null || chown root:root "$log_file" 2>/dev/null; } &&
           chmod 640 "$log_file" 2>/dev/null; then
            log "INFO: uhm.log perms fixed -fixed"
        else
            log "WARNING: cannot fix uhm.log perms -alert"
        fi
        ;;
esac
unset log_stat

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -abort"
    exit 1
fi

# dependencies
for dep_pkg in util-linux coreutils grep systemd; do
    if [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" != *"ok installed"* ]]; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- integer only; use directly with =~
UH_UINT='^(0|[1-9][0-9]*)$'
UH_SINT='^(0|-?[1-9][0-9]*)$'
UH_MAX=9223372036854775807
UH_MIN=-9223372036854775808

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# validation - integer is representable as a signed 64-bit value
uh_fits() {
    local value="${1-}" limit
    [[ "$value" =~ $UH_SINT ]] || return 1
    if [[ "${value:0:1}" == - ]]; then
        limit="${UH_MIN#-}"
        value="${value#-}"
    else
        limit="$UH_MAX"
    fi
    (( ${#value} < ${#limit} )) && return 0
    (( ${#value} > ${#limit} )) && return 1
    [[ "$value" > "$limit" ]] && return 1
    return 0
}

ensure_executable() {
    local script_path="$1" script_name="$2" expected_mode="$3"
    [[ -f "$script_path" ]] || return 1
    local file_owner file_perms
    file_owner=$(stat -c '%U' "$script_path" 2>/dev/null)
    file_perms=$(stat -c '%a' "$script_path" 2>/dev/null)
    if [[ "$file_owner" != "root" || "$file_perms" != "$expected_mode" ]]; then
        if chown root:root "$script_path" 2>/dev/null && chmod "$expected_mode" "$script_path" 2>/dev/null; then
            log "INFO: $script_name perms fixed -fixed"
        else
            log "WARNING: cannot fix $script_name perms -alert"
        fi
    fi
    return 0
}

# Both scripts log their own output via log(); stdout here is a duplicate
# and is discarded, stderr is kept for uncaught bash errors.
#
# Each step is run under `bash -x` so a failure leaves a full trace behind --
# a bare "$script_name failed" with no further detail (e.g. a command that fails
# silently, like `sysctl -w ... >/dev/null 2>&1` with no key present) gives
# no way to diagnose after the fact. The trace is discarded on success and
# kept only when the step actually fails, so this adds no normal overhead.
run_step() {
    local script_path="$1" script_name="$2" step_timeout="$3" expected_mode="$4"
    if ! ensure_executable "$script_path" "$script_name" "$expected_mode"; then
        log "ERROR: $script_name not found -abort"
        exit 1
    fi
    local trace_file
    if ! trace_file=$(mktemp -t "${script_name%.sh}-trace.XXXXXX" 2>/dev/null); then
        log "ERROR: cannot create trace file -abort"
        exit 1
    fi
    local exit_code=0
    timeout "$step_timeout" bash -x "$script_path" >/dev/null 2>"$trace_file" || exit_code=$?
    if [[ "$exit_code" != "0" ]]; then
        # Fixed name, overwritten on every failure (not one file per
        # timestamp) -- a persistent failure retries every cycle, and an
        # unbounded trace per attempt would fill /var/log over time.
        local trace_dest="/var/log/${script_name%.sh}-failure.trace"
        local trace_ok=1
        if ! mv -f "$trace_file" "$trace_dest" 2>/dev/null; then
            log "WARNING: cannot write ${trace_dest##*/} -alert"
            rm -f "$trace_file"
            trace_ok=0
        fi
        if [[ "$exit_code" == "124" ]]; then
            log "ERROR: $script_name timed out after ${step_timeout}s"
        else
            log "ERROR: $script_name failed (exit $exit_code)"
        fi
        if (( trace_ok )); then
            log "ERROR: trace: ${trace_dest##*/} -abort"
        else
            log "ERROR: no trace saved -abort"
        fi
        exit 1
    fi
    rm -f "$trace_file" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
uhm_env="/etc/uhm/uhm.env"
env_specs=("$uhm_env root:root 600")
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
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../tools/uhmenv.sh"
env_keys='UHM_LEASES_TIMEOUT_SECONDS UHM_IPTABLES_TIMEOUT_SECONDS UHM_LEASES UHM_IPTABLES'

# LOAD
# Reads uhm.env; a missing key is handled by the check below
load_uhm_env "$uhm_env" "$env_keys" line || true

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
key_errors=()
for env_key in UHM_LEASES UHM_IPTABLES; do
    if ! grep -q "^${env_key}=" "$uhm_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    fi
done
for env_key in UHM_LEASES_TIMEOUT_SECONDS UHM_IPTABLES_TIMEOUT_SECONDS; do
    if ! grep -q "^${env_key}=" "$uhm_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif ! [[ "${!env_key}" =~ $UH_UINT ]] || [[ "${!env_key}" == 0 ]]; then
        key_errors+=("$env_key invalid seconds")
    elif ! uh_fits "${!env_key}"; then
        key_errors+=("$env_key exceeds the Bash integer range")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$uhm_env") -abort"
    exit 1
fi
unset key_errors key_error env_key

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# No mechanism lock is taken here. This script is a convenience wrapper that
# invokes uhmleases.sh and uhmiptables.sh in order, and could be replaced by
# two direct invocations at any time. The guard belongs to the script that
# writes: uhmleases.sh acquires cycle_lock itself, with its own descriptor,
# whoever invoked it -- so nothing is lost if this wrapper goes away.

# start
log "uhmreload start..."

# Abort if uhmd isn't active -- nothing downstream should run blindly.
if ! systemctl is-active --quiet uhmd; then
    log "ERROR: uhmd not active -abort"
    exit 1
fi

run_step "$UHM_LEASES" "uhmleases.sh" "$UHM_LEASES_TIMEOUT_SECONDS" 755

# uhmsetup.sh deploys uhmiptables.sh as a minimal but working template, so a
# normal install always has a runnable file here. Unlike uhmleases.sh above, a
# missing uhmiptables.sh warns and continues rather than aborting --
# uhmleases.sh is the core ACL/lease reconciliation and its absence must stop
# the reload chain; uhmiptables.sh only enforces at the firewall level, and ACL
# classification keeps working correctly without it.
if [[ ! -f "$UHM_IPTABLES" ]]; then
    log "WARNING: uhmiptables.sh not found -alert"
else
    run_step "$UHM_IPTABLES" "uhmiptables.sh" "$UHM_IPTABLES_TIMEOUT_SECONDS" 750
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "uhmreload done"
