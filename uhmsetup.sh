#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmsetup.sh -- uhm installer / updater
# https://github.com/maravento/uhm
#
# MODES:
# sudo bash uhmsetup.sh            Install (default; aborts if already
#                                  installed -- use --update or --remove)
# sudo bash uhmsetup.sh --update   Update scripts only (preserves config/ACLs)
# sudo bash uhmsetup.sh --remove   Uninstall
# sudo bash uhmsetup.sh --help     Usage
#
# Run from inside the cloned repo. The script expects to find:
# ./core/uhmd.sh
# ./service/uhmd.service
# ./core/uhmreload.sh
# ./core/uhmleases.sh
# ./core/uhmwatch.sh
# ./tools/uhmunifi.sh
# ./tools/uhmacl.sh
# ./tools/uhmwebmin.sh
# ./tools/uhmalert.sh
# ./tools/uhmiptables.sh (minimal template -- deployed only when absent)
# ./tools/uhmiptables_example.txt (reference example only, never deployed)
# ./acl/uhm-auth.txt
# ./acl/uhm-queue.txt
# ./acl/uhm-grace.txt
#
# core/ holds the reload mechanism (uhmleases.sh reconciles ACLs/leases,
# uhmreload.sh invokes it, uhmd.sh/.service run the daemon that calls
# uhmreload.sh) plus uhmwatch.sh -- mandatory too, but for a different
# reason: it is the services watchdog, not part of the reload chain (see
# its own header). uhm cannot function correctly without any of these
# five. tools/ holds independent, optional utilities (auditing,
# monitoring, alerting) that uhm runs fine without. acl/ holds uhm's own
# data files (empty templates in the repo, deployed once and never
# overwritten afterward) --
# not to be confused with /etc/acl, which belongs to pydhcp/iptables.
#
# tools/uhmiptables.sh is a minimal but working template (IPv4 forwarding +
# NAT). tools/uhmiptables_example.txt is the full reference ruleset, never
# deployed -- the administrator copies it over uhmiptables.sh and adapts it
# manually. deploy_scripts() below excludes uhmiptables.sh
# from the tools/*.sh deploy loop; it is never installed automatically.
#
# DEPENDENCIES:
# Hard dependencies (checked before anything else; aborts if any is missing --
# none of these are auto-installed):
#     curl, jq, iptables, ipset, python3, openssl, bsdextrautils (column),
#     mawk (awk), coreutils, util-linux (flock), iproute2 (ip), cron,
#     grep, sed, systemd, ncurses-bin, libc-bin (getent), findutils (find),
#     procps (sysctl, used by uhmiptables.sh)
#
# Hard dependency NOT an apt package (aborts if missing):
#     pydhcpd must be installed and running, with pydhcp.env present and
#     complete (network values pysetup.sh already collected -- uhmsetup.sh
#     reads them from there instead of asking again). pydhcp is not an apt
#     package; install it from https://github.com/maravento/pydhcp before
#     running this script.
#
# Hard dependency NOT an apt package (aborts if missing/unreachable):
#     UniFi Network self-hosted or UniFi OS Server, installed and reachable
#     on this same host (classic on 8443, unifi-os on 11443). If neither is
#     installed yet, use unifisetup.sh to install it first:
#     https://raw.githubusercontent.com/maravento/vault/refs/heads/master/scripts/bash/unifisetup.sh
#
# CONFIG FILE (uhm.env):
# Holds only uhm's own keys: UniFi credentials, guest SSID, hotspot range,
# timers and paths. WAN interface is not a key here -- it is written as a
# placeholder replacement directly into uhmiptables.sh (see Setup wizard),
# the only script that uses it. pydhcp's values are never copied here -- every
# component reads pydhcp.env first and uhm.env after, so a change made in
# pydhcp.env reaches uhm without a re-install. A key already present in
# pydhcp.env is skipped instead of written a second time, and the skip is
# reported on screen: these files are parsed key=value, so a duplicate would
# let uhm.env shadow the value its owner maintains.
#
# LOG: uhmsetup.log, in the same directory this script is run from. Kept
# separate from /var/log/uhm.log (the project's operational log, written by
# uhmd.sh/uhmreload.sh/uhmleases.sh/uhmwatch.sh/uhmalert.sh) so install,
# update and remove runs never mix with daily operation -- and so their
# WARNING/ERROR lines never reach uhmalert.sh, which pushes a notification
# for every one of them it finds in uhm.log. Appended across runs, so an
# install can be compared against the updates that followed it.
# Rewritten on each run.
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# USAGE
# Prints the header block of this file as the help text
usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") [OPTION]

Modes:
  (none)       Install uhm (default). Aborts if already installed --
               use --update or --remove instead. Also aborts if the
               detected UniFi Network version (package "unifi", classic
               or embedded in unifi-os) is below the minimum tested
               (>= 10.4.57).
  --update     Update scripts only (preserves config, ACLs, firewall).
  --remove     Uninstall uhm (interactive, with confirmations).
  --help, -h   Show this help.

Run from inside the cloned uhm repository. See the README for details.
EOF
}

case "${1:-}" in
    --help|-h|help)
        usage
        exit 0
        ;;
esac

# root check
if [[ "$(id -u)" != "0" ]]; then
    echo "ERROR: This script must be run as root -- abort" >&2
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    echo "ERROR: script $(basename "$0") is already running -- abort" >&2
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
bkstack_script="/etc/pydhcp/tools/bkstack.sh"
log_file="${script_dir}/uhmsetup.log"
{ > "$log_file"; } 2>/dev/null || true
uhm_log_file="/var/log/uhm.log"
logrotate_file="/etc/logrotate.d/uhm"
uhm_iptables_dest="${tools_dir}/uhmiptables.sh"
service_dest="/etc/systemd/system/uhmd.service"

# Repo file expectations (relative to this script)
repo_core="${script_dir}/core"
repo_tools="${script_dir}/tools"
repo_acl="${script_dir}/acl"
repo_uhmd="${repo_core}/uhmd.sh"
repo_service="${script_dir}/service/uhmd.service"

# Required apt packages
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- so a
# missing package is reported here instead of failing later in uhmd,
# uhmacl, uhmunifi or uhmiptables.
apt_deps=(curl jq iptables ipset python3 openssl bsdextrautils mawk coreutils util-linux iproute2 cron grep sed systemd ncurses-bin libc-bin findutils procps)

# Discovered runtime values (filled during install)

# Output helpers
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" >/dev/null 2>&1 || true
}
info() { printf ' \e[32m \e[0m %s\n' "$*"; log "INFO: $*"; }
warn() { printf ' \e[33m!\e[0m %s\n' "$*"; log "WARNING: $*"; }
err() { printf ' \e[31m \e[0m %s\n' "$*" >&2; log "ERROR: $*"; }
step() { printf '\n-- %s ---------------------------------------------\n' "$*"; }
abort() { err "$*"; exit 1; }

version_ge() {
    # version_ge A B -- returns 0 if version A >= version B
    [[ "$1" == "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]
}

# validation -- one variable per thing validated; use directly with =~
UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

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
    last_line=$(grep -n '^# =\{5,\}$' "$conf_file" | tail -1 | cut -d: -f1)
    if [[ -z "$last_line" ]]; then
        printf '\n%s\n' "$env_block" >> "$conf_file"
        return
    fi
    tmp_file=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }
    head -n "$last_line" "$conf_file" > "$tmp_file"
    printf '\n%s\n' "$env_block" >> "$tmp_file"
    tail -n "+$((last_line + 1))" "$conf_file" >> "$tmp_file"
    mv "$tmp_file" "$conf_file"
}

dq_escape() {
    # dq_escape STRING -- escape \ " $ ` for safe reuse inside double quotes
    local raw_string="$1"
    raw_string="${raw_string//\\/\\\\}"
    raw_string="${raw_string//\"/\\\"}"
    raw_string="${raw_string//\$/\\\$}"
    raw_string="${raw_string//\`/\\\`}"
    printf '%s' "$raw_string"
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
check_distro() {
    local distro_id="" distro_version=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        distro_id="${ID:-}"
        distro_version="${VERSION_ID:-}"
    fi
    if [[ "$distro_id" != "ubuntu" || "$distro_version" != "24.04" ]]; then
        warn "Tested only on Ubuntu 24.04. Detected: ${distro_id:-unknown} ${distro_version:-unknown}"
        warn "Continuing at your own risk."
    else
        info "Ubuntu ${distro_version} detected"
    fi
}

check_repo_files() {
    [[ -r "$repo_uhmd" ]] || { err "missing $(basename "$repo_uhmd")"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "$repo_service" ]] || { err "missing $(basename "$repo_service")"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${repo_core}/uhmreload.sh" ]] || { err "missing core/uhmreload.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${repo_core}/uhmleases.sh" ]] || { err "missing core/uhmleases.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${repo_core}/uhmwatch.sh" ]] || { err "missing core/uhmwatch.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -d "$repo_tools" ]] || { err "missing tools/ directory"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -d "$repo_acl" ]] || { err "missing acl/ directory"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    info "Repo files located"
}

check_apt_deps() {
    local missing_pkgs=()
    for dep_pkg in "${apt_deps[@]}"; do
        dpkg -s "$dep_pkg" &>/dev/null || missing_pkgs+=("$dep_pkg")
    done
    if (( ${#missing_pkgs[@]} > 0 )); then
        { err "missing package(s): ${missing_pkgs[*]}"; abort "install them with apt, then re-run -- abort"; }
    fi
    info "All apt dependencies present: ${apt_deps[*]}"
}

detect_dhcp_backend() {
    local pydhcp_active=false
    systemctl is-active --quiet pydhcpd 2>/dev/null && pydhcp_active=true

    if $pydhcp_active; then
        info "DHCP backend detected: pydhcpd"
    else
        err "pydhcpd is not active."
        err "Install pydhcpd from https://github.com/maravento/pydhcp"
        abort "DHCP backend required -- abort"
    fi
}

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# Reads pydhcp's own network values (server IP, mask, subnet, broadcast, DNS,
# blockdhcp pool range) from pydhcp_env instead of asking for them again --
# pysetup.sh already collected and persisted them. Only the keys this
# installer itself needs for the wizard are required here: the rest live in
# pydhcp.env and each component reads them from there at runtime, warning
# and falling back if one is missing.
# Sets SERVER_IP, SERV_MASK, SERV_SUBNET, SERV_BROADCAST,
# SERV_DNS, SERV_INI_RANGE_BLOCK, SERV_END_RANGE_BLOCK for
# run_setup_wizard.
load_pydhcp_env() {
    [ -f "$pydhcp_env" ] \
        || { err "$pydhcp_env not found"; abort "install pydhcp first, see its README -- abort"; }

    local missing_keys=() env_key
    for env_key in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK \
               SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
        grep -q "^${env_key}=" "$pydhcp_env" || missing_keys+=("$env_key")
    done
    if (( ${#missing_keys[@]} > 0 )); then
        err "$pydhcp_env is missing pydhcp's own keys: ${missing_keys[*]}"
        abort "re-run pydhcp pysetup.sh, or restore the backup -- abort"
    fi

    # Load only these known keys instead of sourcing the whole file, so a
    # tampered pydhcp.env cannot execute code.
    local env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [ -n "$env_line" ]; do
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
        case "$env_key" in
            SERVER_IP|SERV_MASK|SERV_SUBNET|SERV_BROADCAST|SERV_DNS|\
            SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$pydhcp_env"

    local check_var
    for check_var in SERVER_IP SERV_SUBNET SERV_BROADCAST \
              SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
        [[ "${!check_var:-}" =~ $UH_IPV4 ]] \
            || { err "invalid IPv4 in ${check_var}: '${!check_var:-}'"; abort "fix it in $pydhcp_env and retry -- abort"; }
    done
    [[ "${SERV_MASK:-}" =~ $UH_NETMASK ]] \
        || { err "invalid netmask in SERV_MASK: '${SERV_MASK:-}'"; abort "fix it in $pydhcp_env and retry -- abort"; }
    [[ "${SERV_DNS:-}" =~ $UH_DNS ]] \
        || { err "invalid SERV_DNS list: '${SERV_DNS:-}'"; abort "fix it in $pydhcp_env and retry -- abort"; }
}

# INTERACTIVE PROMPTS
# Ask helpers, each one validating its own answer
ask() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    read -rp " ${prompt_text} [${default_value}]: " user_answer
    printf -v "$target_var" '%s' "${user_answer:-$default_value}"
}

ask_interface() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if ip link show "$user_answer" &>/dev/null; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        err "interface '$user_answer' not found"
        err "available: $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)"
    done
}

ask_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && (( user_answer >= 1 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        err "'$user_answer' is not valid. Enter a positive integer."
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
        read -rp " ${prompt_text} [${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_IPV4 ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        err "'$user_answer' is not a valid IPv4 address."
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

    info "Probing ${server_ip} on ports ${check_ports[*]} ..."
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline).
    login_payload=$(UH_JQ_USER="$unifi_user" UH_JQ_PASS="$unifi_pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    for check_port in "${check_ports[@]}"; do
        test_url="https://${server_ip}:${check_port}"

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
    cookie_jar=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }

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
    local cfg_wan_if
    local cfg_ini_range cfg_end_range cfg_essid
    local cfg_unifi_user cfg_unifi_pass cfg_reload_script
    local found_url found_type

    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- Interactive Setup"
    echo "------------------------------------------------------"

    step "Network"
    # WAN interface is uhm's own: a value another project may have written
    # into pydhcp.env belongs to that project, not to the ecosystem, so uhm
    # asks for its own. The answer is not stored in uhm.env -- it replaces
    # the "eth0" placeholder directly in uhmiptables.sh, the only script
    # that uses it.
    local iface_list
    iface_list=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)
    echo "Available interfaces: $iface_list"
    ask_interface "WAN interface" "eth0" cfg_wan_if
    if [[ -f "$uhm_iptables_dest" ]]; then
        sed -i "s:eth0:$cfg_wan_if:g" "$uhm_iptables_dest"
    fi

    step "pydhcp network configuration"
    info "Loaded from $pydhcp_env"
    info "  Server IP: $SERVER_IP  Mask: $SERV_MASK  DNS: $SERV_DNS"

    step "Hotspot IP range"
    # Two full addresses, the same shape pydhcp already uses for its own pool
    # (SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK) -- no netmask is assumed.
    echo "Range of fixed addresses handed to voucher-authorized guests."
    echo "Network: ${SERV_SUBNET}/${SERV_MASK}"
    echo "pydhcp block pool: ${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}"
    local net_base
    net_base=$(echo "$SERV_SUBNET" | cut -d'.' -f1-3)
    while true; do
        ask_ip "Hotspot range start" "${net_base}.160" cfg_ini_range
        ask_ip "Hotspot range end" "${net_base}.199" cfg_end_range
        if ! ip_le "$cfg_ini_range" "$cfg_end_range"; then
            err "range start ${cfg_ini_range} is above range end"
            err "range end is ${cfg_end_range}"
            continue
        fi
        if ! ip_in_network "$cfg_ini_range" "$SERV_SUBNET" "$SERV_MASK" \
           || ! ip_in_network "$cfg_end_range" "$SERV_SUBNET" "$SERV_MASK"; then
            err "Range ${cfg_ini_range}-${cfg_end_range} falls outside"
            err "  ${SERV_SUBNET}/${SERV_MASK}. Choose addresses inside the network."
            continue
        fi
        if ranges_overlap "$cfg_ini_range" "$cfg_end_range" "$SERVER_IP" "$SERVER_IP"; then
            err "Range ${cfg_ini_range}-${cfg_end_range} includes the server's own IP"
            err "  (${SERVER_IP}). Choose a different range."
            continue
        fi
        if ranges_overlap "$cfg_ini_range" "$cfg_end_range" \
                           "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK"; then
            err "Range ${cfg_ini_range}-${cfg_end_range} overlaps pydhcp's own pool"
            err "  (${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}). Choose a different range."
            continue
        fi
        break
    done

    step "UniFi credentials"
    ask "UniFi admin username" "admin" cfg_unifi_user
    while true; do
        read -rsp " UniFi admin password: " cfg_unifi_pass; echo ""
        [[ -n "$cfg_unifi_pass" ]] && break
        err "Password cannot be empty."
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
        { err "no UniFi controller detected"; err "check credentials, and that it is running and reachable"; abort "if not installed, use unifisetup.sh first -- abort"; }
    fi

    step "Hotspot SSID"
    # uhm only supports a single guest SSID tied to the UniFi captive
    # portal. Exactly one found -> use it directly, no question. None found
    # is a real UniFi-side problem (no SSID configured, or the query itself
    # failed) -- abort the same way as a missing controller. More than one
    # -> the administrator must pick which one is the captive portal SSID.
    local ssid_list=()
    mapfile -t ssid_list < <(fetch_unifi_ssids "$found_url" "$found_type" "$cfg_unifi_user" "$cfg_unifi_pass")
    if (( ${#ssid_list[@]} == 1 )); then
        cfg_essid="${ssid_list[0]}"
        info "SSID detected: $cfg_essid"
    elif (( ${#ssid_list[@]} > 1 )); then
        echo "Multiple SSIDs found -- select the one used by the captive portal:"
        select cfg_essid in "${ssid_list[@]}"; do
            [[ -n "$cfg_essid" ]] && break
            echo "Invalid selection -- enter the number of one of the SSIDs listed above."
        done
        if [[ -z "$cfg_essid" ]]; then
            err "no SSID selected from the list"
            abort "re-run and pick one of the SSIDs shown -- abort"
        fi
    else
        { err "no SSID detected on the UniFi controller"; abort "configure a guest SSID, then retry -- abort"; }
    fi

    step "Dependency check"
    # Same "unifi" package (Network app / ace.jar) in both types -- classic has
    # it directly on the host, unifi-os has it inside the uosserver container.
    local min_unifi_version="10.4.57"
    local detected_version min_version="$min_unifi_version"
    case "$found_type" in
        classic)
            detected_version=$(dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1) || true
            ;;
        unifi-os)
            detected_version=$(sudo -u uosserver podman exec uosserver \
                dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1) || true
            ;;
    esac
    if [[ -z "$detected_version" ]]; then
        if [[ "$found_type" == "unifi-os" ]] && ! command -v podman &>/dev/null; then
            { err "cannot detect UniFi version: 'podman' not available"; abort "install podman, or use unifisetup.sh -- abort"; }
        fi
        { err "cannot detect UniFi version (type: ${found_type})"; err "uhm supports only the versions tested to date"; abort "check the UniFi installation, then re-run -- abort"; }
    fi
    if ! version_ge "$detected_version" "$min_version"; then
        { err "UniFi ${detected_version} (${found_type}) is below ${min_version}"; abort "uhm needs ${min_version} or above -- abort"; }
    fi
    info "UniFi version ${detected_version} (${found_type}) meets minimum"
    info "  tested version (${min_version})"

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
        warn "  uhmd will connect without pinning"
    fi

    step "Reload script"
    echo "Script invoked after every ACL change (must exist and be executable)."
    ask "Path to reload script" "${core_dir}/uhmreload.sh" cfg_reload_script

    step "Timers"
    ask_number "Daemon poll interval in seconds (POLL_INTERVAL)" "20" cfg_poll_interval
    ask_number "Grace period before blocking unknown MACs in seconds (BLOCKDHCP_GRACE_SECONDS)" "86400" cfg_grace_seconds

    step "Managed MAC lists (optional)"
    echo "mac-*.txt files allow specific devices to bypass the captive portal"
    echo "automatically (corporate laptops, APs, printers, switches, etc.)."
    echo "They bypass entirely at the DHCP level (uhmleases.sh) -- the daemon"
    echo "itself never authorizes them in UniFi."
    echo "Files are stored in /etc/acl/mac/ and managed manually."
    mkdir -p /etc/acl/mac
    chmod 700 /etc/acl/mac
    info "Directory /etc/acl/mac created"
    info "  add your mac-*.txt files there"

    step "Writing $config_file"
    (
        umask 077
        local essid_answer user_answer pass_answer url_answer reload_script_answer
        essid_answer=$(dq_escape "$cfg_essid")
        user_answer=$(dq_escape "$cfg_unifi_user")
        pass_answer=$(dq_escape "$cfg_unifi_pass")
        reload_script_answer=$(dq_escape "$cfg_reload_script")
        url_answer=$(dq_escape "$found_url")

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
        uhm_block=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }

        cat > "$uhm_block" <<EOF
# =============================================================================
# UHM
# /etc/uhm/uhm.env
# =============================================================================
# -- UniFi keys ---------------------------------------------------------------
# Guest SSID
UHM_ESSID="${essid_answer}"
# Unifi Access
UNIFI_CONTROLLER_URL="${url_answer}"
UNIFI_USERNAME="${user_answer}"
UNIFI_PASSWORD="${pass_answer}"
# UniFi always creates a site named "default". If the administrator renamed it,
# edit this value to match the exact site name shown in the UniFi controller.
UNIFI_SITE="default"
# Unifi type (classic or unifi-os)
UNIFI_TYPE="${found_type}"
# Cert
UNIFI_CERT_PIN="${cfg_cert_pin}"
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
UHM_RELOAD="${reload_script_answer}"
UHM_LEASES="${core_dir}/uhmleases.sh"
# By sysadmin
UHM_IPTABLES="${uhm_iptables_dest}"
# Timeouts (uhmd -> uhmreload -> uhmleases.sh/uhmiptables.sh)
UHM_LEASES_TIMEOUT_SECONDS=120
UHM_IPTABLES_TIMEOUT_SECONDS=60
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
                    warn "$env_key already set in $(basename "$pydhcp_env") -- not written again"
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
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$dest_path") missing -- creating empty"
        install -m 600 -o root -g root "$repo_file" "$dest_path"
    done
    info "ACL data files present in ${acl_dir}"
}

deploy_scripts() {
    install -m 755 -o root -g root "$repo_uhmd" "${core_dir}/uhmd.sh"
    install -m 755 -o root -g root "${repo_core}/uhmreload.sh" "${core_dir}/uhmreload.sh"
    install -m 755 -o root -g root "${repo_core}/uhmleases.sh" "${core_dir}/uhmleases.sh"
    # uhmwatch.sh lives under core/ (not tools/) because it is mandatory,
    # not an optional utility -- deployed explicitly here for that reason,
    # same as the other three core scripts above.
    install -m 755 -o root -g root "${repo_core}/uhmwatch.sh" "${core_dir}/uhmwatch.sh"
    local repo_file
    for repo_file in "${repo_tools}/"*.sh; do
        # uhmiptables.sh is the administrator's own file once customized, so it
        # is deployed by deploy_uhmiptables() below (only when absent) instead
        # of being overwritten here on every run.
        [[ "$(basename "$repo_file")" == "uhmiptables.sh" ]] && continue
        install -m 755 -o root -g root "$repo_file" "${tools_dir}/"
    done
    # Remove any copy left at the pre-restructure locations (directly under
    # $hotspot_dir / $tools_dir instead of core/), so at most one copy of
    # each script exists on disk. uhmwatch.sh's own pre-restructure location
    # is tools/ (where it lived before becoming mandatory), not $hotspot_dir.
    rm -f "${hotspot_dir}/uhmd.sh" "${tools_dir}/uhmreload.sh" "${tools_dir}/uhmleases.sh" "${tools_dir}/uhmwatch.sh"
    info "Scripts deployed to ${hotspot_dir}"
}

deploy_uhmiptables() {
    if [[ -f "$uhm_iptables_dest" ]]; then
        info "uhmiptables.sh already exists -- skip"
        return 0
    fi
    install -m 750 -o root -g root "${repo_tools}/uhmiptables.sh" "$uhm_iptables_dest"
    info "Minimal template deployed to $uhm_iptables_dest (routing + NAT only)"
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
        info "logrotate config already present at $logrotate_file"
    else
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$logrotate_file") missing -- creating it"
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

deregister_cron() {
    # uhmd triggers its own safety-net reload internally (see
    # RELOAD_SAFETY_INTERVAL_SECONDS in uhmd.sh) -- no external cron
    # entry should exist. Removes a leftover @hourly uhmreload.sh entry if
    # found, matching both the current core/uhmreload.sh path and the
    # pre-restructure tools/uhmreload.sh path.
    local ureload_path_new="${hotspot_dir}/core/uhmreload.sh"
    local ureload_path_old="${hotspot_dir}/tools/uhmreload.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$ureload_path_new" -e "$ureload_path_old"; then
        crontab -l 2>/dev/null | grep -vF -e "$ureload_path_new" -e "$ureload_path_old" | crontab - || true
        info "Removed stale @hourly uhmreload.sh cron entry"
        info "  (now handled by uhmd.sh internally)"
    fi
}

final_sanity_check() {
    step "Sanity check"
    local issue_list=0

    if [[ ! -x "$uhm_iptables_dest" ]]; then
        warn "uhmiptables.sh is missing or not executable"
        warn "  ACL changes will not reach the firewall"
        (( issue_list++ )) || true
    fi

    if (( issue_list == 0 )); then
        info "All checks passed."
    else
        warn "${issue_list} issue(s) need attention before uhm is fully functional."
    fi
}

install_systemd_service() {
    install -m 644 -o root -g root "$repo_service" "$service_dest"
    systemctl daemon-reload
    systemctl enable uhmd
    if systemctl restart uhmd; then
        info "uhmd enabled and started"
    else
        warn "Could not start uhmd -- alert"
        warn "check it with: systemctl status uhmd"
    fi
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

do_install() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- installer"
    echo "------------------------------------------------------"

    if [[ -d "$hotspot_dir" ]]; then
        abort "uhm is already installed at ${hotspot_dir}.
  Use --update to upgrade (keeps config), or --remove to remove first."
    fi

    trap 'install_exit_code=$?; trap - EXIT; (( install_exit_code != 0 )) && { warn "Installation failed, rolling back changes"; perform_remove; }' EXIT

    step "Preflight"
    check_distro
    check_repo_files

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
    bash "${core_dir}/uhmwatch.sh" install

    step "Optional components"
    if confirm "Install uhmalert (ntfy push notifications on connectivity loss)?" "n"; then
        bash "${tools_dir}/uhmalert.sh" install
    fi
    if dpkg -s webmin &>/dev/null; then
        if confirm "Install the Webmin log viewer module?" "n"; then
            bash "${tools_dir}/uhmwebmin.sh" install
        fi
    else
        info "Webmin not detected, module prompt -- skip"
        info "  install Webmin first, run: bash tools/uhmwebmin.sh install"
    fi

    step "Cron"
    deregister_cron

    final_sanity_check

    trap - EXIT

    echo ""
    echo "------------------------------------------------------"
    echo "uhm installed."
    echo ""
    echo "Next steps:"
    echo "1. Optional: ${uhm_iptables_dest} is a minimal template"
    echo "   (routing + NAT). For full enforcement, copy"
    echo "   tools/uhmiptables_example.txt over it and adapt it."
    echo "2. Check service: systemctl status uhmd"
    echo "3. Check logs: tail -f ${uhm_log_file}"
    echo "------------------------------------------------------"
    echo ""
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

do_update() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- update"
    echo "------------------------------------------------------"

    step "Preflight"
    check_distro
    check_repo_files

    # Accepts either the current core/ layout or the pre-restructure layout
    # (uhmd.sh directly under $hotspot_dir, uhmreload.sh/uhmleases.sh under
    # $tools_dir), so an update from an old install isn't mistaken for a
    # fresh one.
    if [[ ! -d "$hotspot_dir" ]] || { [[ ! -f "${core_dir}/uhmd.sh" ]] && [[ ! -f "${hotspot_dir}/uhmd.sh" ]]; }; then
        { err "uhm not installed"; abort "run without --update first -- abort"; }
    fi

    step "Backup"
    if [[ -x "$bkstack_script" ]]; then
        "$bkstack_script" || warn "backup failed, continuing -- alert"
    else
        warn "$bkstack_script not found, no backup taken -- alert"
    fi

    step "Pause services"
    # Stop whatever is actively running its own script file before that file
    # gets overwritten below -- avoids replacing a script out from under a
    # process that may still be mid-cycle. pydhcpd is deliberately left
    # alone: it is a separate project this update never modifies, and
    # stopping it would cut DHCP for the whole LAN, not just the hotspot.
    local uwatch_path="${core_dir}/uhmwatch.sh"
    local uwatch_path_legacy="${tools_dir}/uhmwatch.sh"
    local uhmd_was_active=0 ualert_was_active=0 uwatch_was_active=0
    systemctl is-active --quiet uhmd 2>/dev/null && uhmd_was_active=1
    if [[ -f /etc/systemd/system/uhmalert.service ]]; then
        systemctl is-active --quiet uhmalert 2>/dev/null && ualert_was_active=1
    fi
    if crontab -l 2>/dev/null | awk -v p="$uwatch_path" -v pl="$uwatch_path_legacy" \
        '((index($0,p)>0 || index($0,pl)>0) && substr($0,1,1)!="#"){found_entry=1} END{exit !found_entry}'; then
        uwatch_was_active=1
    fi

    if (( uhmd_was_active )); then
        systemctl stop uhmd && info "uhmd stopped for update" || warn "Could not stop uhmd, continuing anyway"
    fi
    if (( ualert_was_active )); then
        systemctl stop uhmalert && info "uhmalert stopped for update" || warn "Could not stop uhmalert, continuing anyway"
    fi
    if (( uwatch_was_active )); then
        # Remove the active line outright (whichever path it used, current
        # or the pre-restructure tools/ one) instead of just commenting it
        # out -- Resume below re-registers a clean entry at the current
        # path via `uhmwatch.sh install`, which also self-migrates away
        # any stale legacy-path entry. Simpler and correct across the
        # core/-relocation than trying to text-surgery two possible paths.
        crontab -l 2>/dev/null | grep -vF -e "$uwatch_path" -e "$uwatch_path_legacy" | crontab -
        info "uhmwatch cron entry removed for update"
        info "  (re-registered on resume)"
    fi

    step "Deploy updated scripts"
    deploy_scripts

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
            warn "Could not restart uhmd -- alert"
            warn "check it with: systemctl status uhmd"
        fi
    else
        info "uhmd was not active before the update, left stopped"
    fi

    step "Resume services"
    # Only restore what this update itself paused above -- never start
    # something the administrator had deliberately left stopped/disabled.
    if (( ualert_was_active )); then
        systemctl start uhmalert && info "uhmalert restarted" || { warn "Could not restart uhmalert -- alert"; warn "check it with: systemctl status uhmalert"; }
    fi
    if (( uwatch_was_active )); then
        # Re-registers a clean entry at the current core/ path -- also
        # self-migrates away any stale legacy tools/ entry, though Pause
        # above already removed the one this run knew was active.
        bash "${core_dir}/uhmwatch.sh" install
        info "uhmwatch cron entry restored"
    elif ! crontab -l 2>/dev/null | grep -qF -e "$uwatch_path" -e "$uwatch_path_legacy"; then
        # No entry at all (active or commented) -- this install predates
        # uhmwatch becoming mandatory. Install it now rather than leaving
        # an update-in-place without it.
        bash "${core_dir}/uhmwatch.sh" install
        info "uhmwatch installed (was missing, now mandatory)"
    fi

    step "Cron"
    deregister_cron

    echo ""
    echo "------------------------------------------------------"
    echo "Update complete."
    echo ""
    echo "Preserved (never renamed/moved/overwritten if already present):"
    echo "- ${config_file}"
    echo "- ${uhm_iptables_dest}"
    echo "- ACL data files (*.txt)"
    echo "- Logrotate config"
    echo ""
    echo "Paused for the update, then resumed to their prior state:"
    echo "- uhmd.service, uhmalert.service (if it was active)"
    echo "- uhmwatch cron entry (if it was active, or installed"
    echo "  now if this update predates it becoming mandatory)"
    echo ""
    echo "Stale @hourly uhmreload.sh cron entry removed if present"
    echo ""

    echo "------------------------------------------------------"
    echo ""
}

# ------------------------------------------------------------------------------
# REMOVE
# ------------------------------------------------------------------------------

do_remove() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- uninstaller"
    echo "------------------------------------------------------"

    echo ""
    warn "This will permanently remove, without asking again:"
    warn "  - uhmd.service (stopped and disabled) and $service_dest"
    warn "  - cron entries pointing to ${hotspot_dir}/core/uhmreload.sh"
    warn "  - the uhmwatch cron entry"
    warn "  - uhmalert.service if installed"
    warn "  - Webmin module (uhmwebmin) if installed"
    warn "  - ${logrotate_file}"
    warn "  - ${hotspot_dir}"
    warn "    including uhm.env, the ACL lists and YOUR uhmiptables.sh"
    warn "    Run ${bkstack_script} first if you want a backup"
    warn "  - ${uhm_log_file}, rotated logs"
    warn "  - uhmunifi.log and reload failure traces"
    warn "Package dependencies"
    warn "  (curl, jq, iptables, ipset, etc.) are NOT removed."
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" || { info "Aborted by user."; exit 0; }

    perform_remove
}

perform_remove() {
    # Everything below is unconditional -- the single confirmation above,
    # with the full list of what gets removed, is the only gate. Uninstall
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
    # Matches both the current core/uhmreload.sh path and the pre-restructure
    # tools/uhmreload.sh path.
    local ureload_path="${hotspot_dir}/core/uhmreload.sh"
    local ureload_path_old="${hotspot_dir}/tools/uhmreload.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$ureload_path" -e "$ureload_path_old"; then
        crontab -l 2>/dev/null | grep -vF -e "$ureload_path" -e "$ureload_path_old" | crontab - || true
        info "Cron entries removed"
    else
        info "No cron entries found"
    fi

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
    local uwatch_path="${core_dir}/uhmwatch.sh"
    local uwatch_path_legacy="${tools_dir}/uhmwatch.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$uwatch_path" -e "$uwatch_path_legacy"; then
        crontab -l 2>/dev/null | grep -vF -e "$uwatch_path" -e "$uwatch_path_legacy" | crontab - || true
        info "uhmwatch cron entry removed"
    else
        info "No uhmwatch cron entry found"
    fi

    # uhmwebmin / Webmin module (optional component)
    step "uhmwebmin (Webmin module)"
    if [[ -d /usr/share/webmin/uhm ]]; then
        if [[ -f "${tools_dir}/uhmwebmin.sh" ]]; then
            bash "${tools_dir}/uhmwebmin.sh" uninstall || {
                warn "uhmwebmin.sh uninstall failed -- alert"
                warn "remove /usr/share/webmin/uhm and /etc/webmin/uhm by hand"
            }
        else
            warn "Webmin module found but ${tools_dir}/uhmwebmin.sh is missing"
            warn "  remove /usr/share/webmin/uhm and /etc/webmin/uhm manually"
        fi
    else
        info "Webmin module not installed"
    fi

    # Logrotate
    step "Logrotate"
    if [[ -f "$logrotate_file" ]]; then
        rm -f "$logrotate_file"
        info "Removed $logrotate_file"
    else
        info "No logrotate config found"
    fi

    # /etc/uhm
    step "$hotspot_dir"
    if [[ -d "$hotspot_dir" ]]; then
        # Everything under hotspot_dir goes, including uhm.env, the ACL
        # lists and uhmiptables.sh: uninstalling means removing the project.
        # bkstack.sh keeps a copy in /etc/bak, out of reach of this removal.
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

    echo ""
    echo "------------------------------------------------------"
    echo "Uninstall complete."
    echo ""
    echo "IMPORTANT: Firewall rules and ipsets (macgrace, machotspot)"
    echo "were NOT touched. Flush them manually if needed:"
    echo "sudo ipset destroy macgrace 2>/dev/null"
    echo "sudo ipset destroy machotspot 2>/dev/null"
    echo "# then flush related iptables rules"
    echo "------------------------------------------------------"
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {
    log "uhmsetup start..."
    case "${1:-}" in
        ""|install)
            check_apt_deps
            detect_dhcp_backend
            load_pydhcp_env
            do_install
            log "uhmsetup done at: $(date)"
            exit 0
            ;;
        --update|update)
            check_apt_deps
            detect_dhcp_backend
            do_update
            log "uhmsetup done at: $(date)"
            exit 0
            ;;
        --remove|remove|--uninstall|uninstall)
            do_remove
            printf ' \e[32m \e[0m %s\n' "uhmsetup done at: $(date)"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
