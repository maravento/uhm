#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmwatch -- UniFi Hotspot Services Watchdog
#
# DESCRIPTION:
# Mandatory -- installed automatically by uhmsetup.sh, not offered as a
# yes/no prompt like uhmalert/uhmmon. Every unit it watches (uhmd,
# pydhcpd, the UniFi backend) already has its own systemd Restart=
# policy, but that alone gives up permanently once StartLimitBurst is
# exhausted, with no further attempt and no alert -- see the
# StartLimitBurst paragraph below. uhmwatch is the last line of defense
# against that: it runs every minute, independent of whatever state
# systemd itself gave up in, so uhm's essential services don't stay
# down indefinitely just because systemd stopped trying.
#
# Runs every minute via cron. Watches every service uhm depends on
# and restarts whichever one is down. Each restart is preceded by
# `systemctl reset-failed` -- each unit already has its own Restart=
# policy, so a persistent failure eventually exhausts its
# StartLimitBurst and systemd stops trying on its own, leaving the
# service down for good with no further notice. reset-failed clears
# that state so this watchdog's own restart attempt isn't silently
# rejected right when it's needed most. Each service check is fully
# independent -- one check's failure/fix never skips or blocks the others
# in the same run (unlike a naive watchdog that exits after the first fix).
#
# Checks performed, every run:
# 1. uhmd.service -- always.
# 2. uhmalert.service -- only if installed (optional component of uhm;
# silently skipped if its unit file isn't present).
# 3. pydhcpd.service -- always. External dependency (separate project),
# not part of uhm's own codebase, same reasoning as watching the UniFi
# backend below: pydhcpd's own Restart=on-failure eventually exhausts
# its StartLimitBurst and gives up silently (see pydhcp's own README),
# with no alerting of its own -- uhmd cannot function without it, so it
# gets the same treatment as uhmd.service itself. is-active only, no
# functional check (pydhcpd exposes no HTTP API to probe like UniFi does).
# 4. UniFi backend -- branches on UNIFI_TYPE from uhm.env. Both branches
# first require systemctl is-active (start it if not), then run a
# functional check: a real login against the API (same mechanism
# uhmd.sh itself uses -- credentials via jq env, payload via curl
# stdin, never in argv), using UNIFI_USERNAME/UNIFI_PASSWORD from
# uhm.env. HTTP 200 = healthy. HTTP 000 or 5xx = unresponsive,
# restarts the service. Any 4xx = credentials rejected but the service
# itself is up and answering -- logged as a warning, no restart (a
# restart wouldn't fix a wrong password in uhm.env anyway).
# If those credentials are not set in uhm.env, falls back to a
# process/port-only check instead of skipping the check entirely.
# - "unifi-os": uosserver.service. UOS Server is an all-in-one container
# that bundles its own MongoDB internally -- no host-level mongod.service
# is part of this architecture. A broken internal Mongo is exactly the
# failure mode the login check catches that a plain process check
# cannot. A standalone mongod.service found running alongside UOS
# Server is very likely a leftover from a previous classic install and
# is not monitored here.
# - "classic": unifi.service. Ships with UNIFI_MONGODB_SERVICE_ENABLED=false
# by default, so it manages its own embedded MongoDB subprocess
# (127.0.0.1:27117) end-to-end, including its own shutdown logic -- the
# mongodb-org-server package's own mongod.service unit is never started
# and its data directory stays empty. Same all-in-one shape as unifi-os
# above, so restarting unifi.service already covers a Mongo failure
# too. Credentials-absent fallback checks ports 8443/8080 instead.
#
# Standalone -- never reads or modifies uhmd.sh, only manages services
# via systemctl. Independent of the user's own system-wide service
# watchdog (if any); this one only knows about uhm's own dependencies.
#
# USAGE:
# sudo ./uhmwatch.sh install Deploy to /etc/uhm/core/uhmwatch.sh,
# register cron entry (* * * * *)
# sudo ./uhmwatch.sh uninstall Remove the cron entry
# uhmwatch.sh Run the checks directly (what cron invokes)
# uhmwatch.sh -h, --help Show this help
#
# CONFIG: /etc/uhm/uhm.env (reads UNIFI_TYPE, UNIFI_CONTROLLER_URL,
# UNIFI_USERNAME, UNIFI_PASSWORD)
# LOG: /var/log/uhm.log (shared with the rest of uhm). Silent on
# a healthy run -- nothing is written unless a check finds a problem
# or takes a fix action (WARNING/FIX/ERROR only).
#
################################################################################

set -uo pipefail

# PATH for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "Script $(basename "$0") is already running"
    exit 1
fi

# DEPENDENCIES
for dep in curl jq iproute2 cron coreutils util-linux; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency '$dep' is not installed."
        exit 1
    fi
done

TARGET="/etc/uhm/core/uhmwatch.sh"
# Pre-restructure location -- uhmwatch.sh lived under tools/ before it
# became mandatory. install_module() migrates a crontab entry still
# pointing there instead of leaving it stale (see below).
LEGACY_TARGET="/etc/uhm/tools/uhmwatch.sh"

install_module() {
    echo ""
    echo "==========================================="
    echo "Installing uhmwatch (uhm services watchdog)"
    echo "==========================================="
    echo ""

    SELF="$(readlink -f "$0")"
    if [[ "$SELF" != "$TARGET" ]]; then
        echo "Deploying script to $TARGET..."
        mkdir -p "$(dirname "$TARGET")"
        install -m 755 -o root -g root "$SELF" "$TARGET"
    fi

    local cron_entry="* * * * * $TARGET"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if echo "$current" | grep -qF "$LEGACY_TARGET"; then
        current=$(echo "$current" | grep -vF "$LEGACY_TARGET")
        crontab - <<< "$current"
        echo "Removed stale cron entry pointing to legacy path $LEGACY_TARGET"
    fi
    if echo "$current" | grep -vE '^\s*#' | grep -qF "$TARGET"; then
        echo "Cron entry already present -- leaving it untouched."
    else
        { printf '%s\n%s\n' "$current" "$cron_entry"; } | crontab -
        echo "Cron entry registered: $cron_entry"
    fi
    rm -f "$LEGACY_TARGET"

    echo ""
    echo "Installed. First run happens on the next minute mark."
    echo "Check the log with: tail -f $log_file"
    echo ""
}

uninstall_module() {
    echo "Removing uhmwatch cron entry..."
    if crontab -l 2>/dev/null | grep -qF -e "$TARGET" -e "$LEGACY_TARGET"; then
        crontab -l 2>/dev/null | grep -vF -e "$TARGET" -e "$LEGACY_TARGET" | crontab -
        echo "Cron entry removed. $TARGET was left in place --"
        echo "delete it manually if desired."
    else
        echo "No cron entry found for $TARGET."
    fi
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

# -- Checks (default action -- this is what cron runs) --------------------------

# Load UNIFI_TYPE from uhm.env. Safe key=value parsing - file is never
# sourced to prevent code execution.
_UHM_CONF="/etc/uhm/uhm.env"
_load_conf() {
    local file="$1" line key value
    [[ ! -f "$file" ]] && { log "WARNING: $file not found - using built-in defaults"; return 1; }
    local _owner _perms _gdigit _odigit
    _owner=$(stat -c '%U' "$file" 2>/dev/null)
    _perms=$(stat -c '%a' "$file" 2>/dev/null)
    _gdigit="${_perms: -2:1}"
    _odigit="${_perms: -1}"
    if [[ "$_owner" != "root" ]] || [[ "$_gdigit" != "0" ]] || [[ "$_odigit" != "0" ]]; then
        log "WARNING: uhm.env owner/perms unsafe ($_owner/$_perms)"
        log "WARNING: must be root:600 -- using built-in defaults"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*[#] ]] && continue
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
            UNIFI_TYPE|UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_CERT_PIN|RECOVERY_COOLDOWN_SECONDS)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}
_load_conf "$_UHM_CONF"
UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"
_UH_UINT='^(0|[1-9][0-9]*)$'
RECOVERY_COOLDOWN_SECONDS="${RECOVERY_COOLDOWN_SECONDS:-600}"
[[ "$RECOVERY_COOLDOWN_SECONDS" =~ $_UH_UINT ]] || { log "WARNING: RECOVERY_COOLDOWN_SECONDS invalid -- default 600"; RECOVERY_COOLDOWN_SECONDS=600; }
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:11443}"
else
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:8443}"
fi

check_uhmd() {
    if systemctl is-active --quiet uhmd.service; then
        _clear_recovery_attempt "uhmd.service"
    else
        log "WARNING: uhmd OFFLINE"
        if _recovery_on_cooldown "uhmd.service"; then
            log "INFO: uhmd recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "uhmd.service"
        systemctl reset-failed uhmd.service 2>/dev/null || true
        if systemctl restart uhmd.service; then
            log "FIX: uhmd restarted"
            _clear_recovery_attempt "uhmd.service"
        else
            log "ERROR: uhmd restart FAILED"
        fi
    fi
}

check_ualert() {
    # Optional component -- if it was never installed, there's nothing to
    # watch and nothing to fix. Not a failure, just skip silently.
    if [[ ! -f /etc/systemd/system/uhmalert.service ]]; then
        return
    fi
    if systemctl is-active --quiet uhmalert.service; then
        _clear_recovery_attempt "uhmalert.service"
    else
        log "WARNING: uhmalert OFFLINE"
        if _recovery_on_cooldown "uhmalert.service"; then
            log "INFO: uhmalert recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "uhmalert.service"
        systemctl reset-failed uhmalert.service 2>/dev/null || true
        if systemctl restart uhmalert.service; then
            log "FIX: uhmalert restarted"
            _clear_recovery_attempt "uhmalert.service"
        else
            log "ERROR: uhmalert restart FAILED"
        fi
    fi
}

check_pydhcpd() {
    # pydhcp is a separate project uhm depends on for DHCP -- same reasoning
    # as watching the UniFi backend below: an external dependency this host
    # can't function without, but that pydhcp's own systemd unit alone
    # cannot fully self-heal (see pydhcp's README -- systemd gives up after
    # its own StartLimitBurst and has no alerting of its own). No functional
    # check here (pydhcpd exposes no HTTP API to probe like UniFi does) --
    # is-active is the only signal available, same shape as check_uhmd above.
    if systemctl is-active --quiet pydhcpd.service; then
        _clear_recovery_attempt "pydhcpd.service"
    else
        log "WARNING: pydhcpd OFFLINE"
        if _recovery_on_cooldown "pydhcpd.service"; then
            log "INFO: pydhcpd recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "pydhcpd.service"
        systemctl reset-failed pydhcpd.service 2>/dev/null || true
        if systemctl restart pydhcpd.service; then
            log "FIX: pydhcpd restarted"
            _clear_recovery_attempt "pydhcpd.service"
        else
            log "ERROR: pydhcpd restart FAILED"
        fi
    fi
}

# Returns 0 (true) if <service> became active less than RESTART_GRACE_SECONDS
# ago -- gives it time to actually finish booting (UOS Server/UniFi Network
# can take a couple of minutes) before the next cron tick (every min)
# restarts it again mid-boot, which would otherwise never let it converge.
RESTART_GRACE_SECONDS=180
_recently_restarted() {
    local svc="$1" active_since elapsed
    active_since=$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null)
    [[ -z "$active_since" ]] && return 1
    elapsed=$(( $(date +%s) - $(date -d "$active_since" +%s 2>/dev/null || echo 0) ))
    (( elapsed < RESTART_GRACE_SECONDS ))
}

# Recovery cooldown: distinct from _recently_restarted above, which only
# tracks a *successful* start. This tracks the last recovery *attempt*
# (reset-failed + restart) regardless of outcome, so a persistently broken
# service (controller down, credentials wrong, etc.) isn't hammered with a
# restart every single minute -- each unit's own StartLimitBurst would
# otherwise get reset-failed straight through by this watchdog, effectively
# disabling systemd's own circuit breaker. State lives under /run (tmpfs),
# so a reboot naturally clears any stale cooldowns.
RECOVERY_STATE_DIR="/run/uhmwatch"
_recovery_on_cooldown() {
    local svc="$1"
    local state_file="${RECOVERY_STATE_DIR}/${svc}.attempted_at" last now
    [[ -f "$state_file" ]] || return 1
    last=$(cat "$state_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    (( (now - last) < RECOVERY_COOLDOWN_SECONDS ))
}

_mark_recovery_attempt() {
    mkdir -p "$RECOVERY_STATE_DIR"
    date +%s > "${RECOVERY_STATE_DIR}/${1}.attempted_at"
}

# Called once a service is confirmed healthy again -- without this, the
# cooldown from a resolved incident would still throttle a genuinely new,
# unrelated failure that happens to occur within RECOVERY_COOLDOWN_SECONDS
# of the earlier (already-fixed) one.
_clear_recovery_attempt() {
    rm -f "${RECOVERY_STATE_DIR}/${1}.attempted_at" 2>/dev/null || true
}

check_uosserver() {
    # All-in-one container -- its internal MongoDB is bundled and managed by
    # the container itself, never a host-level service. Do not check/restart
    # any standalone mongod.service here; it is not part of this
    # architecture, and restarting uosserver.service would not fix an
    # unrelated host-level Mongo issue.
    if ! systemctl is-active --quiet uosserver.service; then
        log "WARNING: UOS OFFLINE"
        if _recovery_on_cooldown "uosserver.service"; then
            log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "uosserver.service"
        systemctl reset-failed uosserver.service 2>/dev/null || true
        if systemctl start uosserver.service; then
            log "FIX: uosserver started"
            _clear_recovery_attempt "uosserver.service"
        else
            log "ERROR: uosserver start FAILED"
        fi
        return
    fi

    # Functional check: systemctl is-active only proves the unit/process is
    # up, not that the app itself is healthy -- the container's embedded
    # MongoDB can fail to come up while the process keeps running, leaving
    # every real API call broken (a login attempt hangs or errors even though
    # systemctl sees it as fine). A real login is the same proof uhmd.sh
    # itself relies on. Username/password go via jq env (not --arg) and the
    # payload via curl stdin (not -d), so neither ever appears in this
    # process's argv (/proc/<pid>/cmdline).
    if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
        log "WARNING: UNIFI_USERNAME/UNIFI_PASSWORD not set"
        log "Skipping functional login check"
        # Fall back to a port check so this isn't a total no-op.
        if ! ss -lnt | grep -qE ':11443\b'; then
            log "WARNING: UOS BROKEN_PORTS"
            if _recently_restarted "uosserver.service"; then
                log "INFO: uosserver restarted recently -- skip (grace)"
                return
            fi
            if _recovery_on_cooldown "uosserver.service"; then
                log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
                return
            fi
            _mark_recovery_attempt "uosserver.service"
            systemctl reset-failed uosserver.service 2>/dev/null || true
            if systemctl restart uosserver.service; then
                log "FIX: uosserver restarted"
                _clear_recovery_attempt "uosserver.service"
            else
                log "ERROR: uosserver restart FAILED"
            fi
        else
            _clear_recovery_attempt "uosserver.service"
        fi
        return
    fi

    local login_url payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${_tls_opts[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        _clear_recovery_attempt "uosserver.service"
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if _recently_restarted "uosserver.service"; then
            log "INFO: uosserver restarted recently -- skip (grace)"
            return
        fi
        if _recovery_on_cooldown "uosserver.service"; then
            log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "uosserver.service"
        systemctl reset-failed uosserver.service 2>/dev/null || true
        if systemctl restart uosserver.service; then
            log "FIX: uosserver restarted (login failed)"
            _clear_recovery_attempt "uosserver.service"
        else
            log "ERROR: uosserver restart FAILED"
        fi
    elif [[ "$http_code" == "429" ]]; then
        log "WARNING: rate limited (HTTP 429), not a credentials issue"
        log "Stop uhmd+uhmwatch cron before restarting (see README)"
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "Check uhm.env - UOS itself is responding"
    fi
}

check_unifi_classic() {
    if ! systemctl is-active --quiet unifi.service; then
        log "WARNING: UniFi (classic) OFFLINE"
        if _recovery_on_cooldown "unifi.service"; then
            log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "unifi.service"
        systemctl reset-failed unifi.service 2>/dev/null || true
        if systemctl start unifi.service; then
            log "FIX: unifi started"
            _clear_recovery_attempt "unifi.service"
        else
            log "ERROR: unifi.service start FAILED"
        fi
        return
    fi

    # Functional check: same reasoning as check_uosserver() -- systemctl
    # is-active only proves the process is up, not that the app (and its
    # embedded Mongo subprocess, see header) is actually healthy. Same login
    # mechanism as uhmd.sh, but against the classic endpoint (/api/login).
    if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
        log "WARNING: UNIFI_USERNAME/UNIFI_PASSWORD not set"
        log "Skipping functional login check"
        # Fall back to a port check so this isn't a total no-op.
        if ! ss -lnt | grep -qE ':(8443|8080)\b'; then
            log "WARNING: UniFi (classic) BROKEN_PORTS"
            if _recently_restarted "unifi.service"; then
                log "INFO: unifi restarted recently -- skip (grace)"
                return
            fi
            if _recovery_on_cooldown "unifi.service"; then
                log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
                return
            fi
            _mark_recovery_attempt "unifi.service"
            systemctl reset-failed unifi.service 2>/dev/null || true
            if systemctl restart unifi.service; then
                log "FIX: unifi restarted"
                _clear_recovery_attempt "unifi.service"
            else
                log "ERROR: unifi.service restart FAILED"
            fi
        else
            _clear_recovery_attempt "unifi.service"
        fi
        return
    fi

    local login_url payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/login"
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${_tls_opts[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        _clear_recovery_attempt "unifi.service"
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if _recently_restarted "unifi.service"; then
            log "INFO: unifi restarted recently -- skip (grace)"
            return
        fi
        if _recovery_on_cooldown "unifi.service"; then
            log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        _mark_recovery_attempt "unifi.service"
        systemctl reset-failed unifi.service 2>/dev/null || true
        if systemctl restart unifi.service; then
            log "FIX: unifi restarted (login failed)"
            _clear_recovery_attempt "unifi.service"
        else
            log "ERROR: unifi.service restart FAILED"
        fi
    elif [[ "$http_code" == "429" ]]; then
        log "WARNING: rate limited (HTTP 429), not a credentials issue"
        log "Stop uhmd+uhmwatch cron before restarting (see README)"
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "Check uhm.env - unifi.service is responding"
    fi
}

check_uhmd
check_ualert
check_pydhcpd
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    check_uosserver
else
    # No separate Mongo check -- unifi.service ships with
    # UNIFI_MONGODB_SERVICE_ENABLED=false by default, so it manages its own
    # embedded MongoDB subprocess (127.0.0.1:27117) end-to-end, same as
    # uosserver above. check_unifi_classic already covers it.
    check_unifi_classic
fi
