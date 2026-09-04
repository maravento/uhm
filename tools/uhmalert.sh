#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmalert -- UniFi Hotspot Alert Watcher (optional)
#
# DESCRIPTION:
# Watches the shared uhm log in real time and sends a push
# notification via ntfy.sh on three kinds of events:
#
# 1. Connectivity loss to the UniFi controller -- anchors on the
#    "Could not load vouchers" line, which uhmd.sh's load_all_vouchers()
#    logs exactly once per cycle when the controller is unreachable.
#    Successful cycles are silent, so consecutive failures are identified
#    by comparing timestamps: a gap larger than gap_limit = POLL_INTERVAL
#    + 3*api_max_time + jitter_margin (default 20 + 3*30 + 10 = 120s) between two
#    failure lines means cycles succeeded silently in between, and the
#    streak resets. The 3*api_max_time term covers the worst case of a
#    failed cycle still making up to three 30s-capped API calls (vouchers,
#    guest, sta) before it ends. Alerts once UHM_API_FAIL_THRESHOLD
#    consecutive cycles fail, and again once recovered (same gap_limit is
#    the read timeout used to detect recovery -- see watch loop below).
#    Suppressed while uhmd.service has been active for less than
#    UHM_ALERT_QUIET_PERIOD_SECONDS (default 120s) -- UniFi Network/UniFi
#    OS can take a while to come back up after a reboot, and uhmalert
#    itself starts at boot too, so the very first cycles would otherwise
#    alert on a known, expected startup window. A real outage later still
#    alerts at the normal threshold, unaffected.
#
# 2. Any other ERROR or WARNING line -- the log already classifies every
#    line's severity ("TIMESTAMP LEVEL: message"), shared by uhmd.sh and
#    the uhmreload.sh/uhmleases.sh/uhmiptables.sh chain. Fires
#    immediately, no streak -- one occurrence is already worth knowing
#    about. Excludes lines already covered by #1 (so connectivity still
#    waits for the threshold, not the first failure) and "cycle lock held
#    unexpectedly" (expected/already handled, see uhmd.sh run_cycle() --
#    not a bug).
#
# 3. Any FIX: line -- written only by uhmwatch.sh when it successfully
#    recovers a service. Fires immediately, same as #2, and closes out
#    the WARNING alert that reported the problem in the first place.
#
# Standalone -- never reads or modifies uhmd.sh, only tails its log
# file. Runs as its own systemd service (uhmalert.service), independent of
# uhmd, so the daemon stays byte-identical to upstream. Optional:
# uhmd.sh runs fine with or without uhmalert installed.
#
# DEPENDENCIES:
# - bash, curl, mawk, grep, sed, util-linux (flock), GNU coreutils
#   (date -d, tail -F) -- standard on Ubuntu/Debian
# - systemd (systemctl) -- only needed for `install`/`uninstall`
# - uhmd.sh already installed and running (this reads its log; it
#   does not start or manage the daemon itself)
# - An ntfy.sh account is not required. Install the free "ntfy" app
#   (Android/iOS) and subscribe to a topic name of your choice -- treat
#   the topic name as a shared secret, since anyone who knows it can
#   publish to it. https://ntfy.sh
#
# CONFIGURATION:
# `install` appends UHM_NTFY_TOPIC (auto-generated, unpredictable),
# UHM_API_FAIL_THRESHOLD=3 and UHM_ALERT_QUIET_PERIOD_SECONDS=120 to
# uhm.env on first run, and prints the generated
# topic name so you can subscribe the ntfy app to it. Never overwrites
# any of them if already present (safe to re-run/upgrade).
# To change them later, edit uhm.env directly and restart the
# service: systemctl restart uhmalert
# POLL_INTERVAL is read from the same file (falls back to 20 if unset),
# matching uhmd.sh's own cycle interval.
#
# USAGE:
# sudo ./uhmalert.sh install Deploy the script,
# create+enable+start uhmalert.service
# (creates the systemd unit if missing)
# sudo ./uhmalert.sh uninstall Stop+disable the service, remove the unit
# uhmalert.sh Run the watch loop directly (this is what
# uhmalert.service's ExecStart invokes)
# uhmalert.sh -h, --help Show this help
#
# CONFIG: /etc/uhm/uhm.env. reads:
# UHM_NTFY_TOPIC, UHM_API_FAIL_THRESHOLD, UHM_ALERT_QUIET_PERIOD_SECONDS, POLL_INTERVAL
# LOG: /var/log/uhm.log (reads only -- shared with uhmd.sh)
# SERVICE: systemctl status uhmalert
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

# dependencies
for dep_pkg in curl mawk coreutils util-linux grep sed systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

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
        printf '\n%s\n' "$env_block" >> "$conf_file"
        return
    fi
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    head -n "$last_line" "$conf_file" > "$tmp_file"
    printf '\n%s\n' "$env_block" >> "$tmp_file"
    tail -n "+$((last_line + 1))" "$conf_file" >> "$tmp_file"
    mv "$tmp_file" "$conf_file"
}

install_module() {
    local gen_topic
    echo ""
    echo "=================================="
    echo "Installing uhmalert (uhm alert)"
    echo "=================================="
    echo ""

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: $config_file not found" >&2
        echo "ERROR: install and configure uhm first -- abort" >&2
        exit 1
    fi

    # Only append if not already configured -- never overwrite an existing
    # topic (e.g. on a re-install) or a threshold the user already tuned.
    if grep -q '^UHM_NTFY_TOPIC=' "$config_file"; then
        gen_topic=$(grep '^UHM_NTFY_TOPIC=' "$config_file" | tail -1 | cut -d'=' -f2- | tr -d '"')
        echo "UHM_NTFY_TOPIC already set in $config_file -- leaving it untouched."
    else
        gen_topic="uhm-alert-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
        insert_after_last_delimiter "$config_file" "# =============================================================================
# UHM ALERT
# =============================================================================
UHM_NTFY_TOPIC=\"$gen_topic\"
UHM_API_FAIL_THRESHOLD=3
UHM_ALERT_QUIET_PERIOD_SECONDS=120
# ============================================================================="
        echo "Added UHM_NTFY_TOPIC, UHM_API_FAIL_THRESHOLD and"
        echo "UHM_ALERT_QUIET_PERIOD_SECONDS to $config_file"
    fi
    # Insert right after their neighbor in the Alert block (not a plain
    # >> append) so upgrading an older install doesn't scatter these
    # variables to the end of the file, past unrelated later sections.
    if ! grep -q '^UHM_API_FAIL_THRESHOLD=' "$config_file"; then
        sed -i '/^UHM_NTFY_TOPIC=/a UHM_API_FAIL_THRESHOLD=3' "$config_file"
    fi
    if ! grep -q '^UHM_ALERT_QUIET_PERIOD_SECONDS=' "$config_file"; then
        sed -i '/^UHM_API_FAIL_THRESHOLD=/a UHM_ALERT_QUIET_PERIOD_SECONDS=120' "$config_file"
    fi

    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$target_path" ]]; then
        echo "Deploying script to $target_path..."
        mkdir -p "$(dirname "$target_path")"
        install -m 755 -o root -g root "$self_path" "$target_path"
    fi

    echo "Writing systemd unit ($unit_path)..."
    cat > "$unit_path" <<'UNITEOF'
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

    systemctl daemon-reload
    systemctl enable uhmalert.service
    systemctl restart uhmalert.service

    echo ""
    echo "Installed and started. Check with: systemctl status uhmalert"
    echo ""
    echo "=================================="
    echo "ntfy topic: $gen_topic"
    echo "=================================="
    echo "Install the free 'ntfy' app (Android/iOS) and subscribe to the"
    echo "topic above to start receiving alerts on this device."
    echo ""
}

uninstall_module() {
    echo "Stopping and disabling uhmalert.service..."
    systemctl stop uhmalert.service 2>/dev/null || true
    systemctl disable uhmalert.service 2>/dev/null || true
    rm -f "$unit_path"
    systemctl daemon-reload
    echo "uhmalert.service removed. The uhmalert.sh script was not deleted."
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

case "${1:-}" in
    install)
        install_module
        exit 0
        ;;
    uninstall)
        uninstall_module
        exit 0
        ;;
esac

# prevent overlapping runs of the watch loop itself -- install/uninstall above
# are one-shot admin actions and must not block on (or be blocked by) the
# lock the service holds for its entire lifetime.
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# -- Watch loop (default action -- this is what uhmalert.service runs) ------------
# No -e: this is a long-running watch loop, one bad line (e.g. an
# unparseable timestamp) must not kill the whole process.

if [[ ! -f "$config_file" ]]; then
    log "ERROR: $config_file not found -- abort"
    exit 1
fi
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
# Load only known KEY=VALUE pairs instead of sourcing, so a tampered or
# maliciously replaced config file cannot execute code -- same approach as
# uhmleases.sh's load_env_file().
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
        fi
        case "$env_key" in
            UHM_NTFY_TOPIC|UHM_API_FAIL_THRESHOLD|UHM_ALERT_QUIET_PERIOD_SECONDS|POLL_INTERVAL)
                printf -v "$env_key" '%s' "$env_value"
                ;;
            *)
                ;;
        esac
    done < "$conf_file"
}
load_env_file "$config_file"

if [[ -z "${UHM_NTFY_TOPIC:-}" ]]; then
    log "ERROR: UHM_NTFY_TOPIC not set in $config_file -- abort"
    exit 1
fi

fail_threshold="${UHM_API_FAIL_THRESHOLD:-3}"
if ! [[ "$fail_threshold" =~ $UH_UINT ]] || (( fail_threshold == 0 )); then
    log "WARNING: UHM_API_FAIL_THRESHOLD invalid -- fallback"
    fail_threshold=3
fi
POLL_INTERVAL="${POLL_INTERVAL:-20}"
if ! [[ "$POLL_INTERVAL" =~ $UH_UINT ]] || (( POLL_INTERVAL == 0 )); then
    log "WARNING: POLL_INTERVAL invalid -- fallback"
    POLL_INTERVAL=20
fi
quiet_period="${UHM_ALERT_QUIET_PERIOD_SECONDS:-120}"
[[ "$quiet_period" =~ $UH_UINT ]] || { log "WARNING: UHM_ALERT_QUIET_PERIOD_SECONDS invalid -- fallback"; quiet_period=120; }
jitter_margin=10 # tolerance added to POLL_INTERVAL so minor cycle jitter doesn't
            # falsely look like a gap with a silent recovery in between
api_max_time=30 # matches curl --max-time in uhmd.sh's api_get calls
gap_limit=$(( POLL_INTERVAL + 3 * api_max_time + jitter_margin ))
dedup_window=300 # suppress a repeated identical ERROR/WARNING catch-all
                  # alert if it fires again within this many seconds

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
    echo "$term_ts uhmalert done at: $term_ts" | tee -a "$log_file" 2>/dev/null || true
    exit 0
}
trap on_term TERM INT

# start
log "uhmalert start..."

exec 3< <(tail -n0 -F "$log_file" 2>/dev/null)

while true; do
    if (( alert_sent == 1 && last_ts_epoch != 0 )); then
        now_epoch=$(date +%s)
        if (( now_epoch - last_ts_epoch >= gap_limit )); then
            if systemctl is-active --quiet uhmd; then
                notify "uhm: recovered -- no new failures in the last ${gap_limit}s"
                log "ALERT: recovery notice (no new failures) -- sent"
                fail_streak=0
                alert_sent=0
            else
                log "INFO: uhmd not active, no recovery notice -- skip"
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
                log "ALERT: recovery notice (backend ready) -- sent"
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
        # (shared log) -- fires immediately, no streak needed. FIX: lines
        # come only from uhmwatch.sh (any of the services it manages) --
        # a successful recovery closing out an earlier WARNING/ERROR alert.
        if (( is_connectivity == 0 )) && { [[ "$log_msg" == ERROR:* ]] || [[ "$log_msg" == WARNING:* ]] || [[ "$log_msg" == FIX:* ]]; }; then
            now_epoch=$(date +%s)
            if [[ "$log_msg" == "$last_generic_msg" ]] && (( now_epoch - last_generic_time < dedup_window )); then
                log "INFO: dup alert suppressed (${dedup_window}s): ${log_msg:0:25}"
                continue
            fi
            last_generic_msg="$log_msg"
            last_generic_time="$now_epoch"
            notify "uhm: $log_msg"
            log "ALERT: ${log_msg:0:45} -- sent"
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
                log "INFO: $fail_streak failures within startup grace, suppressed"
                fail_streak=0
            else
                notify "uhm: $fail_streak consecutive failed cycles reaching the controller (since $line_ts)"
                log "ALERT: $fail_streak consecutive cycle failures -- sent"
                log "ALERT: latest at $line_ts"
                alert_sent=1
            fi
        fi
    elif (( read_rc == 1 )); then
        log "ERROR: uhmalert lost log monitoring (tail died) -- abort"
        exit 1
    else
        # read timed out: no new line for a full gap_limit window. Recovery
        # (if any) was already evaluated by the pre-read check above; this
        # is just a safety-net reset.
        fail_streak=0
        alert_sent=0
    fi
done
