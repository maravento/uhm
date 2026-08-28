#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmacl - Local ACL Consistency Checker (uhm) -- Interactive Menu
#
# DESCRIPTION:
# Diagnostic tool that verifies the presence and consistency of one or more
# MAC addresses across all local DHCP/ACL data sources used by pydhcpd and
# uhm. Designed for troubleshooting client connectivity issues and
# validating that ACL state is coherent after lease/block operations.
#
# USAGE:
# sudo bash uhmacl.sh
#
# MENU OPTIONS:
# 1. Check MAC        - verify a single MAC across all local data sources,
#                       plus its live state from the UniFi API (essid,
#                       authorized, is_guest, voucher_code)
# 2. Grace period     - list all MACs in grace period with time remaining
# 3. Consistency check - check all MACs from all sources + system summary
# 4. Search by IP/name - find MAC by IP or hostname and run consistency check
# 5. Exit
#
# DATA SOURCES CHECKED:
# uhm-auth.txt      - Clients with an active voucher (hotspot authorized)
# uhm-grace.txt     - Clients in the grace period (no voucher yet)
# blockdhcp.txt     - Blocked MACs (grace expired without voucher)
# acl_mac/*.txt     - Permanent ACL lists (limited, unlimited)
# pydhcpd.leases    - DHCP lease file. A MAC is reported as present when it
#                     appears in the file, which is not the same as holding a
#                     valid lease: pydhcpd keeps an expired lease block on
#                     disk until it next rewrites the file. Only the daemon
#                     evaluates expiry.
# UniFi stat/sta,   - Live state of the UniFi controller (menu options 1
#   stat/guest        and 4, which reuses the same per-MAC report;
#                     requires UNIFI_* credentials in uhm.env).
#                     This is the only source of truth for whether the AP
#                     is actually holding a client at the captive portal
#                     -- a MAC can be fully correct across every local ACL
#                     file above and still be held at the portal if UniFi
#                     reports it authorized=false on a Guest-type WLAN
#
# CONSISTENCY RULES:
# A MAC should appear in only one logical state at a time. The checker
# flags violations but some transient states are expected:
#
# State            | Expected presence
# -----------------+---------------------------------------------------
# Blocked          | blockdhcp only. NOT in acl_mac, grace or leases
# Grace period     | uhm-grace Y, leases Y (may be absent briefly due to
#                  | short 60s pool lease and limited range)
# ACL permanent    | acl_mac Y, NOT in blockdhcp
# Hotspot auth     | uhm-auth Y, uhm-grace N (removed by check_duplicate())
#
# EXIT CODES:
# 0 - Normal exit
# 1 - Not root, already running, missing dependency, unreadable or
#     incomplete configuration, unreadable data file, temp file
#     failure, or UniFi query failure
#
# REQUIREMENTS:
# - Root privileges (files are owned by root / pydhcpd)
# - pydhcpd and uhm installed with standard paths
#
################################################################################

set -uo pipefail

## root check
if [ "$(id -u)" != "0" ]; then
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

# TEMP_FILES accumulates every temp file the script creates: unifi_fetch_sta()
# (login header, stat/sta and stat/guest bodies), menu_consistency() and
# menu_search() -- cleaned up here regardless of which menu option ran or how
# the script exits.
TEMP_FILES=()
cleanup_temp() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

# DEPENDENCIES
for dep in curl jq mawk coreutils util-linux ncurses-bin grep sed; do
    if ! dpkg -s "$dep" &>/dev/null; then
        echo "ERROR: missing dependency '$dep' -- abort" >&2
        exit 1
    fi
done

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

_PYDHCP_CONF="/etc/pydhcp/pydhcp.env"
_UHM_CONF="/etc/uhm/uhm.env"
if [ ! -f "$_UHM_CONF" ]; then
    echo "ERROR: uhm.env not found, run uhmsetup.sh -- abort" >&2
    exit 1
fi
_uhm_owner=$(stat -c '%U' "$_UHM_CONF" 2>/dev/null)
_uhm_perms=$(stat -c '%a' "$_UHM_CONF" 2>/dev/null)
if [[ "$_uhm_owner" != "root" ]] || [[ "$_uhm_perms" != "600" ]]; then
    echo "ERROR: uhm.env must be root:root 600 -- abort" >&2
    exit 1
fi
unset _uhm_owner _uhm_perms
load_uhm_env() {
    local file="$1" line key value raw_key raw_value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        raw_key="$key" raw_value="$value"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$key" != "$raw_key" || "$value" != "$raw_value" ]]; then
            echo "ERROR: stray whitespace in a config key" >&2
            echo "ERROR: key $key -- abort" >&2
            exit 1
        fi
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            BLOCKDHCP_GRACE_SECONDS|UHM_MACAUTH|UHM_GRACE|ACL_BLOCK_FILE|ACL_MAC_PATH|PYDHCPD_LEASES)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}
# pydhcp.env first: it owns the ACL paths and the lease file. uhm.env is
# read after, so uhm's own keys win if a name ever collides.
if [ ! -r "$_PYDHCP_CONF" ]; then
    echo "ERROR: cannot read $_PYDHCP_CONF -- abort" >&2
    echo "ERROR: uhm reads the ACL paths and lease file from it" >&2
    exit 1
fi
load_uhm_env "$_PYDHCP_CONF"
load_uhm_env "$_UHM_CONF"
for _k in BLOCKDHCP_GRACE_SECONDS UHM_MACAUTH UHM_GRACE ACL_BLOCK_FILE ACL_MAC_PATH PYDHCPD_LEASES; do
    if [ -z "${!_k:-}" ]; then
        echo "ERROR: $_k not set in uhm.env or pydhcp.env -- abort" >&2
        exit 1
    fi
done
unset _k

if ! [[ "$BLOCKDHCP_GRACE_SECONDS" =~ $_UH_UINT ]]; then
    echo "ERROR: BLOCKDHCP_GRACE_SECONDS invalid in uhm.env -- abort" >&2
    exit 1
fi

BLOCK_DHCP="$ACL_BLOCK_FILE"
ACL_MAC_DIR="$ACL_MAC_PATH"
LEASES_FILE="$PYDHCPD_LEASES"

if [ ! -d "$ACL_MAC_DIR" ]; then
    echo "ERROR: cannot read $ACL_MAC_DIR -- abort" >&2
    exit 1
fi

shopt -s nullglob
_uhm_mac_lists=("$ACL_MAC_DIR"/*.txt)
shopt -u nullglob
if (( ${#_uhm_mac_lists[@]} == 0 )); then
    echo "ERROR: no mac-*.txt in $ACL_MAC_DIR -- abort" >&2
    exit 1
fi

for _f in "$UHM_MACAUTH" "$UHM_GRACE" "$BLOCK_DHCP" "$LEASES_FILE" \
          "${_uhm_mac_lists[@]}"; do
    grep -qE '' "$_f"
    if (( $? > 1 )); then
        echo "ERROR: cannot read $_f -- abort" >&2
        exit 1
    fi
done
unset _uhm_mac_lists _f

# Bold only -- no color, so output stays legible on light and dark terminals
if [ -t 1 ]; then
    BOLD='\033[1m'
    NC='\033[0m'
else
    BOLD="" NC=""
fi

OK="${BOLD}Y${NC}"
NO="${BOLD}N${NC}"

# --- Helpers -----------------------------------------------------------------
warn() {
    printf " ${BOLD}[!] %s${NC}\n" "$*"
}

info() {
    printf " ${BOLD}[i] %s${NC}\n" "$*"
}

found_in() {
    grep -qiE "^a;${1};" "$2"
}

found_in_leases() {
    grep -qiF "$1" "$2"
}

found_in_acl_dir() {
    grep -rqiE "^a;${1};" "$ACL_MAC_DIR"/
}

press_enter() {
    echo ""
    read -rp " Press ENTER to continue..." _
}

# --- Shared: UniFi live query (used by check_mac) ----------------------------

# Path to the full configuration file (contains UniFi credentials). Only used
# by the UniFi-querying path below -- the local ACL/lease checks don't need it.
HOTSPOT_CONF="$_UHM_CONF"

# Loads the UNIFI_* variables from uhm.env, but only if the file is owned by
# root and has no write permission for group/other (the same validation
# uhmd.sh performs before loading its own config). Returns 1 without loading
# anything if the validation fails, instead of continuing with potentially
# compromised credentials.
load_unifi_config() {
    # Load only known KEY=VALUE pairs instead of sourcing, so a tampered or
    # maliciously replaced config file cannot execute code -- same approach
    # as uhmleases.sh's load_env_file().
    local _line _key _value _raw_key _raw_value
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        _key="${_line%%=*}"
        _value="${_line#*=}"
        _raw_key="$_key" _raw_value="$_value"
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        _value="${_value#"${_value%%[![:space:]]*}"}"
        _value="${_value%"${_value##*[![:space:]]}"}"
        if [[ "$_key" != "$_raw_key" || "$_value" != "$_raw_value" ]]; then
            echo "ERROR: stray whitespace in a config key" >&2
            echo "ERROR: key $_key -- abort" >&2
            exit 1
        fi
        if [[ "$_value" == \"*\" && "$_value" == *\" && ${#_value} -ge 2 ]]; then
            _value="${_value:1:$((${#_value}-2))}"
            _value="${_value//\\\"/\"}"
            _value="${_value//\\\$/\$}"
            _value="${_value//\\\`/\`}"
            _value="${_value//\\\\/\\}"
        fi
        case "$_key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_TYPE|UNIFI_SITE|UNIFI_CERT_PIN|UHM_ESSID)
                printf -v "$_key" '%s' "$_value"
                ;;
            *)
                ;;
        esac
    done < "$HOTSPOT_CONF"

    local missing=()
    [[ -z "${UNIFI_CONTROLLER_URL:-}" ]] && missing+=("UNIFI_CONTROLLER_URL")
    [[ -z "${UNIFI_USERNAME:-}" ]] && missing+=("UNIFI_USERNAME")
    [[ -z "${UNIFI_PASSWORD:-}" ]] && missing+=("UNIFI_PASSWORD")
    [[ -z "${UNIFI_TYPE:-}" ]] && missing+=("UNIFI_TYPE")
    [[ -z "${UNIFI_SITE:-}" ]] && missing+=("UNIFI_SITE")
    [[ -z "${UHM_ESSID:-}" ]] && missing+=("UHM_ESSID")
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: missing variables in uhm.env:" >&2
        local _m
        for _m in "${missing[@]}"; do
            echo "ERROR: $_m" >&2
        done
        echo "ERROR: restore uhm.env or re-run uhmsetup.sh -- abort" >&2
        exit 1
    fi
    return 0
}

# Logs in against UniFi and fetches stat/sta + stat/guest ONCE per script run,
# caching both to temp files (removed on exit by the trap below). check_mac()
# calls this for every MAC it checks (including the loop in menu_search), so
# caching avoids re-authenticating against the controller once per MAC.
# _UNIFI_LOADED is set on the first call, so the controller is queried once
# per run and every subsequent MAC reuses the cached response. A failed
# login or query aborts the script, so there is no failure state to carry.
_UNIFI_LOADED=0
_UNIFI_GUEST_OK=0
_UNIFI_STA_JSON=""
_UNIFI_GUEST_JSON=""
unifi_fetch_sta() {
    [[ "$_UNIFI_LOADED" == "1" ]] && return
    _UNIFI_LOADED=1

    load_unifi_config

    local login_url sta_url guest_url
    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
        sta_url="${UNIFI_CONTROLLER_URL}/proxy/network/api/s/${UNIFI_SITE}/stat/sta"
        guest_url="${UNIFI_CONTROLLER_URL}/proxy/network/api/s/${UNIFI_SITE}/stat/guest"
    else
        login_url="${UNIFI_CONTROLLER_URL}/api/login"
        sta_url="${UNIFI_CONTROLLER_URL}/api/s/${UNIFI_SITE}/stat/sta"
        guest_url="${UNIFI_CONTROLLER_URL}/api/s/${UNIFI_SITE}/stat/guest"
    fi

    printf " ${BOLD}Querying %s...${NC}\n" "$UNIFI_CONTROLLER_URL"

    local hdr token payload cookie_name
    hdr=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    TEMP_FILES+=("$hdr")
    # Pass credentials to jq via environment and the body to curl via stdin --
    # not --arg / -d -- so the plaintext password never appears in either
    # process's argv (readable by any local user via /proc/<pid>/cmdline).
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    curl -s "${_tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -D "$hdr" -o /dev/null \
        -X POST "$login_url" \
        -H "Content-Type: application/json" \
        --data-binary @- <<< "$payload" 2>/dev/null
    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        cookie_name="TOKEN"
        token=$(grep -iE '^set-cookie:[[:space:]]*TOKEN=' "$hdr" 2>/dev/null | sed -E 's/.*TOKEN=([^;]+).*/\1/' | tr -d '\r\n')
    else
        cookie_name="unifises"
        token=$(grep -i '^set-cookie:' "$hdr" 2>/dev/null | grep -i 'unifises=' | sed -E 's/.*unifises=([^;]+).*/\1/' | tr -d '\r\n')
    fi

    if [[ -z "$token" ]]; then
        echo "ERROR: UniFi login failed -- abort" >&2
        echo "ERROR: check UNIFI_USERNAME, UNIFI_PASSWORD, UNIFI_CONTROLLER_URL" >&2
        echo "ERROR: controller may be unavailable, try again later" >&2
        exit 1
    fi

    _UNIFI_STA_JSON=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    _UNIFI_GUEST_JSON=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    TEMP_FILES+=("$_UNIFI_STA_JSON" "$_UNIFI_GUEST_JSON")
    curl -s "${_tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -b "${cookie_name}=${token}" "$sta_url" -o "$_UNIFI_STA_JSON" 2>/dev/null
    curl -s "${_tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -b "${cookie_name}=${token}" "$guest_url" -o "$_UNIFI_GUEST_JSON" 2>/dev/null

    local sta_rc
    sta_rc=$(jq -r '.meta.rc // empty' "$_UNIFI_STA_JSON" 2>/dev/null)
    if [[ "$sta_rc" != "ok" ]]; then
        echo "ERROR: UniFi stat/sta query failed -- abort" >&2
        echo "ERROR: controller may be unavailable, try again later" >&2
        exit 1
    fi

    printf " ${BOLD}Connected to UniFi API${NC}\n"

    local guest_rc
    guest_rc=$(jq -r '.meta.rc // empty' "$_UNIFI_GUEST_JSON" 2>/dev/null)
    [[ "$guest_rc" == "ok" ]] && _UNIFI_GUEST_OK=1
    return 0
}

# Prints the live UniFi state for one MAC: essid, authorized, is_guest (from
# stat/sta) and voucher_code (from stat/guest, if present). This is the
# direct source of truth for whether the AP will hold this client at the
# captive portal -- independent of, and not always predictable from, the
# local ACL files checked above (see the MANAGED MACS note in uhmd.sh: UniFi
# enforces its own authorized/is_guest state per client on any WLAN
# configured as Guest/Hotspot, regardless of DHCP/firewall bypass).
print_unifi_status() {
    local mac="$1"
    unifi_fetch_sta
    printf " UniFi (stat/sta): "

    local row
    row=$(jq -r --arg m "$mac" '
        .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase))
        | [(.essid // "n/a"), (.authorized|tostring), (.is_guest|tostring), (.ip // "n/a"), (.hostname // "n/a")]
        | @tsv
    ' "$_UNIFI_STA_JSON" 2>/dev/null | head -1)

    if [[ -z "$row" ]]; then
        printf "MAC not associated to any AP (no live session)\n"
        return
    fi

    local essid authorized is_guest ip hostname
    IFS=$'\t' read -r essid authorized is_guest ip hostname <<< "$row"
    printf "connected\n"
    printf "   essid=%s\n" "$essid"
    printf "   authorized=%s\n" "$authorized"
    printf "   is_guest=%s\n" "$is_guest"
    printf "   ip=%s\n" "$ip"
    printf "   hostname=%s\n" "$hostname"

    if (( _UNIFI_GUEST_OK == 0 )); then
        info "stat/guest unavailable, voucher_code not shown -- skip"
    else
        local vcode
        vcode=$(jq -r --arg m "$mac" '
            .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase)) | .voucher_code // empty
        ' "$_UNIFI_GUEST_JSON" 2>/dev/null | head -1)
        [[ -n "$vcode" ]] && printf "   voucher_code=%s\n" "$vcode"
    fi

    if [[ "$authorized" == "false" && "$is_guest" == "true" ]]; then
        warn "UniFi reports this MAC unauthorized on a Guest WLAN"
        warn "  the AP holds it at the captive portal regardless of local ACL/DHCP state"
    fi
}

# --- Option 1: Check single MAC ----------------------------------------------
check_mac() {
    local mac="$1"

    printf "${BOLD}=== %s ===${NC}\n" "$mac"

    local in_hotspot=0 in_grace=0 in_block=0 in_acl=0 in_leases=0

    printf " %-18s" "uhm-auth.txt:"
    if found_in "$mac" "$UHM_MACAUTH"; then in_hotspot=1; printf "$OK\n"; else printf "$NO\n"; fi

    printf " %-18s" "uhm-grace.txt:"
    if found_in "$mac" "$UHM_GRACE"; then in_grace=1; printf "$OK\n"; else printf "$NO\n"; fi

    printf " %-18s" "blockdhcp.txt:"
    if found_in "$mac" "$BLOCK_DHCP"; then in_block=1; printf "$OK\n"; else printf "$NO\n"; fi

    printf " %-18s" "acl_mac/*.txt:"
    if found_in_acl_dir "$mac"; then
        in_acl=1; printf "$OK\n"
        grep -rliE "^a;${mac};" "$ACL_MAC_DIR"/ | sed 's/^/ /'
    else
        printf "$NO\n"
    fi

    printf " %-18s" "pydhcpd.leases:"
    if found_in_leases "$mac" "$LEASES_FILE"; then in_leases=1; printf "$OK\n"; else printf "$NO\n"; fi

    echo ""
    print_unifi_status "$mac"

    # Grace period time remaining
    if [ $in_grace -eq 1 ]; then
        local line ts remaining
        line=$(grep -iE "^a;${mac};" "$UHM_GRACE" | head -1)
        ts=$(echo "$line" | awk -F';' '{print $5}')
        if ! [[ "$ts" =~ $_UH_UINT ]]; then
            echo "ERROR: malformed line in $UHM_GRACE -- abort" >&2
            exit 1
        fi
        remaining=$(( (ts + BLOCKDHCP_GRACE_SECONDS) - $(date +%s) ))
        if (( remaining > 0 )); then
            printf " %-18s${BOLD}%dh %dm${NC}\n" "Grace expires in:" "$((remaining/3600))" "$(( (remaining%3600)/60 ))"
        else
            printf " %-18s${BOLD}EXPIRED${NC}\n" "Grace expires in:"
        fi
    fi

    # Consistency checks
    if [ $in_block -eq 1 ]; then
        [ $in_acl -eq 1 ] && warn "In blockdhcp AND acl_mac -- should be in one, not both"
        [ $in_grace -eq 1 ] && warn "In blockdhcp AND uhm-grace -- contradictory state"
        [ $in_leases -eq 1 ] && warn "In blockdhcp AND leases -- lease should have been cleared"
    fi

    if [ $in_grace -eq 1 ] && [ $in_leases -eq 0 ]; then
        info "In uhm-grace without active lease"
        info "This is normal with a short pool lease or a limited range"
    fi

    if [ $in_hotspot -eq 1 ] && [ $in_grace -eq 1 ]; then
        warn "In uhm-auth AND uhm-grace"
        warn "  run uhmreload.sh to clear the uhm-grace entry"
    fi

    local total=$((in_hotspot + in_grace + in_block + in_acl + in_leases))
    if [ $total -eq 0 ]; then
        printf " ${BOLD}[!] MAC not found in any data source${NC}\n"
    fi

    echo ""
}

menu_check_mac() {
    echo ""
    local mac
    while true; do
        read -rp " Enter MAC address (XX:XX:XX:XX:XX:XX, empty to cancel): " mac
        mac="${mac#"${mac%%[![:space:]]*}"}"
        mac="${mac%"${mac##*[![:space:]]}"}"
        mac="${mac,,}"
        [[ -z "$mac" ]] && return
        if [[ "$mac" =~ $_UH_MAC ]]; then
            break
        fi
        printf " ${BOLD}Invalid MAC format, try again${NC}\n"
    done
    echo ""
    check_mac "$mac"
    press_enter
}

# --- Option 2: Grace period status -------------------------------------------
menu_grace_period() {
    echo ""
    if [ ! -r "$UHM_GRACE" ]; then
        echo "ERROR: cannot read $UHM_GRACE -- abort" >&2
        exit 1
    fi

    local now total=0 expired=0 status
    now=$(date +%s)

    printf " ${BOLD}%-20s %-18s %-25s %s${NC}\n" "MAC" "IP" "NAME" "EXPIRES IN"
    printf " %s\n" "$(printf -- '-%.0s' {1..76})"

    while IFS=';' read -r status mac ip name ts _rest; do
        [[ -z "$status$mac$ip$name$ts" ]] && continue
        [[ "$status" != "a" ]] && continue
        if [[ -z "$mac" || -z "$ts" ]] || ! [[ "$ts" =~ $_UH_UINT ]]; then
            echo "ERROR: malformed line in $UHM_GRACE -- abort" >&2
            exit 1
        fi
        total=$((total+1))
        local remaining=$(( (ts + BLOCKDHCP_GRACE_SECONDS) - now ))
        if (( remaining > 0 )); then
            local h=$(( remaining/3600 ))
            local m=$(( (remaining%3600)/60 ))
            printf " %-20s %-18s %-25.25s %dh %dm\n" "$mac" "$ip" "$name" "$h" "$m"
        else
            expired=$((expired+1))
            printf " %-20s %-18s %-25.25s ${BOLD}EXPIRED${NC}\n" "$mac" "$ip" "$name"
        fi
    done < "$UHM_GRACE"

    echo ""
    printf " Total: %d | Expired: %d | Active: %d\n" "$total" "$expired" "$((total-expired))"
    press_enter
}

# --- Option 3: Consistency check + system summary ----------------------------
menu_consistency() {
    echo ""
    printf " ${BOLD}Collecting all MACs from all data sources...${NC}\n\n"

    # Collect all unique MACs
    local tmpfile
    tmpfile=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    TEMP_FILES+=("$tmpfile")

    # From semicolon-delimited files (field 2)
    local _before
    for f in "$UHM_MACAUTH" "$UHM_GRACE" "$BLOCK_DHCP"; do
        _before=$(wc -l < "$tmpfile")
        awk -F';' '$1=="a"{print tolower($2)}' "$f" >> "$tmpfile"
        (( $(wc -l < "$tmpfile") == _before )) && info "no active entries in $(basename "$f")"
    done

    # From acl_mac dir
    shopt -s nullglob
    for f in "$ACL_MAC_DIR"/*.txt; do
        _before=$(wc -l < "$tmpfile")
        grep -hioE '^a;([0-9a-f]{2}:){5}[0-9a-f]{2}' "$f" | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmpfile"
        (( $(wc -l < "$tmpfile") == _before )) && info "no active entries in $(basename "$f")"
    done
    shopt -u nullglob

    # From leases file
    _before=$(wc -l < "$tmpfile")
    grep -ioE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$LEASES_FILE" \
        | tr '[:upper:]' '[:lower:]' >> "$tmpfile"
    (( $(wc -l < "$tmpfile") == _before )) && info "no active entries in $(basename "$LEASES_FILE")"

    local all_macs
    mapfile -t all_macs < <(sort -u "$tmpfile" | grep -E "$_UH_MAC")
    rm -f "$tmpfile"

    local total_warnings=0
    local cnt_grace=0 cnt_block=0 cnt_acl=0 cnt_hotspot=0 cnt_leases=0

    for mac in "${all_macs[@]}"; do
        # Single pass per MAC: these booleans feed both the summary counters
        # and the consistency warnings below.
        local w=0
        local in_hotspot=0 in_grace=0 in_block=0 in_acl=0 in_leases=0
        found_in "$mac" "$UHM_MACAUTH" && in_hotspot=1
        found_in "$mac" "$UHM_GRACE" && in_grace=1
        found_in "$mac" "$BLOCK_DHCP" && in_block=1
        found_in_acl_dir "$mac" && in_acl=1
        found_in_leases "$mac" "$LEASES_FILE" && in_leases=1

        [ $in_hotspot -eq 1 ] && cnt_hotspot=$((cnt_hotspot+1))
        [ $in_grace -eq 1 ] && cnt_grace=$((cnt_grace+1))
        [ $in_block -eq 1 ] && cnt_block=$((cnt_block+1))
        [ $in_acl -eq 1 ] && cnt_acl=$((cnt_acl+1))
        [ $in_leases -eq 1 ] && cnt_leases=$((cnt_leases+1))

        if [ $in_block -eq 1 ]; then
            if [ $in_acl -eq 1 ]; then
                [ $w -eq 0 ] && printf "${BOLD}--- %s ---${NC}\n" "$mac"
                warn "In blockdhcp AND acl_mac -- should be in one, not both"
                w=$((w+1))
            fi
            if [ $in_grace -eq 1 ]; then
                [ $w -eq 0 ] && printf "${BOLD}--- %s ---${NC}\n" "$mac"
                warn "In blockdhcp AND uhm-grace -- contradictory state"
                w=$((w+1))
            fi
            if [ $in_leases -eq 1 ]; then
                [ $w -eq 0 ] && printf "${BOLD}--- %s ---${NC}\n" "$mac"
                warn "In blockdhcp AND leases -- lease should have been cleared"
                w=$((w+1))
            fi
        fi
        if [ $in_hotspot -eq 1 ] && [ $in_grace -eq 1 ]; then
            [ $w -eq 0 ] && printf "${BOLD}--- %s ---${NC}\n" "$mac"
            warn "In uhm-auth AND uhm-grace"
            warn "  run uhmreload.sh to clear the uhm-grace entry"
            w=$((w+1))
        fi
        [ $w -gt 0 ] && echo ""
        total_warnings=$((total_warnings+w))
    done

    # Summary
    printf "${BOLD}=== SYSTEM SUMMARY ===${NC}\n"
    printf "  %-18s: %d\n" "MACs found total" "${#all_macs[@]}"
    printf "  %-18s: %d\n" "Grace period" "$cnt_grace"
    printf "  %-18s: %d\n" "Blocked" "$cnt_block"
    printf "  %-18s: %d\n" "ACL permanent" "$cnt_acl"
    printf "  %-18s: %d\n" "Hotspot auth" "$cnt_hotspot"
    printf "  %-18s: %d\n" "In leases file" "$cnt_leases"
    printf "  %-18s: ${BOLD}%d${NC}\n" "Warnings" "$total_warnings"

    press_enter
}

# --- Option 4: Search by IP or hostname --------------------------------------
menu_search() {
    echo ""
    local query
    read -rp " Enter IP address or hostname: " query
    query="${query#"${query%%[![:space:]]*}"}"
    query="${query%"${query##*[![:space:]]}"}"
    query="${query,,}"
    if [ -z "$query" ]; then
        printf " ${BOLD}Empty query${NC}\n"
        press_enter
        return
    fi

    echo ""
    printf " ${BOLD}Searching for: %s${NC}\n\n" "$query"

    local found_macs=()
    local tmpfile
    tmpfile=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    TEMP_FILES+=("$tmpfile")

    # Search in semicolon-delimited files (all fields)
    for f in "$UHM_MACAUTH" "$UHM_GRACE" "$BLOCK_DHCP"; do
        grep -iF "$query" "$f" \
            | awk -F';' '$1=="a"{print tolower($2)}' >> "$tmpfile"
    done

    # Search in acl_mac dir (lines containing query, extract MAC)
    shopt -s nullglob
    for f in "$ACL_MAC_DIR"/*.txt; do
        grep -hiF "$query" "$f" \
            | grep -ioE '^a;([0-9a-f]{2}:){5}[0-9a-f]{2}' | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmpfile"
    done
    shopt -u nullglob

    # Search in leases file
    grep -iF "$query" "$LEASES_FILE" \
        | grep -ioE '([0-9a-f]{2}:){5}[0-9a-f]{2}' \
        | tr '[:upper:]' '[:lower:]' >> "$tmpfile"

    mapfile -t found_macs < <(sort -u "$tmpfile" | grep -E "$_UH_MAC")
    rm -f "$tmpfile"

    if [ ${#found_macs[@]} -eq 0 ]; then
        printf " ${BOLD}No MACs found matching: %s${NC}\n" "$query"
        press_enter
        return
    fi

    printf " Found %d MAC(s):\n\n" "${#found_macs[@]}"
    for mac in "${found_macs[@]}"; do
        check_mac "$mac"
    done

    press_enter
}

# --- Main menu ---------------------------------------------------------------
main_menu() {
    while true; do
        clear
        printf "${BOLD}#######################################${NC}\n"
        printf "${BOLD}# uhmacl -- Local ACL Diagnostic Tool #${NC}\n"
        printf "${BOLD}#######################################${NC}\n"
        echo ""
        printf " 1. Check MAC\n"
        printf " 2. Grace period status\n"
        printf " 3. Consistency check + system summary\n"
        printf " 4. Search by IP or hostname\n"
        printf " 5. Exit\n"
        echo ""
        read -rp " Select option [1-5]: " opt
        case "$opt" in
            1) menu_check_mac ;;
            2) menu_grace_period ;;
            3) menu_consistency ;;
            4) menu_search ;;
            5|"") echo ""; exit 0 ;;
            *) printf " ${BOLD}Invalid option${NC}\n"; sleep 1 ;;
        esac
    done
}

main_menu
