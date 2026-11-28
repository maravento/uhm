#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmsetup -- uhm installer / updater
# FILE: uhmsetup.sh
#
# USAGE:
# COMMAND                            ACTION
# sudo bash uhmsetup.sh --install    Install (aborts if already installed)
# sudo bash uhmsetup.sh --update     Update scripts only (keeps config/ACLs)
# sudo bash uhmsetup.sh --uninstall  Uninstall
# sudo bash uhmsetup.sh --status     Report services, port, config and log
# sudo bash uhmsetup.sh              Interactive menu
# sudo bash uhmsetup.sh -h           Usage
# sudo bash uhmsetup.sh --help       Usage
#
# LOG: uhmsetup.log, in the directory containing this script
#
################################################################################

set -euo pipefail

# root check
if [[ "$(id -u)" != "0" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

install_php_hardening() (
    local conf_dir="${1%/*}/conf.d" target staged
    [ -d "$conf_dir" ] || return 1
    target="$conf_dir/99-project-php-hardening.ini"
    staged=$(mktemp -- "$target.XXXXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    cat > "$staged" <<'PHP_HARDENING' || return 1
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
allow_url_include = Off
enable_dl = Off
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
session.upload_progress.enabled = 0
file_uploads = Off
upload_max_filesize = 2M
post_max_size = 8M
max_file_uploads = 20
PHP_HARDENING
    [ ! -L "$target" ] || return 1
    if [ -e "$target" ]; then
        [ -f "$target" ] || return 1
        if cmp -s -- "$staged" "$target" && [ "$(stat -c %a -- "$target")" = 644 ]; then
            return 0
        fi
        [ -f "$target.bak" ] || cp -p -- "$target" "$target.bak" || return 1
    fi
    chmod 0644 -- "$staged" && mv -fT -- "$staged" "$target"
)

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

# Help exits before logging
case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
esac

check_requirements() {
    local network_command
    for network_command in ip timeout awk python3; do
        command -v "$network_command" >/dev/null 2>&1 \
            || abort "network command '$network_command' missing -abort"
    done
    case "$1" in
        install)
            check_repo_files
            if [[ -d "$hotspot_dir" ]]; then
                abort "uhm installed; use --update | --uninstall -abort"
            fi
            check_port tcp 4048 "web interface"
            check_ipv4_interfaces
            check_internet
            lan_change_requested=false
            check_preinstalled
            select_network_interfaces
            read_lan_ipv4 "$lan_iface" "${UHM_SERVER_IP:-}"
            if [[ -t 0 && -z "${UHM_LAN_IFACE:-}${UHM_SERVER_IP:-}" ]]; then
                select_setup_lan_settings "$lan_iface" || exit 1
            else
                check_static_lan "$lan_iface" "${lan_cidr_answer%/*}"
            fi
            return 0
            ;;
        update)
            detect_dhcp_backend
            [ -d "$hotspot_dir" ] && [ -f "$core_dir/uhmd.sh" ] \
                || abort "uhm is not installed -abort"
            local INTERFACESv4="" SERVER_IP="" WAN_IFACE=""
            load_uhm_env "$pydhcp_env" 'INTERFACESv4 SERVER_IP' line
            load_uhm_env "$uhm_env" 'WAN_IFACE' line
            local network_key
            for network_key in WAN_IFACE INTERFACESv4 SERVER_IP; do
                [ -n "${!network_key:-}" ] \
                    || abort "$network_key not set -abort"
            done
            choose_lan_interface "$WAN_IFACE" "" WAN
            choose_lan_interface "$INTERFACESv4" "$WAN_IFACE" LAN
            check_static_lan "$INTERFACESv4" "$SERVER_IP"
            ;;
    esac
    check_ipv4_interfaces
    local package
    for package in "${apt_deps[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
            | grep -q "ok installed"; then
            check_internet
            break
        fi
    done
}

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

# check ipv4 interfaces
list_ifaces() {
    ip -br link show 2>/dev/null | awk '$1 != "lo" {sub(/@.*/, "", $1); printf "%s %s\n", $1, ($2 == "UP") ? "UP" : "DOWN"}'
}

list_ipv4_ifaces() {
    local iface state
    while read -r iface state; do
        [ "$state" = UP ] || continue
        if ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
            | awk '$4 != "" {found=1} END {exit !found}'; then
            printf '%s\n' "$iface"
        fi
    done < <(list_ifaces)
}

check_ipv4_interfaces() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if [ -n "$(list_ipv4_ifaces)" ]; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for an interface with IPv4..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no interface with IPv4 -abort"
    exit 1
}

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

check_static_lan() {
    case "$(lan_ipv4_condition "$1" "$2")" in
        static) return 0 ;;
        dynamic)
            log "ERROR: [1/2] LAN $1: $2 uses DHCP"
            log "ERROR: [2/2] configure a static LAN IPv4 -abort"
            ;;
        *)
            log "ERROR: [1/2] LAN $1: $2"
            log "ERROR: [2/2] cannot verify persistent static IPv4 -abort"
            ;;
    esac
    exit 1
}

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hotspot_dir="/etc/uhm"
core_dir="${hotspot_dir}/core"
tools_dir="${hotspot_dir}/tools"
acl_dir="${hotspot_dir}/acl"
acl_base_dir="/etc/acl"
acl_mac_dir="$acl_base_dir"
uhm_env="${hotspot_dir}/uhm.env"
pydhcp_env="/etc/pydhcp/pydhcp.env"
uhmbk_script="${tools_dir}/uhmbk.sh"
log_file="${script_dir}/uhmsetup.log"
{ > "$log_file"; } 2>/dev/null || true
uhm_log_file="/var/log/uhm.log"
logrotate_file="/etc/logrotate.d/uhm"
fw_dir="${hotspot_dir}/fw"
uhm_iptables_dest="${fw_dir}/uhmiptables.sh"
fw_conf_dest="${fw_dir}/toggles.conf"
service_dest="/etc/systemd/system/uhmd.service"
web_root="/var/www/uhm"
web_port="4048"
vhost_dest="/etc/apache2/sites-available/uhmweb.conf"
sudoers_dest="/etc/sudoers.d/uhmweb"
apache_ports="/etc/apache2/ports.conf"

# Repo file expectations (relative to this script)
repo_core="${script_dir}/core"
repo_tools="${script_dir}/tools"
repo_acl="${script_dir}/acl"
repo_uhmd="${repo_core}/uhmd.sh"
repo_web="${script_dir}/web"
repo_config="${script_dir}/config"
repo_uhmweb="${repo_config}/web"
repo_fw_conf="${repo_config}/fw/toggles.conf"
repo_fw_iptables="${repo_config}/fw/uhmiptables.sh"
repo_service="${repo_config}/service/uhmd.service"

# Required apt packages
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- so a
# missing package is reported here instead of failing later in uhmd,
# uhmhotspot or uhmiptables.
apt_deps=(python3-yaml curl jq iptables ipset python3 openssl coreutils util-linux iproute2 cron grep sed systemd libc-bin findutils procps logrotate git zip expect gzip diffutils arptables ebtables kmod ulogd2 unbound sudo)

# Output helpers
log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then echo "$msg" >&2; else echo "$msg"; fi
}
info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
err() { log "ERROR: $*"; }
abort() { err "$*"; exit 1; }

# port in use
check_port() {
    local proto="$1" port="$2" role="$3" port_listeners
    if ! port_listeners=$(python3 - "${proto,,}" "$port" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["ss", "-lnH", f"--{sys.argv[1]}", f"sport = :{sys.argv[2]}"],
        capture_output=True,
        text=True,
    )
except OSError:
    sys.exit(1)
if result.returncode != 0 or result.stderr.strip():
    sys.exit(1)
sys.stdout.write(result.stdout)
PY
    ); then
        err "[1/2] cannot check ${proto^^} port $port"
        abort "[2/2] fix the ss query before installing -abort"
    fi
    if [ -n "$port_listeners" ]; then
        err "[1/2] ${proto^^} port $port in use by another $role"
        abort "[2/2] stop that service before installing -abort"
    fi
}

query_port_listeners() {
    local port_error
    port_error=$(ss -lnH "--$1" "sport = :$2" 2>&1 >&3) || return 1
    [[ "$port_error" != *[![:space:]]* ]]
} 3>&1

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
            err "[1/2] UniFi OS version: $os_version"
            abort "[2/2] UniFi OS requires 5x or later -abort"
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
        err "[1/2] UniFi Network version: $network_version"
        abort "[2/2] UniFi Network requires 10x or later -abort"
    fi
}

# validation - one variable per thing validated; use directly with =~
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'

# validation - signed integer only; use directly with =~
UH_SINT='^(0|-?[1-9][0-9]*)$'
UH_MAX=9223372036854775807
UH_MIN=-9223372036854775808

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

retry_cmd() {
    [ "$#" -ge 2 ] || return 2
    local retry_label="$1" retry_attempt retry_status
    shift
    for retry_attempt in 1 2 3; do
        if "$@"; then
            return 0
        else
            retry_status=$?
        fi
        [ "$retry_attempt" -lt 3 ] || return "$retry_status"
        if declare -F log >/dev/null; then
            log "INFO: $retry_label: retry $((retry_attempt + 1))/3" >&2
        else
            printf '%s INFO: %s: retry %s/3\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$retry_label" \
                "$((retry_attempt + 1))" >&2
        fi
        sleep 5
    done
}

# UPDATE CHECKS
# Helpers that stage, check, apply and roll back an update
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
        log "ERROR: [1/2] $unit state: $state"
        update_error "[2/2] $unit did not stop"
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
            log "ERROR: [1/2] src and dst: $compared_file"
            update_error "[2/2] src and dst do not match"
        }
        info "updated $(basename "$target")"
    done
}

update_resume() {
    local unit state
    for unit in "${update_services[@]}"; do
        systemctl start "$unit" || update_error "cannot start service: $unit"
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect started: $unit"
        [ "$state" = active ] || {
            log "ERROR: [1/2] $unit state: $state"
            update_error "[2/2] $unit did not start"
        }
    done
}

update_finish() {
    update_resume
    rm -f -- "${update_cron_file}.update-disabled" || update_error "cannot finish cron update: $(basename "$update_cron_file")"
    trap - EXIT
    unset UPDATE_CRON_OWNER
}

update_cleanup() {
    local status="$1" unit
    trap - EXIT
    if (( update_copying == 0 )); then
        for unit in "${update_services[@]}"; do
            systemctl start "$unit" || warn "cannot resume $unit -alert"
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

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt_text="$1" default_value="${2:-n}" user_answer hint_text
    [[ "$default_value" == "y" ]] && hint_text="[Y/n]" || hint_text="[y/N]"
    read -rp " ${prompt_text} ${hint_text}: " user_answer || return 1
    user_answer="${user_answer:-$default_value}"
    [[ "${user_answer,,}" =~ ^y(es)?$ ]]
}

# PREFLIGHT CHECKS
# Verified before anything is written to disk
check_repo_files() {
    [[ -r "$repo_uhmd" ]] || { err "[1/2] missing $(basename "$repo_uhmd")"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -r "$repo_service" ]] || { err "[1/2] missing $(basename "$repo_service")"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmreload.sh" ]] || { err "[1/2] missing core/uhmreload.sh"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmleases.sh" ]] || { err "[1/2] missing core/uhmleases.sh"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -r "${repo_core}/uhmwatch.sh" ]] || { err "[1/2] missing core/uhmwatch.sh"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -d "$repo_tools" ]] || { err "[1/2] missing tools/ directory"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -r "${repo_tools}/uhmenv.sh" ]] || { err "[1/2] missing tools/uhmenv.sh"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -d "$repo_acl" ]] || { err "[1/2] missing acl/ directory"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -d "$repo_web" ]] || { err "[1/2] missing web/ directory"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    [[ -d "$repo_config" ]] || { err "[1/2] missing config/ directory"; abort "[2/2] run uhmsetup.sh inside the cloned repo -abort"; }
    info "Repo files located"
}

install_apt_deps() {
    if ! command -v awk >/dev/null 2>&1; then
        abort "awk is not installed -abort"
    fi
    local dep_pkg missing_pkgs=()
    (( $# > 0 )) || set -- "${apt_deps[@]}"
    for dep_pkg in "$@"; do
        [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" == *"ok installed"* ]] || missing_pkgs+=("$dep_pkg")
    done
    (( ${#missing_pkgs[@]} == 0 )) && return 0
    check_ipv4_interfaces
    check_internet
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { for dep_pkg in "${missing_pkgs[@]}"; do warn "cannot install $dep_pkg -alert"; done; abort "install them with apt, then re-run -abort"; }
    for dep_pkg in "${missing_pkgs[@]}"; do info "installed $dep_pkg"; done
}

# conflicting packages
check_conflicts() {
    local role="$1"; shift
    local found=()
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            found+=("$dep_pkg")
        fi
    done
    if [ "${#found[@]}" -gt 0 ]; then
        for dep_pkg in "${found[@]}"; do
            warn "conflicting $role: $dep_pkg -alert"
        done
        abort "remove them with apt purge -abort"
    fi
}

# overlapping packages
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
        err "[1/2] pydhcpd is not active"
        abort "[2/2] install github.com/maravento/pydhcp -abort"
    fi
}

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}" excluded_iface="${2:-}" iface_label="${3:-LAN}"
    local iface_name iface_choice iface_index iface_state
    local -a lan_candidates=()
    while IFS= read -r iface_name; do
        [ "$iface_name" = "$excluded_iface" ] && continue
        lan_candidates+=("$iface_name")
    done < <(list_ipv4_ifaces)
    (( ${#lan_candidates[@]} > 0 )) || {
        log "ERROR: no $iface_label interface available -abort"
        exit 1
    }
    if [ -n "$preset_iface" ]; then
        for iface_name in "${lan_candidates[@]}"; do
            if [ "$preset_iface" = "$iface_name" ]; then
                lan_iface_answer="$preset_iface"
                return 0
            fi
        done
        log "ERROR: $iface_label must be an eligible IPv4 interface -abort"
        exit 1
    fi
    echo ""
    echo "==== Available $iface_label Interfaces ===="
    for iface_index in "${!lan_candidates[@]}"; do
        iface_name="${lan_candidates[$iface_index]}"
        iface_state=$(ip -br link show "$iface_name" | awk '{print $2}')
        printf ' [%d] %s (%s)\n' "$((iface_index + 1))" "$iface_name" "$iface_state"
        describe_lan_ipv4 "$iface_name"
    done
    while true; do
        read -r -p "Select $iface_label Interface [1-${#lan_candidates[@]}]: " iface_choice || {
            log "ERROR: cannot read $iface_label interface selection -abort"
            exit 1
        }
        echo ""
        if [[ "$iface_choice" =~ $UH_UINT ]] && [ "${#iface_choice}" -le 5 ] \
           && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#lan_candidates[@]}" ]; then
            lan_iface_answer="${lan_candidates[$((iface_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid $iface_label interface selection -retry"
    done
}

select_network_interfaces() {
    local -a network_candidates=()
    mapfile -t network_candidates < <(list_ipv4_ifaces)
    (( ${#network_candidates[@]} >= 2 )) || abort "two active interfaces with IPv4 are required -abort"
    choose_lan_interface "${UHM_WAN_IFACE:-}" "" WAN
    wan_iface="$lan_iface_answer"
    choose_lan_interface "${UHM_LAN_IFACE:-}" "$wan_iface" LAN
    lan_iface="$lan_iface_answer"
}

# check persistent static IPv4
static_ipv4_query() {
    LC_ALL=C PAGER=cat SYSTEMD_PAGER=cat timeout -k 1s 3s "$@" </dev/null 2>/dev/null
}

keyfile_has_ipv4() {
    local file="$1" uuid="$2" cidr="$3"
    local line section='' saved_uuid='' method='' value key found=1
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            \[*\]) section="$line" ;;
            *=*)
                key="${line%%=*}"
                value="${line#*=}"
                case "$section:$key" in
                    '[connection]:uuid') saved_uuid="$value" ;;
                    '[ipv4]:method') method="$value" ;;
                    '[ipv4]:address'*)
                        if [[ "$key" =~ ^address[0-9]+$ && "${value%%,*}" == "$cidr" ]]; then
                            found=0
                        fi
                        ;;
                esac
                ;;
        esac
    done < "$file"
    [[ "$saved_uuid" == "$uuid" && ( "$method" == manual || "$method" == auto ) ]] &&
        return "$found"
    return 1
}

netplan_has_ipv4() (
    local id="$1" cidr="$2" uuid="${3:-}"
    local kind path entries key value runtime netplan_root dir profile_uuid
    local -a root_args=()
    [[ "$id" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    id=${id//./\\.}
    for runtime in /run/netplan/*.yaml; do
        [[ -e "$runtime" || -L "$runtime" ]] || continue
        [[ -n "$uuid" ]] || return 1
        netplan_root=$(mktemp -d /tmp/static-ipv4.XXXXXXXX) || return 1
        trap 'rm -rf -- "$netplan_root"' EXIT
        for dir in /etc /lib /usr/lib; do
            [[ -d "$dir/netplan" ]] || continue
            mkdir -p -- "$netplan_root$dir" || return 1
            ln -s -- "$dir/netplan" "$netplan_root$dir/netplan" || return 1
        done
        root_args=(--root-dir "$netplan_root")
        break
    done
    for kind in ethernets wifis bridges bonds vlans; do
        path="$kind.$id"
        if [[ -n "$uuid" ]]; then
            profile_uuid=$(static_ipv4_query netplan get "${root_args[@]}" "$path.networkmanager.uuid") || continue
            profile_uuid=${profile_uuid//\"/}
            [[ "$profile_uuid" == null || -z "$profile_uuid" || "$profile_uuid" == "$uuid" ]] || continue
        fi
        entries=$(static_ipv4_query netplan get "${root_args[@]}" "$path.addresses") || entries=
        while read -r key value; do
            if [[ "$key" == - && "${value//\"/}" == "$cidr" ]]; then
                return 0
            fi
        done <<< "$entries"

        [[ -n "$uuid" && "$profile_uuid" == "$uuid" ]] || continue
        entries=$(static_ipv4_query netplan get "${root_args[@]}" "$path.networkmanager.passthrough") || continue
        while read -r key value; do
            value="${value//\"/}"
            if [[ "$key" =~ ^ipv4[.]address[0-9]+:$ && "${value%%,*}" == "$cidr" ]]; then
                return 0
            fi
        done <<< "$entries"
    done
    return 1
)

netplan_profile_id() {
    local LC_ALL=C
    local file="$1" uuid="$2" ssid encoded='' char escaped index
    ssid=$(static_ipv4_query nmcli --escape no -g 802-11-wireless.ssid connection show uuid "$uuid") || ssid=
    for (( index=0; index<${#ssid}; index++ )); do
        char=${ssid:index:1}
        if [[ "$char" =~ [a-zA-Z0-9._~-] || "$char" > $'\177' ]]; then
            encoded+="$char"
        else
            printf -v escaped '%%%02X' "'$char"
            encoded+="$escaped"
        fi
    done
    if [[ -n "$encoded" ]]; then
        file=${file%"-$encoded"}
    fi
    printf '%s' "$file"
}

has_persistent_ipv4() {
    local iface="$1" cidr="$2" uuid addresses profiles key file status
    uuid=$(static_ipv4_query nmcli -g GENERAL.CON-UUID device show "$iface") || uuid=
    if [[ -n "$uuid" && "$uuid" != -- ]]; then
        addresses=$(static_ipv4_query nmcli -g ipv4.addresses connection show uuid "$uuid") || return 1
        [[ ",${addresses// /}," == *",$cidr,"* ]] || return 1

        profiles=$(static_ipv4_query nmcli -t --escape no -f UUID,FILENAME connection show) || return 1
        while IFS=: read -r key file; do
            [[ "$key" == "$uuid" ]] || continue
            case "$file" in
                /etc/NetworkManager/system-connections/*)
                    keyfile_has_ipv4 "$file" "$uuid" "$cidr"
                    return "$?"
                    ;;
                /run/NetworkManager/system-connections/netplan-*.nmconnection)
                    file="${file##*/netplan-}"
                    file=$(netplan_profile_id "${file%.nmconnection}" "$uuid")
                    netplan_has_ipv4 "$file" "$cidr" "$uuid"
                    return "$?"
                    ;;
            esac
        done <<< "$profiles"
        return 1
    fi

    status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
    while read -r key file; do
        if [[ "$key $file" =~ ^Network\ File:\ /run/systemd/network/10-netplan-(.+)[.]network$ ]]; then
            netplan_has_ipv4 "${BASH_REMATCH[1]}" "$cidr"
            return "$?"
        fi
    done <<< "$status"
    setup_networkd_has_ipv4 "$iface" "$cidr"
}

lan_ipv4_condition() {
    local iface="$1" address="$2" addresses cidr flags
    if addresses=$(static_ipv4_query ip -4 -o addr show dev "$iface" scope global); then
        while read -r _ _ _ cidr flags; do
            [[ "${cidr%/*}" == "$address" && "$cidr" == */* ]] || continue
            if [[ " $flags " == *" dynamic "* ]]; then
                printf 'dynamic'
                return 0
            fi
            if has_persistent_ipv4 "$iface" "$cidr"; then
                printf 'static'
                return 0
            fi
            break
        done <<< "$addresses"
    fi
    printf 'unverified'
}

describe_lan_ipv4() {
    local cidr
    while read -r cidr; do
        printf '      %s (%s)\n' "$cidr" \
            "$(lan_ipv4_condition "$1" "${cidr%/*}")"
    done < <(ip -4 -o addr show dev "$1" scope global | awk '{print $4}')
}

# Prepare the selected LAN before deployment.
setup_ipv4_number() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

setup_lan_mask() {
    local mask=$(( (0xffffffff << (32 - $1)) & 0xffffffff ))
    printf '%d.%d.%d.%d\n' "$((mask >> 24))" "$((mask >> 16 & 255))" \
        "$((mask >> 8 & 255))" "$((mask & 255))"
}

setup_lan_prefix() {
    local mask="$1" prefix
    [[ "$mask" =~ $UH_IPV4 ]] || return 1
    for ((prefix=0; prefix<=30; prefix++)); do
        if [[ "$(setup_lan_mask "$prefix")" == "$mask" ]]; then
            printf '%s\n' "$prefix"
            return 0
        fi
    done
    return 1
}

setup_lan_host() {
    local address="$1" cidr="$2" ip network mask
    [[ "$address" =~ $UH_IPV4 ]] || return 1
    ip=$(setup_ipv4_number "$address")
    network=$(setup_ipv4_number "${cidr%/*}")
    mask=$(( (0xffffffff << (32 - ${cidr#*/})) & 0xffffffff ))
    (( (ip & mask) == (network & mask) && (ip & ~mask) != 0 &&
       (ip & ~mask) != (0xffffffff ^ mask) ))
}

setup_lan_default_route() {
    local iface="$1" routes
    routes=$(static_ipv4_query ip -4 -o route show default dev "$iface") || return 1
    [[ "$routes" != *$'\n'* ]] || return 1
    lan_gateway=''
    lan_metric=''
    if [[ -n "$routes" ]]; then
        [[ "$routes" =~ [[:space:]]via[[:space:]]([^[:space:]]+) ]] || return 1
        lan_gateway="${BASH_REMATCH[1]}"
        [[ "$lan_gateway" =~ $UH_IPV4 ]] || return 1
        if [[ "$routes" =~ [[:space:]]metric[[:space:]]([0-9]+) ]]; then
            lan_metric="${BASH_REMATCH[1]}"
        else
            lan_metric=0
        fi
    fi
}

select_setup_lan_settings() {
    local iface="$1" condition mask address prefix answer
    local lan_gateway lan_metric
    lan_original_cidr="$lan_cidr_answer"
    condition=$(lan_ipv4_condition "$iface" "${lan_original_cidr%/*}")
    mask=$(setup_lan_mask "${lan_original_cidr#*/}")
    setup_lan_default_route "$iface" || abort "cannot identify the LAN default route -abort"
    case "$condition" in
        static)
            printf 'LAN %s: IPv4 %s, mask %s, gateway %s\n' \
                "$iface" "${lan_original_cidr%/*}" "$mask" "${lan_gateway:-none}"
            if (( ${lan_original_cidr#*/} < 31 )) &&
                setup_lan_host "${lan_original_cidr%/*}" "$lan_original_cidr"; then
                while true; do
                    read -r -p 'Keep the LAN IPv4 settings? [Y/n]: ' answer \
                        || abort "cannot read LAN confirmation -abort"
                    case "$answer" in
                        ''|y|Y) return 0 ;;
                        n|N) break ;;
                        *) info "answer y or n -retry" ;;
                    esac
                done
            fi
            ;;
        dynamic) ;;
        *) abort "cannot verify current LAN IPv4 -abort" ;;
    esac
    while true; do
        read -r -p 'Enter static LAN IPv4: ' address || abort "cannot read LAN IPv4 -abort"
        read -r -p "Enter LAN netmask [$mask]: " answer || abort "cannot read LAN mask -abort"
        prefix=$(setup_lan_prefix "${answer:-$mask}") || prefix=
        if [[ -n "$prefix" ]] && setup_lan_host "$address" "$address/$prefix"; then
            lan_cidr_answer="$address/$prefix"
            lan_change_requested=true
            return 0
        fi
        info "invalid LAN IPv4 or netmask -retry"
    done
}

setup_lan_origin() {
    local iface="$1" status file kind id definition match mac expected_mac
    lan_backend=''
    lan_uuid=$(static_ipv4_query nmcli -g GENERAL.CON-UUID device show "$iface") || lan_uuid=
    if [[ -n "$lan_uuid" && "$lan_uuid" != -- ]]; then
        status=$(static_ipv4_query nmcli -g GENERAL.STATE device show "$iface") || return 1
        [[ "$status" == '100 (connected)' ]] || return 1
        file=$(static_ipv4_query nmcli -t --escape no -f UUID,FILENAME connection show |
            awk -v uuid="$lan_uuid" 'index($0, uuid ":") == 1 {print substr($0, length(uuid) + 2)}') || return 1
        case "$file" in
            /etc/NetworkManager/system-connections/*)
                [[ -f "$file" && ! -L "$file" ]] || return 1
                match=$(static_ipv4_query nmcli -g connection.interface-name connection show uuid "$lan_uuid") || return 1
                [[ "$match" == "$iface" ]] || return 1
                lan_backend=nm
                lan_origin="$file"
                return 0
                ;;
            /run/NetworkManager/system-connections/netplan-*.nmconnection)
                lan_backend=netplan-nm
                id="${file##*/netplan-}"
                id=$(netplan_profile_id "${id%.nmconnection}" "$lan_uuid")
                ;;
            *) return 1 ;;
        esac
    else
        status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
        file=$(awk '/^[[:space:]]*Network File: / {print $3}' <<< "$status")
        case "$file" in
            /run/systemd/network/10-netplan-*.network)
                lan_backend=netplan-networkd
                id="${file##*/10-netplan-}"
                id="${id%.network}"
                ;;
            /etc/systemd/network/*.network)
                setup_networkd_file "$iface" "$file" || return 1
                lan_backend=networkd
                lan_origin="$file"
                return 0
                ;;
            *) return 1 ;;
        esac
    fi

    [[ "$id" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    id=${id//./\\.}
    for kind in ethernets wifis bridges bonds vlans; do
        definition=$(static_ipv4_query netplan get "$kind.$id") || return 1
        [[ -n "$definition" && "$definition" != null ]] || continue
        match=$(static_ipv4_query netplan get "$kind.$id.match") || return 1
        if [[ -z "$match" || "$match" == null || "$match" == '{}' ]]; then
            [[ "$id" == "${iface//./\\.}" ]] || return 1
        else
            expected_mac=$(static_ipv4_query netplan get "$kind.$id.match.macaddress") || return 1
            expected_mac=${expected_mac//\"/}
            mac=$(static_ipv4_query ip -br link show "$iface" | awk '{print $3}') || return 1
            match=$(static_ipv4_query netplan get "$kind.$id.match.name") || return 1
            match=${match//\"/}
            [[ "$match" == "$iface" || ( -n "$mac" && "${expected_mac,,}" == "${mac,,}" ) ]] || return 1
        fi
        lan_origin="$kind.$id"
        return 0
    done
    return 1
}

setup_lan_reload() {
    local iface="$1"
    case "$lan_backend" in
        netplan-*) timeout -k 2s 20s netplan generate || return 1 ;;
    esac
    case "$lan_backend" in
        nm|netplan-nm)
            timeout -k 2s 20s nmcli connection reload &&
                timeout -k 2s 20s nmcli --wait 15 connection up uuid "$lan_uuid" ifname "$iface"
            ;;
        networkd|netplan-networkd)
            timeout -k 2s 20s networkctl reload &&
                timeout -k 2s 20s networkctl reconfigure "$iface"
            ;;
    esac
}

setup_lan_stage_netplan() {
    local stage="$1" old="$2" new="$3"
    local dir file raw key value gateway existing_routes address_list= dns_csv
    for file in /run/netplan/*.yaml; do
        [[ ! -e "$file" && ! -L "$file" ]] || return 1
    done
    mkdir -p "$stage/etc/netplan" || return 1
    for file in /etc/netplan/*.yaml; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || return 1
        cp -p -- "$file" "$stage/etc/netplan/" || return 1
    done
    for dir in /lib /usr/lib; do
        [[ -d "$dir/netplan" ]] || continue
        mkdir -p "$stage$dir/netplan" || return 1
        for file in "$dir/netplan/"*.yaml; do
            [[ -f "$file" ]] || continue
            cp -- "$file" "$stage$dir/netplan/" || return 1
        done
    done
    raw=$(static_ipv4_query netplan get "$lan_origin.networkmanager.passthrough") || return 1
    if [[ "$raw" =~ (^|$'\n')ipv4\.(address[0-9]+|method|gateway|route[0-9]+): ]]; then
        return 1
    fi
    raw=$(static_ipv4_query netplan get "$lan_origin.addresses") || return 1
    if [[ "$raw" != null && -n "$raw" && "$raw" != '[]' ]]; then
        while read -r key value; do
            value=${value//\"/}
            [[ "$key" == - && "$value" =~ ^[0-9a-fA-F.:]+/[0-9]+$ ]] || return 1
            [[ "$value" == "$old" || "$value" == "$new" ]] || address_list+="$value, "
        done <<< "$raw"
        timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.addresses=null" || return 1
    fi
    timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.addresses=[$address_list$new]" &&
        timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.dhcp4=false" || return 1

    if [[ -n "$lan_gateway" ]]; then
        gateway=$(static_ipv4_query netplan get "$lan_origin.gateway4") || return 1
        gateway=${gateway//\"/}
        existing_routes=$(static_ipv4_query netplan get "$lan_origin.routes") || return 1
        if [[ "$gateway" != null && -n "$gateway" ]]; then
            if [[ "$gateway" != "$lan_gateway" ]]; then
                timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.gateway4=$lan_gateway" || return 1
            fi
        elif grep -Eq '(to: (-?default|0\.0\.0\.0/0)|^- to: ("default"|"0\.0\.0\.0/0"))$' <<< "$existing_routes"; then
            [[ "$lan_gateway" == "$lan_previous_gateway" ]] || return 1
        else
            timeout -k 1s 8s netplan set --root-dir "$stage" \
                "$lan_origin.routes=[{to: default, via: $lan_gateway, metric: $lan_metric}]" || return 1
        fi
    fi
    if (( ${#lan_dns[@]} )); then
        printf -v dns_csv '%s, ' "${lan_dns[@]}"
        timeout -k 1s 8s netplan set --root-dir "$stage" \
            "$lan_origin.nameservers.addresses=[${dns_csv%, }]" || return 1
    fi
}

setup_lan_is_active() {
    [[ "$(static_ipv4_query ip -br link show "$1" | awk '{print $2}')" == UP ]] &&
        static_ipv4_query ip -4 -o addr show dev "$1" scope global |
        awk -v address="$2" '$4 == address {found=1} END {exit !found}'
}

apply_setup_lan() (
    local iface="$1" old="$2" new="$3" temp file base current addresses address dns_raw
    local lan_backend lan_origin lan_uuid lan_gateway lan_metric lan_previous_gateway
    local committed=false changed=false mode old_condition
    local -a modified=() lan_dns=() options=()
    setup_lan_is_active "$iface" "$old" || abort "LAN settings changed during setup -abort"
    old_condition=$(lan_ipv4_condition "$iface" "${old%/*}")
    [[ "$old_condition" == static || "$old_condition" == dynamic ]] \
        || abort "cannot verify current LAN IPv4 -abort"
    setup_lan_origin "$iface" || abort "cannot identify a supported LAN configuration -abort"
    setup_lan_default_route "$iface" || abort "cannot identify the LAN default route -abort"
    lan_previous_gateway="$lan_gateway"
    if [[ -n "$lan_gateway" ]]; then
        while [[ "$lan_gateway" == "${new%/*}" ]] || ! setup_lan_host "$lan_gateway" "$new"; do
            read -r -p 'Enter LAN gateway for the new subnet: ' lan_gateway \
                || abort "cannot read LAN gateway -abort"
        done
    fi
    if [[ "$lan_backend" == *nm ]]; then
        dns_raw=$(static_ipv4_query nmcli -g IP4.DNS device show "$iface") || dns_raw=
    else
        dns_raw=$(static_ipv4_query resolvectl dns "$iface") || dns_raw=
        dns_raw=${dns_raw#*:}
    fi
    for address in $dns_raw; do
        if [[ "$address" =~ $UH_IPV4 ]]; then
            lan_dns+=("$address")
        fi
    done
    if [[ -n "$lan_gateway" ]] && (( ${#lan_dns[@]} == 0 )); then
        while true; do
            read -r -p 'Enter LAN DNS IPv4 [keep system resolver]: ' address \
                || abort "cannot read LAN DNS -abort"
            [[ -n "$address" ]] || break
            if [[ "$address" =~ $UH_IPV4 ]]; then
                lan_dns+=("$address")
                break
            fi
            info "invalid DNS IPv4 -retry"
        done
    fi
    current=$(static_ipv4_query ip -4 -o addr show scope global) || abort "cannot read IPv4 addresses -abort"
    if awk -v iface="$iface" -v address="${new%/*}" \
        '{split($4, ip, "/")} $2 != iface && ip[1] == address {found=1} END {exit !found}' <<< "$current"; then
        abort "requested IPv4 is active on another interface -abort"
    fi

    temp=$(mktemp -d /tmp/pydhcp-lan.XXXXXXXX) || abort "cannot stage LAN configuration -abort"
    restore_setup_lan() {
        local status=$? target attempt restore_ok=true
        trap - EXIT
        trap '' HUP INT TERM
        if "$changed" && ! "$committed"; then
            for target in "${modified[@]}"; do
                base="${target##*/}"
                if [[ -f "$temp/before/$base" ]]; then
                    cp -p -- "$temp/before/$base" "$target" || restore_ok=false
                else
                    rm -f -- "$target" || restore_ok=false
                fi
            done
            if setup_lan_reload "$iface" >/dev/null; then
                for (( attempt=1; attempt<=12; attempt++ )); do
                    if setup_lan_is_active "$iface" "$old" &&
                        [[ "$(lan_ipv4_condition "$iface" "${old%/*}")" == "$old_condition" ]]; then
                        break
                    fi
                    sleep 1
                done
                (( attempt <= 12 )) || restore_ok=false
            else
                restore_ok=false
            fi
            if "$restore_ok"; then
                info "previous LAN configuration restored -fixed"
            else
                err "[1/2] cannot restore LAN configuration"
                err "[2/2] backup at $temp -abort"
                exit 1
            fi
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap restore_setup_lan EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$temp/before" || abort "cannot prepare LAN backup -abort"

    if [[ "$lan_backend" == nm ]]; then
        cp -p -- "$lan_origin" "$temp/before/" || abort "cannot back up LAN profile -abort"
        addresses=$(static_ipv4_query nmcli -g ipv4.addresses connection show uuid "$lan_uuid") \
            || abort "cannot read LAN profile addresses -abort"
        addresses=${addresses// /}
        local -a profile_addresses=()
        IFS=, read -r -a profile_addresses <<< "$addresses"
        addresses="$new"
        for address in "${profile_addresses[@]}"; do
            [[ -z "$address" || "$address" == "$old" || "$address" == "$new" ]] || addresses+=",$address"
        done
        options=(ipv4.method manual ipv4.addresses "$addresses")
        if [[ -n "$lan_gateway" ]]; then
            options+=(ipv4.gateway "$lan_gateway" ipv4.route-metric "$lan_metric")
        fi
        for address in "${lan_dns[@]}"; do options+=(+ipv4.dns "$address"); done
        timeout -k 2s 20s nmcli --offline connection modify "${options[@]}" \
            < "$lan_origin" > "$temp/staged-profile" || abort "cannot stage the LAN profile -abort"
        keyfile_has_ipv4 "$temp/staged-profile" "$lan_uuid" "$new" \
            || abort "cannot validate the staged LAN profile -abort"
        modified+=("$lan_origin")
        changed=true
        install -m 600 -- "$temp/staged-profile" "$lan_origin" \
            || abort "cannot publish the LAN profile -abort"
    elif [[ "$lan_backend" == networkd ]]; then
        cp -p -- "$lan_origin" "$temp/before/" || abort "cannot back up the LAN file -abort"
        setup_stage_networkd "$lan_origin" "$old" "$new" > "$temp/staged-profile" \
            || abort "cannot stage the networkd LAN file -abort"
        modified+=("$lan_origin")
        changed=true
        cp -- "$temp/staged-profile" "$lan_origin" || abort "cannot write the LAN file -abort"
    else
        setup_lan_stage_netplan "$temp/staged" "$old" "$new" \
            || abort "cannot stage the selected LAN definition -abort"
        for file in /etc/netplan/*.yaml "$temp"/staged/etc/netplan/*.yaml; do
            [[ -f "$file" ]] || continue
            base="${file##*/}"
            [[ ! -L "/etc/netplan/$base" ]] || abort "LAN YAML is a symbolic link -abort"
            if [[ -f "$temp/before/$base" ]]; then continue; fi
            if cmp -s "/etc/netplan/$base" "$temp/staged/etc/netplan/$base"; then continue; fi
            if [[ -f "/etc/netplan/$base" ]]; then
                cp -p -- "/etc/netplan/$base" "$temp/before/$base" \
                    || abort "cannot back up Netplan LAN configuration -abort"
            fi
            modified+=("/etc/netplan/$base")
        done
        changed=true
        for file in "${modified[@]}"; do
            base="${file##*/}"
            if [[ -f "$temp/staged/etc/netplan/$base" ]]; then
                install -m 600 -- "$temp/staged/etc/netplan/$base" "$file" \
                    || abort "cannot publish the LAN YAML -abort"
            else
                rm -f -- "$file" || abort "cannot remove obsolete LAN YAML -abort"
            fi
        done
    fi

    setup_lan_reload "$iface" >/dev/null || abort "cannot apply LAN configuration -abort"
    setup_lan_gateway_matches() {
        [[ -z "$lan_gateway" ]] || static_ipv4_query ip -4 route show default dev "$iface" |
            awk -v gateway="$lan_gateway" '$1 == "default" && $2 == "via" && $3 == gateway {found=1} END {exit !found}'
    }
    for (( mode=1; mode<=12; mode++ )); do
        if setup_lan_is_active "$iface" "$new" && setup_lan_gateway_matches &&
            [[ "$(lan_ipv4_condition "$iface" "${new%/*}")" == static ]]; then
            break
        fi
        sleep 1
    done
    (( mode <= 12 )) || abort "configured LAN IPv4 could not be verified -abort"
    check_internet || exit 1
    committed=true
)

setup_networkd_file() {
    local iface="$1" file="$2" path base suffix
    [[ -f "$file" && ! -L "$file" ]] || return 1
    base="${file##*/}"
    for path in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
        for suffix in "$path/$base.d/"*.conf "$path/network.d/"*.conf; do
            [[ ! -e "$suffix" && ! -L "$suffix" ]] || return 1
        done
    done
    awk -v iface="$iface" '
        /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
        section == "[Match]" && /^[[:space:]]*Name[[:space:]]*=/ {
            name=$0
            sub(/^[^=]*=[[:space:]]*/, "", name)
            sub(/[[:space:]]*$/, "", name)
            if(name == iface) matched++
            else failed=1
        }
        END {exit (failed || matched != 1)}
    ' "$file"
}

setup_networkd_has_ipv4() {
    local iface="$1" cidr="$2" file status
    status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
    file=$(awk '/^[[:space:]]*Network File: / {print $3}' <<< "$status")
    [[ "$file" == /etc/systemd/network/*.network ]] || return 1
    setup_networkd_file "$iface" "$file" || return 1
    awk -v cidr="$cidr" '
        /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
        (section == "[Network]" || section == "[Address]") && /^[[:space:]]*Address[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (value == "") found=0
            else if (value == cidr) found=1
        }
        END {exit !found}
    ' "$file"
}

setup_stage_networkd() {
    local file="$1" old="$2" new="$3"
    awk -v old="$old" -v new="$new" -v gateway="$lan_gateway" \
        -v previous="$lan_previous_gateway" -v metric="$lan_metric" -v dns="${lan_dns[*]}" '
        function finish_network() {
            print "DHCP=" (dhcp ~ /^(yes|true|on|1|ipv6)$/ ? "ipv6" : "no")
            print "Address=" new
            if (dns != "") print "DNS=" dns
        }
        /^[[:space:]]*\[/ {
            if (section == "[Network]") finish_network()
            section=$0
            gsub(/[[:space:]]/, "", section)
            if (section == "[Network]") networks++
            if (section == "[Route]") routes++
            print
            next
        }
        {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
        }
        section == "[Network]" && /^[[:space:]]*DHCP[[:space:]]*=/ { dhcp=value; next }
        section == "[Network]" && /^[[:space:]]*Address[[:space:]]*=/ && (value == old || value == new) { next }
        section == "[Address]" && /^[[:space:]]*Address[[:space:]]*=/ && value == old && old != new { failed=1 }
        section == "[Network]" && /^[[:space:]]*Gateway[[:space:]]*=/ && value == previous {
            if (gateway != "") print "Gateway=" gateway
            direct_gateway=1
            next
        }
        { print }
        END {
            if (section == "[Network]") finish_network()
            if (failed || networks != 1 || (routes && gateway != previous)) exit 1
            if (gateway != "" && !direct_gateway && !routes) {
                print ""
                print "[Route]"
                print "Destination=0.0.0.0/0"
                print "Gateway=" gateway
                print "Metric=" metric
            }
        }
    ' "$file"
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
    echo ""
    echo "==== IPv4 Addresses on LAN '$selected_iface' ===="
    for ipv4_index in "${!lan_addresses[@]}"; do
        printf ' [%d] %s (%s)\n' "$((ipv4_index + 1))" \
            "${lan_addresses[$ipv4_index]}" \
            "$(lan_ipv4_condition "$selected_iface" \
                "${lan_addresses[$ipv4_index]%/*}")"
    done
    while true; do
        read -r -p "Select LAN IPv4 number: " ipv4_choice || {
            log "ERROR: cannot read LAN IPv4 selection -abort"
            exit 1
        }
        echo ""
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
        || { err "[1/2] $pydhcp_env not found"; abort "[2/2] install pydhcp first, see its README -abort"; }

    local absent_keys=() env_key
    for env_key in INTERFACESv4 SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK \
               SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
        grep -q "^${env_key}=" "$pydhcp_env" || absent_keys+=("$env_key")
    done
    if (( ${#absent_keys[@]} > 0 )); then
        for env_key in "${absent_keys[@]}"; do
            warn "$env_key missing line -alert"
        done
        abort "${#absent_keys[@]} key(s) invalid in pydhcp.env -abort"
    fi

    # Load only these known keys instead of sourcing the whole file, so a
    # tampered pydhcp.env cannot execute code.
    load_uhm_env "$pydhcp_env" "$env_keys" line
    [ "$INTERFACESv4" = "$lan_iface" ] || abort "LAN differs from pydhcp interface -abort"
    [ "$SERVER_IP" = "$lan_ip" ] || abort "LAN IPv4 differs from pydhcp SERVER_IP -abort"

    local check_var
    for check_var in SERVER_IP SERV_SUBNET SERV_BROADCAST \
              SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
        [[ "${!check_var:-}" =~ $UH_IPV4 ]] \
            || { err "[1/2] invalid IPv4 in ${check_var}: '${!check_var:-}'"; abort "[2/2] fix it in $pydhcp_env and retry -abort"; }
    done
    [[ "${SERV_MASK:-}" =~ $UH_NETMASK ]] \
        || { err "[1/2] invalid netmask in SERV_MASK: '${SERV_MASK:-}'"; abort "[2/2] fix it in $pydhcp_env and retry -abort"; }
    [[ "${SERV_DNS:-}" =~ $UH_DNS ]] \
        || { err "[1/2] invalid SERV_DNS list: '${SERV_DNS:-}'"; abort "[2/2] fix it in $pydhcp_env and retry -abort"; }
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
    log "INFO: $(basename "$acl_path") perms fixed -fixed"
}

ask() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
    printf -v "$target_var" '%s' "${user_answer:-$default_value}"
}

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

ask_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && uh_fits "$user_answer" && (( user_answer >= 1 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "invalid value, enter a positive integer -retry"
    done
}

# ip_le A B -- returns 0 if address A is lower than or equal to address B
ip_le() {
    (( $(setup_ipv4_number "$1") <= $(setup_ipv4_number "$2") ))
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
        info "invalid IPv4 address -retry"
    done
}

# Return success for a usable host address in the configured subnet.
ip_is_usable_host() {
    local address mask network broadcast
    address=$(setup_ipv4_number "$1")
    mask=$(setup_ipv4_number "$3")
    network=$(( $(setup_ipv4_number "$2") & mask ))
    broadcast=$(( network | (0xffffffff ^ mask) ))
    (( network < address && address < broadcast ))
}

# Returns 0 (true) if dotted-quad IP ranges [s1,e1] and [s2,e2] intersect.
ranges_overlap() {
    (( $(setup_ipv4_number "$1") <= $(setup_ipv4_number "$4") &&
       $(setup_ipv4_number "$3") <= $(setup_ipv4_number "$2") ))
}

# UNIFI DISCOVERY
# Finds the controller and its type without asking for them
discovered_url=""
discovered_type=""

discover_unifi_controller() {
    local unifi_user="$1" unifi_pass="$2" server_ip="$3"
    local check_ports=(8443 11443)
    local test_url http_code login_payload

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

# Queries one controller endpoint with a fresh login, so run_setup_wizard
# can offer select menus instead of free-text entry. Prints the raw JSON.
# Usage: fetch_unifi <url> <type> <user> <pass> <path below the API root>
fetch_unifi() {
    local controller_url="$1" unifi_type="$2" unifi_user="$3" unifi_pass="$4" api_path="$5"
    local login_path base_path login_payload cookie_jar

    if [[ "$unifi_type" == "unifi-os" ]]; then
        login_path="/api/auth/login"
        base_path="/proxy/network/api"
    else
        login_path="/api/login"
        base_path="/api"
    fi

    login_payload=$(UH_JQ_USER="$unifi_user" UH_JQ_PASS="$unifi_pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    cookie_jar=$(mktemp) || { err "[1/2] cannot create temp file in /tmp"; abort "[2/2] check space, read-only or immutable -abort"; }

    curl -sk -c "$cookie_jar" -o /dev/null \
        -X POST "${controller_url}${login_path}" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 5 <<< "$login_payload"

    curl -sk -b "$cookie_jar" "${controller_url}${base_path}/${api_path}" --connect-timeout 5

    rm -f "$cookie_jar"
}

hotspot_range_defaults() {
    local mask network pool_first pool_last server dhcp_start dhcp_end preferred_start start end
    local start_offset=160 end_offset=199
    local best_start=1 best_end=0
    mask=$(setup_ipv4_number "$SERV_MASK")
    network=$(( $(setup_ipv4_number "$SERV_SUBNET") & mask ))
    pool_first=$(( network + 1 ))
    pool_last=$(( (network | (0xffffffff ^ mask)) - 1 ))
    server=$(setup_ipv4_number "$SERVER_IP")
    dhcp_start=$(setup_ipv4_number "$SERV_INI_RANGE_BLOCK")
    dhcp_end=$(setup_ipv4_number "$SERV_END_RANGE_BLOCK")
    preferred_start=$(( network + start_offset ))
    (( preferred_start <= pool_last )) || preferred_start=$pool_last

    for start in "$preferred_start" "$pool_first" "$((server + 1))" "$((dhcp_end + 1))"; do
        (( pool_first <= start && start <= pool_last && start != server )) || continue
        end=$(( start + end_offset - start_offset ))
        (( end <= pool_last )) || end=$pool_last
        if (( start < server && server <= end )); then
            end=$(( server - 1 ))
        fi
        if (( start <= dhcp_end )); then
            (( start < dhcp_start )) || continue
            (( end < dhcp_start )) || end=$(( dhcp_start - 1 ))
        fi
        if (( end - start > best_end - best_start )); then
            best_start=$start
            best_end=$end
        fi
        (( end - start < end_offset - start_offset )) || break
    done
    (( best_start <= best_end )) || abort "LAN has no free Hotspot range -abort"
    printf '%u.%u.%u.%u %u.%u.%u.%u\n' \
        "$(( best_start >> 24 ))" "$(( best_start >> 16 & 255 ))" \
        "$(( best_start >> 8 & 255 ))" "$(( best_start & 255 ))" \
        "$(( best_end >> 24 ))" "$(( best_end >> 16 & 255 ))" \
        "$(( best_end >> 8 & 255 ))" "$(( best_end & 255 ))"
}

# SETUP WIZARD
# Collects every value uhm.env needs and writes the block
run_setup_wizard() {
    local cfg_ini_range cfg_end_range cfg_essid
    local cfg_unifi_user cfg_unifi_pass cfg_reload_script
    local found_url found_type
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
        { err "[1/2] no UniFi controller detected"; abort "[2/2] check controller credentials and service -abort"; }
    fi
    # UNIFI_SITE takes the site's internal name, not the name shown in UniFi
    local site_list=() site_answer cfg_site=""
    mapfile -t site_list < <(fetch_unifi "$found_url" "$found_type" "$cfg_unifi_user" "$cfg_unifi_pass" self/sites \
        | jq -r '.data[]? | select(.name | type == "string" and test("^[a-zA-Z0-9._-]+$")) | "\(.name)\t\(.desc // .name)"' 2>/dev/null)
    if (( ${#site_list[@]} == 0 )); then
        cfg_site=default
        warn "no UniFi site listed; using default -fallback"
    elif (( ${#site_list[@]} == 1 )); then
        cfg_site="${site_list[0]%%$'\t'*}"
        info "UniFi site detected: $cfg_site"
    else
        local site_index site_default=1
        echo ""
        echo "==== Available UniFi Sites ===="
        for site_index in "${!site_list[@]}"; do
            printf ' [%d] %s (%s)\n' "$((site_index + 1))" "${site_list[$site_index]%%$'\t'*}" "${site_list[$site_index]#*$'\t'}"
            [[ "${site_list[$site_index]%%$'\t'*}" == default ]] && site_default=$((site_index + 1))
        done
        while true; do
            read -rp "Select UniFi site [1-${#site_list[@]}] [Default: ${site_default}]: " site_answer \
                || abort "cannot read UniFi site selection -abort"
            echo ""
            site_answer="${site_answer:-$site_default}"
            if [[ "$site_answer" =~ $UH_UINT ]] && [ "${#site_answer}" -le 5 ] \
               && [ "$site_answer" -ge 1 ] && [ "$site_answer" -le "${#site_list[@]}" ]; then
                cfg_site="${site_list[$((site_answer - 1))]%%$'\t'*}"
                break
            fi
            info "invalid UniFi site selection -retry"
        done
    fi
    local ssid_list=() ssid_config
    ssid_config=$(fetch_unifi "$found_url" "$found_type" "$cfg_unifi_user" "$cfg_unifi_pass" "s/$cfg_site/rest/wlanconf" \
        | jq -c '[.data[]? | select(.name | type == "string" and length > 0) | {name, is_guest}]' 2>/dev/null)
    mapfile -t ssid_list < <(jq -r '.[] | .name' <<< "$ssid_config")
    if (( ${#ssid_list[@]} == 1 )); then
        cfg_essid="${ssid_list[0]}"
        info "SSID detected: $cfg_essid"
    elif (( ${#ssid_list[@]} > 1 )); then
        local ssid_index ssid_answer
        echo ""
        echo "==== Available SSIDs ===="
        for ssid_index in "${!ssid_list[@]}"; do
            printf ' [%d] %s\n' "$((ssid_index + 1))" "${ssid_list[$ssid_index]}"
        done
        while true; do
            read -rp "Select SSID [1-${#ssid_list[@]}] [Default: 1]: " ssid_answer \
                || abort "cannot read SSID selection -abort"
            echo ""
            ssid_answer="${ssid_answer:-1}"
            if [[ "$ssid_answer" =~ $UH_UINT ]] && [ "${#ssid_answer}" -le 5 ] \
               && [ "$ssid_answer" -ge 1 ] && [ "$ssid_answer" -le "${#ssid_list[@]}" ]; then
                cfg_essid="${ssid_list[$((ssid_answer - 1))]}"
                break
            fi
            info "invalid SSID selection -retry"
        done
    else
        cfg_essid=""
        warn "no SSID found in UniFi; using Manual mode -alert"
    fi

    local cfg_hotspot_enabled=false
    if [[ -n "$cfg_essid" ]]; then
        cfg_hotspot_enabled=""
        local hotspot_answer hotspot_attempt
        local portal_host portal_redirect
        portal_host=${found_url#https://}
        portal_host=${portal_host%%/*}
        portal_host=${portal_host%:*}
        for (( hotspot_attempt=1; hotspot_attempt<=3; hotspot_attempt++ )); do
            read -rp "Does the selected SSID use Hotspot? [Y/n]: " hotspot_answer \
                || abort "no Hotspot selection received -abort"
            case "$hotspot_answer" in
                ""|[Yy]|[Yy][Ee][Ss])
                    if ! jq -e --arg name "$cfg_essid" '
                        [.[] | select(.name == $name)] |
                        length == 1 and .[0].is_guest == true
                    ' <<< "$ssid_config" >/dev/null; then
                        warn "Hotspot not detected on the selected SSID -alert"
                        continue
                    fi
                    # The firewall redirects clients to HTTP on port 8880.
                    if ! portal_redirect=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 10 \
                        --output /dev/null --write-out '%{redirect_url}' \
                        "http://$portal_host:8880/guest/s/$cfg_site/" 2>/dev/null) \
                        || [[ "$portal_redirect" == https://* ]]; then
                        warn "port 8880 unreachable or redirects to HTTPS -alert"
                        continue
                    fi
                    cfg_hotspot_enabled=true
                    break
                    ;;
                [Nn]|[Nn][Oo]) cfg_hotspot_enabled=false; break ;;
                *) info "answer yes or no -retry" ;;
            esac
        done
        [[ -n "$cfg_hotspot_enabled" ]] || abort "Hotspot not confirmed; check SSID and rerun -abort"
    fi

    cfg_ini_range=""
    cfg_end_range=""
    if [[ "$cfg_hotspot_enabled" == true ]]; then
        # Two full addresses, the same shape pydhcp already uses for its own pool
        # (SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK) -- no netmask is assumed.
        echo "Range of fixed addresses handed to voucher-authorized guests"
        echo "Network: ${SERV_SUBNET}/${SERV_MASK}"
        echo "pydhcp block pool: ${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}"
        local default_range range_start_default range_end_default
        default_range=$(hotspot_range_defaults)
        read -r range_start_default range_end_default <<< "$default_range"
        while true; do
            ask_ip "Hotspot range start" "$range_start_default" cfg_ini_range
            ask_ip "Hotspot range end" "$range_end_default" cfg_end_range
            if ! ip_le "$cfg_ini_range" "$cfg_end_range"; then
                info "Hotspot range is inverted -retry"
                continue
            fi
            if ! ip_is_usable_host "$cfg_ini_range" "$SERV_SUBNET" "$SERV_MASK" \
               || ! ip_is_usable_host "$cfg_end_range" "$SERV_SUBNET" "$SERV_MASK"; then
                info "range ends must be usable hosts in the subnet -retry"
                continue
            fi
            if ranges_overlap "$cfg_ini_range" "$cfg_end_range" "$SERVER_IP" "$SERVER_IP"; then
                info "Invalid Hotspot range: SERVER_IP is inside -retry"
                continue
            fi
            if ranges_overlap "$cfg_ini_range" "$cfg_end_range" \
                               "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK"; then
                info "Invalid Hotspot range: overlaps pydhcp pool -retry"
                continue
            fi
            break
        done
    fi
    check_unifi_versions "$found_type"
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
        warn "[1/2] Could not compute TLS certificate pin"
        warn "[2/2] uhmd will connect without pinning -alert"
    fi
    cfg_reload_script="${core_dir}/uhmreload.sh"
    [ -f "$cfg_reload_script" ] && [ -x "$cfg_reload_script" ] \
        || abort "reload script not found or not executable -abort"
    ask_number "Daemon poll interval in seconds (POLL_INTERVAL)" "20" cfg_poll_interval
    cfg_grace_seconds=""
    if [[ "$cfg_hotspot_enabled" == true ]]; then
        ask_number "Grace period before blocking unknown MACs in seconds (BLOCKDHCP_GRACE_SECONDS)" "86400" cfg_grace_seconds
    fi
    echo "mac-*.txt files assign fixed IPv4 addresses to approved devices"
    if [[ "$cfg_hotspot_enabled" == true ]]; then
        echo "Approved devices bypass the captive portal"
    fi
    echo "Files are stored in /etc/acl/ and managed manually"
    acl_prepare "$acl_mac_dir" 700 600
    info "Add your mac-*.txt files to /etc/acl/"
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

        local uhm_block
        uhm_block=$(mktemp) || { err "[1/2] cannot create temp file in /tmp"; abort "[2/2] check space, read-only or immutable -abort"; }

        cat > "$uhm_block" <<EOF
# =============================================================================
# UHM
# /etc/uhm/uhm.env
# =============================================================================

# Network
WAN_IFACE=${wan_iface}

# UniFi
# Guest SSID
UHM_ESSID=${essid_answer}
UNIFI_HOTSPOT_ENABLED=${cfg_hotspot_enabled}
# Unifi Access
UNIFI_CONTROLLER_URL=${url_answer}
UNIFI_USERNAME=${user_answer}
UNIFI_PASSWORD=${pass_answer}
# Internal site name selected during installation
UNIFI_SITE=${cfg_site}
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
# Firewall, switches in toggles.conf
UHM_IPTABLES=${uhm_iptables_dest}
UHM_TOGGLES=${fw_conf_dest}

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
BACKUP_DIR=/etc/bak/uhm
# =============================================================================
EOF

        cat "$uhm_block" >> "$uhm_env" || abort "cannot write uhm.env -abort"
        rm -f "$uhm_block"
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
    install -m 750 -o root -g root "$repo_uhmd" "${core_dir}/uhmd.sh"
    info "updated core/uhmd.sh"
    install -m 750 -o root -g root "${repo_core}/uhmreload.sh" "${core_dir}/uhmreload.sh"
    info "updated core/uhmreload.sh"
    install -m 750 -o root -g root "${repo_core}/uhmleases.sh" "${core_dir}/uhmleases.sh"
    info "updated core/uhmleases.sh"
    # uhmwatch.sh lives under core/ (not tools/) because it is mandatory,
    # not an optional utility -- deployed explicitly here for that reason,
    # same as the other three core scripts above.
    install -m 750 -o root -g root "${repo_core}/uhmwatch.sh" "${core_dir}/uhmwatch.sh"
    info "updated core/uhmwatch.sh"
    local repo_file
    for repo_file in "${repo_tools}/"*.sh; do
        case "$(basename "$repo_file")" in
            uhmenv.sh) continue ;;
        esac
        install -m 750 -o root -g root "$repo_file" "${tools_dir}/"
        info "updated tools/$(basename "$repo_file")"
    done
}

deploy_uhmiptables() {
    install -d -m 700 -o root -g root -- "$fw_dir"
    if [[ -f "$uhm_iptables_dest" ]]; then
        info "uhmiptables.sh already exists -skip"
        return 0
    fi
    install -m 750 -o root -g root "$repo_fw_iptables" "$uhm_iptables_dest"
    info "Firewall deployed to $uhm_iptables_dest"
}

# Firewall switches read by uhmiptables.sh and edited from FWView. The file
# belongs to the administrator once deployed, so an existing one is kept.
deploy_fw_switches() {
    install -d -m 700 -o root -g root -- "$fw_dir"
    if [[ -e "$fw_conf_dest" ]]; then
        info "toggles.conf already exists -skip"
        return 0
    fi
    install -m 600 -o root -g root "$repo_fw_conf" "$fw_conf_dest"
    info "Switches deployed to $fw_conf_dest"
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
        if [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" != *"ok installed"* ]]; then
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
        warn "[1/2] apache configtest failed, not reloaded"
        warn "[2/2] check $(basename "$vhost_dest"), reload apache2 -alert"
        return 1
    fi
    if ! systemctl reload apache2 &>/dev/null; then
        warn "cannot reload apache2; web setup incomplete -alert"
        return 1
    fi

    info "Web interface configured at http://127.0.0.1:${web_port}/"
    return 0
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
    # Replaced, not edited; the package rotation and reload are kept.
    if [[ -f "$apache_rotate" && ! -f "$apache_rotate.bak" ]]; then
        cp -f "$apache_rotate" "$apache_rotate.bak" \
            || { warn "cannot back up ${apache_rotate#/etc/} -alert"; return 0; }
    fi
    if ! cat > "$apache_rotate" <<'EOF'
/var/log/apache2/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then
            run-parts /etc/logrotate.d/httpd-prerotate
        fi
    endscript
    postrotate
        if pgrep -f ^/usr/sbin/apache2 > /dev/null; then
            invoke-rc.d apache2 reload 2>&1 | logger -t apache2.logrotate
        fi
    endscript
}
EOF
    then
        warn "cannot write ${apache_rotate#/etc/} -alert"
        return 0
    fi
    chown root:root "$apache_rotate" && chmod 644 "$apache_rotate" \
        || { warn "cannot set ${apache_rotate#/etc/} permissions -alert"; return 0; }
    info "${apache_rotate#/etc/} replaced, previous kept as .bak -fixed"
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
    weekly
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
    local issue_list=0

    if [[ ! -x "$uhm_iptables_dest" ]]; then
        warn "[1/2] uhmiptables.sh is missing or not executable"
        warn "[2/2] ACL changes will not reach firewall -alert"
        (( issue_list++ )) || true
    fi

    if (( issue_list > 0 )); then
        warn "${issue_list} issue(s): uhm not fully functional -alert"
    fi
}

install_systemd_service() {
    install -m 644 -o root -g root "$repo_service" "$service_dest"
    systemctl daemon-reload
    systemctl enable uhmd
    if systemctl restart uhmd; then
        info "uhmd enabled and started"
    else
        warn "[1/2] Could not start uhmd"
        warn "[2/2] check it with: systemctl status uhmd -alert"
    fi
}

# Runs the PyDHCP installer before UHM applies its own changes.
install_pydhcp() {
    local pydhcp_path="${script_dir}/pydhcp"
    local pydhcp_daemon="${pydhcp_env%/*}/core/pydhcpd.py"
    local action="--install"

    if [[ -f "$pydhcp_env" && -f "$pydhcp_daemon" ]]; then
        action="--update"
        load_pydhcp_conf
        echo "UHM will run pysetup.sh --update before installing UHM."
        echo "DHCP service may pause. UHM will start pydhcpd if it is stopped."
        if ! confirm "Update PyDHCP and continue?" "y"; then
            info "installation cancelled"
            log "INFO: uhmsetup done"
            exit 0
        fi
    elif [[ -e "$pydhcp_env" || -e "$pydhcp_daemon" ]] \
        || systemctl is-active --quiet pydhcpd 2>/dev/null; then
        err "[1/2] incomplete PyDHCP installation"
        abort "[2/2] check pydhcp.env and core/pydhcpd.py -abort"
    else
        echo "UHM requires PyDHCP. Its installer will ask for DHCP settings."
    fi

    if [[ ! -d "$pydhcp_path" ]]; then
        command -v git >/dev/null || abort "git is needed to obtain pydhcp sources -abort"
        retry_cmd "clone project sources" git clone https://github.com/maravento/pydhcp "$pydhcp_path" \
            || { err "[1/2] cannot clone pydhcp"; abort "[2/2] check network access, then re-run -abort"; }
    fi

    [[ -r "${pydhcp_path}/pysetup.sh" ]] \
        || { err "[1/2] pysetup.sh not found in $pydhcp_path"; abort "[2/2] remove that directory and re-run -abort"; }

    ( cd "$pydhcp_path" && PYDHCP_LAN_IFACE="$lan_iface" PYDHCP_SERVER_IP="$lan_ip" bash pysetup.sh "$action" ) \
        || { err "[1/2] pysetup.sh $action failed"; abort "[2/2] see ${pydhcp_path}/pysetup.log -abort"; }

    # Standalone updates preserve the inactive state of a stopped DHCP service.
    if [[ "$action" == --update ]] && ! systemctl is-active --quiet pydhcpd; then
        systemctl start pydhcpd || abort "cannot start pydhcpd -abort"
    fi
    systemctl is-active --quiet pydhcpd 2>/dev/null \
        || { err "[1/2] pydhcpd is not active after $action"; abort "[2/2] check it with: systemctl status pydhcpd -abort"; }
    info "pydhcpd active after $action"
}

# Installs apache2, which uhm needs for the web panel. Kept apart from
# apt_deps because it also enables the apache2 service.
install_apache2() {
    local dep_pkg missing_pkgs=()

    for dep_pkg in apache2 apache2-bin apache2-data apache2-doc apache2-utils libapache2-mod-php; do
        [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" == *"ok installed"* ]] || missing_pkgs+=("$dep_pkg")
    done
    if (( ${#missing_pkgs[@]} == 0 )); then
        info "apache2 already present"
    else
        retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
            || { for dep_pkg in "${missing_pkgs[@]}"; do warn "cannot install $dep_pkg -alert"; done; abort "install them with apt, then re-run -abort"; }
        systemctl enable apache2 &>/dev/null || true
        for dep_pkg in "${missing_pkgs[@]}"; do info "installed $dep_pkg"; done
    fi
    # apache2-doc breaks after apache2 installs or upgrades; reinstall it always
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --reinstall apache2-doc \
        || abort "cannot reinstall apache2-doc -abort"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

confirm_install_replacements() {
    local existing_config answer apache_php_ini
    local -a php_configs=()
    for existing_config in "$apache_ports" "$vhost_dest" "$sudoers_dest" "$logrotate_file" \
        /etc/logrotate.d/apache2 /etc/cron.d/uhm "$service_dest"; do
        [ ! -f "$existing_config" ] || existing_configs+=("$existing_config")
    done
    for apache_php_ini in /etc/php/*/apache2/php.ini; do
        [ -f "$apache_php_ini" ] || continue
        php_configs+=("${apache_php_ini%/*}/conf.d/99-project-php-hardening.ini")
    done
    (( ${#existing_configs[@]} + ${#php_configs[@]} > 0 )) || return 0
    printf '%s\n' "Configuration targets:"
    printf ' %s\n' "${existing_configs[@]}" "${php_configs[@]}"
    echo "Apache modules and the UHM site will be configured. Apache will be restarted."
    read -r -p "Continue with these changes? [Y/n]: " answer || answer=n
    case "${answer,,}" in
        ""|y|yes) ;;
        *) info "installation cancelled"; log "INFO: uhmsetup done"; exit 0 ;;
    esac
}

do_install() {
    check_requirements install
    local existing_config apache_ports_before=""
    local -a existing_configs=()
    confirm_install_replacements
    if [ -f "$apache_ports" ]; then
        apache_ports_before=$(cksum < "$apache_ports") || abort "cannot read ports.conf -abort"
    fi

    lan_ip="${lan_cidr_answer%/*}"
    info "WAN interface: $wan_iface"
    info "LAN interface: $lan_iface ($lan_cidr_answer)"
    local unifi_action=""
    if [ "$(dpkg-query -W -f='${db:Status-Status}' unifi 2>/dev/null)" = installed ] \
        || [[ -f /var/lib/uosserver/server.conf ]]; then
        info "UniFi already installed"
    else
        local unifi_choice
        echo ""
        echo "==== UniFi Component for UHM ===="
        echo "1) UniFi Network Application"
        echo "2) UniFi OS Server"
        ask "Select an option (1-2)" 1 unifi_choice
        echo ""
        case "$unifi_choice" in
            1) unifi_action="network" ;;
            2) unifi_action="osserver" ;;
            *) abort "invalid option -abort" ;;
        esac
    fi

    if "$lan_change_requested"; then
        apply_setup_lan "$lan_iface" "$lan_original_cidr" "$lan_cidr_answer" || exit 1
    else
        check_static_lan "$lan_iface" "${lan_cidr_answer%/*}"
    fi
    install_pydhcp
    for existing_config in "${existing_configs[@]}"; do
        # PyDHCP may already have backed up this version while deploying WPAD.
        if [ "$existing_config" = "$apache_ports" ] && [ -n "$apache_ports_before" ] \
            && [ -f "$apache_ports.bak" ] \
            && [ "$(cksum < "$apache_ports.bak")" = "$apache_ports_before" ]; then
            continue
        fi
        [ -f "${existing_config}.bak" ] || cp -p -- "$existing_config" "${existing_config}.bak" \
            || abort "cannot back up $(basename "$existing_config") -abort"
    done

    local dep_pkg
    local -a script_packages=() component_packages=()
    for dep_pkg in "${apt_deps[@]}"; do
        case "$dep_pkg" in
            unbound|ulogd2) component_packages+=("$dep_pkg") ;;
            *) script_packages+=("$dep_pkg") ;;
        esac
    done
    install_apt_deps "${script_packages[@]}"
    install_apt_deps "${component_packages[@]}"

    if [ -n "$unifi_action" ]; then
        local unifisetup_tmp
        unifisetup_tmp=$(mktemp) || { err "[1/2] cannot create temp file in /tmp"; abort "[2/2] check space, read-only or immutable -abort"; }
        local unifisetup_url="https://raw.githubusercontent.com/maravento/vault/refs/heads/master/scripts/bash/unifisetup.sh"
        local unifisetup_rc=0 unifisetup_code
        unifisetup_code=$(curl -sL -w '%{http_code}' -o "$unifisetup_tmp" "$unifisetup_url") || unifisetup_rc=$?
        case "${unifisetup_code:-000}" in
            2*) if (( unifisetup_rc == 0 )); then
                    log "SAVED: unifisetup.sh"
                else
                    log "PARTIAL: $unifisetup_url"
                fi ;;
            000) log "TIMEOUT: $unifisetup_url" ;;
            5*) log "BUSY: $unifisetup_code $unifisetup_url" ;;
            404|410) log "BROKEN: $unifisetup_code $unifisetup_url" ;;
            *) log "HTTP_ERROR: $unifisetup_code $unifisetup_url" ;;
        esac
        if [[ "${unifisetup_code:-000}" != 2* ]] || (( unifisetup_rc != 0 )); then
            rm -f "$unifisetup_tmp"
            abort "unifisetup.sh not available -abort"
        fi
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

        if [ "$(dpkg-query -W -f='${db:Status-Status}' unifi 2>/dev/null)" != installed ] \
            && [[ ! -f /var/lib/uosserver/server.conf ]]; then
            abort "UniFi install incomplete; see unifisetup.log -abort"
        fi

        echo ""
        echo "Enter that URL and set up your local account"
        read -n1 -rsp " Press any key once you've done that, to continue... "
        echo ""
    fi

    trap 'install_exit_code=$?; trap - EXIT; (( install_exit_code != 0 )) && { warn "Installation failed, rolling back changes -alert"; perform_remove; }' EXIT
    install_apache2

    local apache_php_ini
    for apache_php_ini in /etc/php/*/apache2/php.ini; do
        [ -f "$apache_php_ini" ] || continue
        install_php_hardening "$apache_php_ini" || abort "cannot edit $apache_php_ini -abort"
    done

    systemctl restart apache2 || abort "cannot restart apache2 -abort"

    detect_dhcp_backend
    load_pydhcp_conf
    deploy_directories
    deploy_scripts
    deploy_acl_files
    deploy_uhmiptables
    deploy_fw_switches

    run_setup_wizard
    install_logrotate
    install_systemd_service
    register_project_cron || abort "cannot write uhm cron -abort"
    install_web

    final_sanity_check

    trap - EXIT

    echo "Web interface: http://127.0.0.1:${web_port}/"
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

update_apache_port() {
    local ports_file="$1" site_file="$2" bind_ip="$3" port="$4" status
    sed -i -E "s/^([[:space:]]*<VirtualHost[[:space:]]+)[^>]+>/\1*:${port}>/" "$site_file" \
        || update_error "cannot configure Apache site port"
    if grep -Eq "^[[:space:]]*Listen[[:space:]]+([^[:space:]]*:)?${port}([[:space:]]|$)" "$ports_file"; then
        return 0
    else
        status=$?
        [ "$status" -eq 1 ] || update_error "cannot read Apache ports.conf"
    fi
    printf 'Listen %s:%s\n' "$bind_ip" "$port" >> "$ports_file" \
        || update_error "cannot write Apache ports.conf"
}

do_update() {
    check_requirements update
    install_apt_deps
    [ -d "$hotspot_dir" ] && [ -f "$core_dir/uhmd.sh" ] || abort "uhm is not installed -abort"
    local UNIFI_HOTSPOT_ENABLED=""
    load_uhm_env "$uhm_env" 'UNIFI_HOTSPOT_ENABLED' line || true
    case "$UNIFI_HOTSPOT_ENABLED" in
        true|false) ;;
        *) abort "UNIFI_HOTSPOT_ENABLED must be true/false -abort" ;;
    esac
    update_reset /etc/cron.d/uhm
    local file mode
    for file in uhmd.sh uhmreload.sh uhmleases.sh uhmwatch.sh; do
        update_file "$repo_core/$file" "$core_dir/$file" 750 root:root
    done
    for file in uhmenv.sh uhmtool.sh uhmalert.sh uhmhotspot.sh uhmbk.sh; do
        mode=750
        case "$file" in uhmenv.sh) mode=644 ;; esac
        update_file "$repo_tools/$file" "$tools_dir/$file" "$mode" root:root
    done
    update_target "$fw_dir" d700 root:root
    if [ ! -e "$uhm_iptables_dest" ]; then
        update_file "$repo_fw_iptables" "$uhm_iptables_dest" 750 root:root
    fi
    if [ -d "$web_root" ]; then
        for file in index.html api.php aclview/index.php logview/index.php toolview/index.php fwview/index.php; do
            update_file "$repo_web/$file" "$web_root/$file" 644 root:root
        done
    fi
    if [ ! -e "$fw_conf_dest" ]; then
        update_file "$repo_fw_conf" "$fw_conf_dest" 600 root:root
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
    if [ -d "$web_root" ]; then
        [ -f /etc/apache2/ports.conf ] && [ ! -L /etc/apache2/ports.conf ] \
            || update_error "ports.conf is missing or invalid"
        [ -f "$vhost_dest" ] && [ ! -L "$vhost_dest" ] \
            || update_error "Apache site is missing or invalid"
        update_target /etc/apache2/ports.conf
        update_target "$vhost_dest"
    fi
    update_preflight
    update_backup "$repo_tools/uhmbk.sh"
    update_begin
    update_stop_service uhmd
    if [ -d "$web_root" ]; then update_stop_service apache2; fi
    if [ -f /etc/systemd/system/uhmalert.service ]; then update_stop_service uhmalert; fi
    update_wait_jobs
    update_apply
    if [ -d "$web_root" ]; then
        update_apache_port /etc/apache2/ports.conf "$vhost_dest" 127.0.0.1 "$web_port"
        apache2ctl configtest || update_error "Apache configuration invalid"
    fi
    acl_prepare "$acl_mac_dir" 700 600
    acl_prepare "$acl_dir" 700 600 "$acl_dir/uhm-auth.txt" "$acl_dir/uhm-queue.txt" "$acl_dir/uhm-grace.txt"
    install_logrotate warn || update_error "cannot configure uhm log rotation"
    systemctl daemon-reload || update_error "cannot reload systemd configuration"
    register_project_cron \
        || update_error "cannot regenerate uhm cron"
    update_finish
    info "update complete"
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

do_uninstall() {
    echo ""
    echo "This will permanently remove, without asking again:"
    echo "- uhmd.service: stopped, disabled, unit file removed"
    echo "- /etc/cron.d/uhm: uhmwatch and uhmbk entries"
    echo "- uhmalert.service if installed"
    echo "- web panel, its vhost and sudo rule, if installed"
    echo "- ${logrotate_file}"
    echo "- ${hotspot_dir}"
    echo "including uhm.env, ACL lists and YOUR uhmiptables.sh"
    echo "A backup is taken with ${uhmbk_script} before anything is removed"
    echo "- ${uhm_log_file}, rotated logs"
    echo "- uhmhotspot.log and reload failure traces"
    echo "/etc/bak is NOT touched"
    echo "Package dependencies"
    echo "(curl, jq, iptables, ipset, etc.) are NOT removed"
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" || {
        info "Aborted by user"
        log "INFO: uhmsetup done"
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
        log "INFO: uhmsetup done"
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
    rm -f /etc/cron.d/uhm /etc/cron.d/uhm.update-disabled
    info "Cron entries removed"

    # uhmalert (optional component)
    if [[ -f /etc/systemd/system/uhmalert.service ]]; then
        systemctl disable --now uhmalert 2>/dev/null || true
        rm -f /etc/systemd/system/uhmalert.service
        systemctl daemon-reload
        info "uhmalert.service removed"
    else
        info "uhmalert.service not installed"
    fi

    # Web interface (optional component)
    remove_web

    # Logrotate
    if [[ -f "$logrotate_file" ]]; then
        rm -f "$logrotate_file"
        info "Removed $logrotate_file"
    else
        info "No logrotate config found"
    fi

    # /etc/uhm
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
    local extra_logs=() check_log
    for check_log in /var/log/uhmhotspot.log /var/log/uhmleases-failure.trace /var/log/uhmiptables-failure.trace; do
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
    local port_listeners
    if ! port_listeners=$(query_port_listeners tcp "$web_port"); then
        echo ":$web_port UNKNOWN"
    elif [ -n "$port_listeners" ]; then
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
        echo "==== UHM Installation Menu ===="
        echo "1) Install"
        echo "2) Update"
        echo "3) Uninstall"
        echo "4) Status"
        echo "5) Exit"
        read -p "Select option [5]: " menu_option
        echo ""
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
if ! source "$repo_tools/uhmenv.sh" 2>/dev/null; then
    abort "cannot load uhmenv.sh -abort"
fi
env_keys='INTERFACESv4 SERVER_IP SERV_MASK SERV_SUBNET SERV_BROADCAST SERV_DNS SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK'

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "INFO: uhmsetup start..."

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

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "INFO: uhmsetup done"
