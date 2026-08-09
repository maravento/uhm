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
# Installed alongside uhmleases.sh and uhmd.sh under /etc/uhm/core/ --
# these three plus uhmd.service are the reload mechanism itself, not
# auxiliary tools (unlike /etc/uhm/tools/, which holds independent
# scripts, mostly optional: uhmaudit.sh, uhmcheck.sh, uhmmon.sh,
# uhmalert.sh, plus the admin-provided uhmiptables.sh -- uhmwatch.sh is
# the one exception, installed there too but mandatory).
# Runs uhmleases.sh (lease/ACL rebuild) then uhmiptables.sh (firewall rules), in
# that order. The two are not treated the same on failure:
# - uhmleases.sh: missing, not executable, or a genuine execution failure all
# abort the reload (WARNING + exit 1). It is the core ACL/lease
# reconciliation step -- nothing downstream can be trusted without it.
# - uhmiptables.sh: missing or not executable only warns and continues (the
# reload still counts as done). It also ships as a stub that
# intentionally exits 1 until configured, detected and skipped the same
# way. A genuine execution failure (script exists, runs, exits non-zero)
# still aborts (WARNING + exit 1) -- only its absence is tolerated.
#
# TIMEOUTS (uhm.env):
# uhmd.sh invokes this script with no time limit of its own -- it just
# waits for uhmreload.sh to finish. Each step below is bounded individually
# instead: ULEASES_TIMEOUT_SECONDS (default 120) and UIPTABLES_TIMEOUT_SECONDS
# (default 60). A step that exceeds its limit is killed, its trace saved to
# /var/log/<step>-failure.trace, and the reload aborts (WARNING logged).
#
# NOTE on logging:
# - Writes to /var/log/uhm.log (shared with uhmleases.sh). Rotation
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

# DEPENDENCIES
for dep in util-linux coreutils; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency '$dep' is not installed."
        exit 1
    fi
done

_UH_UINT='^(0|[1-9][0-9]*)$'

CONFIG_FILE="/etc/uhm/uhm.env"
ULEASES_TIMEOUT_SECONDS=$(grep -m1 '^ULEASES_TIMEOUT_SECONDS=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$ULEASES_TIMEOUT_SECONDS" ]]; then
    log "WARNING: ULEASES_TIMEOUT_SECONDS not set in $CONFIG_FILE"
    log "  using default 120"
    ULEASES_TIMEOUT_SECONDS=120
fi
[[ "$ULEASES_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || ULEASES_TIMEOUT_SECONDS=120

UIPTABLES_TIMEOUT_SECONDS=$(grep -m1 '^UIPTABLES_TIMEOUT_SECONDS=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UIPTABLES_TIMEOUT_SECONDS" ]]; then
    log "WARNING: UIPTABLES_TIMEOUT_SECONDS not set"
    log "  using default 60"
    UIPTABLES_TIMEOUT_SECONDS=60
fi
[[ "$UIPTABLES_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || UIPTABLES_TIMEOUT_SECONDS=60

ULEASES_SCRIPT=$(grep -m1 '^ULEASES_SCRIPT=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$ULEASES_SCRIPT" ]]; then
    log "WARNING: ULEASES_SCRIPT not set in $CONFIG_FILE"
    log "  using default /etc/uhm/core/uhmleases.sh"
    ULEASES_SCRIPT="/etc/uhm/core/uhmleases.sh"
fi

UIPTABLES_SCRIPT=$(grep -m1 '^UIPTABLES_SCRIPT=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
if [[ -z "$UIPTABLES_SCRIPT" ]]; then
    log "WARNING: UIPTABLES_SCRIPT not set in $CONFIG_FILE"
    log "  using default /etc/uhm/tools/uhmiptables.sh"
    UIPTABLES_SCRIPT="/etc/uhm/tools/uhmiptables.sh"
fi

# UHM_RELOAD_ACTIVE: not set here. The daemon exports it before calling
# this script (so uhmleases.sh skips its own guard, since the daemon already
# holds CYCLE_LOCK). If this script is run manually (not by the daemon),
# UHM_RELOAD_ACTIVE stays unset, so uhmleases.sh acquires CYCLE_LOCK
# itself instead, to avoid racing a daemon cycle that might be in progress.

# Start
log "uhmreload start..."

# Abort if uhmd isn't active -- nothing downstream should run blindly.
if ! systemctl is-active --quiet uhmd; then
    log "ERROR: uhmd is not active"
    log "  aborting (uhmleases.sh/uhmiptables.sh not invoked)"
    exit 1
fi

# Both scripts log their own output via log(); stdout here is a duplicate
# and is discarded, stderr is kept for uncaught bash errors.
#
# Each step is run under `bash -x` so a failure leaves a full trace behind --
# a bare "$name failed" with no further detail (e.g. a command that fails
# silently, like `sysctl -w ... >/dev/null 2>&1` with no key present) gives
# no way to diagnose after the fact. The trace is discarded on success and
# kept only when the step actually fails, so this adds no normal overhead.
run_step() {
    local script="$1" name="$2" step_timeout="$3"
    if [[ ! -x "$script" ]]; then
        log "WARNING: $name not found or not executable: $script"
        log "  aborting"
        exit 1
    fi
    local trace_file
    trace_file=$(mktemp -t "${name%.sh}-trace.XXXXXX")
    local exit_code=0
    timeout "$step_timeout" bash -x "$script" >/dev/null 2>"$trace_file" || exit_code=$?
    if [[ "$exit_code" != "0" ]]; then
        # Fixed name, overwritten on every failure (not one file per
        # timestamp) -- a persistent failure retries every cycle, and an
        # unbounded trace per attempt would fill /var/log over time.
        local trace_dest="/var/log/${name%.sh}-failure.trace"
        mv -f "$trace_file" "$trace_dest" 2>/dev/null || { log "WARNING: failed to move trace to $trace_dest -- discarding"; rm -f "$trace_file"; }
        if [[ "$exit_code" == "124" ]]; then
            log "WARNING: $name timed out after ${step_timeout}s"
            log "  aborting; trace saved to $trace_dest"
        else
            log "WARNING: $name failed (exit $exit_code)"
            log "  aborting; trace saved to $trace_dest"
        fi
        exit 1
    fi
    rm -f "$trace_file" 2>/dev/null || true
}

run_step "$ULEASES_SCRIPT" "uhmleases.sh" "$ULEASES_TIMEOUT_SECONDS"

# uhmiptables.sh ships as a stub that always exits 1 until the admin replaces
# it with real firewall rules (see README) -- that is the normal state right
# after install, not a failure. Only invoke it once it looks configured, so
# an unconfigured stub does not trigger a WARNING/trace file on every reload.
# Unlike uhmleases.sh above, a missing uhmiptables.sh warns and continues rather
# than aborting -- uhmleases.sh is the core ACL/lease reconciliation and its
# absence must stop the reload chain; uhmiptables.sh only enforces at the
# firewall level, and ACL classification keeps working correctly without it.
if [[ ! -x "$UIPTABLES_SCRIPT" ]]; then
    log "WARNING: uhmiptables.sh not found or not executable"
    log "  path: $UIPTABLES_SCRIPT -- skipping"
elif grep -qF "UHM_STUB_MARKER" "$UIPTABLES_SCRIPT" 2>/dev/null; then
    log "INFO: uhmiptables.sh not configured yet"
    log "  skipping firewall reload (see README)"
else
    run_step "$UIPTABLES_SCRIPT" "uhmiptables.sh" "$UIPTABLES_TIMEOUT_SECONDS"
fi

# End
log "uhmreload done at: $(date)"
