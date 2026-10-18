#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmsetup -- uhm installer / updater
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
config_file="${hotspot_dir}/uhm.env"
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
repo_uhmweb="${repo_config}/uhmweb"
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
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

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
    log "Checking for conflicting pre-installed packages..."
    check_conflicts "DHCP server" isc-dhcp-server kea-dhcp4-server udhcpd
    check_conflicts "web server"  nginx lighttpd caddy
    check_conflicts "firewall"    firewalld
    warn_overlap "dhcp" dnsmasq
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        err "ufw active; disable it before UHM -abort"
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

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
source "$repo_tools/uhmenv.sh"
env_keys='SERVER_IP SERV_MASK SERV_SUBNET SERV_BROADCAST SERV_DNS SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK WPAD_ENABLED WPAD_PORT'

# Reads pydhcp's own network values (server IP, mask, subnet, broadcast, DNS,
# blockdhcp pool range) from pydhcp_env instead of asking for them again --
# pysetup.sh already collected and persisted them. Only the keys this
# installer itself needs for the wizard are required here: the rest live in
# pydhcp.env and each component reads them from there at runtime, warning
# and falling back if one is missing.
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

ask_interface_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" max_value="$4" user_answer
    while true; do
        read -rp " ${prompt_text} [1-${max_value}] [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] \
           && [ "${#user_answer}" -le "${#max_value}" ] \
           && [ "$user_answer" -ge 1 ] && [ "$user_answer" -le "$max_value" ]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid selection, try again -retry"
    done
}

list_interfaces() {
    local iface_index iface_state iface_ip
    for iface_index in "${!iface_list[@]}"; do
        iface_state=$(ip -br link show "${iface_list[$iface_index]}" | awk '{print $2}')
        iface_ip=$(ip -4 -o addr show dev "${iface_list[$iface_index]}" 2>/dev/null | awk '{print $4}' | paste -sd' ')
        printf " [%d] %s (%s, %s)\n" "$((iface_index+1))" "${iface_list[$iface_index]}" "$iface_state" "${iface_ip:-no IPv4}"
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

    log "Probing ${server_ip} on ports ${check_ports[*]} ..."
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
    # is a real UniFi-side problem (no SSID configured, or the query itself
    # failed) -abort the same way as a missing controller. More than one
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
            warn "set UHM_ESSID in $(basename "$config_file") before starting uhm -alert"
        fi
    else
        cfg_essid=""
        warn "no SSID detected on UniFi controller -alert"
        warn "set UHM_ESSID in $(basename "$config_file") before starting uhm -alert"
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
    mkdir -p /etc/acl/mac
    chmod 700 /etc/acl/mac
    info "Add your mac-*.txt files to /etc/acl/mac/"

    step "Writing $config_file"
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
        : > "$config_file"

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
# -- UniFi keys ---------------------------------------------------------------
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
# -- Hotspot keys ---------------------------------------------------------------
# Hotspot Range
UHM_INI_RANGE=${cfg_ini_range}
UHM_END_RANGE=${cfg_end_range}
# Daemon timers (uhm's own)
POLL_INTERVAL=${cfg_poll_interval}
STARTUP_GRACE_SECONDS=120
RELOAD_SAFETY_INTERVAL_SECONDS=3600
BLOCKDHCP_GRACE_SECONDS=${cfg_grace_seconds}
RECOVERY_COOLDOWN_SECONDS=600
# -- Scripts ------------------------------------------------------------------
UHM_RELOAD=${reload_script_answer}
UHM_LEASES=${core_dir}/uhmleases.sh
# By sysadmin
UHM_IPTABLES=${uhm_iptables_dest}
# Timeouts (uhmd -> uhmreload -> uhmleases.sh/uhmiptables.sh)
UHM_LEASES_TIMEOUT_SECONDS=120
UHM_IPTABLES_TIMEOUT_SECONDS=60
# -- API defaults -------------------------------------------------------------
# Changing these defaults is not recommended
UHM_API_TIMEOUT_SECONDS=30
# -- ACLs (uhm's own; read by uhmd.sh / uhmleases.sh) -------------------------
UHM_PATH=${hotspot_dir}
UHM_GRACE=${acl_dir}/uhm-grace.txt
UHM_MACAUTH=${acl_dir}/uhm-auth.txt
UHM_QUEUE=${acl_dir}/uhm-queue.txt
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

        insert_after_last_delimiter "$config_file" "$filtered_block"
    )
    chown root:root "$config_file"
    chmod 600 "$config_file"
    info "Config saved to $config_file (mode 600)"
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

    # Written here instead of copied from the repo: both the LAN wildcard and
    # the proxy line depend on values only known at install time, so a shipped
    # template would be rewritten line by line anyway.
    install -d -m 755 -o www-data -g www-data "$wpad_root"
    cat > "${wpad_root}/wpad.pac" <<EOF
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) || shExpMatch(host, "localhost"))
        return "DIRECT";
    if (shExpMatch(host, "$(echo "$SERV_SUBNET" | awk -F. '{OFS="."; $4="*"; print $0}')") || shExpMatch(host, "127.*"))
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
        touch "$uhm_log_file"
    fi
    chmod 640 "$uhm_log_file"
    chown root:adm "$uhm_log_file" 2>/dev/null || chown root:root "$uhm_log_file"

    if [[ -f "$logrotate_file" ]]; then
        info "logrotate config exists: $logrotate_file"
    else
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$logrotate_file") missing -alert"
        cat > "$logrotate_file" <<EOF
${uhm_log_file} {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
        chown root:root "$logrotate_file"
        chmod 644 "$logrotate_file"
        info "logrotate config installed at $logrotate_file"
    fi
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
# questions (interface, netmask, pool, DNS, cleanup interval) and writes them
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

    ( cd "$pydhcp_path" && PYDHCP_LAN_IFACE="$lan_iface" bash pysetup.sh ) \
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
    mapfile -t iface_list < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
    if [[ ${#iface_list[@]} -eq 0 ]]; then
        abort "no network interfaces found -abort"
    fi
    list_interfaces
    echo ""
    ask_interface_number "Select LAN interface number" "1" lan_iface_choice "${#iface_list[@]}"
    lan_iface="${iface_list[$((lan_iface_choice-1))]}"
    lan_ip="$(ip -4 -o addr show dev "$lan_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [[ -n "$lan_ip" ]] || abort "interface $lan_iface has no IPv4 address -abort"
    info "LAN interface: $lan_iface ($lan_ip)"

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

    step "uhmwatch"
    # Mandatory, not optional -- uhmd/pydhcpd/UniFi backend all rely on it
    # to recover from a persistent failure systemd itself gives up on (see
    # core/uhmwatch.sh header). cron is a hard dependency (APT_DEPS above)
    # precisely so this step can never fail here.
    bash "${core_dir}/uhmwatch.sh" --install

    step "uhmbk"
    if [[ -x "$uhmbk_script" ]]; then
        "$uhmbk_script" --install || warn "uhmbk.sh: monthly backup setup failed -alert"
    fi

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

    step "Preflight"
    check_repo_files

    if [[ ! -d "$hotspot_dir" ]] || [[ ! -f "${core_dir}/uhmd.sh" ]]; then
        { err "uhm not installed"; abort "use --install to install first -abort"; }
    fi

    step "Backup"
    if [[ -x "$uhmbk_script" ]]; then
        if "$uhmbk_script"; then
            info "backup taken with uhmbk.sh"
        else
            warn "uhmbk.sh: backup failed -alert"
        fi
    else
        warn "uhmbk.sh: missing or not executable -alert"
    fi

    step "Pause services"
    # Stop whatever is actively running its own script file before that file
    # gets overwritten below -- avoids replacing a script out from under a
    # process that may still be mid-cycle. pydhcpd is deliberately left
    # alone: it is a separate project this update never modifies, and
    # stopping it would cut DHCP for the whole LAN, not just the hotspot.
    local uwatch_path="${core_dir}/uhmwatch.sh"
    local uhmd_was_active=0 ualert_was_active=0 uwatch_was_active=0
    systemctl is-active --quiet uhmd 2>/dev/null && uhmd_was_active=1
    if [[ -f /etc/systemd/system/uhmalert.service ]]; then
        systemctl is-active --quiet uhmalert 2>/dev/null && ualert_was_active=1
    fi
    if awk -v p="$uwatch_path" \
        'index($0,p)>0 && $0 !~ /^[[:space:]]*#/ {found_entry=1}
         END {exit !found_entry}' /etc/cron.d/uhm 2>/dev/null; then
        uwatch_was_active=1
    fi

    if (( uhmd_was_active )); then
        systemctl stop uhmd && info "uhmd stopped for update" || warn "Could not stop uhmd, continuing anyway -alert"
    fi
    if (( ualert_was_active )); then
        systemctl stop uhmalert && info "uhmalert stopped for update" || warn "Could not stop uhmalert, continuing anyway -alert"
    fi
    if (( uwatch_was_active )); then
        # Remove the active line outright instead of just commenting it
        # out -- Resume below re-registers a clean entry via
        # `uhmwatch.sh --install`.
        bash "${core_dir}/uhmwatch.sh" --uninstall >/dev/null 2>&1 || true
        info "uhmwatch cron entry removed, restored on resume"
    fi

    step "Deploy updated scripts"
    deploy_scripts

    step "Web interface"
    # Code only, and only where the panel is already installed. The vhost
    # carries the administrator's own LAN range, so it is never rewritten.
    if [[ -d "$web_root" ]]; then
        cp -a "${repo_web}/." "$web_root/"
        chown -R root:root "$web_root"
        find "$web_root" -type d -exec chmod 755 {} +
        find "$web_root" -type f -exec chmod 644 {} +
        info "updated web code in $web_root"
    else
        info "web interface not installed -skip"
    fi

    step "ACL data files"
    # acl_dir (uhm-auth.txt, uhm-queue.txt, uhm-grace.txt), config_file
    # and uhm_iptables_dest are the administrator's own live/customized data.
    # --update never renames, moves or overwrites anything already present --
    # deploy_acl_files()/deploy_uhmiptables() below only create what's
    # missing (e.g. a partial/broken install, warning about it since that
    # should not normally happen) and leave every existing file untouched.
    # No unconditional mkdir/chmod on an already-existing acl_dir either;
    # only created (and chmod 700) here if it doesn't exist yet.
    [[ -d "$acl_dir" ]] || { mkdir -p "$acl_dir"; chmod 700 "$acl_dir"; }
    deploy_acl_files warn
    deploy_uhmiptables

    step "Logrotate"
    install_logrotate warn

    step "Systemd service"
    install -m 644 -o root -g root "$repo_service" "$service_dest"
    systemctl daemon-reload
    if (( uhmd_was_active )); then
        if systemctl restart uhmd; then
            info "uhmd restarted"
        else
            warn "Could not restart uhmd"
            warn "check it with: systemctl status uhmd -alert"
        fi
    else
        info "uhmd was not active before update, left stopped"
    fi

    step "Resume services"
    # Only restore what this update itself paused above -- never start
    # something the administrator had deliberately left stopped/disabled.
    if (( ualert_was_active )); then
        systemctl start uhmalert && info "uhmalert restarted" || { warn "Could not restart uhmalert"; warn "check it with: systemctl status uhmalert -alert"; }
    fi
    if (( uwatch_was_active )); then
        # Re-registers a clean entry, since Pause above removed it.
        if ! bash "${core_dir}/uhmwatch.sh" --install >/dev/null 2>&1; then
            err "cannot restore uhmwatch -abort"
            return 1
        fi
        info "uhmwatch cron entry restored"
    elif ! grep -qF "$uwatch_path" /etc/cron.d/uhm 2>/dev/null; then
        # No current entry exists. Install the mandatory current entry.
        if ! bash "${core_dir}/uhmwatch.sh" --install >/dev/null 2>&1; then
            err "cannot install uhmwatch -abort"
            return 1
        fi
        info "uhmwatch installed (was missing, now mandatory)"
    fi

    info "update complete"
    info "preserved ${config_file}"
    info "preserved ${uhm_iptables_dest}"
    info "preserved ACL data files"
    info "preserved logrotate config"
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
    echo "Run ${uhmbk_script} first if you want a backup"
    echo "- ${uhm_log_file}, rotated logs"
    echo "- uhmunifi.log and reload failure traces"
    echo "/etc/bak is NOT touched"
    echo "Package dependencies"
    echo "(curl, jq, iptables, ipset, etc.) are NOT removed"
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" || {
        info "Aborted by user"
        log "uhmsetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
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
        log "uhmsetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
        exit 0
    fi
    echo ""

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
    rm -f /etc/cron.d/uhm
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

    # uhmwatch (mandatory component, but --remove uninstalls everything
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
    if [[ -f "$config_file" ]]; then
        echo "$config_file present"
    else
        echo "$config_file not found"
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
            5) exit 0 ;;
            *) info "invalid option -retry" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "uhmsetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    --status) do_status ;;
    "") show_menu ;;
    *)
        err "unknown option $1 -abort"
        usage
        exit 1
        ;;
esac

log "uhmsetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
