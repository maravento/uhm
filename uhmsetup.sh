#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmsetup -- uhm installer / updater
# FILE: uhmsetup.sh
#
# USAGE:
# sudo bash uhmsetup.sh --install     Install (aborts if already installed)
# sudo bash uhmsetup.sh --update      Update scripts only (keeps config/ACLs)
# sudo bash uhmsetup.sh --uninstall   Uninstall
# sudo bash uhmsetup.sh --status      Report services, port, config and log
# sudo bash uhmsetup.sh               Interactive menu
# sudo bash uhmsetup.sh --help        Usage
#
# LOG: uhmsetup.log, in the directory containing this script
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# USAGE
# Answered before any check: --help must work without root
usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") [OPTION]

Modes:
  --install    Install uhm. Aborts if already installed -- use --update
               or --uninstall instead. Requires UniFi Network 10x or later.
               UniFi OS deployments also require UniFi OS 5x or later.
               Later major versions are accepted for both products.
  --update     Update scripts only (preserves config, ACLs, firewall).
  --uninstall  Uninstall uhm (interactive, with confirmations).
  --status     Report services, panel port, config and log.
  (none)       Open the interactive menu.
  --help, -h   Show this help.

Run from inside the cloned uhm repository. See the README for details.
EOF
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
esac

# root check
if [[ "$(id -u)" != "0" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
exec 200>"$script_lock"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: script $(basename "$0") is already running -abort" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hotspot_dir="/etc/uhm"
core_dir="${hotspot_dir}/core"
tools_dir="${hotspot_dir}/tools"
acl_dir="${hotspot_dir}/acl"
acl_base_dir="/etc/acl"
acl_mac_dir="${acl_base_dir}/mac"
uhm_env="${hotspot_dir}/uhm.env"
pydhcp_env="/etc/pydhcp/pydhcp.env"
uhmbk_script="${tools_dir}/uhmbk.sh"
log_file="${script_dir}/uhmsetup.log"
{ > "$log_file"; } 2>/dev/null || true
uhm_log_file="/var/log/uhm.log"
logrotate_file="/etc/logrotate.d/uhm"
uhm_iptables_dest="${tools_dir}/uhmiptables.sh"
service_dest="/etc/systemd/system/uhmd.service"
web_root="/var/www/uhm"
web_port="4048"
vhost_dest="/etc/apache2/sites-available/uhmweb.conf"
sudoers_dest="/etc/sudoers.d/uhmweb"
apache_ports="/etc/apache2/ports.conf"
wpad_root="/var/www/wpad"
wpad_vhost_dest="/etc/apache2/sites-available/wpad.conf"

# Repo file expectations (relative to this script)
repo_core="${script_dir}/core"
repo_tools="${script_dir}/tools"
repo_acl="${script_dir}/acl"
repo_uhmd="${repo_core}/uhmd.sh"
repo_web="${script_dir}/web"
repo_config="${script_dir}/config"
repo_wpad="${repo_config}/wpad"
repo_uhmweb="${repo_config}/web"
repo_service="${repo_config}/service/uhmd.service"

# Required apt packages
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- so a
# missing package is reported here instead of failing later in uhmd,
# uhmunifi or uhmiptables.
apt_deps=(curl jq iptables ipset python3 openssl coreutils util-linux iproute2 cron grep sed systemd libc-bin findutils procps logrotate git zip expect)

# Discovered runtime values (filled during install)

# Output helpers
log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then echo "$msg" >&2; else echo "$msg"; fi
}
info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
err() { log "ERROR: $*"; }
step() { :; }
abort() { err "$*"; exit 1; }

# port in use
check_port() {
    local proto="$1" port="$2" role="$3"
    if [ -n "$(ss -lnH "-${proto,,}" "sport = :$port" 2>/dev/null)" ]; then
        err "${proto^^} port $port in use by another $role"
        abort "stop that service before installing -abort"
    fi
}

version_ge() {
    # version_ge A B -- returns 0 if version A >= version B
    [[ "$1" == "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]
}

# Network is required in both deployments; OS is checked only for unifi-os.
check_unifi_versions() {
    local unifi_type="$1" network_version="" os_version=""
    if [[ "$unifi_type" == "unifi-os" ]]; then
        os_version=$(grep -m1 -E '^(APP_VERSION|UOS_SERVER_VERSION)=' \
            /var/lib/uosserver/server.conf 2>/dev/null | cut -d'=' -f2) || true
        if [[ ! "$os_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            abort "cannot read UniFi OS version from server.conf -abort"
        fi
        if ! version_ge "$os_version" "5.0.0"; then
            err "UniFi OS version: $os_version"
            abort "UniFi OS requires 5x or later -abort"
        fi
        command -v podman &>/dev/null \
            || abort "cannot check UniFi Network: podman is missing -abort"
        network_version=$(sudo -u uosserver podman exec uosserver \
            dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1) || true
    else
        network_version=$(dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1) || true
    fi
    if [[ ! "$network_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        abort "cannot detect UniFi Network version -abort"
    fi
    if ! version_ge "$network_version" "10.0.0"; then
        err "UniFi Network version: $network_version"
        abort "UniFi Network requires 10x or later -abort"
    fi
}

# validation -- one variable per thing validated; use directly with =~
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# check internet
check_internet() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if getent hosts www.google.com >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for internet..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no internet connection -abort"
    exit 1
}

# UPDATE CHECKS
update_error() {
    if declare -F err >/dev/null; then
        err "$* -abort"
    else
        log "ERROR: $* -abort"
    fi
    exit 1
}

update_reset() {
    update_cron_file="$1"
    update_files=()
    update_jobs=()
    update_services=()
    update_stopped_services=()
    update_daemons=()
    update_copying=0
    update_cron_paused=0
    update_cron_existed=0
    update_cron_already_paused=0
}

update_file() {
    update_files+=("$1" "$2" "$3" "$4")
    case "$2" in *.sh|*.py|*.pl) update_jobs+=("$2") ;; esac
}

update_target() {
    update_files+=("" "$1" "${2:-644}" "${3:-root:root}")
}

update_preflight() {
    command -v python3 >/dev/null 2>&1 || update_error "python3 is required for update checks"
    local check_message
    if check_message=$(python3 - "${update_files[@]}" <<'UPDATE_PY'
import array, errno, fcntl, os, stat, sys, tempfile
items = [sys.argv[i:i + 4] for i in range(1, len(sys.argv), 4)]
space, probes = {}, set()
def fail(message):
    print(message)
    raise SystemExit(1)
def flags(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            value = array.array('L', [0])
            try:
                fcntl.ioctl(fd, 0x80086601, value, True)
            except OSError as exc:
                if exc.errno not in (errno.ENOTTY, errno.EOPNOTSUPP, errno.EINVAL):
                    raise
            else:
                if value[0] & 0x30:
                    protection = []
                    if value[0] & 0x10:
                        protection.append('immutable')
                    if value[0] & 0x20:
                        protection.append('append-only')
                    fail(os.path.basename(path) + ' is ' + ' and '.join(protection))
        finally:
            os.close(fd)
    except OSError as exc:
        fail(exc.strerror.lower() + ': ' + os.path.basename(path))
for source, target, mode, owner in items:
    if source:
        try:
            st = os.lstat(source)
            if not stat.S_ISREG(st.st_mode):
                fail('source is not a file: ' + os.path.basename(source))
            with open(source, 'rb') as stream:
                stream.read(1)
        except OSError as exc:
            fail('cannot read source: ' + os.path.basename(source))
for source, target, mode, owner in items:
    target = os.path.abspath(target)
    directory = mode.startswith('d')
    try:
        parent = target if directory else os.path.dirname(target)
        if os.path.lexists(target):
            st = os.lstat(target)
            if (directory and not stat.S_ISDIR(st.st_mode)) or (not directory and not stat.S_ISREG(st.st_mode)):
                fail(('dst is not a folder: ' if directory else 'dst is not a file: ') + os.path.basename(target))
            flags(target)
            if not directory:
                fd = os.open(target, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(fd)
        while not os.path.exists(parent):
            if os.path.lexists(parent):
                fail('folder is a symbolic link: ' + parent)
            parent = os.path.dirname(parent)
        if not os.path.isdir(parent):
            fail('not a folder: ' + parent)
        current = parent
        while current != '/':
            if os.path.islink(current):
                fail('folder is a symbolic link: ' + current)
            flags(current)
            current = os.path.dirname(current)
        fs = os.statvfs(parent)
        if fs.f_flag & os.ST_RDONLY:
            fail('filesystem is read-only: ' + parent)
        if parent not in probes:
            fd, probe = tempfile.mkstemp(prefix='update-check-', dir=parent)
            try:
                os.write(fd, b'update check\n')
                os.fsync(fd)
            finally:
                os.close(fd)
                os.unlink(probe)
            probes.add(parent)
        device = os.stat(parent).st_dev
        required = os.stat(source).st_size if source else 4096
        needed, available, label = space.get(device, (0, fs.f_bavail * fs.f_frsize, parent))
        space[device] = (needed + required + 4096, available, label)
        if fs.f_favail == 0:
            fail('no free inodes for dst: ' + os.path.basename(target))
    except OSError as exc:
        fail('cannot write dst: ' + os.path.basename(target))
for needed, available, label in space.values():
    if available < needed:
        fail('not enough space to update: ' + label)
UPDATE_PY
    ); then
        :
    else
        update_error "$check_message"
    fi
}

update_backup() {
    [ -f "$1" ] && [ -r "$1" ] || update_error "backup script not readable: $(basename "$1")"
    bash "$1" || update_error "backup failed: $(basename "$1")"
}

update_begin() {
    export UPDATE_CRON_OWNER="$$"
    trap 'update_cleanup "$?"' EXIT
    local disabled="${update_cron_file}.update-disabled"
    [ ! -L "${update_cron_file}.lock" ] || update_error "invalid cron lock: $update_cron_file"
    (umask 077; : >> "${update_cron_file}.lock") || update_error "cannot open cron lock: $update_cron_file"
    exec 203>"${update_cron_file}.lock" || update_error "cannot open cron lock: $update_cron_file"
    flock -n 203 || update_error "cron file is being changed: $(basename "$update_cron_file")"
    if [ -e "$disabled" ] || [ -L "$disabled" ]; then
        [ -f "$disabled" ] && [ ! -L "$disabled" ] || update_error "invalid paused cron: $(basename "$disabled")"
        [ ! -e "$update_cron_file" ] || update_error "both active and paused cron exist: $(basename "$update_cron_file")"
        update_cron_already_paused=1
        update_cron_paused=1
    elif [ -e "$update_cron_file" ]; then
        mv -T -- "$update_cron_file" "$disabled" || update_error "cannot pause cron: $update_cron_file"
        update_cron_existed=1
        update_cron_paused=1
    else
        (umask 077; set -C; : > "$disabled") || update_error "cannot pause cron: $update_cron_file"
        update_cron_paused=1
    fi
    exec 203>&-
}

update_pids() {
    python3 - "$1" <<'UPDATE_PIDS'
import os, sys
wanted = os.path.realpath(sys.argv[1])
for entry in os.scandir('/proc'):
    if not entry.name.isdigit() or int(entry.name) == os.getpid():
        continue
    try:
        with open(entry.path + '/cmdline', 'rb') as stream:
            args = [os.fsdecode(value) for value in stream.read().split(b'\0') if value]
        if args and any(os.path.realpath(value) == wanted for value in args if value.startswith('/')):
            print(entry.name)
    except (OSError, ValueError):
        continue
UPDATE_PIDS
}

update_wait() {
    local script="$1" pids attempt
    for attempt in {1..30}; do
        pids=$(update_pids "$script") || update_error "cannot inspect processes: $(basename "$script")"
        [ -z "$pids" ] && return 0
        sleep 1
    done
    update_error "process still running: $(basename "$script")"
}

update_stop_daemon() {
    local script="$1" pids
    pids=$(update_pids "$script") || update_error "cannot inspect processes: $script"
    if [ -n "$pids" ]; then
        update_daemons+=("$script")
        bash "$script" --stop || update_error "cannot stop daemon: $script"
        update_wait "$script"
    fi
}

update_stop_service() {
    local unit="$1" state load_state
    load_state=$(systemctl show -p LoadState --value "$unit") || update_error "cannot inspect service: $unit"
    [ "$load_state" != not-found ] || return 0
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect service: $unit"
    case "$state" in
        active|reloading|activating|deactivating) update_services+=("$unit") ;;
        inactive|failed) ;;
        *) update_error "unexpected service state: $unit ($state)" ;;
    esac
    update_stopped_services+=("$unit")
    systemctl stop "$unit" || update_error "cannot stop service: $unit"
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
    [ "$state" = inactive ] || {
        log "ERROR: $unit state: $state"
        update_error "$unit did not stop"
    }
}

update_wait_jobs() {
    local script unit state
    for script in "${update_jobs[@]}"; do
        update_wait "$script"
    done
    for unit in "${update_stopped_services[@]}"; do
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
        [ "$state" = inactive ] || update_error "service restarted in update: $unit"
    done
}

update_apply() {
    update_preflight
    update_copying=1
    local i source target mode owner
    for ((i=0; i<${#update_files[@]}; i+=4)); do
        source="${update_files[i]}"
        target="${update_files[i+1]}"
        mode="${update_files[i+2]}"
        owner="${update_files[i+3]}"
        if [[ "$mode" == d* ]]; then
            install -d -m "${mode#d}" -o "${owner%:*}" -g "${owner#*:}" -- "$target" \
                || update_error "cannot prepare directory: $target"
            continue
        fi
        if [ -z "$source" ]; then
            if [ ! -d "$(dirname "$target")" ]; then
                install -d -m 755 -o root -g root -- "$(dirname "$target")" \
                    || update_error "cannot prepare destination parent: $(basename "$target")"
            fi
            continue
        fi
        install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" -- "$source" "$target" \
            || update_error "cannot replace file: $(basename "$target")"
        cmp -s -- "$source" "$target" || {
            local compared_file
            compared_file=$(basename "$target")
            if (( ${#compared_file} <= 19 )); then
                update_error "src and dst do not match: $compared_file"
            fi
            log "ERROR: src and dst: $compared_file"
            update_error "src and dst do not match"
        }
        info "updated $(basename "$target")"
    done
}

update_resume() {
    local unit script state
    for unit in "${update_services[@]}"; do
        systemctl start "$unit" || update_error "cannot start service: $unit"
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect started: $unit"
        [ "$state" = active ] || {
            log "ERROR: $unit state: $state"
            update_error "$unit did not start"
        }
    done
    for script in "${update_daemons[@]}"; do
        bash "$script" --start || update_error "cannot start daemon: $script"
        [ -n "$(update_pids "$script")" ] || update_error "daemon did not start: $script"
    done
}

update_finish() {
    update_resume
    rm -f -- "${update_cron_file}.update-disabled" || update_error "cannot finish cron update: $(basename "$update_cron_file")"
    trap - EXIT
    unset UPDATE_CRON_OWNER
}

update_cleanup() {
    local status="$1" unit script
    trap - EXIT
    if (( update_copying == 0 )); then
        for unit in "${update_services[@]}"; do
            systemctl start "$unit" || warn "cannot resume $unit -alert"
        done
        for script in "${update_daemons[@]}"; do
            bash "$script" --start || warn "cannot resume $(basename "$script") -alert"
        done
        if (( update_cron_paused && ! update_cron_already_paused )); then
            if (( update_cron_existed )); then
                mv -T -- "${update_cron_file}.update-disabled" "$update_cron_file" \
                    || warn "cannot restore paused cron -alert"
            else
                rm -f -- "${update_cron_file}.update-disabled" || warn "cannot clear paused cron -alert"
            fi
        fi
    else
        if rm -f -- "$update_cron_file"; then
            warn "update failed; cron remains disabled -alert"
        else
            warn "cannot keep project cron paused -alert"
        fi
        for unit in "${update_services[@]}"; do
            systemctl stop "$unit" || warn "cannot keep $unit stopped -alert"
        done
        for script in "${update_daemons[@]}"; do
            bash "$script" --stop || warn "cannot keep $(basename "$script") stopped -alert"
        done
    fi
    (( status != 0 )) || status=1
    exit "$status"
}

# CRON FILE
# Publish the complete project schedule after preparing it successfully.
cron_d_write() (
    local cron_file="/etc/cron.d/uhm"
    local cron_tmp

    [ "$#" -gt 0 ] || return 1
    [ ! -L "${cron_file}.lock" ] || return 1
    (umask 077; : >> "${cron_file}.lock") || return 1
    exec 201>"${cron_file}.lock" || return 1
    flock -x 201 || return 1
    if [ -e "${cron_file}.update-disabled" ] && [ "${UPDATE_CRON_OWNER:-}" != "$$" ]; then
        return 1
    fi
    [ ! -L "$cron_file" ] || return 1
    [ ! -e "$cron_file" ] || [ -f "$cron_file" ] || return 1

    cron_tmp=$(mktemp "${cron_file}.XXXXXX") || return 1
    trap 'rm -f -- "$cron_tmp"' EXIT
    {
        printf '%s\n' '# Managed by the project installer; manual changes are replaced.'
        printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        printf '%s\n' "$@"
    } > "$cron_tmp" || return 1
    chmod 644 "$cron_tmp" && chown root:root "$cron_tmp" || return 1
    mv -fT -- "$cron_tmp" "$cron_file" || return 1
)

# PROJECT SCHEDULE
# Publish all tasks defined by this project
register_project_cron() {
    cron_d_write "* * * * * root $core_dir/uhmwatch.sh" "@monthly root $uhmbk_script"
}

# Appends $2 (one or more lines) right after the file's LAST
# "# ====...====" line, instead of a plain >> append -- so a new block
# always lands right after whatever content (from any project sharing this
# file) is already there, never after a stray trailing line some other
# script might append later. Falls back to a plain append if the file has
# no delimiter line at all (empty/malformed file).
insert_after_last_delimiter() {
    local conf_file="$1" env_block="$2" last_line tmp_file
    last_line=$(awk '/^# =====+$/{last=NR} END{if(last) print last}' "$conf_file")
    if [[ -z "$last_line" ]]; then
        printf '\n%s\n' "$env_block" >> "$conf_file"
        return
    fi
    tmp_file=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -abort"; }
    head -n "$last_line" "$conf_file" > "$tmp_file"
    printf '\n%s\n' "$env_block" >> "$tmp_file"
    tail -n "+$((last_line + 1))" "$conf_file" >> "$tmp_file"
    mv "$tmp_file" "$conf_file"
}

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt_text="$1" default_value="${2:-n}" user_answer hint_text
    [[ "$default_value" == "y" ]] && hint_text="[Y/n]" || hint_text="[y/N]"
    read -rp " ${prompt_text} ${hint_text}: " user_answer
    user_answer="${user_answer:-$default_value}"
    [[ "${user_answer,,}" =~ ^y(es)?$ ]]
}

# PREFLIGHT CHECKS
# Verified before anything is written to disk
check_repo_files() {
    [[ -r "$repo_uhmd" ]] || { err "missing $(basename "$repo_uhmd")"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -r "$repo_service" ]] || { err "missing $(basename "$repo_service")"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmreload.sh" ]] || { err "missing core/uhmreload.sh"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmleases.sh" ]] || { err "missing core/uhmleases.sh"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmwatch.sh" ]] || { err "missing core/uhmwatch.sh"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -d "$repo_tools" ]] || { err "missing tools/ directory"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -r "${repo_tools}/uhmenv.sh" ]] || { err "missing tools/uhmenv.sh"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -d "$repo_acl" ]] || { err "missing acl/ directory"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -d "$repo_web" ]] || { err "missing web/ directory"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    [[ -d "$repo_config" ]] || { err "missing config/ directory"; abort "run uhmsetup.sh from inside the cloned repo -abort"; }
    info "Repo files located"
}

check_apt_deps() {
    local dep_pkg
    for dep_pkg in "${apt_deps[@]}"; do
        if ! dpkg -s "$dep_pkg" &>/dev/null; then
            abort "dependency '$dep_pkg' is not installed -abort"
        fi
    done
}

# Aborts if software uhm would collide with is already installed. Same shape
# as gateproxy's own check, but a shorter list: apache2 and pydhcp are uhm's
# own components, and squid is what the reference ruleset expects, so none of
# the three is a conflict here.
check_conflicts() {
    local role="$1"; shift
    local found=() dep_pkg
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            found+=("$dep_pkg")
        fi
    done
    if (( ${#found[@]} > 0 )); then
        for dep_pkg in "${found[@]}"; do
            warn "conflicting $role: $dep_pkg -alert"
        done
        abort "remove them with apt purge, then re-run -abort"
    fi
}

# Installed but not necessarily in the way -- reported, never fatal
warn_overlap() {
    local feature="$1"; shift
    local dep_pkg
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            warn "$dep_pkg installed, keep its $feature disabled -alert"
        fi
    done
}

check_preinstalled() {
    log "EVENT: Checking for conflicting pre-installed packages..."
    check_conflicts "DHCP server" isc-dhcp-server kea-dhcp4-server udhcpd
    check_conflicts "web server"  nginx lighttpd caddy
    check_conflicts "firewall"    firewalld
    warn_overlap "dhcp" dnsmasq
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        abort "ufw active; disable it before UHM -abort"
    fi
    info "No conflicting packages found"
}

detect_dhcp_backend() {
    local pydhcp_active=false
    systemctl is-active --quiet pydhcpd 2>/dev/null && pydhcp_active=true

    if $pydhcp_active; then
        info "DHCP backend detected: pydhcpd"
    else
        err "pydhcpd is not active"
        abort "pydhcpd: install github.com/maravento/pydhcp -abort"
    fi
}

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}" excluded_iface="${2:-}"
    local iface_name iface_choice iface_index iface_addrs
    local -a lan_candidates=()
    if [ -n "$preset_iface" ]; then
        ip link show dev "$preset_iface" >/dev/null 2>&1 || {
            log "ERROR: LAN interface '$preset_iface' not found -abort"
            exit 1
        }
        [ "$preset_iface" != "$excluded_iface" ] || {
            log "ERROR: LAN and WAN must differ -abort"
            exit 1
        }
        lan_iface_answer="$preset_iface"
        return 0
    fi
    while IFS= read -r iface_name; do
        [ "$iface_name" = "$excluded_iface" ] && continue
        lan_candidates+=("$iface_name")
    done < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
    (( ${#lan_candidates[@]} > 0 )) || {
        log "ERROR: no LAN interface available -abort"
        exit 1
    }
    if (( ${#lan_candidates[@]} == 1 )); then
        lan_iface_answer="${lan_candidates[0]}"
        return 0
    fi
    echo "Available LAN interfaces:"
    for iface_index in "${!lan_candidates[@]}"; do
        iface_name="${lan_candidates[$iface_index]}"
        iface_addrs=$(ip -4 -o addr show dev "$iface_name" scope global | awk '{print $4}' | paste -sd' ')
        printf ' [%d] %s (%s)\n' "$((iface_index + 1))" "$iface_name" "${iface_addrs:-no IPv4}"
    done
    while true; do
        read -r -p "Select LAN interface number: " iface_choice || {
            log "ERROR: cannot read LAN interface selection -abort"
            exit 1
        }
        if [[ "$iface_choice" =~ $UH_UINT ]] && [ "${#iface_choice}" -le 5 ] \
           && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#lan_candidates[@]}" ]; then
            lan_iface_answer="${lan_candidates[$((iface_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN interface selection -retry"
    done
}

read_lan_ipv4() {
    local selected_iface="$1" preset_ip="${2:-}" ipv4_choice ipv4_index candidate_cidr
    local -a lan_addresses=()
    mapfile -t lan_addresses < <(ip -4 -o addr show dev "$selected_iface" scope global | awk '{print $4}')
    (( ${#lan_addresses[@]} > 0 )) || {
        log "ERROR: LAN '$selected_iface' has no IPv4 address -abort"
        exit 1
    }
    for candidate_cidr in "${lan_addresses[@]}"; do
        [[ "$candidate_cidr" =~ $UH_CIDR ]] || {
            log "ERROR: LAN '$selected_iface' has invalid IPv4/prefix -abort"
            exit 1
        }
    done
    if [ -n "$preset_ip" ]; then
        for candidate_cidr in "${lan_addresses[@]}"; do
            if [ "${candidate_cidr%/*}" = "$preset_ip" ]; then
                lan_cidr_answer="$candidate_cidr"
                return 0
            fi
        done
        log "ERROR: requested IPv4 is not configured on LAN -abort"
        exit 1
    fi
    if (( ${#lan_addresses[@]} == 1 )); then
        lan_cidr_answer="${lan_addresses[0]}"
        return 0
    fi
    echo "IPv4 addresses on LAN '$selected_iface':"
    for ipv4_index in "${!lan_addresses[@]}"; do
        printf ' [%d] %s\n' "$((ipv4_index + 1))" "${lan_addresses[$ipv4_index]}"
    done
    while true; do
        read -r -p "Select LAN IPv4 number: " ipv4_choice || {
            log "ERROR: cannot read LAN IPv4 selection -abort"
            exit 1
        }
        if [[ "$ipv4_choice" =~ $UH_UINT ]] && [ "${#ipv4_choice}" -le 5 ] \
           && [ "$ipv4_choice" -ge 1 ] && [ "$ipv4_choice" -le "${#lan_addresses[@]}" ]; then
            lan_cidr_answer="${lan_addresses[$((ipv4_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN IPv4 selection -retry"
    done
}

# Reads pydhcp's own network values (server IP, mask, subnet, broadcast, DNS,
# blockdhcp pool range) from pydhcp_env instead of asking for them again --
# pysetup.sh already collected and persisted them. Only the keys this
# installer itself needs for the wizard are required here: the rest live in
# pydhcp.env and each component reads and validates its required keys
# from there at runtime.
# Sets SERVER_IP, SERV_MASK, SERV_SUBNET, SERV_BROADCAST,
# SERV_DNS, SERV_INI_RANGE_BLOCK, SERV_END_RANGE_BLOCK for
# run_setup_wizard.
load_pydhcp_conf() {
    [ -f "$pydhcp_env" ] \
        || { err "$pydhcp_env not found"; abort "install pydhcp first, see its README -abort"; }

    local missing_keys=() env_key
    for env_key in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK \
               SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
        grep -q "^${env_key}=" "$pydhcp_env" || missing_keys+=("$env_key")
    done
    if (( ${#missing_keys[@]} > 0 )); then
        for env_key in "${missing_keys[@]}"; do
            err "$(basename "$pydhcp_env"): missing key $env_key -abort"
        done
        exit 1
    fi

    # Load only these known keys instead of sourcing the whole file, so a
    # tampered pydhcp.env cannot execute code.
    load_uhm_env "$pydhcp_env" "$env_keys" line

    local check_var
    for check_var in SERVER_IP SERV_SUBNET SERV_BROADCAST \
              SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
        [[ "${!check_var:-}" =~ $UH_IPV4 ]] \
            || { err "invalid IPv4 in ${check_var}: '${!check_var:-}'"; abort "fix it in $pydhcp_env and retry -abort"; }
    done
    [[ "${SERV_MASK:-}" =~ $UH_NETMASK ]] \
        || { err "invalid netmask in SERV_MASK: '${SERV_MASK:-}'"; abort "fix it in $pydhcp_env and retry -abort"; }
    [[ "${SERV_DNS:-}" =~ $UH_DNS ]] \
        || { err "invalid SERV_DNS list: '${SERV_DNS:-}'"; abort "fix it in $pydhcp_env and retry -abort"; }
}

# INTERACTIVE PROMPTS
# Ask helpers, each one validating its own answer
# ACL PREPARATION
# Canonical block -- copied byte for byte into every script that creates a
# directory or a list under /etc/acl. Prepare /etc/acl first, then only the
# subdirectory and the lists this script needs. Never recursive.
# Usage: acl_prepare <dir> <dir_mode> <file_mode> [file ...]
acl_prepare() {
    local acl_dir="$1" dir_mode="$2" file_mode="$3" acl_file
    shift 3

    # mkdir without -p fails when the directory already exists, so a success
    # means this run created it and no concurrent run did.
    if mkdir -m "$dir_mode" -- "$acl_dir" 2>/dev/null; then
        if ! chown root:root -- "$acl_dir"; then
            log "ERROR: cannot set owner of $acl_dir -abort"
            exit 1
        fi
        log "WARNING: created ACL directory $acl_dir -alert"
    elif [ -d "$acl_dir" ] && [ ! -L "$acl_dir" ]; then
        acl_fix_perms "$acl_dir" "$dir_mode"
    else
        log "ERROR: $acl_dir is not a regular directory -abort"
        exit 1
    fi

    for acl_file in "$@"; do
        # Checked before the redirection: noclobber only protects regular
        # files, and opening a FIFO for writing blocks until a reader shows up.
        if [ -L "$acl_file" ] || { [ -e "$acl_file" ] && [ ! -f "$acl_file" ]; }; then
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
        # noclobber makes the redirection fail when the file already exists,
        # and umask 077 keeps the new file closed until chmod sets its mode.
        if (set -C; umask 077; : > "$acl_file") 2>/dev/null; then
            if ! { chmod "$file_mode" -- "$acl_file" \
                && chown root:root -- "$acl_file"; }; then
                log "ERROR: cannot set perms of $(basename "$acl_file") -abort"
                exit 1
            fi
            log "WARNING: created empty $(basename "$acl_file") -alert"
        elif [ -f "$acl_file" ] && [ ! -L "$acl_file" ]; then
            acl_fix_perms "$acl_file" "$file_mode"
        else
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
    done
}

# Repairs mode and owner of an existing ACL object, per Autorreparación
acl_fix_perms() {
    local acl_path="$1" want_mode="$2" cur_mode cur_owner
    cur_mode=$(stat -c '%a' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    cur_owner=$(stat -c '%U:%G' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    [[ "$cur_mode" == "$want_mode" && "$cur_owner" == "root:root" ]] && return 0
    if ! { chmod "$want_mode" -- "$acl_path" \
        && chown root:root -- "$acl_path"; }; then
        log "ERROR: cannot fix $(basename "$acl_path") perms -abort"
        exit 1
    fi
    log "INFO: $acl_path perms fixed -fixed"
}

ask() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
    printf -v "$target_var" '%s' "${user_answer:-$default_value}"
}

ask_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && (( user_answer >= 1 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "'$user_answer' is not valid, enter a positive integer -retry"
    done
}

# ip_le A B -- returns 0 if address A is lower than or equal to address B
ip_le() {
    python3 -c "
import ipaddress, sys
sys.exit(0 if ipaddress.IPv4Address(sys.argv[1]) <= ipaddress.IPv4Address(sys.argv[2]) else 1)
" "$1" "$2"
}

ask_ip() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_IPV4 ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "'$user_answer' is not a valid IPv4 address -retry"
    done
}

# ip_in_network IP NETWORK NETMASK -- returns 0 if IP belongs to the network
ip_in_network() {
    python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Network(sys.argv[2] + '/' + sys.argv[3], strict=False)
sys.exit(0 if ipaddress.IPv4Address(sys.argv[1]) in net else 1)
" "$1" "$2" "$3"
}

# Returns 0 (true) if dotted-quad IP ranges [s1,e1] and [s2,e2] intersect.
ranges_overlap() {
    local start_ip_1="$1" end_ip_1="$2" start_ip_2="$3" end_ip_2="$4"
    python3 -c "
import ipaddress, sys
s1, e1, s2, e2 = (ipaddress.IPv4Address(a) for a in sys.argv[1:5])
sys.exit(0 if s1 <= e2 and s2 <= e1 else 1)
" "$start_ip_1" "$end_ip_1" "$start_ip_2" "$end_ip_2"
}

# UNIFI DISCOVERY
# Finds the controller and its type without asking for them
discovered_url=""
discovered_type=""

discover_unifi_controller() {
    local unifi_user="$1" unifi_pass="$2" server_ip="$3"
    local check_ports=(8443 11443)
    local test_url http_code login_payload

    log "EVENT: Probing ${server_ip} on ports ${check_ports[*]} ..."
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline).
    login_payload=$(UH_JQ_USER="$unifi_user" UH_JQ_PASS="$unifi_pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    for probe_port in "${check_ports[@]}"; do
        test_url="https://${server_ip}:${probe_port}"

        # Body goes to curl via stdin (--data-binary @-), not -d, for the
        # same reason: -d "$login_payload" would put the password in curl's argv.
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/auth/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$login_payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found UniFi OS controller at ${test_url}"
            discovered_url="$test_url"
            discovered_type="unifi-os"
            return 0
        fi

        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$login_payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found classic UniFi controller at ${test_url}"
            discovered_url="$test_url"
            discovered_type="classic"
            return 0
        fi
    done

    return 1
}

# Queries the controller's configured SSIDs (rest/wlanconf) with a fresh
# login, so run_setup_wizard can offer a select menu instead of free-text
# entry for the guest SSID -- avoids a typo in a value that must match
# UniFi exactly. Echoes one SSID name per line on success; nothing on any
# failure (login, HTTP error, empty list), so the caller falls back to
# manual entry. Site is always "default" -- see UNIFI_SITE note below.
fetch_unifi_ssids() {
    local controller_url="$1" unifi_type="$2" unifi_user="$3" unifi_pass="$4"
    local login_path base_path login_payload cookie_jar

    if [[ "$unifi_type" == "unifi-os" ]]; then
        login_path="/api/auth/login"
        base_path="/proxy/network/api/s/default"
    else
        login_path="/api/login"
        base_path="/api/s/default"
    fi

    login_payload=$(UH_JQ_USER="$unifi_user" UH_JQ_PASS="$unifi_pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    cookie_jar=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -abort"; }

    curl -sk -c "$cookie_jar" -o /dev/null \
        -X POST "${controller_url}${login_path}" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 5 <<< "$login_payload"

    curl -sk -b "$cookie_jar" "${controller_url}${base_path}/rest/wlanconf" --connect-timeout 5 \
        | jq -r '.data[]?.name // empty' 2>/dev/null

    rm -f "$cookie_jar"
}

# SETUP WIZARD
# Collects every value uhm.env needs and writes the block
run_setup_wizard() {
    local cfg_ini_range cfg_end_range cfg_essid
    local cfg_unifi_user cfg_unifi_pass cfg_reload_script
    local found_url found_type

    step "pydhcp network configuration"
    # WAN_IFACE is not asked here. pysetup.sh writes it into pydhcp.env as a
    # shared key, and every script that needs it reads it from there.

    step "Hotspot IP range"
    # Two full addresses, the same shape pydhcp already uses for its own pool
    # (SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK) -- no netmask is assumed.
    echo "Range of fixed addresses handed to voucher-authorized guests"
    echo "Network: ${SERV_SUBNET}/${SERV_MASK}"
    echo "pydhcp block pool: ${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}"
    local net_base
    net_base=$(echo "$SERV_SUBNET" | cut -d'.' -f1-3)
    while true; do
        ask_ip "Hotspot range start" "${net_base}.160" cfg_ini_range
        ask_ip "Hotspot range end" "${net_base}.199" cfg_end_range
        if ! ip_le "$cfg_ini_range" "$cfg_end_range"; then
            info "Hotspot range ${cfg_ini_range}-${cfg_end_range}"
            info "Hotspot range is inverted -retry"
            continue
        fi
        if ! ip_in_network "$cfg_ini_range" "$SERV_SUBNET" "$SERV_MASK" \
           || ! ip_in_network "$cfg_end_range" "$SERV_SUBNET" "$SERV_MASK"; then
            info "Hotspot range ${cfg_ini_range}-${cfg_end_range}"
            info "Hotspot range is outside $(basename "$pydhcp_env") subnet -retry"
            continue
        fi
        if ranges_overlap "$cfg_ini_range" "$cfg_end_range" "$SERVER_IP" "$SERVER_IP"; then
            info "Hotspot range ${cfg_ini_range}-${cfg_end_range}"
            info "Invalid Hotspot range: SERVER_IP is inside -retry"
            continue
        fi
        if ranges_overlap "$cfg_ini_range" "$cfg_end_range" \
                           "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK"; then
            info "Hotspot range ${cfg_ini_range}-${cfg_end_range}"
            info "Invalid Hotspot range: overlaps pydhcp pool -retry"
            continue
        fi
        break
    done

    step "UniFi credentials"
    ask "UniFi admin username" "admin" cfg_unifi_user
    while true; do
        read -rsp " UniFi admin password: " cfg_unifi_pass; echo ""
        # load_conf rejects a value that starts or ends with a quote or a
        # space, so uhmd would abort on every start.
        if [[ "$cfg_unifi_pass" == [\"\'[:space:]]* \
           || "$cfg_unifi_pass" == *[\"\'[:space:]] ]]; then
            info "Password: no quote or space at either end -retry"
            continue
        fi
        [[ -n "$cfg_unifi_pass" ]] && break
        info "Password cannot be empty -retry"
    done

    step "UniFi controller discovery"
    # uhm only supports a single controller -- discover_unifi_controller()
    # returns on the first match found, so "more than one" cannot occur here.
    # Not found means a real UniFi-side problem (wrong credentials, controller
    # down, unexpected port); there is no sensible manual fallback to ask for.
    discovered_url=""
    discovered_type=""
    if discover_unifi_controller "$cfg_unifi_user" "$cfg_unifi_pass" "$SERVER_IP"; then
        found_url="$discovered_url"
        found_type="$discovered_type"
    else
        { err "no UniFi controller detected"; abort "UniFi controller: check credentials/service -abort"; }
    fi

    step "Hotspot SSID"
    # uhm only supports a single guest SSID tied to the UniFi captive
    # portal. Exactly one found -> use it directly, no question. None found
    # -> warn and continue; UHM_ESSID must be set before operation. More than one
    # -> the administrator must pick which one is the captive portal SSID.
    local ssid_list=()
    mapfile -t ssid_list < <(fetch_unifi_ssids "$found_url" "$found_type" "$cfg_unifi_user" "$cfg_unifi_pass")
    if (( ${#ssid_list[@]} == 1 )); then
        cfg_essid="${ssid_list[0]}"
        info "SSID detected: $cfg_essid"
    elif (( ${#ssid_list[@]} > 1 )); then
        echo "Multiple SSIDs found -- select one used by captive portal:"
        select cfg_essid in "${ssid_list[@]}"; do
            [[ -n "$cfg_essid" ]] && break
            echo "Invalid selection -- enter number of one of SSIDs listed above"
        done
        if [[ -z "$cfg_essid" ]]; then
            warn "no SSID selected from list -alert"
            warn "set UHM_ESSID in $(basename "$uhm_env") before starting uhm -alert"
        fi
    else
        cfg_essid=""
        warn "no SSID detected on UniFi controller -alert"
        warn "set UHM_ESSID in $(basename "$uhm_env") before starting uhm -alert"
    fi

    step "Dependency check"
    check_unifi_versions "$found_type"

    step "TLS certificate pin"
    local cfg_cert_pin=""
    local pin_host="${found_url#*://}"
    pin_host="${pin_host%%/*}"
    local pin_port="443"
    if [[ "$pin_host" == *:* ]]; then
        pin_port="${pin_host##*:}"
        pin_host="${pin_host%%:*}"
    fi
    cfg_cert_pin=$(openssl s_client -connect "${pin_host}:${pin_port}" -servername "$pin_host" </dev/null 2>/dev/null \
        | openssl x509 -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl enc -base64 2>/dev/null) || true
    if [[ -n "$cfg_cert_pin" ]]; then
        cfg_cert_pin="sha256//${cfg_cert_pin}"
        info "TLS certificate pinned"
    else
        warn "Could not compute TLS certificate pin"
        warn "uhmd will connect without pinning -alert"
    fi

    step "Reload script"
    echo "Script invoked after every ACL change (must exist and be executable)"
    ask "Path to reload script" "${core_dir}/uhmreload.sh" cfg_reload_script

    step "Timers"
    ask_number "Daemon poll interval in seconds (POLL_INTERVAL)" "20" cfg_poll_interval
    ask_number "Grace period before blocking unknown MACs in seconds (BLOCKDHCP_GRACE_SECONDS)" "86400" cfg_grace_seconds

    step "Managed MAC lists (optional)"
    echo "mac-*.txt files allow specific devices to bypass captive portal"
    echo "automatically (corporate laptops, APs, printers, switches, etc.)"
    echo "They bypass entirely at DHCP level (uhmleases.sh) -- daemon"
    echo "itself never authorizes them in UniFi"
    echo "Files are stored in /etc/acl/mac/ and managed manually"
    acl_prepare "$acl_base_dir" 755 644
    acl_prepare "$acl_mac_dir" 700 600
    info "Add your mac-*.txt files to /etc/acl/mac/"

    step "Writing $uhm_env"
    (
        umask 077
        local essid_answer user_answer pass_answer url_answer reload_script_answer
        # Written verbatim: uhm.env holds bare KEY=value lines, so a value
        # never needs escaping and load_conf would read any added backslash
        # as part of the value.
        essid_answer="$cfg_essid"
        user_answer="$cfg_unifi_user"
        pass_answer="$cfg_unifi_pass"
        reload_script_answer="$cfg_reload_script"
        url_answer="$found_url"

        # uhm.env holds only uhm's own keys. pydhcp's values (network,
        # ACL paths, leases) stay in pydhcp.env and are read from there at
        # runtime, so a change in that file reaches uhm without a re-install.
        : > "$uhm_env"

        # Any key pydhcp.env already defines -- pydhcp's own, or one added
        # there by another project -- is skipped
        # instead of written here too: every component reads pydhcp.env
        # first and uhm.env after, so a duplicate would let uhm.env shadow
        # the value its owner maintains.
        local uhm_block
        uhm_block=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -abort"; }

        cat > "$uhm_block" <<EOF
# =============================================================================
# UHM
# /etc/uhm/uhm.env
# =============================================================================

# UniFi
# Guest SSID
UHM_ESSID=${essid_answer}
# Unifi Access
UNIFI_CONTROLLER_URL=${url_answer}
UNIFI_USERNAME=${user_answer}
UNIFI_PASSWORD=${pass_answer}
# UniFi always creates a site named "default". If the administrator renamed it,
# edit this value to match the exact site name shown in the UniFi controller.
UNIFI_SITE=default
# Unifi type (classic or unifi-os)
UNIFI_TYPE=${found_type}
# Cert
UNIFI_CERT_PIN=${cfg_cert_pin}

# Hotspot
# Hotspot Range
UHM_INI_RANGE=${cfg_ini_range}
UHM_END_RANGE=${cfg_end_range}

# Daemon
POLL_INTERVAL=${cfg_poll_interval}
STARTUP_GRACE_SECONDS=120
RELOAD_SAFETY_INTERVAL_SECONDS=3600
BLOCKDHCP_GRACE_SECONDS=${cfg_grace_seconds}
RECOVERY_COOLDOWN_SECONDS=600

# Scripts
UHM_RELOAD=${reload_script_answer}
UHM_LEASES=${core_dir}/uhmleases.sh
# By sysadmin
UHM_IPTABLES=${uhm_iptables_dest}

# Timeouts
UHM_LEASES_TIMEOUT_SECONDS=120
UHM_IPTABLES_TIMEOUT_SECONDS=60

# API
# Changing these defaults is not recommended
UHM_API_TIMEOUT_SECONDS=30

# ACL
UHM_PATH=${hotspot_dir}
UHM_GRACE=${acl_dir}/uhm-grace.txt
UHM_MACAUTH=${acl_dir}/uhm-auth.txt
UHM_QUEUE=${acl_dir}/uhm-queue.txt

# Backup
# Changing these defaults is not recommended
BACKUP_DIR=/etc/bak/uhm
# =============================================================================
EOF

        # Filter out any key the file already defines, then insert what's
        # left right after the last existing "# ====...====" line -- never a
        # blind append, so the UHM block always lands immediately after
        # whatever content (pydhcp's own, or another project's) is already
        # there, regardless of which project wrote it or in what order.
        local env_line env_key filtered_block
        filtered_block=""
        while IFS= read -r env_line || [[ -n "$env_line" ]]; do
            if [[ "$env_line" == *=* && "$env_line" != \#* ]]; then
                env_key="${env_line%%=*}"
                if grep -q "^${env_key}=" "$pydhcp_env"; then
                    info "$env_key already set in $(basename "$pydhcp_env") -skip"
                    continue
                fi
            fi
            filtered_block+="${env_line}"$'\n'
        done < "$uhm_block"
        rm -f "$uhm_block"

        insert_after_last_delimiter "$uhm_env" "$filtered_block"
    )
    chown root:root "$uhm_env"
    chmod 600 "$uhm_env"
    info "Config saved to $uhm_env (mode 600)"
}

# FILESYSTEM LAYOUT
# Creates the directories and deploys the project files
deploy_directories() {
    mkdir -p "$hotspot_dir" "$core_dir" "$tools_dir" "$acl_dir"
    chmod 700 "$hotspot_dir"
    chmod 700 "$core_dir"
    chmod 700 "$tools_dir"
    chmod 700 "$acl_dir"
    info "Directories created"
}

deploy_acl_files() {
    # Own data files (uhm-auth.txt, uhm-queue.txt, uhm-grace.txt) --
    # repo ships them as empty templates. Copy once and never overwrite an
    # existing one, on install or update, so real ACL/voucher/queue data
    # already on disk is never touched.
    #
    # $1: "warn" logs a WARNING per missing file before creating it empty
    # (used by --update, where a missing ACL file means a partial/broken
    # install and is worth flagging); default is quiet (used by a fresh
    # install, where creating them is the expected, normal case).
    local report_mode="${1:-quiet}"
    local repo_file dest_path
    for repo_file in "${repo_acl}/"*.txt; do
        dest_path="${acl_dir}/$(basename "$repo_file")"
        if [[ -f "$dest_path" ]]; then
            continue
        fi
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$dest_path") missing -alert"
        install -m 600 -o root -g root "$repo_file" "$dest_path"
    done
    info "ACL data files present in ${acl_dir}"
}

deploy_scripts() {
    install -m 644 -o root -g root "${repo_tools}/uhmenv.sh" "${tools_dir}/uhmenv.sh"
    info "updated tools/uhmenv.sh"
    install -m 755 -o root -g root "$repo_uhmd" "${core_dir}/uhmd.sh"
    info "updated core/uhmd.sh"
    install -m 755 -o root -g root "${repo_core}/uhmreload.sh" "${core_dir}/uhmreload.sh"
    info "updated core/uhmreload.sh"
    install -m 755 -o root -g root "${repo_core}/uhmleases.sh" "${core_dir}/uhmleases.sh"
    info "updated core/uhmleases.sh"
    # uhmwatch.sh lives under core/ (not tools/) because it is mandatory,
    # not an optional utility -- deployed explicitly here for that reason,
    # same as the other three core scripts above.
    install -m 755 -o root -g root "${repo_core}/uhmwatch.sh" "${core_dir}/uhmwatch.sh"
    info "updated core/uhmwatch.sh"
    local repo_file
    for repo_file in "${repo_tools}/"*.sh; do
        # uhmiptables.sh is the administrator's own file once customized, so it
        # is deployed by deploy_uhmiptables() below (only when absent) instead
        # of being overwritten here on every run.
        case "$(basename "$repo_file")" in
            uhmiptables.sh|uhmenv.sh) continue ;;
        esac
        install -m 755 -o root -g root "$repo_file" "${tools_dir}/"
        info "updated tools/$(basename "$repo_file")"
    done
}

deploy_uhmiptables() {
    # The reference ruleset is not customized data: it is deployed on every
    # run, before the placeholder guard below, so --update refreshes it and a
    # host installed before it existed also gets it.
    install -m 644 -o root -g root "${repo_tools}/uhmiptables_example.txt" \
        "${tools_dir}/uhmiptables_example.txt"
    info "Reference: ${tools_dir}/uhmiptables_example.txt"

    if [[ -f "$uhm_iptables_dest" ]]; then
        info "uhmiptables.sh already exists -skip"
        return 0
    fi
    install -m 750 -o root -g root "${repo_tools}/uhmiptables.sh" "$uhm_iptables_dest"
    info "Placeholder deployed to $uhm_iptables_dest"
}

deploy_web_sudo_rule() (
    local sudoers_tmp
    sudoers_tmp=$(mktemp "${sudoers_dest}.XXXXXX") || {
        warn "uhmweb: cannot prepare sudo rule -alert"
        exit 1
    }
    trap 'rm -f -- "$sudoers_tmp"' EXIT

    if ! install -m 440 -o root -g root \
        "${repo_uhmweb}/uhmweb.sudoers" "$sudoers_tmp"; then
        warn "uhmweb: cannot prepare sudo rule -alert"
        exit 1
    fi
    if ! visudo -c -f "$sudoers_tmp" &>/dev/null; then
        warn "uhmweb: sudo check failed; not installed -alert"
        exit 1
    fi
    if ! mv -fT -- "$sudoers_tmp" "$sudoers_dest"; then
        warn "uhmweb: cannot install sudo rule -alert"
        exit 1
    fi
)

# Deploys the web interface: pages under $web_root, the vhost, the sudo
# rule that lets www-data reach uhmtool.sh, and the Listen directives.
# uhmtool.sh itself is already deployed by deploy_scripts().
install_web() {
    local dep_pkg

    for dep_pkg in apache2 libapache2-mod-php; do
        if ! dpkg -s "$dep_pkg" &>/dev/null; then
            abort "'$dep_pkg' is not installed -abort"
        fi
    done

    mkdir -p "$web_root"
    cp -a "${repo_web}/." "$web_root/"
    chown -R root:root "$web_root"
    find "$web_root" -type d -exec chmod 755 {} +
    find "$web_root" -type f -exec chmod 644 {} +

    install -m 644 -o root -g root "${repo_uhmweb}/uhmweb.conf" "$vhost_dest"

    deploy_web_sudo_rule || return 1

    [ -f "${apache_ports}.bak" ] || cp -f "$apache_ports" "${apache_ports}.bak" &>/dev/null || true
    sed -i -E "/^Listen [^[:space:]]*:${web_port}\$/d; /^Listen ${web_port}\$/d" "$apache_ports"
    echo "Listen 127.0.0.1:${web_port}" >> "$apache_ports"

    a2enmod headers &>/dev/null || true
    a2ensite uhmweb &>/dev/null || true

    if ! apache2ctl configtest &>/dev/null; then
        warn "apache configtest failed, not reloaded"
        warn "check $(basename "$vhost_dest"), run: systemctl reload apache2 -alert"
        return 1
    fi
    if ! systemctl reload apache2 &>/dev/null; then
        warn "cannot reload apache2; web setup incomplete -alert"
        return 1
    fi

    info "Web interface configured at http://127.0.0.1:${web_port}/"
    return 0
}

# Deploys the WPAD/PAC infrastructure: an apache2 virtualhost on WPAD_PORT,
# the PAC file under $wpad_root, and the WPAD_ENABLED flip in pydhcp.env.
#
# pydhcp decides whether to announce DHCP option 252 by probing the PAC URL,
# in pysetup.sh, and re-checks it on every reload, in pyleases.sh. It never
# serves the PAC itself, so on a pydhcp-first install that probe fails and
# WPAD_ENABLED lands as false. uhm is the component that can serve it, so
# uhm is the one that asks.
install_wpad() {
    local wpad_port squid_port pac_proxy
    wpad_port="${WPAD_PORT:-18100}"
    pac_proxy=""

    if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
        info "WPAD already enabled in $pydhcp_env -skip"
        return 0
    fi

    echo "WPAD serves a proxy auto-config file over HTTP, and pydhcp"
    echo "announces its URL as DHCP option 252. It is off because nothing"
    echo "was serving a PAC file on port ${wpad_port} when pydhcp was"
    echo "installed. Enabling it adds an apache2 virtualhost on that port"
    confirm "WPAD is disabled. Enable it?" "n" || return 0

    # The PAC is built from what is actually running. A proxy line only makes
    # sense if squid answers, otherwise a client honouring option 252 waits
    # for a port nothing listens on before falling back to DIRECT.
    # Three server package names exist: squid is the GnuTLS flavour,
    # squid-openssl the OpenSSL one gateproxy installs, squid3 the legacy name.
    if dpkg -s squid &>/dev/null || dpkg -s squid-openssl &>/dev/null \
       || dpkg -s squid3 &>/dev/null; then
        squid_port=$(awk '$1=="http_port"{print $2; exit}' /etc/squid/squid.conf 2>/dev/null)
        squid_port="${squid_port##*:}"
        if [[ "$squid_port" =~ $UH_UINT ]] \
           && [ -n "$(ss -lnH -t "sport = :$squid_port" 2>/dev/null)" ]; then
            pac_proxy="PROXY ${SERVER_IP}:${squid_port}; DIRECT"
            info "squid answering on port ${squid_port}, PAC will use it"
        else
            warn "squid not listening, PAC returns DIRECT -alert"
        fi
    else
        info "no squid on this host, PAC returns DIRECT"
    fi
    [ -n "$pac_proxy" ] || pac_proxy="DIRECT"

    # Written here instead of copied from the repo: the LAN network, mask and
    # the proxy line depend on values only known at install time, so a shipped
    # template would be rewritten line by line anyway.
    install -d -m 755 -o www-data -g www-data "$wpad_root"
    cat > "${wpad_root}/wpad.pac" <<EOF
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) || shExpMatch(host, "localhost"))
        return "DIRECT";
    if (isInNet(host, "${SERV_SUBNET}", "${SERV_MASK}") || shExpMatch(host, "127.*"))
        return "DIRECT";
    return "${pac_proxy}";
}
EOF
    chown www-data:www-data "${wpad_root}/wpad.pac"
    chmod 644 "${wpad_root}/wpad.pac"

    install -m 644 -o root -g root "${repo_wpad}/wpad.conf" "$wpad_vhost_dest"
    sed -i "s|\*:18100|*:${wpad_port}|" "$wpad_vhost_dest"

    [ -f "${apache_ports}.bak" ] || cp -f "$apache_ports" "${apache_ports}.bak" &>/dev/null || true
    sed -i -E "/^Listen [^[:space:]]*:${wpad_port}\$/d; /^Listen ${wpad_port}\$/d" "$apache_ports"
    echo "Listen ${SERVER_IP}:${wpad_port}" >> "$apache_ports"

    a2ensite wpad &>/dev/null || true
    if ! apache2ctl configtest &>/dev/null; then
        warn "apache configtest failed, WPAD not enabled -alert"
        return 1
    fi
    systemctl reload apache2 &>/dev/null || true

    # pyleases.sh re-probes this URL on every reload. If it does not answer,
    # option 252 stays commented whatever the key says, so the flip below is
    # only written once the PAC is proven reachable.
    if ! curl -fsS --noproxy '*' --max-time 5 -o /dev/null \
         "http://${SERVER_IP}:${wpad_port}/wpad.pac"; then
        warn "PAC unavailable; WPAD_ENABLED unchanged -alert"
        return 1
    fi

    if grep -q '^WPAD_ENABLED=' "$pydhcp_env"; then
        sed -i 's|^WPAD_ENABLED=.*|WPAD_ENABLED=true|' "$pydhcp_env"
    else
        echo "WPAD_ENABLED=true" >> "$pydhcp_env"
    fi
    info "WPAD enabled: http://${SERVER_IP}:${wpad_port}/wpad.pac"
    return 0
}

remove_wpad() {
    local wpad_port
    # do_uninstall never loads pydhcp.env, so the port has to be read here or
    # the Listen line below would be deleted by its default value alone.
    load_uhm_env "$pydhcp_env" "$env_keys" line || true
    wpad_port="${WPAD_PORT:-18100}"
    a2dissite wpad &>/dev/null || true
    rm -f "$wpad_vhost_dest"
    rm -rf "$wpad_root"
    if [[ -f "$apache_ports" ]]; then
        sed -i -E "/^Listen [^[:space:]]*:${wpad_port}\$/d; /^Listen ${wpad_port}\$/d" "$apache_ports"
    fi
    if [[ -f "$pydhcp_env" ]] && grep -q '^WPAD_ENABLED=true' "$pydhcp_env"; then
        sed -i 's|^WPAD_ENABLED=.*|WPAD_ENABLED=false|' "$pydhcp_env"
    fi
}

remove_web() {
    if [[ -f "$vhost_dest" ]]; then
        a2dissite uhmweb &>/dev/null || true
        rm -f "$vhost_dest"
        info "Removed $vhost_dest"
    else
        info "No vhost found"
    fi

    if [[ -f "$apache_ports" ]]; then
        sed -i -E "/^Listen [^[:space:]]*:${web_port}\$/d; /^Listen ${web_port}\$/d" "$apache_ports"
        info "Listen directives for ${web_port} removed"
    fi

    rm -f "$sudoers_dest"
    rm -rf "$web_root"
    info "Removed $web_root and $sudoers_dest"

    if dpkg -s apache2 &>/dev/null && apache2ctl configtest &>/dev/null; then
        systemctl reload apache2 &>/dev/null || true
    fi
}

# APACHE LOGROTATE
# Apache keeps 14 rotations by default; the projects keep 7
set_apache_logrotate() {
    local apache_rotate="/etc/logrotate.d/apache2"
    [[ -f "$apache_rotate" ]] || { warn "apache2 has no logrotate file -alert"; return 0; }
    if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$apache_rotate"; then
        info "${apache_rotate#/etc/} already rotate 7 -skip"
        return 0
    fi
    cp -f "$apache_rotate"{,.bak} &>/dev/null || true
    sed -i -E 's/^([[:space:]]*)rotate[[:space:]]+[0-9]+$/\1rotate 7/' "$apache_rotate"
    if grep -qE '^[[:space:]]*rotate[[:space:]]+7$' "$apache_rotate"; then
        info "${apache_rotate#/etc/} set to rotate 7 -fixed"
    else
        warn "cannot set rotate 7 in ${apache_rotate#/etc/} -alert"
    fi
}

install_logrotate() {
    # $1: "warn" logs a WARNING before creating a missing logrotate config
    # (used by --update, where this should already exist); default is quiet
    # (used by a fresh install, where creating it is the expected case).
    local report_mode="${1:-quiet}"

    # Ensure the shared log file exists with correct permissions from install
    # time, instead of leaving it to whichever of uhmd.sh/uhmreload.sh/
    # uhmleases.sh happens to create it first (tee -a defaults) or waiting for
    # logrotate's first cycle (create 640 root adm only applies on rotation).
    if [[ ! -f "$uhm_log_file" ]]; then
        touch "$uhm_log_file" || return 1
    fi
    chmod 640 "$uhm_log_file" || return 1
    chown root:adm "$uhm_log_file" 2>/dev/null || chown root:root "$uhm_log_file" || return 1

    if [[ ! -f "$logrotate_file" && "$report_mode" == warn ]]; then
        warn "$(basename "$logrotate_file") missing -alert"
    fi
    cat > "$logrotate_file" <<EOF
${uhm_log_file} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    [ "$?" -eq 0 ] || return 1
    chown root:root "$logrotate_file" || return 1
    chmod 644 "$logrotate_file" || return 1
    info "updated $logrotate_file"
    set_apache_logrotate
}

final_sanity_check() {
    step "Sanity check"
    local issue_list=0

    if [[ ! -x "$uhm_iptables_dest" ]]; then
        warn "uhmiptables.sh is missing or not executable"
        warn "ACL changes will not reach firewall -alert"
        (( issue_list++ )) || true
    fi

    if (( issue_list > 0 )); then
        warn "${issue_list} issue(s) need attention, uhm not fully functional -alert"
    fi
}

install_systemd_service() {
    install -m 644 -o root -g root "$repo_service" "$service_dest"
    systemctl daemon-reload
    systemctl enable uhmd
    if systemctl restart uhmd; then
        info "uhmd enabled and started"
    else
        warn "Could not start uhmd"
        warn "check it with: systemctl status uhmd -alert"
    fi
}

# Installs pydhcp, uhm's DHCP backend, by running its own installer.
#
# pysetup.sh is run interactively, not driven with expect: it owns the network
# questions (interface, IPv4 address, pool, DNS, cleanup interval) and writes them
# to pydhcp.env, which every component then reads. Asking them here too would
# duplicate both the prompts and their validation.
install_pydhcp() {
    local pydhcp_path="${script_dir}/pydhcp"

    if systemctl is-active --quiet pydhcpd 2>/dev/null; then
        info "pydhcpd already active -skip"
        return 0
    fi

    echo ""
    echo "uhm needs pydhcp as its DHCP backend. Its installer runs next and"
    echo "asks for network values uhm reads afterwards from pydhcp.env"
    echo ""

    if [[ ! -d "$pydhcp_path" ]]; then
        git clone https://github.com/maravento/pydhcp "$pydhcp_path" \
            || { err "cannot clone pydhcp"; abort "check network access, then re-run -abort"; }
    fi

    [[ -r "${pydhcp_path}/pysetup.sh" ]] \
        || { err "pysetup.sh not found in $pydhcp_path"; abort "remove that directory and re-run -abort"; }

    ( cd "$pydhcp_path" && PYDHCP_LAN_IFACE="$lan_iface" PYDHCP_SERVER_IP="$lan_ip" bash pysetup.sh ) \
        || { err "pydhcp install failed"; abort "see ${pydhcp_path}/pysetup.log -abort"; }

    systemctl is-active --quiet pydhcpd 2>/dev/null \
        || { err "pydhcpd is not active after install"; abort "check it with: systemctl status pydhcpd -abort"; }
    info "pydhcp installed, pydhcpd active"
}

# Installs apache2, which uhm needs for the web panel and for WPAD. Unlike
# apt_deps, these two are installed instead of merely verified: they are
# uhm's own serving layer, not a tool it calls.
install_apache2() {
    local dep_pkg missing_pkgs=()

    for dep_pkg in apache2 libapache2-mod-php; do
        dpkg -s "$dep_pkg" &>/dev/null || missing_pkgs+=("$dep_pkg")
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        info "apache2 already present"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { err "cannot install ${missing_pkgs[*]}"; abort "install them with apt, then re-run -abort"; }
    systemctl enable apache2 &>/dev/null || true
    info "Installed: ${missing_pkgs[*]}"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

do_install() {
    check_apt_deps
    check_internet

    if [[ -d "$hotspot_dir" ]]; then
        err "uhm is already installed at ${hotspot_dir}"
        abort "use --update to upgrade, or --uninstall first -abort"
    fi

    trap 'install_exit_code=$?; trap - EXIT; (( install_exit_code != 0 )) && { warn "Installation failed, rolling back changes -alert"; perform_remove; }' EXIT

    step "Preflight"
    check_repo_files
    check_preinstalled
    check_port tcp 4048 "web interface"

    step "Network interface"
    choose_lan_interface
    lan_iface="$lan_iface_answer"
    read_lan_ipv4 "$lan_iface"
    lan_ip="${lan_cidr_answer%/*}"
    info "LAN interface: $lan_iface ($lan_cidr_answer)"

    step "UniFi dependency"
    if dpkg -s unifi &>/dev/null || [[ -f /var/lib/uosserver/server.conf ]]; then
        info "UniFi already installed"
    else
        local unifi_reply unifi_choice unifi_action
        read -rp " UniFi is not installed. Install it now? (y/N) " unifi_reply
        case "$unifi_reply" in
            [Yy]*) ;;
            *) abort "UniFi is required, install it then re-run -abort" ;;
        esac

        echo "1) UniFi Network Application"
        echo "2) UniFi OS Server"
        read -rp " Select an option (1-2): " unifi_choice
        case "$unifi_choice" in
            1) unifi_action="network" ;;
            2) unifi_action="osserver" ;;
            *) abort "invalid option -abort" ;;
        esac

        local unifisetup_tmp
        unifisetup_tmp=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -abort"; }
        if ! curl -fsSL "https://raw.githubusercontent.com/maravento/vault/refs/heads/master/scripts/bash/unifisetup.sh" -o "$unifisetup_tmp"; then
            rm -f "$unifisetup_tmp"
            { err "failed to download unifisetup.sh"; abort "check network access to GitHub -abort"; }
        fi
        log "SAVED: unifisetup.sh"
        chmod +x "$unifisetup_tmp"
        local unifi_expect
        unifi_expect=$(mktemp) || abort "cannot create temp file in /tmp -abort"
        cat > "$unifi_expect" <<EOF
set timeout -1
spawn bash "$unifisetup_tmp" --install "$unifi_action"
expect {
    -re {\[([0-9]+)\][ \t]+$lan_iface[ \t(]} {
        send "\$expect_out(1,string)\r"
        exp_continue
    }
    eof {}
}
catch wait result
exit [lindex \$result 3]
EOF
        expect -f "$unifi_expect" || true
        rm -f "$unifi_expect"
        rm -f "$unifisetup_tmp"

        if ! dpkg -s unifi &>/dev/null && [[ ! -f /var/lib/uosserver/server.conf ]]; then
            abort "UniFi install incomplete; see unifisetup.log -abort"
        fi

        echo ""
        echo "Enter that URL and set up your local account"
        read -n1 -rsp " Press any key once you've done that, to continue... "
        echo ""
    fi

    step "pydhcp"
    install_pydhcp

    step "apache2"
    install_apache2

    # Both run here, after pydhcp: detect_dhcp_backend needs pydhcpd active
    # and load_pydhcp_conf needs pydhcp.env written, and neither exists on a
    # host where uhm installs pydhcp itself.
    detect_dhcp_backend
    load_pydhcp_conf

    step "Filesystem layout"
    deploy_directories
    deploy_scripts
    deploy_acl_files
    deploy_uhmiptables

    run_setup_wizard

    step "Logrotate"
    install_logrotate

    step "Systemd service"
    install_systemd_service

    step "Project cron"
    register_project_cron || abort "cannot write uhm cron -abort"

    step "Optional components"
    if confirm "Install uhmalert (ntfy push notifications on connectivity loss)?" "n"; then
        bash "${tools_dir}/uhmalert.sh" --install
    fi
    if confirm "Install the web interface (log viewer, ACL editor, reports)?" "n"; then
        install_web || true
    fi
    install_wpad || true

    final_sanity_check

    trap - EXIT

    echo "uhm installed"
    echo ""
    echo "Next steps:"
    echo "1. Optional: ${uhm_iptables_dest} is a placeholder"
    echo "   (routing + NAT). For full enforcement, copy"
    echo "   ${tools_dir}/uhmiptables_example.txt over it,"
    echo "   then read it through and adapt it. See its header"
    echo "2. Check service: systemctl status uhmd"
    echo "3. Check logs: tail -f ${uhm_log_file}"
    echo ""
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

do_update() {
    check_apt_deps
    detect_dhcp_backend
    [ -d "$hotspot_dir" ] && [ -f "$core_dir/uhmd.sh" ] || abort "uhm is not installed -abort"
    update_reset /etc/cron.d/uhm
    local file mode
    for file in uhmd.sh uhmreload.sh uhmleases.sh uhmwatch.sh; do
        update_file "$repo_core/$file" "$core_dir/$file" 755 root:root
    done
    for file in uhmenv.sh uhmtool.sh uhmalert.sh uhmunifi.sh uhmbk.sh uhmiptables_example.txt; do
        mode=755
        case "$file" in uhmenv.sh|uhmiptables_example.txt) mode=644 ;; esac
        update_file "$repo_tools/$file" "$tools_dir/$file" "$mode" root:root
    done
    if [ ! -e "$uhm_iptables_dest" ]; then
        update_file "$repo_tools/uhmiptables.sh" "$uhm_iptables_dest" 750 root:root
    fi
    if [ -d "$web_root" ]; then
        for file in index.html api.php aclview/index.php logview/index.php toolview/index.php; do
            update_file "$repo_web/$file" "$web_root/$file" 644 root:root
        done
    fi
    update_target "$acl_dir" d700 root:root
    local acl_name
    for acl_name in uhm-auth.txt uhm-queue.txt uhm-grace.txt; do
        update_target "$acl_dir/$acl_name" 600
        if [ ! -e "$acl_dir/$acl_name" ]; then
            update_file "$repo_acl/$acl_name" "$acl_dir/$acl_name" 600 root:root
        fi
    done
    update_file "$repo_service" "$service_dest" 644 root:root
    update_target "$uhm_log_file" 640 root:adm
    update_target "$logrotate_file"
    update_target "$update_cron_file"
    update_target "${update_cron_file}.lock" 600
    update_preflight
    update_backup "$uhmbk_script"
    update_begin
    update_stop_service uhmd
    if [ -d "$web_root" ]; then update_stop_service apache2; fi
    if [ -f /etc/systemd/system/uhmalert.service ]; then update_stop_service uhmalert; fi
    update_wait_jobs
    update_apply
    acl_prepare "$acl_dir" 700 600 "$acl_dir/uhm-auth.txt" "$acl_dir/uhm-queue.txt" "$acl_dir/uhm-grace.txt"
    install_logrotate warn || update_error "cannot configure uhm log rotation"
    systemctl daemon-reload || update_error "cannot reload systemd configuration"
    register_project_cron \
        || update_error "cannot regenerate uhm cron"
    update_finish
    info "update complete"
}

# ------------------------------------------------------------------------------
# REMOVE
# ------------------------------------------------------------------------------

do_uninstall() {
    echo ""
    echo "This will permanently remove, without asking again:"
    echo "- uhmd.service: stopped, disabled, unit file removed"
    echo "- cron entries pointing to ${hotspot_dir}/core/uhmreload.sh"
    echo "- uhmwatch cron entry"
    echo "- uhmalert.service if installed"
    echo "- web panel, its vhost and sudo rule, if installed"
    echo "- ${logrotate_file}"
    echo "- ${hotspot_dir}"
    echo "including uhm.env, ACL lists and YOUR uhmiptables.sh"
    echo "A backup is taken with ${uhmbk_script} before anything is removed"
    echo "- ${uhm_log_file}, rotated logs"
    echo "- uhmunifi.log and reload failure traces"
    echo "/etc/bak is NOT touched"
    echo "Package dependencies"
    echo "(curl, jq, iptables, ipset, etc.) are NOT removed"
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" || {
        info "Aborted by user"
        log "EVENT: uhmsetup done"
        exit 0
    }

    local confirm_answer
    echo ""
    echo "Final confirmation required"
    echo "Type word YES (uppercase) to remove uhm:"
    echo ""
    read -rp " > " confirm_answer
    if [[ "$confirm_answer" != "YES" ]]; then
        info "Aborted by user"
        log "EVENT: uhmsetup done"
        exit 0
    fi
    echo ""

    if [[ -x "$uhmbk_script" ]]; then
        if "$uhmbk_script"; then
            info "backup taken with uhmbk.sh"
        else
            abort "uhmbk.sh: backup failed -abort"
        fi
    else
        abort "uhmbk.sh: missing or not executable -abort"
    fi

    perform_remove
}

perform_remove() {
    # Everything below is unconditional -- the two confirmations above,
    # with the full list of what gets removed, are the only gate. Uninstall
    # means removing everything (except package dependencies), not a
    # step-by-step negotiation.

    # Systemd service
    step "Systemd service"
    if systemctl is-active --quiet uhmd 2>/dev/null || systemctl is-enabled --quiet uhmd 2>/dev/null; then
        systemctl disable --now uhmd 2>/dev/null || true
        info "uhmd.service disabled and stopped"
    fi
    if [[ -f "$service_dest" ]]; then
        rm -f "$service_dest"
        systemctl daemon-reload
        info "Service file removed"
    fi

    # Cron entries
    step "Cron"
    rm -f /etc/cron.d/uhm /etc/cron.d/uhm.update-disabled
    info "Cron entries removed"

    # uhmalert (optional component)
    step "uhmalert"
    if [[ -f /etc/systemd/system/uhmalert.service ]]; then
        systemctl disable --now uhmalert 2>/dev/null || true
        rm -f /etc/systemd/system/uhmalert.service
        systemctl daemon-reload
        info "uhmalert.service removed"
    else
        info "uhmalert.service not installed"
    fi

    # uhmwatch (mandatory component, but --uninstall uninstalls everything
    # regardless -- defensive check in case it was manually uninstalled)
    step "uhmwatch"
    # Web interface (optional component)
    step "Web interface"
    remove_web

    # WPAD (optional component)
    step "WPAD"
    remove_wpad

    # Logrotate
    step "Logrotate"
    if [[ -f "$logrotate_file" ]]; then
        rm -f "$logrotate_file"
        info "Removed $logrotate_file"
    else
        info "No logrotate config found"
    fi

    # uhmbk cron entry
    step "uhmbk"
    if [[ -x "$uhmbk_script" ]]; then
        "$uhmbk_script" --uninstall || true
    fi

    # /etc/uhm
    step "$hotspot_dir"
    if [[ -d "$hotspot_dir" ]]; then
        # Everything under hotspot_dir goes, including uhm.env, the ACL
        # lists and uhmiptables.sh: uninstalling means removing the project.
        # uhmbk.sh keeps a copy in /etc/bak, out of reach of this removal.
        rm -rf "$hotspot_dir"
        info "Removed $hotspot_dir"
    else
        info "$hotspot_dir does not exist"
    fi

    # Logs
    step "Logs"
    local extra_logs=() check_log
    for check_log in /var/log/uhmunifi.log /var/log/uhmleases-failure.trace /var/log/uhmiptables-failure.trace; do
        [[ -f "$check_log" ]] && extra_logs+=("$check_log")
    done
    if compgen -G "${uhm_log_file}*" >/dev/null || [[ ${#extra_logs[@]} -gt 0 ]]; then
        rm -f -- "${uhm_log_file}" "${uhm_log_file}".* "${extra_logs[@]+"${extra_logs[@]}"}"
        info "Logs removed"
    else
        info "No log files found"
    fi

    echo "Uninstall complete"
    echo "IMPORTANT: Firewall rules and ipsets (macgrace, machotspot)"
    echo "were NOT touched. Flush them manually if needed:"
    echo "sudo ipset destroy macgrace 2>/dev/null"
    echo "sudo ipset destroy machotspot 2>/dev/null"
    echo "# then flush related iptables rules"
    echo ""
}

# ------------------------------------------------------------------------------
# STATUS
# ------------------------------------------------------------------------------

do_status() {
    echo ""
    echo "=== uhm Services ==="
    local unit
    for unit in uhmd uhmalert; do
        if [[ ! -f "/etc/systemd/system/${unit}.service" ]]; then
            echo "$unit: NOT INSTALLED"
        elif systemctl is-active --quiet "$unit"; then
            echo "$unit: RUNNING"
        else
            echo "$unit: STOPPED"
        fi
    done

    echo ""
    echo "=== Panel Port ==="
    if ss -tln 2>/dev/null | grep -qE ":${web_port}[[:space:]]"; then
        echo ":$web_port OPEN"
    else
        echo ":$web_port CLOSED"
    fi

    echo ""
    echo "=== Config ==="
    if [[ -f "$uhm_env" ]]; then
        echo "$uhm_env present"
    else
        echo "$uhm_env not found"
    fi

    echo ""
    echo "=== Log ==="
    if [[ -f "$uhm_log_file" ]]; then
        echo "$uhm_log_file (last 10):"
        tail -10 "$uhm_log_file" | sed 's/^/ /'
    else
        echo "$uhm_log_file not found"
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

# Interactive menu shown when the script runs without arguments
show_menu() {
    local menu_option
    while true; do
        echo ""
        echo "uhm installer"
        echo "1) Install"
        echo "2) Update"
        echo "3) Uninstall"
        echo "4) Status"
        echo "5) Exit"
        echo ""
        read -p "Select option [5]: " menu_option
        menu_option="${menu_option:-5}"
        case "$menu_option" in
            1) do_install; break ;;
            2) do_update; break ;;
            3) do_uninstall; break ;;
            4) do_status; break ;;
            5) break ;;
            *) info "invalid option -retry" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
source "$repo_tools/uhmenv.sh"
env_keys='SERVER_IP SERV_MASK SERV_SUBNET SERV_BROADCAST SERV_DNS SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK WPAD_ENABLED WPAD_PORT'

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "EVENT: uhmsetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    --status) do_status ;;
    "") show_menu ;;
    *)
        err "invalid option -abort"
        usage
        exit 1
        ;;
esac

log "EVENT: uhmsetup done"
