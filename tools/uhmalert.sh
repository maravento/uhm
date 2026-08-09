#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmalert -- UniFi Hotspot Alert Watcher (optional)
#
# DESCRIPTION:
# Watches /var/log/uhm.log in real time and sends a push
# notification via ntfy.sh on two kinds of events:
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
# API_FAIL_THRESHOLD consecutive cycles fail, and again once recovered
# (same GAP_LIMIT is the read timeout used to detect recovery -- see
# watch loop below).
# Suppressed while uhmd.service has been active for less than
# UALERT_QUIET_PERIOD_SECONDS (default 120s) -- UniFi Network/UniFi OS can
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
# Standalone -- never reads or modifies uhmd.sh, only tails its log
# file. Runs as its own systemd service (uhmalert.service), independent of
# uhmd, so the daemon stays byte-identical to upstream. Optional:
# uhmd.sh runs fine with or without uhmalert installed.
#
# DEPENDENCIES:
# - bash, curl, GNU coreutils (date -d, tail -F) -- standard on Ubuntu/Debian
# - systemd (systemctl) -- only needed for `install`/`uninstall`
# - uhmd.sh already installed and running (this reads its log; it
# does not start or manage the daemon itself)
# - An ntfy.sh account is not required. Install the free "ntfy" app
# (Android/iOS) and subscribe to a topic name of your choice -- treat
# the topic name as a shared secret, since anyone who knows it can
# publish to it. https://ntfy.sh
#
# CONFIGURATION:
# `install` appends NTFY_TOPIC (auto-generated, unpredictable),
# API_FAIL_THRESHOLD=3 and UALERT_QUIET_PERIOD_SECONDS=120 to
# /etc/uhm/uhm.env on first run, and prints the generated
# topic name so you can subscribe the ntfy app to it. Never overwrites
# any of them if already present (safe to re-run/upgrade).
# To change them later, edit uhm.env directly and restart the
# service: systemctl restart uhmalert
# POLL_INTERVAL is read from the same file (falls back to 20 if unset),
# matching uhmd.sh's own cycle interval.
#
# USAGE:
# sudo ./uhmalert.sh install Deploy to /etc/uhm/tools/uhmalert.sh,
# create+enable+start uhmalert.service
# (creates the systemd unit if missing)
# sudo ./uhmalert.sh uninstall Stop+disable the service, remove the unit
# uhmalert.sh Run the watch loop directly (this is what
# uhmalert.service's ExecStart invokes)
# uhmalert.sh -h, --help Show this help
#
# CONFIG: /etc/uhm/uhm.env (reads NTFY_TOPIC, API_FAIL_THRESHOLD, UALERT_QUIET_PERIOD_SECONDS, POLL_INTERVAL)
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
for dep in curl mawk coreutils util-linux; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency '$dep' is not installed."
        exit 1
    fi
done

_UH_UINT='^(0|[1-9][0-9]*)$'

TARGET="/etc/uhm/tools/uhmalert.sh"
UNIT_PATH="/etc/systemd/system/uhmalert.service"
CONFIG_FILE="/etc/uhm/uhm.env"

# Inserts $2 (one or more lines) right before the file's last closing
# "# ====...====" delimiter, instead of a plain >> append -- keeps the block
# inside the UHM frame instead of scattering variables past it. Falls
# back to a plain append if no delimiter line is found (older file).
insert_before_closing_delimiter() {
    local file="$1" content="$2" last_line tmp
    last_line=$(grep -n '^# =\{5,\}$' "$file" | tail -1 | cut -d: -f1)
    if [[ -z "$last_line" ]]; then
        printf '%s\n' "$content" >> "$file"
        return
    fi
    tmp=$(mktemp)
    head -n "$((last_line - 1))" "$file" > "$tmp"
    printf '%s\n' "$content" >> "$tmp"
    tail -n "+${last_line}" "$file" >> "$tmp"
    mv "$tmp" "$file"
}

install_module() {
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
    if grep -q '^NTFY_TOPIC=' "$CONFIG_FILE"; then
        gen_topic=$(grep '^NTFY_TOPIC=' "$CONFIG_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"')
        echo "NTFY_TOPIC already set in $CONFIG_FILE -- leaving it untouched."
    else
        gen_topic="uhm-alert-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
        insert_before_closing_delimiter "$CONFIG_FILE" "# -- Alert --------------------------------------------------------------------
NTFY_TOPIC=\"$gen_topic\"
API_FAIL_THRESHOLD=3
UALERT_QUIET_PERIOD_SECONDS=120"
        echo "Added NTFY_TOPIC, API_FAIL_THRESHOLD and"
        echo "UALERT_QUIET_PERIOD_SECONDS to $CONFIG_FILE"
    fi
    # Insert right after their neighbor in the Alert block (not a plain
    # >> append) so upgrading an older install doesn't scatter these
    # variables to the end of the file, past unrelated later sections.
    if ! grep -q '^API_FAIL_THRESHOLD=' "$CONFIG_FILE"; then
        sed -i '/^NTFY_TOPIC=/a API_FAIL_THRESHOLD=3' "$CONFIG_FILE"
    fi
    if ! grep -q '^UALERT_QUIET_PERIOD_SECONDS=' "$CONFIG_FILE"; then
        sed -i '/^API_FAIL_THRESHOLD=/a UALERT_QUIET_PERIOD_SECONDS=120' "$CONFIG_FILE"
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
    echo "uhmalert.service removed. $TARGET was left in place --"
        echo "delete it manually if desired."
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
    log "Script $(basename "$0") is already running"
    exit 1
fi

# -- Watch loop (default action -- this is what uhmalert.service runs) ------------
# No -e: this is a long-running watch loop, one bad line (e.g. an
# unparseable timestamp) must not kill the whole process.

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: $CONFIG_FILE not found -- aborting"
    exit 1
fi
_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
_gdigit="${_perms: -2:1}"
_odigit="${_perms: -1}"
if [[ "$_owner" != "root" ]] || [[ "$_gdigit" != "0" ]] || [[ "$_odigit" != "0" ]]; then
    log "ERROR: $CONFIG_FILE has unsafe owner/permissions"
    log "  (owner=$_owner perms=$_perms)"
    log "ERROR: must be owned by root with no group/other access"
    log "  (600)"
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
            NTFY_TOPIC|API_FAIL_THRESHOLD|UALERT_QUIET_PERIOD_SECONDS|POLL_INTERVAL)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$CONFIG_FILE"

if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "ERROR: NTFY_TOPIC not set in $CONFIG_FILE -- aborting"
    exit 1
fi

FAIL_THRESHOLD="${API_FAIL_THRESHOLD:-3}"
[[ "$FAIL_THRESHOLD" =~ $_UH_UINT ]] || { log "WARNING: API_FAIL_THRESHOLD invalid ($FAIL_THRESHOLD) -- using default 3"; FAIL_THRESHOLD=3; }
POLL_INTERVAL="${POLL_INTERVAL:-20}"
[[ "$POLL_INTERVAL" =~ $_UH_UINT ]] || { log "WARNING: POLL_INTERVAL invalid ($POLL_INTERVAL) -- using default 20"; POLL_INTERVAL=20; }
UALERT_QUIET_PERIOD="${UALERT_QUIET_PERIOD_SECONDS:-120}"
[[ "$UALERT_QUIET_PERIOD" =~ $_UH_UINT ]] || { log "WARNING: UALERT_QUIET_PERIOD_SECONDS invalid ($UALERT_QUIET_PERIOD) -- using default 120"; UALERT_QUIET_PERIOD=120; }
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
    curl -s -d "$msg" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 &
}

trap 'log "uhmalert done at: $(date)"; exit 0' TERM INT

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
        # API_FAIL_THRESHOLD consecutive cycles) rather than firing on the
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
                log "INFO: suppressing repeated alert"
                log "  (same message within ${DEDUP_WINDOW}s) -- $msg"
                continue
            fi
            last_generic_msg="$msg"
            last_generic_time="$_now_epoch"
            notify "uhm: $msg"
            log "ALERT: sent -- $msg"
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
            if (( uhmd_start > 0 )) && (( epoch - uhmd_start < UALERT_QUIET_PERIOD )); then
                log "INFO: $streak consecutive failures within uhmd startup grace"
            log "  window (${UALERT_QUIET_PERIOD}s)"
                log "INFO: suppressing alert"
                streak=0
            else
                notify "uhm: $streak consecutive failed cycles reaching the controller (since $ts)"
                log "ALERT: sent -- $streak consecutive cycle failures"
            log "  latest at $ts"
                alerted=1
            fi
        fi
    elif (( _read_rc == 1 )); then
        log "ERROR: tail process on log_file died (EOF on fd 3)"
        log "ERROR: exiting for systemd to restart"
        exit 1
    else
        # read timed out: no new line for a full GAP_LIMIT window. Recovery
        # (if any) was already evaluated by the pre-read check above; this
        # is just a safety-net reset.
        streak=0
        alerted=0
    fi
done
