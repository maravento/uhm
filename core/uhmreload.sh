#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmreload - Reload wrapper
#
# DESCRIPTION:
# invoked by uhmd after ACL changes, or on its own safety-net cadence
# (RELOAD_SAFETY_INTERVAL_SECONDS in uhm.env, default 1h) -- no cron
# entry needed. Can also be run manually for troubleshooting, but only while
# uhmd.service is active -- it aborts otherwise (see the guard below).
# Runs uhmleases.sh (lease/ACL rebuild) then uhmiptables.sh (firewall
# rules), in that order. The two are not treated the same on failure:
# - uhmleases.sh: missing, or a genuine execution failure, aborts the reload
#   (ERROR + exit 1). It is the core ACL/lease reconciliation step --
#   nothing downstream can be trusted without it.
# - uhmiptables.sh: missing only warns and continues (the reload still
#   counts as done). uhmsetup.sh deploys it as a minimal working template,
#   so a normal install always has it. A genuine execution failure (script
#   exists, runs, exits non-zero) still aborts (ERROR + exit 1) -- only
#   its absence is tolerated.
# Owner and mode of both scripts are restored to what uhmsetup.sh deployed
# (755 for uhmleases.sh, 750 for uhmiptables.sh) before running them.
#
# TIMEOUTS (uhm.env):
# uhmd.sh invokes this script with no time limit of its own -- it just waits
# for uhmreload.sh to finish. Each step below is bounded individually
# instead: UHM_LEASES_TIMEOUT_SECONDS (default 120) and
# UHM_IPTABLES_TIMEOUT_SECONDS (default 60). A step that exceeds its limit is
# killed, its trace saved to /var/log/<step>-failure.trace, and the reload
# aborts (ERROR logged).
#
# NOTE on logging:
# - Writes to /var/log/uhm.log (shared with uhmleases.sh). Rotation
#   (/etc/logrotate.d/uhm) is installed by uhmsetup.sh only.
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

# dependencies
for dep_pkg in util-linux coreutils grep systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

UH_UINT='^(0|[1-9][0-9]*)$'

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

config_file="/etc/uhm/uhm.env"
if [[ ! -f "$config_file" ]]; then
    log "ERROR: uhm.env not found, run uhmsetup.sh -- abort"
    exit 1
fi
env_owner=$(stat -c '%U' "$config_file" 2>/dev/null)
env_perms=$(stat -c '%a' "$config_file" 2>/dev/null)
if [[ "$env_owner" != "root" ]] || [[ "$env_perms" != "600" ]]; then
    if chown root:root "$config_file" 2>/dev/null && chmod 600 "$config_file" 2>/dev/null; then
        log "WARNING: uhm.env perms fixed -- alert"
    else
        log "ERROR: cannot fix uhm.env perms -- abort"
        exit 1
    fi
fi
unset env_owner env_perms

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

UHM_LEASES_TIMEOUT_SECONDS=$(grep -m1 '^UHM_LEASES_TIMEOUT_SECONDS=' "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UHM_LEASES_TIMEOUT_SECONDS" ]]; then
    log "WARNING: UHM_LEASES_TIMEOUT_SECONDS not set -- fallback"
    UHM_LEASES_TIMEOUT_SECONDS=120
fi
if ! [[ "$UHM_LEASES_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( UHM_LEASES_TIMEOUT_SECONDS == 0 )); then
    log "WARNING: UHM_LEASES_TIMEOUT_SECONDS invalid -- fallback"
    UHM_LEASES_TIMEOUT_SECONDS=120
fi

UHM_IPTABLES_TIMEOUT_SECONDS=$(grep -m1 '^UHM_IPTABLES_TIMEOUT_SECONDS=' "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UHM_IPTABLES_TIMEOUT_SECONDS" ]]; then
    log "WARNING: UHM_IPTABLES_TIMEOUT_SECONDS not set -- fallback"
    UHM_IPTABLES_TIMEOUT_SECONDS=60
fi
if ! [[ "$UHM_IPTABLES_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( UHM_IPTABLES_TIMEOUT_SECONDS == 0 )); then
    log "WARNING: UHM_IPTABLES_TIMEOUT_SECONDS invalid -- fallback"
    UHM_IPTABLES_TIMEOUT_SECONDS=60
fi

UHM_LEASES=$(grep -m1 '^UHM_LEASES=' "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UHM_LEASES" ]]; then
    log "WARNING: UHM_LEASES not set -- fallback"
    UHM_LEASES="/etc/uhm/core/uhmleases.sh"
fi

UHM_IPTABLES=$(grep -m1 '^UHM_IPTABLES=' "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UHM_IPTABLES" ]]; then
    log "WARNING: UHM_IPTABLES not set -- fallback"
    UHM_IPTABLES="/etc/uhm/tools/uhmiptables.sh"
fi

# No mechanism lock is taken here. This script is a convenience wrapper that
# invokes uhmleases.sh and uhmiptables.sh in order, and could be replaced by
# two direct invocations at any time. The guard belongs to the script that
# writes: uhmleases.sh acquires cycle_lock itself, with its own descriptor,
# whoever invoked it -- so nothing is lost if this wrapper goes away.

# start
log "uhmreload start..."

# Abort if uhmd isn't active -- nothing downstream should run blindly.
if ! systemctl is-active --quiet uhmd; then
    log "ERROR: uhmd not active -- abort"
    exit 1
fi

ensure_executable() {
    local script_path="$1" script_name="$2" expected_mode="$3"
    [[ -f "$script_path" ]] || return 1
    local file_owner file_perms
    file_owner=$(stat -c '%U' "$script_path" 2>/dev/null)
    file_perms=$(stat -c '%a' "$script_path" 2>/dev/null)
    if [[ "$file_owner" != "root" || "$file_perms" != "$expected_mode" ]]; then
        if chown root:root "$script_path" 2>/dev/null && chmod "$expected_mode" "$script_path" 2>/dev/null; then
            log "WARNING: $script_name perms fixed -- alert"
        else
            log "WARNING: cannot fix $script_name perms -- alert"
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
        log "ERROR: $script_name not found -- abort"
        exit 1
    fi
    local trace_file
    if ! trace_file=$(mktemp -t "${script_name%.sh}-trace.XXXXXX" 2>/dev/null); then
        log "ERROR: cannot create trace file -- abort"
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
            log "WARNING: cannot write ${trace_dest##*/} -- alert"
            rm -f "$trace_file"
            trace_ok=0
        fi
        if [[ "$exit_code" == "124" ]]; then
            log "ERROR: $script_name timed out after ${step_timeout}s"
        else
            log "ERROR: $script_name failed (exit $exit_code)"
        fi
        if (( trace_ok )); then
            log "ERROR: trace: ${trace_dest##*/} -- abort"
        else
            log "ERROR: no trace saved -- abort"
        fi
        exit 1
    fi
    rm -f "$trace_file" 2>/dev/null || true
}

run_step "$UHM_LEASES" "uhmleases.sh" "$UHM_LEASES_TIMEOUT_SECONDS" 755

# uhmsetup.sh deploys uhmiptables.sh as a minimal but working template, so a
# normal install always has a runnable file here. Unlike uhmleases.sh above, a
# missing uhmiptables.sh warns and continues rather than aborting --
# uhmleases.sh is the core ACL/lease reconciliation and its absence must stop
# the reload chain; uhmiptables.sh only enforces at the firewall level, and ACL
# classification keeps working correctly without it.
if [[ ! -f "$UHM_IPTABLES" ]]; then
    log "WARNING: uhmiptables.sh not found -- alert"
else
    run_step "$UHM_IPTABLES" "uhmiptables.sh" "$UHM_IPTABLES_TIMEOUT_SECONDS" 750
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "uhmreload done at: $(date)"
