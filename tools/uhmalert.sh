#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmalert -- UniFi Hotspot Alert Watcher (optional)
#
# USAGE:
# sudo ./uhmalert.sh --install     Deploy the script, create+enable+start
#                                uhmalert.service
# sudo ./uhmalert.sh --uninstall   Stop+disable the service, remove the unit
# uhmalert.sh                    Run the watch loop directly (what
#                                uhmalert.service's ExecStart invokes)
# uhmalert.sh -h, --help         Show this help
#
# LOG: /var/log/uhm.log
#
################################################################################

set -uo pipefail

# USAGE
# Answered before any check: --help must work without root
usage() {
    awk 'NR==1{next} /^#{20,}$/{c++; if(c==2){exit}} {print}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

case "${1:-}" in
    -h|--help)
        usage
        ;;
esac

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

# dependencies
for dep_pkg in curl coreutils util-linux grep sed systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- integer only; use directly with =~
UH_UINT='^(0|[1-9][0-9]*)$'

target_path="/etc/uhm/tools/uhmalert.sh"
unit_path="/etc/systemd/system/uhmalert.service"
config_file="/etc/uhm/uhm.env"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Appends $2 (one or more lines) right after the file's LAST
# "# ====...====" line, instead of a plain >> append -- so the new block
# always lands right after whatever content (from any script sharing this
# file: uhmsetup.sh, uhmalert.sh, ...) is already there, never inside
# whichever one of them happens to be last. Falls back to a plain append if
# the file has no delimiter line at all (empty/malformed file).
insert_after_last_delimiter() {
    local conf_file="$1" env_block="$2" last_line tmp_file
    last_line=$(grep -n '^# =\{5,\}$' "$conf_file" | tail -1 | cut -d: -f1)
    if [[ -z "$last_line" ]]; then
        printf '\n%s\n' "$env_block" >> "$conf_file" \
            || { log "ERROR: cannot write $(basename "$conf_file") -abort"; exit 1; }
        return
    fi
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -abort"; exit 1; }
    if ! { head -n "$last_line" "$conf_file" > "$tmp_file" \
        && printf '\n%s\n' "$env_block" >> "$tmp_file" \
        && tail -n "+$((last_line + 1))" "$conf_file" >> "$tmp_file" \
        && mv "$tmp_file" "$conf_file"; }; then
        rm -f "$tmp_file"
        log "ERROR: cannot write $(basename "$conf_file") -abort"
        exit 1
    fi
}

install_module() {
    local gen_topic
    echo ""
    echo "Installing uhmalert (uhm alert)"
    echo ""

    if [[ ! -f "$config_file" ]]; then
        log "ERROR: $config_file not found"
        log "ERROR: install and configure uhm first -abort"
        exit 1
    fi

    # Only append if not already configured -- never overwrite an existing
    # topic (e.g. on a re-install) or a threshold the user already tuned.
    if grep -q '^UHM_NTFY_TOPIC=' "$config_file"; then
        gen_topic=$(grep '^UHM_NTFY_TOPIC=' "$config_file" | tail -1 | cut -d'=' -f2- | tr -d '"')
        log "INFO: UHM_NTFY_TOPIC already set, left untouched"
    else
        gen_topic="uhm-alert-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
        insert_after_last_delimiter "$config_file" "# =============================================================================
# UHM ALERT
# =============================================================================
UHM_NTFY_TOPIC=$gen_topic
UHM_API_FAIL_THRESHOLD=3
UHM_ALERT_QUIET_PERIOD_SECONDS=120
# Alert defaults
# Changing these defaults is not recommended
UHM_ALERT_JITTER_SECONDS=10
UHM_ALERT_DEDUP_SECONDS=300
# ============================================================================="
        log "INFO: added 5 alert keys to $config_file"
    fi
    # Insert right after their neighbor in the Alert block (not a plain
    # >> append) so upgrading an older install doesn't scatter these
    # variables to the end of the file, past unrelated later sections.
    if ! grep -q '^UHM_API_FAIL_THRESHOLD=' "$config_file"; then
        sed -i '/^UHM_NTFY_TOPIC=/a UHM_API_FAIL_THRESHOLD=3' "$config_file" \
            || { log "ERROR: cannot write $(basename "$config_file") -abort"; exit 1; }
    fi
    if ! grep -q '^UHM_ALERT_QUIET_PERIOD_SECONDS=' "$config_file"; then
        sed -i '/^UHM_API_FAIL_THRESHOLD=/a UHM_ALERT_QUIET_PERIOD_SECONDS=120' "$config_file" \
            || { log "ERROR: cannot write $(basename "$config_file") -abort"; exit 1; }
    fi

    if ! grep -q '^UHM_ALERT_JITTER_SECONDS=' "$config_file"; then
        sed -i '/^UHM_ALERT_QUIET_PERIOD_SECONDS=/a # Alert defaults\n# Changing these defaults is not recommended\nUHM_ALERT_JITTER_SECONDS=10' "$config_file" \
            || { log "ERROR: cannot write $(basename "$config_file") -abort"; exit 1; }
    fi
    if ! grep -q '^UHM_ALERT_DEDUP_SECONDS=' "$config_file"; then
        sed -i '/^UHM_ALERT_JITTER_SECONDS=/a UHM_ALERT_DEDUP_SECONDS=300' "$config_file" \
            || { log "ERROR: cannot write $(basename "$config_file") -abort"; exit 1; }
    fi

    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$target_path" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Deploying script to $target_path..."
        if ! { mkdir -p "$(dirname "$target_path")" \
            && install -m 644 -o root -g root "$(dirname "$self_path")/uhmenv.sh" "$(dirname "$target_path")/uhmenv.sh" \
            && install -m 755 -o root -g root "$self_path" "$target_path"; }; then
            log "ERROR: cannot deploy uhmalert to $target_path -abort"
            exit 1
        fi
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Writing systemd unit ($unit_path)..."
    if ! cat > "$unit_path" <<'UNITEOF'
[Unit]
Description=UniFi Hotspot Connectivity Alert Watcher
After=network.target uhmd.service
Wants=uhmd.service

[Service]
Type=simple
ExecStart=/etc/uhm/tools/uhmalert.sh
Restart=always
RestartSec=10
PrivateTmp=yes
ProtectHome=read-only
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectKernelLogs=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
UNITEOF
    then
        log "ERROR: cannot write $(basename "$unit_path") -abort"
        exit 1
    fi

    if ! { systemctl daemon-reload \
        && systemctl enable uhmalert.service \
        && systemctl restart uhmalert.service; }; then
        log "ERROR: cannot start uhmalert.service -abort"
        exit 1
    fi

    echo ""
    echo "Installed and started. Check with: systemctl status uhmalert"
    echo ""
    echo "ntfy topic: $gen_topic"
    echo "Install free 'ntfy' app (Android/iOS) and subscribe to the"
    echo "topic above to start receiving alerts on this device"
    echo ""
}

uninstall_module() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') Stopping and disabling uhmalert.service..."
    systemctl stop uhmalert.service 2>/dev/null || true
    systemctl disable uhmalert.service 2>/dev/null || true
    if ! { rm -f "$unit_path" && systemctl daemon-reload; }; then
        log "ERROR: cannot remove $(basename "$unit_path") -abort"
        exit 1
    fi
    log "INFO: uhmalert.service removed, script kept"
}

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

case "${1:-}" in
    --install)
        install_module
        exit 0
        ;;
    --uninstall)
        uninstall_module
        exit 0
        ;;
esac

# prevent overlapping runs of the watch loop itself -- install/uninstall above
# are one-shot admin actions and must not block on (or be blocked by) the
# lock the service holds for its entire lifetime.
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

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
env_specs=("$config_file root:root 600")
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
env_keys='UHM_NTFY_TOPIC UHM_API_FAIL_THRESHOLD UHM_ALERT_QUIET_PERIOD_SECONDS UHM_ALERT_JITTER_SECONDS UHM_ALERT_DEDUP_SECONDS UHM_API_TIMEOUT_SECONDS POLL_INTERVAL'

# LOAD
# Reads uhm.env; a missing key is handled by the check below
load_uhm_env "$config_file" "$env_keys" line || true

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
# Alert keys are written by this script's install action; POLL_INTERVAL by uhmsetup.sh.
key_errors=()
if ! grep -q "^UHM_NTFY_TOPIC=" "$config_file"; then
    key_errors+=("UHM_NTFY_TOPIC missing line")
elif [[ -z "${UHM_NTFY_TOPIC:-}" ]]; then
    key_errors+=("UHM_NTFY_TOPIC not set")
fi
for env_key in UHM_API_FAIL_THRESHOLD POLL_INTERVAL UHM_API_TIMEOUT_SECONDS; do
    if ! grep -q "^${env_key}=" "$config_file"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif ! [[ "${!env_key}" =~ $UH_UINT ]] || (( ${!env_key} == 0 )); then
        key_errors+=("$env_key invalid count")
    fi
done
for env_key in UHM_ALERT_QUIET_PERIOD_SECONDS UHM_ALERT_JITTER_SECONDS UHM_ALERT_DEDUP_SECONDS; do
    if ! grep -q "^${env_key}=" "$config_file"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif ! [[ "${!env_key}" =~ $UH_UINT ]]; then
        key_errors+=("$env_key invalid seconds")
    fi
done
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$config_file") -abort"
    exit 1
fi
unset key_errors key_error env_key
jitter_margin="$UHM_ALERT_JITTER_SECONDS"
dedup_window="$UHM_ALERT_DEDUP_SECONDS"

fail_threshold="$UHM_API_FAIL_THRESHOLD"
quiet_period="$UHM_ALERT_QUIET_PERIOD_SECONDS"

# Maximum log silence allowed before reporting recovery
gap_limit=$(( POLL_INTERVAL + 3 * UHM_API_TIMEOUT_SECONDS + jitter_margin ))

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# No -e: this is a long-running watch loop, one bad line (e.g. an
# unparseable timestamp) must not kill the whole process.

fail_streak=0
alert_sent=0
last_ts_epoch=0
last_generic_msg=""
last_generic_time=0

# Time since uhmd.service itself became active (not uhmalert's own
# uptime) -- UniFi-OS/UniFi Network can take a couple of minutes to come
# back up after a reboot, and uhmd starts failing its cycles
# immediately, before the controller is ready to answer. Suppressing the
# alert during this known startup window avoids false alarms without
# weakening the threshold for a real outage later in the day.
uhmd_started_at() {
    local started_ts
    started_ts=$(systemctl show -p ActiveEnterTimestamp --value uhmd 2>/dev/null)
    date -d "$started_ts" +%s 2>/dev/null || echo 0
}

notify() {
    curl -s -d "$1" "https://ntfy.sh/${UHM_NTFY_TOPIC}" >/dev/null 2>&1 &
}

# Bash builtins only, no fork -- systemd's default KillMode=control-group
# sends TERM to this whole cgroup at once, so an external `date` (forked
# either by log()'s own timestamp prefix or by this line's message) can be
# killed before it prints anything, logging this line with an empty
# timestamp. printf's %()T is bash's own strftime, no subprocess involved.
on_term() {
    printf -v term_ts '%(%Y-%m-%d %H:%M:%S)T' -1
    printf '%s uhmalert done at: %s\n' "$term_ts" "$term_ts"
    exit 0
}
trap on_term TERM INT

# start
echo "$(date '+%Y-%m-%d %H:%M:%S') uhmalert start..."

exec 3< <(tail -n0 -F "$log_file" 2>/dev/null)

while true; do
    if (( alert_sent == 1 && last_ts_epoch != 0 )); then
        now_epoch=$(date +%s)
        if (( now_epoch - last_ts_epoch >= gap_limit )); then
            if systemctl is-active --quiet uhmd; then
                notify "uhm: recovered -- no new failures in the last ${gap_limit}s"
                log "INFO: recovery notice (no new failures)"
                fail_streak=0
                alert_sent=0
            else
                log "INFO: uhmd not active, no recovery notice -skip"
                fail_streak=0
                last_ts_epoch=0
            fi
        fi
    fi
    read_rc=0
    IFS= read -r -t "$gap_limit" -u 3 log_line || read_rc=$?
    if (( read_rc == 0 )); then
        if [[ "$log_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\  ]]; then
            log_msg="${log_line:20}"
        else
            log_msg="$log_line"
        fi

        # Known-benign -- expected/already handled, must never alert.
        [[ "$log_msg" == *"cycle lock held unexpectedly"* ]] && continue

        # Edge-triggered recovery: uhmd logs this once, exactly when
        # the backend transitions from failing to answering OK -- fires
        # the recovery notice immediately instead of waiting for gap_limit.
        if [[ "$log_msg" == "INFO: UniFi backend ready (voucher/guest/sta OK)" ]]; then
            if (( alert_sent == 1 )); then
                notify "uhm: recovered -- backend answering again"
                log "INFO: recovery notice (backend ready)"
                fail_streak=0
                alert_sent=0
            fi
            continue
        fi

        # Connectivity-loss lines are ERROR/WARNING too, but they are
        # handled by the streak counter below (waits for
        # UHM_API_FAIL_THRESHOLD consecutive cycles) rather than firing on the
        # first occurrence like the generic catch-all does.
        is_connectivity=0
        [[ "$log_msg" == *"Could not load vouchers"* ]] && is_connectivity=1
        [[ "$log_msg" == *"API GET"* ]] && is_connectivity=1

        # Generic catch-all: any other ERROR/WARNING line, from
        # uhmd.sh or the uhmreload.sh/uhmleases.sh/uhmiptables.sh chain
        # (shared log) -- fires immediately, no streak needed.
        if (( is_connectivity == 0 )) && { [[ "$log_msg" == ERROR:* ]] || [[ "$log_msg" == WARNING:* ]]; }; then
            now_epoch=$(date +%s)
            if [[ "$log_msg" == "$last_generic_msg" ]] && (( now_epoch - last_generic_time < dedup_window )); then
                dup_text="${log_msg#* }"
                case "$dup_text" in
                    *" -abort"|*" -alert"|*" -fallback"|*" -skip"|*" -retry"|*" -fixed")
                        dup_text="${dup_text% -*}" ;;
                esac
                log "INFO: dup alert (${dedup_window}s): $dup_text -skip"
                continue
            fi
            last_generic_msg="$log_msg"
            last_generic_time="$now_epoch"
            # The quoted line carries its own label and control action; both
            # are stripped so this one does not end up with two of each.
            alert_text="${log_msg#* }"
            case "$alert_text" in
                *" -abort"|*" -alert"|*" -fallback"|*" -skip"|*" -retry"|*" -fixed")
                    alert_text="${alert_text% -*}" ;;
            esac
            notify "uhm: $log_msg"
            log "INFO: $alert_text"
            continue
        fi

        [[ "$log_msg" != *"Could not load vouchers"* ]] && continue

        line_ts="${log_line:0:19}"
        line_epoch=$(date -d "$line_ts" +%s 2>/dev/null) || continue

        # Gap since the last matching failure is bigger than one cycle
        # (plus margin) -- cycles succeeded silently in between, so this is
        # a fresh outage, not a continuation of the previous one.
        if (( last_ts_epoch != 0 )) && (( line_epoch - last_ts_epoch > gap_limit )); then
            fail_streak=0
            alert_sent=0
        fi
        last_ts_epoch=$line_epoch
        fail_streak=$(( fail_streak + 1 ))

        if (( fail_streak == fail_threshold )) && (( alert_sent == 0 )); then
            uhmd_start=$(uhmd_started_at)
            if (( uhmd_start > 0 )) && (( line_epoch - uhmd_start < quiet_period )); then
                log "INFO: $fail_streak failures within startup grace -skip"
                fail_streak=0
            else
                notify "uhm: $fail_streak consecutive failed cycles reaching the controller (since $line_ts)"
                log "INFO: $fail_streak consecutive cycle failures"
                log "INFO: latest at $line_ts"
                alert_sent=1
            fi
        fi
    elif (( read_rc == 1 )); then
        log "ERROR: uhmalert lost log monitoring (tail died) -abort"
        exit 1
    else
        # read timed out: no new line for a full gap_limit window. The streak
        # is reset, but not alert_sent: the window can close during the read,
        # and the pre-read check above still owes that recovery notice.
        fail_streak=0
    fi
done
