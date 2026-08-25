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
# "Could not load vouchers" line, which uhmd.sh's
# load_all_vouchers() logs exactly once per cycle when the controller
# is unreachable. Successful cycles are silent, so consecutive
# failures are identified by comparing timestamps: a gap larger than
# GAP_LIMIT = POLL_INTERVAL + 3*API_MAX_TIME + MARGIN (default
# 20 + 3*30 + 10 = 120s) between two failure lines means cycles
# succeeded silently in between, and the streak resets. The 3*API_MAX_TIME
# term covers the worst case of a failed cycle still making up to three
# 30s-capped API calls (vouchers, guest, sta) before it ends. Alerts once
# UHM_API_FAIL_THRESHOLD consecutive cycles fail, and again once recovered
# (same GAP_LIMIT is the read timeout used to detect recovery -- see
# watch loop below).
# Suppressed while uhmd.service has been active for less than
# UHM_ALERT_QUIET_PERIOD_SECONDS (default 120s) -- UniFi Network/UniFi OS can
# take a while to come back up after a reboot, and uhmalert itself
# starts at boot too, so the very first cycles would otherwise alert
# on a known, expected startup window. A real outage later still
# alerts at the normal threshold, unaffected.
#
# 2. Any other ERROR or WARNING line -- the log already classifies every
# line's severity ("TIMESTAMP LEVEL: message"), shared by
# uhmd.sh and the uhmreload.sh/uhmleases.sh/uhmiptables.sh chain.
# Fires immediately, no streak -- one occurrence is already worth
# knowing about. Excludes lines already covered by #1 (so
# connectivity still waits for the threshold, not the first failure)
# and "cycle lock held unexpectedly" (expected/already handled, see
# uhmd.sh run_cycle() -- not a bug).
#
# 3. Any FIX: line -- written only by uhmwatch.sh when it successfully
# recovers a service. Fires immediately, same as #2, and closes out
# the WARNING alert that reported the problem in the first place.
#
# Standalone -- never reads or modifies uhmd.sh, only tails its log
# file. Runs as its own systemd service (uhmalert.service), independent of
# uhmd, so the daemon stays byte-identical to upstream. Optional:
# uhmd.sh runs fine with or without uhmalert installed.
#
# DEPENDENCIES:
# - bash, curl, mawk, grep, sed, util-linux (flock), GNU coreutils
# (date -d, tail -F) -- standard on Ubuntu/Debian
# - systemd (systemctl) -- only needed for `install`/`uninstall`
# - uhmd.sh already installed and running (this reads its log; it
# does not start or manage the daemon itself)
# - An ntfy.sh account is not required. Install the free "ntfy" app
# (Android/iOS) and subscribe to a topic name of your choice -- treat
# the topic name as a shared secret, since anyone who knows it can
# publish to it. https://ntfy.sh
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

# logging
log_file="/var/log/uhm.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

usage() {
    awk 'NR==1{next} /^#{20,}$/{c++; if(c==2){exit}} {print}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

case "${1:-}" in
    -h|--help)
        usage
        ;;
esac

## root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# DEPENDENCIES
for dep in curl mawk coreutils util-linux grep sed systemd; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency '$dep' is not installed."
        exit 1
    fi
done

_UH_UINT='^(0|[1-9][0-9]*)$'

TARGET="/etc/uhm/tools/uhmalert.sh"
UNIT_PATH="/etc/systemd/system/uhmalert.service"
CONFIG_FILE="/etc/uhm/uhm.env"

# Appends $2 (one or more lines) right after the file's LAST
# "# ====...====" line, instead of a plain >> append -- so the new block
# always lands right after whatever content (from any project sharing this
# file: pydhcp, uhm, gateproxy, ...) is already there, never inside
# whichever one of them happens to be last. Falls back to a plain append if
# the file has no delimiter line at all (empty/malformed file).
insert_after_last_delimiter() {
    local file="$1" content="$2" last_line tmp
    last_line=$(grep -n '^# =\{5,\}$' "$file" | tail -1 | cut -d: -f1)
    if [[ -z "$last_line" ]]; then
        printf '\n%s\n' "$content" >> "$file"
        return
    fi
    tmp=$(mktemp)
    head -n "$last_line" "$file" > "$tmp"
    printf '\n%s\n' "$content" >> "$tmp"
    tail -n "+$((last_line + 1))" "$file" >> "$tmp"
    mv "$tmp" "$file"
}

install_module() {
    local gen_topic
    echo ""
    echo "=================================="
    echo "Installing uhmalert (uhm alert)"
    echo "=================================="
    echo ""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: $CONFIG_FILE not found -- install/configure uhmd.sh first"
        exit 1
    fi

    # Only append if not already configured -- never overwrite an existing
    # topic (e.g. on a re-install) or a threshold the user already tuned.
    if grep -q '^UHM_NTFY_TOPIC=' "$CONFIG_FILE"; then
        gen_topic=$(grep '^UHM_NTFY_TOPIC=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"')
        echo "UHM_NTFY_TOPIC already set in $CONFIG_FILE -- leaving it untouched."
    else
        gen_topic="uhm-alert-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
        insert_after_last_delimiter "$CONFIG_FILE" "# =============================================================================
# UHM ALERT
# =============================================================================
UHM_NTFY_TOPIC=\"$gen_topic\"
UHM_API_FAIL_THRESHOLD=3
UHM_ALERT_QUIET_PERIOD_SECONDS=120
# ============================================================================="
        echo "Added UHM_NTFY_TOPIC, UHM_API_FAIL_THRESHOLD and"
        echo "UHM_ALERT_QUIET_PERIOD_SECONDS to $CONFIG_FILE"
    fi
    # Insert right after their neighbor in the Alert block (not a plain
    # >> append) so upgrading an older install doesn't scatter these
    # variables to the end of the file, past unrelated later sections.
    if ! grep -q '^UHM_API_FAIL_THRESHOLD=' "$CONFIG_FILE"; then
        sed -i '/^UHM_NTFY_TOPIC=/a UHM_API_FAIL_THRESHOLD=3' "$CONFIG_FILE"
    fi
    if ! grep -q '^UHM_ALERT_QUIET_PERIOD_SECONDS=' "$CONFIG_FILE"; then
        sed -i '/^UHM_API_FAIL_THRESHOLD=/a UHM_ALERT_QUIET_PERIOD_SECONDS=120' "$CONFIG_FILE"
    fi

    SELF="$(readlink -f "$0")"
    if [[ "$SELF" != "$TARGET" ]]; then
        echo "Deploying script to $TARGET..."
        mkdir -p "$(dirname "$TARGET")"
        install -m 755 -o root -g root "$SELF" "$TARGET"
    fi

    echo "Writing systemd unit ($UNIT_PATH)..."
    cat > "$UNIT_PATH" <<'UNITEOF'
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
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    echo "uhmalert.service removed. The uhmalert.sh script was not deleted."
}

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
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "WARNING: script $(basename "$0") is already running"
    exit 1
fi

# -- Watch loop (default action -- this is what uhmalert.service runs) ------------
# No -e: this is a long-running watch loop, one bad line (e.g. an
# unparseable timestamp) must not kill the whole process.

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: $CONFIG_FILE not found -- abort"
    exit 1
fi
_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
_gdigit="${_perms: -2:1}"
_odigit="${_perms: -1}"
if [[ "$_owner" != "root" ]] || [[ "$_gdigit" != "0" ]] || [[ "$_odigit" != "0" ]]; then
    log "ERROR: uhm.env unsafe owner/perms, must be root-owned 600"
    exit 1
fi
# Load only known KEY=VALUE pairs instead of sourcing, so a tampered or
# maliciously replaced config file cannot execute code -- same approach as
# uhmleases.sh's load_env_file().
load_env_file() {
    local file="$1" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
            value="${value:1:$((${#value}-2))}"
        fi
        case "$key" in
            UHM_NTFY_TOPIC|UHM_API_FAIL_THRESHOLD|UHM_ALERT_QUIET_PERIOD_SECONDS|POLL_INTERVAL)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$CONFIG_FILE"

if [[ -z "${UHM_NTFY_TOPIC:-}" ]]; then
    log "ERROR: UHM_NTFY_TOPIC not set in $CONFIG_FILE -- abort"
    exit 1
fi

FAIL_THRESHOLD="${UHM_API_FAIL_THRESHOLD:-3}"
if ! [[ "$FAIL_THRESHOLD" =~ $_UH_UINT ]] || (( FAIL_THRESHOLD == 0 )); then
    log "WARNING: UHM_API_FAIL_THRESHOLD invalid -- fallback"
    FAIL_THRESHOLD=3
fi
POLL_INTERVAL="${POLL_INTERVAL:-20}"
if ! [[ "$POLL_INTERVAL" =~ $_UH_UINT ]] || (( POLL_INTERVAL == 0 )); then
    log "WARNING: POLL_INTERVAL invalid -- fallback"
    POLL_INTERVAL=20
fi
UHM_ALERT_QUIET_PERIOD="${UHM_ALERT_QUIET_PERIOD_SECONDS:-120}"
[[ "$UHM_ALERT_QUIET_PERIOD" =~ $_UH_UINT ]] || { log "WARNING: UHM_ALERT_QUIET_PERIOD_SECONDS invalid ($UHM_ALERT_QUIET_PERIOD)"; log "WARNING: using default 120"; UHM_ALERT_QUIET_PERIOD=120; }
MARGIN=10 # tolerance added to POLL_INTERVAL so minor cycle jitter doesn't
            # falsely look like a gap with a silent recovery in between
API_MAX_TIME=30 # matches curl --max-time in uhmd.sh's api_get calls
GAP_LIMIT=$(( POLL_INTERVAL + 3 * API_MAX_TIME + MARGIN ))
DEDUP_WINDOW=300 # suppress a repeated identical ERROR/WARNING catch-all
                  # alert if it fires again within this many seconds

streak=0
alerted=0
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
    local ts
    ts=$(systemctl show -p ActiveEnterTimestamp --value uhmd 2>/dev/null)
    date -d "$ts" +%s 2>/dev/null || echo 0
}

notify() {
    local msg="$1"
    curl -s -d "$msg" "https://ntfy.sh/${UHM_NTFY_TOPIC}" >/dev/null 2>&1 &
}

# Bash builtins only, no fork -- systemd's default KillMode=control-group
# sends TERM to this whole cgroup at once, so an external `date` (forked
# either by log()'s own timestamp prefix or by this line's message) can be
# killed before it prints anything, logging this line with an empty
# timestamp. printf's %()T is bash's own strftime, no subprocess involved.
_on_term() {
    printf -v _term_ts '%(%Y-%m-%d %H:%M:%S)T' -1
    echo "$_term_ts uhmalert done at: $_term_ts" | tee -a "$log_file" 2>/dev/null || true
    exit 0
}
trap _on_term TERM INT

# Start
log "uhmalert start..."

exec 3< <(tail -n0 -F "$log_file" 2>/dev/null)

while true; do
    if (( alerted == 1 && last_ts_epoch != 0 )); then
        _now_epoch=$(date +%s)
        if (( _now_epoch - last_ts_epoch >= GAP_LIMIT )); then
            if systemctl is-active --quiet uhmd; then
                notify "uhm: recovered -- no new failures in the last ${GAP_LIMIT}s"
                log "ALERT: recovery notice sent"
            else
                log "INFO: uhmd is not active -- suppressing recovery notice"
            fi
            streak=0
            alerted=0
        fi
    fi
    _read_rc=0
    IFS= read -r -t "$GAP_LIMIT" -u 3 line || _read_rc=$?
    if (( _read_rc == 0 )); then
        if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\  ]]; then
            msg="${line:20}"
        else
            msg="$line"
        fi

        # Known-benign -- expected/already handled, must never alert.
        [[ "$msg" == *"cycle lock held unexpectedly"* ]] && continue

        # Edge-triggered recovery: uhmd logs this once, exactly when
        # the backend transitions from failing to answering OK -- fires
        # the recovery notice immediately instead of waiting for GAP_LIMIT.
        if [[ "$msg" == "INFO: UniFi backend ready (voucher/guest/sta OK)" ]]; then
            if (( alerted == 1 )); then
                notify "uhm: recovered -- backend answering again"
                log "ALERT: recovery notice sent (backend ready)"
                streak=0
                alerted=0
            fi
            continue
        fi

        # Connectivity-loss lines are ERROR/WARNING too, but they are
        # handled by the streak counter below (waits for
        # UHM_API_FAIL_THRESHOLD consecutive cycles) rather than firing on the
        # first occurrence like the generic catch-all does.
        is_connectivity=0
        [[ "$msg" == *"Could not load vouchers"* ]] && is_connectivity=1
        [[ "$msg" == *"API GET"* ]] && is_connectivity=1
        [[ "$msg" == *"no response (timeout or network error)"* ]] && is_connectivity=1

        # Generic catch-all: any other ERROR/WARNING line, from
        # uhmd.sh or the uhmreload.sh/uhmleases.sh/uhmiptables.sh chain
        # (shared log) -- fires immediately, no streak needed. FIX: lines
        # come only from uhmwatch.sh (any of the services it manages) --
        # a successful recovery closing out an earlier WARNING/ERROR alert.
        if (( is_connectivity == 0 )) && { [[ "$msg" == ERROR:* ]] || [[ "$msg" == WARNING:* ]] || [[ "$msg" == FIX:* ]]; }; then
            _now_epoch=$(date +%s)
            if [[ "$msg" == "$last_generic_msg" ]] && (( _now_epoch - last_generic_time < DEDUP_WINDOW )); then
                log "INFO: dup alert suppressed (${DEDUP_WINDOW}s): ${msg:0:25}"
                continue
            fi
            last_generic_msg="$msg"
            last_generic_time="$_now_epoch"
            notify "uhm: $msg"
            log "ALERT: sent -- ${msg:0:45}"
            continue
        fi

        [[ "$msg" != *"Could not load vouchers"* ]] && continue

        ts="${line:0:19}"
        epoch=$(date -d "$ts" +%s 2>/dev/null) || continue

        # Gap since the last matching failure is bigger than one cycle
        # (plus margin) -- cycles succeeded silently in between, so this is
        # a fresh outage, not a continuation of the previous one.
        if (( last_ts_epoch != 0 )) && (( epoch - last_ts_epoch > GAP_LIMIT )); then
            streak=0
            alerted=0
        fi
        last_ts_epoch=$epoch
        streak=$(( streak + 1 ))

        if (( streak == FAIL_THRESHOLD )) && (( alerted == 0 )); then
            uhmd_start=$(uhmd_started_at)
            if (( uhmd_start > 0 )) && (( epoch - uhmd_start < UHM_ALERT_QUIET_PERIOD )); then
                log "INFO: $streak failures within startup grace, suppressed"
                streak=0
            else
                notify "uhm: $streak consecutive failed cycles reaching the controller (since $ts)"
                log "ALERT: sent -- $streak consecutive cycle failures"
                log "ALERT: latest at $ts"
                alerted=1
            fi
        fi
    elif (( _read_rc == 1 )); then
        log "ERROR: uhmalert lost log monitoring (tail died) -- abort"
        exit 1
    else
        # read timed out: no new line for a full GAP_LIMIT window. Recovery
        # (if any) was already evaluated by the pre-read check above; this
        # is just a safety-net reset.
        streak=0
        alerted=0
    fi
done
