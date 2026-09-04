#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmwatch -- UniFi Hotspot Services Watchdog
#
# DESCRIPTION:
# Mandatory -- installed automatically, not offered as a
# yes/no prompt like uhmalert/uhmwebmin. Every unit it watches (uhmd,
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
#    silently skipped if its unit file isn't present).
# 3. pydhcpd.service -- always. External dependency (separate project),
#    not part of uhm's own codebase, same reasoning as watching the UniFi
#    backend below: pydhcpd's own Restart=on-failure eventually exhausts
#    its StartLimitBurst and gives up silently (see pydhcp's own README),
#    with no alerting of its own -- uhmd cannot function without it, so it
#    gets the same treatment as uhmd.service itself. is-active only, no
#    functional check (pydhcpd exposes no HTTP API to probe like UniFi does).
#    Skipped (not restarted) if uhmleases.sh currently holds cycle_lock --
#    it stops/reconfigures/starts pydhcpd itself as part of a normal reload
#    (~1-3s), and a cron tick landing in that window would otherwise "fix"
#    a service that isn't actually broken, colliding with uhmleases.sh's own
#    pending restart and aborting that reload.
# 4. UniFi backend -- branches on UNIFI_TYPE from uhm.env. Both branches
#    first require systemctl is-active (start it if not), then run a
#    functional check: a real login against the API (same mechanism
#    uhmd.sh itself uses -- credentials via jq env, payload via curl
#    stdin, never in argv), using UNIFI_USERNAME/UNIFI_PASSWORD from
#    uhm.env. HTTP 200 = healthy. HTTP 000 or 5xx = unresponsive,
#    restarts the service -- except within STARTUP_GRACE_SECONDS of
#    uhmd.service's own start (same margin and same config key uhmd.sh
#    uses for its own login retries): logged as INFO instead of WARNING,
#    no restart attempted, since the controller is expected to still be
#    booting after a reboot. Any 4xx = credentials rejected but the service
#    itself is up and answering -- logged as a warning, no restart (a
#    restart wouldn't fix a wrong password in uhm.env anyway).
# If those credentials are not set in uhm.env, falls back to a
# process/port-only check instead of skipping the check entirely.
# - "unifi-os": uosserver.service. UOS Server is an all-in-one container
#   that bundles its own MongoDB internally -- no host-level mongod.service
#   is part of this architecture. A broken internal Mongo is exactly the
#   failure mode the login check catches that a plain process check
#   cannot. A standalone mongod.service found running alongside UOS
# Server is very likely a leftover from a previous classic install and
# is not monitored here.
# - "classic": unifi.service. Ships with UNIFI_MONGODB_SERVICE_ENABLED=false
#   by default, so it manages its own embedded MongoDB subprocess
#   (127.0.0.1:27117) end-to-end, including its own shutdown logic -- the
#   mongodb-org-server package's own mongod.service unit is never started
#   and its data directory stays empty. Same all-in-one shape as unifi-os
#   above, so restarting unifi.service already covers a Mongo failure
#   too. Credentials-absent fallback checks ports 8443/8080 instead.
#
# Standalone -- never reads or modifies uhmd.sh, only manages services
# via systemctl. Independent of the user's own system-wide service
# watchdog (if any); this one only knows about uhm's own dependencies.
#
# USAGE:
# sudo ./uhmwatch.sh install     Deploy the script and register its cron
#                                entry (* * * * *)
# sudo ./uhmwatch.sh uninstall   Remove the cron entry
# uhmwatch.sh                    Run the checks directly (what cron invokes)
# uhmwatch.sh -h, --help         Show this help
#
# CONFIG: /etc/uhm/uhm.env (reads UNIFI_TYPE, UNIFI_CONTROLLER_URL,
#         UNIFI_USERNAME, UNIFI_PASSWORD, UNIFI_CERT_PIN,
#         RECOVERY_COOLDOWN_SECONDS, STARTUP_GRACE_SECONDS)
#
# LOG: /var/log/uhm.log (shared with the rest of uhm). Silent on a healthy
#      run -- nothing is written unless a check finds a problem or takes a
#      fix action.
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

# path for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# uhmd.sh/uhmleases.sh hold this same lock (cycle_lock in uhmd.sh) for the
# ~1-3s a reload actively stops/reconfigures/starts pydhcpd -- a real,
# expected gap, not a failure. Without this check, a cron tick landing in
# that narrow window sees pydhcpd not-yet-restarted, restarts it itself, and
# collides with uhmleases.sh's own pending `systemctl start pydhcpd`,
# aborting that reload (uhmleases.sh exits 1). fd 250 is used only for this
# instantaneous non-blocking probe -- always released right after, opened
# fresh on every call so it never competes with script_lock (fd 200) above.
uhm_cycle_lock="/var/lock/uhmd-cycle.lock"
uhm_reload_in_progress() {
    [[ -e "$uhm_cycle_lock" ]] || return 1
    exec 250>"$uhm_cycle_lock" 2>/dev/null || return 1
    if flock -n 250; then
        flock -u 250
        exec 250>&-
        return 1
    fi
    exec 250>&-
    return 0
}

# dependencies
for dep_pkg in curl jq mawk coreutils util-linux cron grep sed systemd iproute2; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

target_path="/etc/uhm/core/uhmwatch.sh"
# Pre-restructure location -- uhmwatch.sh lived under tools/ before it
# became mandatory. install_module() migrates a crontab entry still
# pointing there instead of leaving it stale (see below).
legacy_target_path="/etc/uhm/tools/uhmwatch.sh"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

install_module() {
    echo ""
    echo "==========================================="
    echo "Installing uhmwatch (uhm services watchdog)"
    echo "==========================================="
    echo ""

    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$target_path" ]]; then
        echo "Deploying script to $target_path..."
        mkdir -p "$(dirname "$target_path")"
        install -m 755 -o root -g root "$self_path" "$target_path"
    fi

    local cron_entry="* * * * * $target_path"
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)
    if echo "$current_crontab" | grep -qF "$legacy_target_path"; then
        current_crontab=$(echo "$current_crontab" | grep -vF "$legacy_target_path")
        crontab - <<< "$current_crontab"
        echo "Removed stale cron entry pointing to legacy path $legacy_target_path"
    fi
    if echo "$current_crontab" | grep -vE '^\s*#' | grep -qF "$target_path"; then
        echo "Cron entry already present -- leaving it untouched."
    else
        { printf '%s\n%s\n' "$current_crontab" "$cron_entry"; } | crontab -
        echo "Cron entry registered: $cron_entry"
    fi
    rm -f "$legacy_target_path"

    echo ""
    echo "Installed. First run happens on the next minute mark."
    echo "Check the log with: tail -f $log_file"
    echo ""
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

uninstall_module() {
    echo "Removing uhmwatch cron entry..."
    if crontab -l 2>/dev/null | grep -qF -e "$target_path" -e "$legacy_target_path"; then
        crontab -l 2>/dev/null | grep -vF -e "$target_path" -e "$legacy_target_path" | crontab -
        echo "Cron entry removed. The uhmwatch.sh script was not deleted."
    else
        echo "No cron entry found for $target_path."
    fi
}

# ------------------------------------------------------------------------------
# ACTIONS
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

# ------------------------------------------------------------------------------
# CHECKS
# ------------------------------------------------------------------------------

# Load UNIFI_TYPE from uhm.env. Safe key=value parsing - file is never
# sourced to prevent code execution.
uhm_conf="/etc/uhm/uhm.env"
load_conf() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
    [[ ! -f "$conf_file" ]] && { log "WARNING: uhm.env not found -- fallback"; return 1; }
    local file_owner file_perms
    file_owner=$(stat -c '%U' "$conf_file" 2>/dev/null)
    file_perms=$(stat -c '%a' "$conf_file" 2>/dev/null)
    if [[ "$file_owner" != "root" ]] || [[ "$file_perms" != "600" ]]; then
        if chown root:root "$conf_file" 2>/dev/null && chmod 600 "$conf_file" 2>/dev/null; then
            log "WARNING: uhm.env perms fixed -- alert"
        else
            log "ERROR: cannot fix uhm.env perms -- abort"
            return 1
        fi
    fi
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ "$env_line" =~ ^[[:space:]]*[#] ]] && continue
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
            UNIFI_TYPE|UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_CERT_PIN|RECOVERY_COOLDOWN_SECONDS|STARTUP_GRACE_SECONDS)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}
load_conf "$uhm_conf"
UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"
UH_UINT='^(0|[1-9][0-9]*)$'
RECOVERY_COOLDOWN_SECONDS="${RECOVERY_COOLDOWN_SECONDS:-600}"
if ! [[ "$RECOVERY_COOLDOWN_SECONDS" =~ $UH_UINT ]] || (( RECOVERY_COOLDOWN_SECONDS <= 60 )); then
    log "WARNING: RECOVERY_COOLDOWN_SECONDS invalid -- fallback"
    RECOVERY_COOLDOWN_SECONDS=600
fi
# Same key uhmd.sh reads for its own startup-grace login retries -- reused
# here so the two share one margin instead of drifting apart. Without this,
# uhmd.sh stays quiet while UniFi is still booting after a reboot, but this
# script's own functional login check (below) had no such exemption and
# alerted anyway for the exact same, already-expected condition.
STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-120}"
if ! [[ "$STARTUP_GRACE_SECONDS" =~ $UH_UINT ]]; then
    log "WARNING: STARTUP_GRACE_SECONDS invalid -- fallback"
    STARTUP_GRACE_SECONDS=120
fi

# Time since uhmd.service itself became active -- same reasoning and same
# config key as uhmalert.sh's own uhmd_started_at().
uhmd_started_at() {
    local started_ts
    started_ts=$(systemctl show -p ActiveEnterTimestamp --value uhmd 2>/dev/null)
    date -d "$started_ts" +%s 2>/dev/null || echo 0
}
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:11443}"
else
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:8443}"
fi

check_uhmd() {
    if systemctl is-active --quiet uhmd.service; then
        clear_recovery_attempt "uhmd.service"
    else
        log "WARNING: uhmd OFFLINE"
        if recovery_on_cooldown "uhmd.service"; then
            log "INFO: uhmd recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "uhmd.service"
        systemctl reset-failed uhmd.service 2>/dev/null || true
        if systemctl restart uhmd.service; then
            log "FIX: uhmd restarted"
            clear_recovery_attempt "uhmd.service"
        else
            log "WARNING: uhmd restart FAILED -- alert"
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
        clear_recovery_attempt "uhmalert.service"
    else
        log "WARNING: uhmalert OFFLINE"
        if recovery_on_cooldown "uhmalert.service"; then
            log "INFO: uhmalert recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "uhmalert.service"
        systemctl reset-failed uhmalert.service 2>/dev/null || true
        if systemctl restart uhmalert.service; then
            log "FIX: uhmalert restarted"
            clear_recovery_attempt "uhmalert.service"
        else
            log "WARNING: uhmalert restart FAILED -- alert"
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
        clear_recovery_attempt "pydhcpd.service"
    else
        if uhm_reload_in_progress; then
            log "INFO: pydhcpd down mid-reload (uhmleases.sh) -- skip"
            return
        fi
        log "WARNING: pydhcpd OFFLINE"
        if recovery_on_cooldown "pydhcpd.service"; then
            log "INFO: pydhcpd recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "pydhcpd.service"
        systemctl reset-failed pydhcpd.service 2>/dev/null || true
        if systemctl restart pydhcpd.service; then
            log "FIX: pydhcpd restarted"
            clear_recovery_attempt "pydhcpd.service"
        else
            log "WARNING: pydhcpd restart FAILED -- alert"
        fi
    fi
}

# Returns 0 (true) if <service> became active less than restart_grace_seconds
# ago -- gives it time to actually finish booting (UOS Server/UniFi Network
# can take a couple of minutes) before the next cron tick (every min)
# restarts it again mid-boot, which would otherwise never let it converge.
restart_grace_seconds=180
recently_restarted() {
    local service_name="$1" active_since elapsed_seconds
    active_since=$(systemctl show -p ActiveEnterTimestamp --value "$service_name" 2>/dev/null)
    [[ -z "$active_since" ]] && return 1
    elapsed_seconds=$(( $(date +%s) - $(date -d "$active_since" +%s 2>/dev/null || echo 0) ))
    (( elapsed_seconds < restart_grace_seconds ))
}

# Recovery cooldown: distinct from recently_restarted above, which only
# tracks a *successful* start. This tracks the last recovery *attempt*
# (reset-failed + restart) regardless of outcome, so a persistently broken
# service (controller down, credentials wrong, etc.) isn't hammered with a
# restart every single minute -- each unit's own StartLimitBurst would
# otherwise get reset-failed straight through by this watchdog, effectively
# disabling systemd's own circuit breaker. State lives under /run (tmpfs),
# so a reboot naturally clears any stale cooldowns.
recovery_state_dir="/run/uhmwatch"
recovery_on_cooldown() {
    local service_name="$1"
    local state_file="${recovery_state_dir}/${service_name}.attempted_at" last_attempt now_epoch
    [[ -f "$state_file" ]] || return 1
    last_attempt=$(cat "$state_file" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    (( (now_epoch - last_attempt) < RECOVERY_COOLDOWN_SECONDS ))
}

mark_recovery_attempt() {
    mkdir -p "$recovery_state_dir"
    date +%s > "${recovery_state_dir}/${1}.attempted_at"
}

# Called once a service is confirmed healthy again -- without this, the
# cooldown from a resolved incident would still throttle a genuinely new,
# unrelated failure that happens to occur within RECOVERY_COOLDOWN_SECONDS
# of the earlier (already-fixed) one.
clear_recovery_attempt() {
    rm -f "${recovery_state_dir}/${1}.attempted_at" 2>/dev/null || true
}

check_uosserver() {
    # All-in-one container -- its internal MongoDB is bundled and managed by
    # the container itself, never a host-level service. Do not check/restart
    # any standalone mongod.service here; it is not part of this
    # architecture, and restarting uosserver.service would not fix an
    # unrelated host-level Mongo issue.
    if ! systemctl is-active --quiet uosserver.service; then
        log "WARNING: UOS OFFLINE"
        if recovery_on_cooldown "uosserver.service"; then
            log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "uosserver.service"
        systemctl reset-failed uosserver.service 2>/dev/null || true
        if systemctl start uosserver.service; then
            log "FIX: uosserver started"
            clear_recovery_attempt "uosserver.service"
        else
            log "WARNING: uosserver start FAILED -- alert"
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
        log "INFO: UNIFI_USERNAME/UNIFI_PASSWORD not set -- skip"
        # Fall back to a port check so this isn't a total no-op.
        if ! ss -lnt | grep -qE ':11443\b'; then
            log "WARNING: UOS BROKEN_PORTS"
            if recently_restarted "uosserver.service"; then
                log "INFO: uosserver restarted recently -- skip"
                return
            fi
            if recovery_on_cooldown "uosserver.service"; then
                log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
                return
            fi
            mark_recovery_attempt "uosserver.service"
            systemctl reset-failed uosserver.service 2>/dev/null || true
            if systemctl restart uosserver.service; then
                log "FIX: uosserver restarted"
                clear_recovery_attempt "uosserver.service"
            else
                log "WARNING: uosserver restart FAILED -- alert"
            fi
        else
            clear_recovery_attempt "uosserver.service"
        fi
        return
    fi

    local login_url login_payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${tls_opts[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$login_payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        clear_recovery_attempt "uosserver.service"
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        local uhmd_start now_epoch
        uhmd_start=$(uhmd_started_at)
        now_epoch=$(date +%s)
        if (( uhmd_start > 0 )) && (( now_epoch - uhmd_start < STARTUP_GRACE_SECONDS )); then
            log "INFO: UniFi login failed (HTTP $http_code) in grace -- skip"
            return
        fi
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if recently_restarted "uosserver.service"; then
            log "INFO: uosserver restarted recently -- skip"
            return
        fi
        if recovery_on_cooldown "uosserver.service"; then
            log "INFO: uosserver recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "uosserver.service"
        systemctl reset-failed uosserver.service 2>/dev/null || true
        if systemctl restart uosserver.service; then
            log "FIX: uosserver restarted (login failed)"
            clear_recovery_attempt "uosserver.service"
        else
            log "WARNING: uosserver restart FAILED -- alert"
        fi
    elif [[ "$http_code" == "429" ]]; then
        log "WARNING: rate limited (HTTP 429), not a credentials issue"
        log "WARNING: stop uhmd and uhmwatch cron -- alert"
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "WARNING: check uhm.env, UOS is responding -- alert"
    fi
}

check_unifi_classic() {
    if ! systemctl is-active --quiet unifi.service; then
        log "WARNING: UniFi (classic) OFFLINE"
        if recovery_on_cooldown "unifi.service"; then
            log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "unifi.service"
        systemctl reset-failed unifi.service 2>/dev/null || true
        if systemctl start unifi.service; then
            log "FIX: unifi started"
            clear_recovery_attempt "unifi.service"
        else
            log "WARNING: unifi.service start FAILED -- alert"
        fi
        return
    fi

    # Functional check: same reasoning as check_uosserver() -- systemctl
    # is-active only proves the process is up, not that the app (and its
    # embedded Mongo subprocess, see header) is actually healthy. Same login
    # mechanism as uhmd.sh, but against the classic endpoint (/api/login).
    if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
        log "INFO: UNIFI_USERNAME/UNIFI_PASSWORD not set -- skip"
        # Fall back to a port check so this isn't a total no-op.
        if ! ss -lnt | grep -qE ':(8443|8080)\b'; then
            log "WARNING: UniFi (classic) BROKEN_PORTS"
            if recently_restarted "unifi.service"; then
                log "INFO: unifi restarted recently -- skip"
                return
            fi
            if recovery_on_cooldown "unifi.service"; then
                log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
                return
            fi
            mark_recovery_attempt "unifi.service"
            systemctl reset-failed unifi.service 2>/dev/null || true
            if systemctl restart unifi.service; then
                log "FIX: unifi restarted"
                clear_recovery_attempt "unifi.service"
            else
                log "WARNING: unifi.service restart FAILED -- alert"
            fi
        else
            clear_recovery_attempt "unifi.service"
        fi
        return
    fi

    local login_url login_payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/login"
    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    http_code=$(curl -s "${tls_opts[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$login_payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        clear_recovery_attempt "unifi.service"
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        local uhmd_start now_epoch
        uhmd_start=$(uhmd_started_at)
        now_epoch=$(date +%s)
        if (( uhmd_start > 0 )) && (( now_epoch - uhmd_start < STARTUP_GRACE_SECONDS )); then
            log "INFO: UniFi login failed (HTTP $http_code) in grace -- skip"
            return
        fi
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if recently_restarted "unifi.service"; then
            log "INFO: unifi restarted recently -- skip"
            return
        fi
        if recovery_on_cooldown "unifi.service"; then
            log "INFO: unifi recovery cooldown (${RECOVERY_COOLDOWN_SECONDS}s) -- skip"
            return
        fi
        mark_recovery_attempt "unifi.service"
        systemctl reset-failed unifi.service 2>/dev/null || true
        if systemctl restart unifi.service; then
            log "FIX: unifi restarted (login failed)"
            clear_recovery_attempt "unifi.service"
        else
            log "WARNING: unifi.service restart FAILED -- alert"
        fi
    elif [[ "$http_code" == "429" ]]; then
        log "WARNING: rate limited (HTTP 429), not a credentials issue"
        log "WARNING: stop uhmd and uhmwatch cron -- alert"
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "WARNING: check uhm.env, unifi.service is responding -- alert"
    fi
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

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
