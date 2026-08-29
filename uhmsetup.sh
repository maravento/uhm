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
# install can be compared against the updates that followed it. Not covered
# by /etc/logrotate.d/uhm; empty it by hand when needed:
# truncate -s 0 uhmsetup.log
#
################################################################################

set -euo pipefail

# --- Usage -------------------------------------------------------------------
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

## root check
if [[ "$(id -u)" != "0" ]]; then
    echo "ERROR: This script must be run as root -- abort" >&2
    exit 1
fi

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    echo "ERROR: script $(basename "$0") is already running -- abort" >&2
    exit 1
fi

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTSPOT_DIR="/etc/uhm"
CORE_DIR="${HOTSPOT_DIR}/core"
TOOLS_DIR="${HOTSPOT_DIR}/tools"
ACL_DIR="${HOTSPOT_DIR}/acl"
CONFIG_FILE="${HOTSPOT_DIR}/uhm.env"
PYDHCP_ENV="/etc/pydhcp/pydhcp.env"
BKSTACK="/etc/pydhcp/tools/bkstack.sh"
LOG_FILE="${SCRIPT_DIR}/uhmsetup.log"
UHM_LOG_FILE="/var/log/uhm.log"
LOGROTATE_FILE="/etc/logrotate.d/uhm"
UHM_IPTABLES_DEST="${TOOLS_DIR}/uhmiptables.sh"
SERVICE_DEST="/etc/systemd/system/uhmd.service"

# --- Repo file expectations (relative to this script) ------------------------
REPO_CORE="${SCRIPT_DIR}/core"
REPO_TOOLS="${SCRIPT_DIR}/tools"
REPO_ACL="${SCRIPT_DIR}/acl"
REPO_UHMD="${REPO_CORE}/uhmd.sh"
REPO_SERVICE="${SCRIPT_DIR}/service/uhmd.service"

# --- Required apt packages ----------------------------------------------------
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- so a
# missing package is reported here instead of failing later in uhmd,
# uhmacl, uhmunifi or uhmiptables.
APT_DEPS=(curl jq iptables ipset python3 openssl bsdextrautils mawk coreutils util-linux iproute2 cron grep sed systemd ncurses-bin libc-bin findutils procps)

# --- Discovered runtime values (filled during install) -----------------------
DHCP_BACKEND="" # "pydhcpd"

# --- Output helpers ----------------------------------------------------------
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
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

# VALIDATION -- one variable per thing validated; use directly with =~
_UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
_UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
_UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
_UH_UINT='^(0|[1-9][0-9]*)$'
_UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
_UH_MAC='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
_UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# Appends $2 (one or more lines) right after the file's LAST
# "# ====...====" line, instead of a plain >> append -- so a new block
# always lands right after whatever content (from any project sharing this
# file) is already there, never after a stray trailing line some other
# script might append later. Falls back to a plain append if the file has
# no delimiter line at all (empty/malformed file).
insert_after_last_delimiter() {
    local file="$1" content="$2" last_line tmp
    last_line=$(grep -n '^# =\{5,\}$' "$file" | tail -1 | cut -d: -f1)
    if [[ -z "$last_line" ]]; then
        printf '\n%s\n' "$content" >> "$file"
        return
    fi
    tmp=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }
    head -n "$last_line" "$file" > "$tmp"
    printf '\n%s\n' "$content" >> "$tmp"
    tail -n "+$((last_line + 1))" "$file" >> "$tmp"
    mv "$tmp" "$file"
}

dq_escape() {
    # dq_escape STRING -- escape \ " $ ` for safe reuse inside double quotes
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt="$1" default="${2:-n}" answer hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp " ${prompt} ${hint}: " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

# --- Preflight checks --------------------------------------------------------
check_distro() {
    local id="" ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        id="${ID:-}"
        ver="${VERSION_ID:-}"
    fi
    if [[ "$id" != "ubuntu" || "$ver" != "24.04" ]]; then
        warn "Tested only on Ubuntu 24.04. Detected: ${id:-unknown} ${ver:-unknown}"
        warn "Continuing at your own risk."
    else
        info "Ubuntu ${ver} detected"
    fi
}

check_repo_files() {
    [[ -r "$REPO_UHMD" ]] || { err "missing $(basename "$REPO_UHMD")"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "$REPO_SERVICE" ]] || { err "missing $(basename "$REPO_SERVICE")"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${REPO_CORE}/uhmreload.sh" ]] || { err "missing core/uhmreload.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${REPO_CORE}/uhmleases.sh" ]] || { err "missing core/uhmleases.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -r "${REPO_CORE}/uhmwatch.sh" ]] || { err "missing core/uhmwatch.sh"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -d "$REPO_TOOLS" ]] || { err "missing tools/ directory"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    [[ -d "$REPO_ACL" ]] || { err "missing acl/ directory"; abort "run uhmsetup.sh from inside the cloned repo -- abort"; }
    info "Repo files located"
}

check_apt_deps() {
    local missing=()
    for pkg in "${APT_DEPS[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if (( ${#missing[@]} > 0 )); then
        { err "missing package(s): ${missing[*]}"; abort "install them with apt, then re-run -- abort"; }
    fi
    info "All apt dependencies present: ${APT_DEPS[*]}"
}

detect_dhcp_backend() {
    local pydhcp_active=false
    systemctl is-active --quiet pydhcpd 2>/dev/null && pydhcp_active=true

    if $pydhcp_active; then
        DHCP_BACKEND="pydhcpd"
        info "DHCP backend detected: pydhcpd"
    else
        err "pydhcpd is not active."
        err "Install pydhcpd from https://github.com/maravento/pydhcp"
        abort "DHCP backend required -- abort"
    fi
}

# Reads pydhcp's own network values (server IP, mask, subnet, broadcast, DNS,
# blockdhcp pool range) from PYDHCP_ENV instead of asking for them again --
# pysetup.sh already collected and persisted them. Only the keys this
# installer itself needs for the wizard are required here: the rest live in
# pydhcp.env and each component reads them from there at runtime, warning
# and falling back if one is missing.
# Sets CFG_SERVER_IP, CFG_SERV_MASK, CFG_SERV_SUBNET, CFG_SERV_BROADCAST,
# CFG_SERV_DNS, CFG_SERV_INI_RANGE_BLOCK, CFG_SERV_END_RANGE_BLOCK for
# run_setup_wizard.
load_pydhcp_env() {
    [ -f "$PYDHCP_ENV" ] \
        || { err "$PYDHCP_ENV not found"; abort "install pydhcp first, see its README -- abort"; }

    local missing=() key
    for key in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK \
               SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
        grep -q "^${key}=" "$PYDHCP_ENV" || missing+=("$key")
    done
    if (( ${#missing[@]} > 0 )); then
        err "$PYDHCP_ENV is missing pydhcp's own keys: ${missing[*]}"
        abort "re-run pydhcp pysetup.sh, or restore the backup -- abort"
    fi

    # Load only these known keys instead of sourcing the whole file, so a
    # tampered pydhcp.env cannot execute code.
    local line key2 value raw_key2 raw_value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key2="${line%%=*}"
        value="${line#*=}"
        raw_key2="$key2" raw_value="$value"
        key2="${key2#"${key2%%[![:space:]]*}"}"
        key2="${key2%"${key2##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$key2" != "$raw_key2" || "$value" != "$raw_value" ]]; then
            log "WARNING: stray whitespace fixed -- alert"
            log "WARNING: key $key2"
        fi
        case "$key2" in
            SERVER_IP)            CFG_SERVER_IP="$value" ;;
            SERV_MASK)            CFG_SERV_MASK="$value" ;;
            SERV_SUBNET)          CFG_SERV_SUBNET="$value" ;;
            SERV_BROADCAST)       CFG_SERV_BROADCAST="$value" ;;
            SERV_DNS)             CFG_SERV_DNS="$value" ;;
            SERV_INI_RANGE_BLOCK) CFG_SERV_INI_RANGE_BLOCK="$value" ;;
            SERV_END_RANGE_BLOCK) CFG_SERV_END_RANGE_BLOCK="$value" ;;
        esac
    done < "$PYDHCP_ENV"

    local _v
    for _v in CFG_SERVER_IP CFG_SERV_SUBNET CFG_SERV_BROADCAST \
              CFG_SERV_INI_RANGE_BLOCK CFG_SERV_END_RANGE_BLOCK; do
        [[ "${!_v:-}" =~ $_UH_IPV4 ]] \
            || { err "invalid IPv4 in ${_v#CFG_}: '${!_v:-}'"; abort "fix it in $PYDHCP_ENV and retry -- abort"; }
    done
    [[ "${CFG_SERV_MASK:-}" =~ $_UH_NETMASK ]] \
        || { err "invalid netmask in SERV_MASK: '${CFG_SERV_MASK:-}'"; abort "fix it in $PYDHCP_ENV and retry -- abort"; }
    [[ "${CFG_SERV_DNS:-}" =~ $_UH_DNS ]] \
        || { err "invalid SERV_DNS list: '${CFG_SERV_DNS:-}'"; abort "fix it in $PYDHCP_ENV and retry -- abort"; }
}

# --- Interactive prompts ------------------------------------------------------
ask() {
    local prompt="$1" default="$2" var="$3" answer
    read -rp " ${prompt} [${default}]: " answer
    printf -v "$var" '%s' "${answer:-$default}"
}

ask_interface() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if ip link show "$answer" &>/dev/null; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "interface '$answer' not found"
        err "available: $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)"
    done
}

ask_number() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_UINT ]] && (( answer >= 1 )); then
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "'$answer' is not valid. Enter a positive integer."
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
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_IPV4 ]]; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "'$answer' is not a valid IPv4 address."
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
    local s1="$1" e1="$2" s2="$3" e2="$4"
    python3 -c "
import ipaddress, sys
s1, e1, s2, e2 = (ipaddress.IPv4Address(a) for a in sys.argv[1:5])
sys.exit(0 if s1 <= e2 and s2 <= e1 else 1)
" "$s1" "$e1" "$s2" "$e2"
}

# --- UniFi controller discovery ----------------------------------------------
DISCOVERED_URL=""
DISCOVERED_TYPE=""

discover_unifi_controller() {
    local user="$1" pass="$2" server_ip="$3"
    local ports=(8443 11443)
    local test_url http_code payload

    info "Probing ${server_ip} on ports ${ports[*]} ..."
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline).
    payload=$(UH_JQ_USER="$user" UH_JQ_PASS="$pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    for port in "${ports[@]}"; do
        test_url="https://${server_ip}:${port}"

        # Body goes to curl via stdin (--data-binary @-), not -d, for the
        # same reason: -d "$payload" would put the password in curl's argv.
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/auth/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found UniFi OS controller at ${test_url}"
            DISCOVERED_URL="$test_url"
            DISCOVERED_TYPE="unifi-os"
            return 0
        fi

        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found classic UniFi controller at ${test_url}"
            DISCOVERED_URL="$test_url"
            DISCOVERED_TYPE="classic"
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
    local url="$1" type="$2" user="$3" pass="$4"
    local login_path base_path payload cookie_jar

    if [[ "$type" == "unifi-os" ]]; then
        login_path="/api/auth/login"
        base_path="/proxy/network/api/s/default"
    else
        login_path="/api/login"
        base_path="/api/s/default"
    fi

    payload=$(UH_JQ_USER="$user" UH_JQ_PASS="$pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    cookie_jar=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }

    curl -sk -c "$cookie_jar" -o /dev/null \
        -X POST "${url}${login_path}" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 5 <<< "$payload"

    curl -sk -b "$cookie_jar" "${url}${base_path}/rest/wlanconf" --connect-timeout 5 \
        | jq -r '.data[]?.name // empty' 2>/dev/null

    rm -f "$cookie_jar"
}

# --- Setup wizard ------------------------------------------------------------
run_setup_wizard() {
    local CFG_WAN_IF
    local CFG_INI_RANGE CFG_END_RANGE CFG_ESSID
    local CFG_UNIFI_USER CFG_UNIFI_PASS CFG_RELOAD_SCRIPT
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
    local ifaces
    ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)
    echo "Available interfaces: $ifaces"
    ask_interface "WAN interface" "eth0" CFG_WAN_IF
    if [[ -f "$UHM_IPTABLES_DEST" ]]; then
        sed -i "s:eth0:$CFG_WAN_IF:g" "$UHM_IPTABLES_DEST"
    fi

    step "pydhcp network configuration"
    info "Loaded from $PYDHCP_ENV"
    info "  Server IP: $CFG_SERVER_IP  Mask: $CFG_SERV_MASK  DNS: $CFG_SERV_DNS"

    step "Hotspot IP range"
    # Two full addresses, the same shape pydhcp already uses for its own pool
    # (SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK) -- no netmask is assumed.
    echo "Range of fixed addresses handed to voucher-authorized guests."
    echo "Network: ${CFG_SERV_SUBNET}/${CFG_SERV_MASK}"
    echo "pydhcp block pool: ${CFG_SERV_INI_RANGE_BLOCK}-${CFG_SERV_END_RANGE_BLOCK}"
    local _net_base
    _net_base=$(echo "$CFG_SERV_SUBNET" | cut -d'.' -f1-3)
    while true; do
        ask_ip "Hotspot range start" "${_net_base}.160" CFG_INI_RANGE
        ask_ip "Hotspot range end" "${_net_base}.199" CFG_END_RANGE
        if ! ip_le "$CFG_INI_RANGE" "$CFG_END_RANGE"; then
            err "range start ${CFG_INI_RANGE} is above range end"
            err "range end is ${CFG_END_RANGE}"
            continue
        fi
        if ! ip_in_network "$CFG_INI_RANGE" "$CFG_SERV_SUBNET" "$CFG_SERV_MASK" \
           || ! ip_in_network "$CFG_END_RANGE" "$CFG_SERV_SUBNET" "$CFG_SERV_MASK"; then
            err "Range ${CFG_INI_RANGE}-${CFG_END_RANGE} falls outside"
            err "  ${CFG_SERV_SUBNET}/${CFG_SERV_MASK}. Choose addresses inside the network."
            continue
        fi
        if ranges_overlap "$CFG_INI_RANGE" "$CFG_END_RANGE" "$CFG_SERVER_IP" "$CFG_SERVER_IP"; then
            err "Range ${CFG_INI_RANGE}-${CFG_END_RANGE} includes the server's own IP"
            err "  (${CFG_SERVER_IP}). Choose a different range."
            continue
        fi
        if ranges_overlap "$CFG_INI_RANGE" "$CFG_END_RANGE" \
                           "$CFG_SERV_INI_RANGE_BLOCK" "$CFG_SERV_END_RANGE_BLOCK"; then
            err "Range ${CFG_INI_RANGE}-${CFG_END_RANGE} overlaps pydhcp's own pool"
            err "  (${CFG_SERV_INI_RANGE_BLOCK}-${CFG_SERV_END_RANGE_BLOCK}). Choose a different range."
            continue
        fi
        break
    done

    step "UniFi credentials"
    ask "UniFi admin username" "admin" CFG_UNIFI_USER
    while true; do
        read -rsp " UniFi admin password: " CFG_UNIFI_PASS; echo ""
        [[ -n "$CFG_UNIFI_PASS" ]] && break
        err "Password cannot be empty."
    done

    step "UniFi controller discovery"
    # uhm only supports a single controller -- discover_unifi_controller()
    # returns on the first match found, so "more than one" cannot occur here.
    # Not found means a real UniFi-side problem (wrong credentials, controller
    # down, unexpected port); there is no sensible manual fallback to ask for.
    DISCOVERED_URL=""
    DISCOVERED_TYPE=""
    if discover_unifi_controller "$CFG_UNIFI_USER" "$CFG_UNIFI_PASS" "$CFG_SERVER_IP"; then
        found_url="$DISCOVERED_URL"
        found_type="$DISCOVERED_TYPE"
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
    mapfile -t ssid_list < <(fetch_unifi_ssids "$found_url" "$found_type" "$CFG_UNIFI_USER" "$CFG_UNIFI_PASS")
    if (( ${#ssid_list[@]} == 1 )); then
        CFG_ESSID="${ssid_list[0]}"
        info "SSID detected: $CFG_ESSID"
    elif (( ${#ssid_list[@]} > 1 )); then
        echo "Multiple SSIDs found -- select the one used by the captive portal:"
        select CFG_ESSID in "${ssid_list[@]}"; do
            [[ -n "$CFG_ESSID" ]] && break
            echo "Invalid selection -- enter the number of one of the SSIDs listed above."
        done
        if [[ -z "$CFG_ESSID" ]]; then
            err "no SSID selected from the list"
            abort "re-run and pick one of the SSIDs shown -- abort"
        fi
    else
        { err "no SSID detected on the UniFi controller"; abort "configure a guest SSID, then retry -- abort"; }
    fi

    step "Dependency check"
    # Same "unifi" package (Network app / ace.jar) in both types -- classic has
    # it directly on the host, unifi-os has it inside the uosserver container.
    local MIN_VERSION_UNIFI="10.4.57"
    local detected_version min_version="$MIN_VERSION_UNIFI"
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
    local CFG_CERT_PIN=""
    local pin_host="${found_url#*://}"
    pin_host="${pin_host%%/*}"
    local pin_port="443"
    if [[ "$pin_host" == *:* ]]; then
        pin_port="${pin_host##*:}"
        pin_host="${pin_host%%:*}"
    fi
    CFG_CERT_PIN=$(openssl s_client -connect "${pin_host}:${pin_port}" -servername "$pin_host" </dev/null 2>/dev/null \
        | openssl x509 -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl enc -base64 2>/dev/null) || true
    if [[ -n "$CFG_CERT_PIN" ]]; then
        CFG_CERT_PIN="sha256//${CFG_CERT_PIN}"
        info "TLS certificate pinned"
    else
        warn "Could not compute TLS certificate pin"
        warn "  uhmd will connect without pinning"
    fi

    step "Reload script"
    echo "Script invoked after every ACL change (must exist and be executable)."
    ask "Path to reload script" "${CORE_DIR}/uhmreload.sh" CFG_RELOAD_SCRIPT

    step "Timers"
    ask_number "Daemon poll interval in seconds (POLL_INTERVAL)" "20" CFG_POLL_INTERVAL
    ask_number "Grace period before blocking unknown MACs in seconds (BLOCKDHCP_GRACE_SECONDS)" "86400" CFG_GRACE_SECONDS

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

    step "Writing $CONFIG_FILE"
    (
        umask 077
        local ESSID_Q USER_Q PASS_Q URL_Q RELOAD_SCRIPT_Q
        ESSID_Q=$(dq_escape "$CFG_ESSID")
        USER_Q=$(dq_escape "$CFG_UNIFI_USER")
        PASS_Q=$(dq_escape "$CFG_UNIFI_PASS")
        RELOAD_SCRIPT_Q=$(dq_escape "$CFG_RELOAD_SCRIPT")
        URL_Q=$(dq_escape "$found_url")

        # uhm.env holds only uhm's own keys. pydhcp's values (network,
        # ACL paths, leases) stay in pydhcp.env and are read from there at
        # runtime, so a change in that file reaches uhm without a re-install.
        : > "$CONFIG_FILE"

        # Any key pydhcp.env already defines -- pydhcp's own, or one added
        # there by another project -- is skipped
        # instead of written here too: every component reads pydhcp.env
        # first and uhm.env after, so a duplicate would let uhm.env shadow
        # the value its owner maintains.
        local _uhm_block
        _uhm_block=$(mktemp) || { err "cannot create temp file in /tmp"; abort "check free space, read-only mount, immutable -- abort"; }

        cat > "$_uhm_block" <<EOF
# =============================================================================
# UHM
# /etc/uhm/uhm.env
# =============================================================================
# -- UniFi keys ---------------------------------------------------------------
# Guest SSID
UHM_ESSID="${ESSID_Q}"
# Unifi Access
UNIFI_CONTROLLER_URL="${URL_Q}"
UNIFI_USERNAME="${USER_Q}"
UNIFI_PASSWORD="${PASS_Q}"
# UniFi always creates a site named "default". If the administrator renamed it,
# edit this value to match the exact site name shown in the UniFi controller.
UNIFI_SITE="default"
# Unifi type (classic or unifi-os)
UNIFI_TYPE="${found_type}"
# Cert
UNIFI_CERT_PIN="${CFG_CERT_PIN}"
# -- Hotspot keys ---------------------------------------------------------------
# Hotspot Range
UHM_INI_RANGE=${CFG_INI_RANGE}
UHM_END_RANGE=${CFG_END_RANGE}
# Daemon timers (uhm's own)
POLL_INTERVAL=${CFG_POLL_INTERVAL}
STARTUP_GRACE_SECONDS=120
RELOAD_SAFETY_INTERVAL_SECONDS=3600
BLOCKDHCP_GRACE_SECONDS=${CFG_GRACE_SECONDS}
RECOVERY_COOLDOWN_SECONDS=600
# -- Scripts ------------------------------------------------------------------
UHM_RELOAD="${RELOAD_SCRIPT_Q}"
UHM_LEASES="${CORE_DIR}/uhmleases.sh"
# By sysadmin
UHM_IPTABLES="${UHM_IPTABLES_DEST}"
# Timeouts (uhmd -> uhmreload -> uhmleases.sh/uhmiptables.sh)
UHM_LEASES_TIMEOUT_SECONDS=120
UHM_IPTABLES_TIMEOUT_SECONDS=60
# -- ACLs (uhm's own; read by uhmd.sh / uhmleases.sh) -------------------------
UHM_PATH=${HOTSPOT_DIR}
UHM_GRACE=${ACL_DIR}/uhm-grace.txt
UHM_MACAUTH=${ACL_DIR}/uhm-auth.txt
UHM_QUEUE=${ACL_DIR}/uhm-queue.txt
# =============================================================================
EOF

        # Filter out any key the file already defines, then insert what's
        # left right after the last existing "# ====...====" line -- never a
        # blind append, so the UHM block always lands immediately after
        # whatever content (pydhcp's own, or another project's) is already
        # there, regardless of which project wrote it or in what order.
        local _line _key _filtered
        _filtered=""
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            if [[ "$_line" == *=* && "$_line" != \#* ]]; then
                _key="${_line%%=*}"
                if grep -q "^${_key}=" "$PYDHCP_ENV"; then
                    warn "$_key already set in $(basename "$PYDHCP_ENV") -- not written again"
                    continue
                fi
            fi
            _filtered+="${_line}"$'\n'
        done < "$_uhm_block"
        rm -f "$_uhm_block"

        insert_after_last_delimiter "$CONFIG_FILE" "$_filtered"
    )
    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    info "Config saved to $CONFIG_FILE (mode 600)"
}

# --- Filesystem layout -------------------------------------------------------
deploy_directories() {
    mkdir -p "$HOTSPOT_DIR" "$CORE_DIR" "$TOOLS_DIR" "$ACL_DIR"
    chmod 700 "$HOTSPOT_DIR"
    chmod 700 "$CORE_DIR"
    chmod 700 "$TOOLS_DIR"
    chmod 700 "$ACL_DIR"
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
    local f dest
    for f in "${REPO_ACL}/"*.txt; do
        dest="${ACL_DIR}/$(basename "$f")"
        if [[ -f "$dest" ]]; then
            continue
        fi
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$dest") missing -- creating empty"
        install -m 600 -o root -g root "$f" "$dest"
    done
    info "ACL data files present in ${ACL_DIR}"
}

deploy_scripts() {
    install -m 755 -o root -g root "$REPO_UHMD" "${CORE_DIR}/uhmd.sh"
    install -m 755 -o root -g root "${REPO_CORE}/uhmreload.sh" "${CORE_DIR}/uhmreload.sh"
    install -m 755 -o root -g root "${REPO_CORE}/uhmleases.sh" "${CORE_DIR}/uhmleases.sh"
    # uhmwatch.sh lives under core/ (not tools/) because it is mandatory,
    # not an optional utility -- deployed explicitly here for that reason,
    # same as the other three core scripts above.
    install -m 755 -o root -g root "${REPO_CORE}/uhmwatch.sh" "${CORE_DIR}/uhmwatch.sh"
    local f
    for f in "${REPO_TOOLS}/"*.sh; do
        # uhmiptables.sh is the administrator's own file once customized, so it
        # is deployed by deploy_uhmiptables() below (only when absent) instead
        # of being overwritten here on every run.
        [[ "$(basename "$f")" == "uhmiptables.sh" ]] && continue
        install -m 755 -o root -g root "$f" "${TOOLS_DIR}/"
    done
    # Remove any copy left at the pre-restructure locations (directly under
    # $HOTSPOT_DIR / $TOOLS_DIR instead of core/), so at most one copy of
    # each script exists on disk. uhmwatch.sh's own pre-restructure location
    # is tools/ (where it lived before becoming mandatory), not $HOTSPOT_DIR.
    rm -f "${HOTSPOT_DIR}/uhmd.sh" "${TOOLS_DIR}/uhmreload.sh" "${TOOLS_DIR}/uhmleases.sh" "${TOOLS_DIR}/uhmwatch.sh"
    info "Scripts deployed to ${HOTSPOT_DIR}"
}

deploy_uhmiptables() {
    if [[ -f "$UHM_IPTABLES_DEST" ]]; then
        info "uhmiptables.sh already exists -- skip"
        return 0
    fi
    install -m 750 -o root -g root "${REPO_TOOLS}/uhmiptables.sh" "$UHM_IPTABLES_DEST"
    info "Minimal template deployed to $UHM_IPTABLES_DEST (routing + NAT only)"
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
    if [[ ! -f "$UHM_LOG_FILE" ]]; then
        touch "$UHM_LOG_FILE"
    fi
    chmod 640 "$UHM_LOG_FILE"
    chown root:adm "$UHM_LOG_FILE" 2>/dev/null || chown root:root "$UHM_LOG_FILE"

    if [[ -f "$LOGROTATE_FILE" ]]; then
        info "logrotate config already present at $LOGROTATE_FILE"
    else
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$LOGROTATE_FILE") missing -- creating it"
        cat > "$LOGROTATE_FILE" <<EOF
${UHM_LOG_FILE} {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
        chown root:root "$LOGROTATE_FILE"
        chmod 644 "$LOGROTATE_FILE"
        info "logrotate config installed at $LOGROTATE_FILE"
    fi
}

deregister_cron() {
    # uhmd triggers its own safety-net reload internally (see
    # RELOAD_SAFETY_INTERVAL_SECONDS in uhmd.sh) -- no external cron
    # entry should exist. Removes a leftover @hourly uhmreload.sh entry if
    # found, matching both the current core/uhmreload.sh path and the
    # pre-restructure tools/uhmreload.sh path.
    local ureload_path_new="${HOTSPOT_DIR}/core/uhmreload.sh"
    local ureload_path_old="${HOTSPOT_DIR}/tools/uhmreload.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$ureload_path_new" -e "$ureload_path_old"; then
        crontab -l 2>/dev/null | grep -vF -e "$ureload_path_new" -e "$ureload_path_old" | crontab - || true
        info "Removed stale @hourly uhmreload.sh cron entry"
        info "  (now handled by uhmd.sh internally)"
    fi
}

final_sanity_check() {
    step "Sanity check"
    local issues=0

    if [[ ! -x "$UHM_IPTABLES_DEST" ]]; then
        warn "uhmiptables.sh is missing or not executable"
        warn "  ACL changes will not reach the firewall"
        (( issues++ )) || true
    fi

    if (( issues == 0 )); then
        info "All checks passed."
    else
        warn "${issues} issue(s) need attention before uhm is fully functional."
    fi
}

install_systemd_service() {
    install -m 644 -o root -g root "$REPO_SERVICE" "$SERVICE_DEST"
    systemctl daemon-reload
    systemctl enable uhmd
    if systemctl restart uhmd; then
        info "uhmd enabled and started"
    else
        warn "Could not start uhmd -- alert"
        warn "check it with: systemctl status uhmd"
    fi
}

# --- Install mode ------------------------------------------------------------
do_install() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- installer"
    echo "------------------------------------------------------"

    if [[ -d "$HOTSPOT_DIR" ]]; then
        abort "uhm is already installed at ${HOTSPOT_DIR}.
  Use --update to upgrade (keeps config), or --remove to remove first."
    fi

    trap '_install_ec=$?; trap - EXIT; (( _install_ec != 0 )) && { warn "Installation failed, rolling back changes"; _perform_remove; }' EXIT

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
    bash "${CORE_DIR}/uhmwatch.sh" install

    step "Optional components"
    if confirm "Install uhmalert (ntfy push notifications on connectivity loss)?" "n"; then
        bash "${TOOLS_DIR}/uhmalert.sh" install
    fi
    if dpkg -s webmin &>/dev/null; then
        if confirm "Install the Webmin log viewer module?" "n"; then
            bash "${TOOLS_DIR}/uhmwebmin.sh" install
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
    echo "1. Optional: ${UHM_IPTABLES_DEST} is a minimal template"
    echo "   (routing + NAT). For full enforcement, copy"
    echo "   tools/uhmiptables_example.txt over it and adapt it."
    echo "2. Check service: systemctl status uhmd"
    echo "3. Check logs: tail -f ${UHM_LOG_FILE}"
    echo "------------------------------------------------------"
    echo ""
}

# --- Update mode -------------------------------------------------------------
do_update() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- update"
    echo "------------------------------------------------------"

    step "Preflight"
    check_distro
    check_repo_files

    # Accepts either the current core/ layout or the pre-restructure layout
    # (uhmd.sh directly under $HOTSPOT_DIR, uhmreload.sh/uhmleases.sh under
    # $TOOLS_DIR), so an update from an old install isn't mistaken for a
    # fresh one.
    if [[ ! -d "$HOTSPOT_DIR" ]] || { [[ ! -f "${CORE_DIR}/uhmd.sh" ]] && [[ ! -f "${HOTSPOT_DIR}/uhmd.sh" ]]; }; then
        { err "uhm not installed"; abort "run without --update first -- abort"; }
    fi

    step "Backup"
    if [[ -x "$BKSTACK" ]]; then
        "$BKSTACK" || warn "backup failed, continuing -- alert"
    else
        warn "$BKSTACK not found, no backup taken -- alert"
    fi

    step "Pause services"
    # Stop whatever is actively running its own script file before that file
    # gets overwritten below -- avoids replacing a script out from under a
    # process that may still be mid-cycle. pydhcpd is deliberately left
    # alone: it is a separate project this update never modifies, and
    # stopping it would cut DHCP for the whole LAN, not just the hotspot.
    local uwatch_path="${CORE_DIR}/uhmwatch.sh"
    local uwatch_path_legacy="${TOOLS_DIR}/uhmwatch.sh"
    local _uhmd_was_active=0 _ualert_was_active=0 _uwatch_was_active=0
    systemctl is-active --quiet uhmd 2>/dev/null && _uhmd_was_active=1
    if [[ -f /etc/systemd/system/uhmalert.service ]]; then
        systemctl is-active --quiet uhmalert 2>/dev/null && _ualert_was_active=1
    fi
    if crontab -l 2>/dev/null | awk -v p="$uwatch_path" -v pl="$uwatch_path_legacy" \
        '((index($0,p)>0 || index($0,pl)>0) && substr($0,1,1)!="#"){f=1} END{exit !f}'; then
        _uwatch_was_active=1
    fi

    if (( _uhmd_was_active )); then
        systemctl stop uhmd && info "uhmd stopped for update" || warn "Could not stop uhmd, continuing anyway"
    fi
    if (( _ualert_was_active )); then
        systemctl stop uhmalert && info "uhmalert stopped for update" || warn "Could not stop uhmalert, continuing anyway"
    fi
    if (( _uwatch_was_active )); then
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
    # ACL_DIR (uhm-auth.txt, uhm-queue.txt, uhm-grace.txt), CONFIG_FILE
    # and UHM_IPTABLES_DEST are the administrator's own live/customized data.
    # --update never renames, moves or overwrites anything already present --
    # deploy_acl_files()/deploy_uhmiptables() below only create what's
    # missing (e.g. a partial/broken install, warning about it since that
    # should not normally happen) and leave every existing file untouched.
    # No unconditional mkdir/chmod on an already-existing ACL_DIR either;
    # only created (and chmod 700) here if it doesn't exist yet.
    [[ -d "$ACL_DIR" ]] || { mkdir -p "$ACL_DIR"; chmod 700 "$ACL_DIR"; }
    deploy_acl_files warn
    deploy_uhmiptables

    step "Logrotate"
    install_logrotate warn

    step "Systemd service"
    install -m 644 -o root -g root "$REPO_SERVICE" "$SERVICE_DEST"
    systemctl daemon-reload
    if (( _uhmd_was_active )); then
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
    if (( _ualert_was_active )); then
        systemctl start uhmalert && info "uhmalert restarted" || { warn "Could not restart uhmalert -- alert"; warn "check it with: systemctl status uhmalert"; }
    fi
    if (( _uwatch_was_active )); then
        # Re-registers a clean entry at the current core/ path -- also
        # self-migrates away any stale legacy tools/ entry, though Pause
        # above already removed the one this run knew was active.
        bash "${CORE_DIR}/uhmwatch.sh" install
        info "uhmwatch cron entry restored"
    elif ! crontab -l 2>/dev/null | grep -qF -e "$uwatch_path" -e "$uwatch_path_legacy"; then
        # No entry at all (active or commented) -- this install predates
        # uhmwatch becoming mandatory. Install it now rather than leaving
        # an update-in-place without it.
        bash "${CORE_DIR}/uhmwatch.sh" install
        info "uhmwatch installed (was missing, now mandatory)"
    fi

    step "Cron"
    deregister_cron

    echo ""
    echo "------------------------------------------------------"
    echo "Update complete."
    echo ""
    echo "Preserved (never renamed/moved/overwritten if already present):"
    echo "- ${CONFIG_FILE}"
    echo "- ${UHM_IPTABLES_DEST}"
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

# --- Remove mode -------------------------------------------------------------
do_remove() {
    echo ""
    echo "------------------------------------------------------"
    echo "uhm -- uninstaller"
    echo "------------------------------------------------------"

    echo ""
    warn "This will permanently remove, without asking again:"
    warn "  - uhmd.service (stopped and disabled) and $SERVICE_DEST"
    warn "  - cron entries pointing to ${HOTSPOT_DIR}/core/uhmreload.sh"
    warn "  - the uhmwatch cron entry"
    warn "  - uhmalert.service if installed"
    warn "  - Webmin module (uhmwebmin) if installed"
    warn "  - ${LOGROTATE_FILE}"
    warn "  - ${HOTSPOT_DIR}, except ${HOTSPOT_DIR}/bak/"
    warn "    including uhm.env, the ACL lists and YOUR uhmiptables.sh"
    warn "    Run ${BKSTACK} first if you want a backup"
    warn "  - ${UHM_LOG_FILE}, rotated logs"
    warn "  - uhmunifi.log and reload failure traces"
    warn "Package dependencies"
    warn "  (curl, jq, iptables, ipset, etc.) are NOT removed."
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" || { info "Aborted by user."; exit 0; }

    _perform_remove
}

_perform_remove() {
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
    if [[ -f "$SERVICE_DEST" ]]; then
        rm -f "$SERVICE_DEST"
        systemctl daemon-reload
        info "Service file removed"
    fi

    # Cron entries
    step "Cron"
    # Matches both the current core/uhmreload.sh path and the pre-restructure
    # tools/uhmreload.sh path.
    local ureload_path="${HOTSPOT_DIR}/core/uhmreload.sh"
    local ureload_path_old="${HOTSPOT_DIR}/tools/uhmreload.sh"
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
    local uwatch_path="${CORE_DIR}/uhmwatch.sh"
    local uwatch_path_legacy="${TOOLS_DIR}/uhmwatch.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$uwatch_path" -e "$uwatch_path_legacy"; then
        crontab -l 2>/dev/null | grep -vF -e "$uwatch_path" -e "$uwatch_path_legacy" | crontab - || true
        info "uhmwatch cron entry removed"
    else
        info "No uhmwatch cron entry found"
    fi

    # uhmwebmin / Webmin module (optional component)
    step "uhmwebmin (Webmin module)"
    if [[ -d /usr/share/webmin/uhm ]]; then
        if [[ -f "${TOOLS_DIR}/uhmwebmin.sh" ]]; then
            bash "${TOOLS_DIR}/uhmwebmin.sh" uninstall || {
                warn "uhmwebmin.sh uninstall failed -- alert"
                warn "remove /usr/share/webmin/uhm and /etc/webmin/uhm by hand"
            }
        else
            warn "Webmin module found but ${TOOLS_DIR}/uhmwebmin.sh is missing"
            warn "  remove /usr/share/webmin/uhm and /etc/webmin/uhm manually"
        fi
    else
        info "Webmin module not installed"
    fi

    # Logrotate
    step "Logrotate"
    if [[ -f "$LOGROTATE_FILE" ]]; then
        rm -f "$LOGROTATE_FILE"
        info "Removed $LOGROTATE_FILE"
    else
        info "No logrotate config found"
    fi

    # /etc/uhm
    step "$HOTSPOT_DIR"
    if [[ -d "$HOTSPOT_DIR" ]]; then
        # Everything under HOTSPOT_DIR goes, including uhm.env, the ACL
        # lists and uhmiptables.sh: uninstalling means removing the project.
        # Only bak/ survives; bkstack.sh is the way to keep a copy.
        find "$HOTSPOT_DIR" -mindepth 1 -maxdepth 1 ! -name bak -exec rm -rf {} +
        info "Removed $HOTSPOT_DIR"
    else
        info "$HOTSPOT_DIR does not exist"
    fi

    # Logs
    step "Logs"
    local extra_logs=()
    for f in /var/log/uhmunifi.log /var/log/uhmleases-failure.trace /var/log/uhmiptables-failure.trace; do
        [[ -f "$f" ]] && extra_logs+=("$f")
    done
    if compgen -G "${UHM_LOG_FILE}*" >/dev/null || [[ ${#extra_logs[@]} -gt 0 ]]; then
        rm -f -- "${UHM_LOG_FILE}" "${UHM_LOG_FILE}".* "${extra_logs[@]+"${extra_logs[@]}"}"
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

# --- Dispatch ----------------------------------------------------------------
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
