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
# 4. Search by IP/client_name - find MAC by IP or hostname and run consistency check
# 5. Exit
#
# DATA SOURCES CHECKED:
# uhm-auth.txt      - Clients with an active voucher (hotspot authorized)
# uhm-grace.txt     - Clients in the grace period (no voucher yet)
# blockdhcp.txt     - Blocked MACs (grace expired without voucher)
# mac/*.txt     - Permanent ACL lists (limited, unlimited)
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
#                     reports it sta_authorized=false on a Guest-type WLAN
#
# CONSISTENCY RULES:
# A MAC should appear in only one logical state at a time. The checker
# flags violations but some transient states are expected:
#
# State            | Expected presence
# -----------------+---------------------------------------------------
# Blocked          | blockdhcp only. NOT in mac, grace or leases
# Grace period     | uhm-grace Y, leases Y (may be absent briefly due to
#                  | short 60s pool lease and limited range)
# ACL permanent    | mac Y, NOT in blockdhcp
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

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
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

# temp_files accumulates every temp file the script creates: unifi_fetch_sta()
# (login header, stat/sta and stat/guest bodies), menu_consistency() and
# menu_search() -- cleaned up here regardless of which menu option ran or how
# the script exits.
temp_files=()
cleanup_temp() {
    local temp_file
    for temp_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$temp_file" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

# dependencies
for dep_pkg in curl jq mawk coreutils util-linux ncurses-bin grep sed; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        echo "ERROR: missing dependency '$dep_pkg' -- abort" >&2
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

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
# ENV
# ------------------------------------------------------------------------------

pydhcp_conf="/etc/pydhcp/pydhcp.env"
uhm_conf="/etc/uhm/uhm.env"
if [ ! -f "$uhm_conf" ]; then
    echo "ERROR: uhm.env not found, run uhmsetup.sh -- abort" >&2
    exit 1
fi
uhm_owner=$(stat -c '%U' "$uhm_conf" 2>/dev/null)
uhm_perms=$(stat -c '%a' "$uhm_conf" 2>/dev/null)
if [[ "$uhm_owner" != "root" ]] || [[ "$uhm_perms" != "600" ]]; then
    echo "ERROR: uhm.env must be root:root 600 -- abort" >&2
    exit 1
fi
unset uhm_owner uhm_perms
load_uhm_env() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
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
            echo "ERROR: stray whitespace in a config key" >&2
            echo "ERROR: key $env_key -- abort" >&2
            exit 1
        fi
        env_value="${env_value%\"}"
        env_value="${env_value#\"}"
        case "$env_key" in
            BLOCKDHCP_GRACE_SECONDS|UHM_MACAUTH|UHM_GRACE|ACL_BLOCK_FILE|ACL_MAC_PATH|PYDHCPD_LEASES)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}
# pydhcp.env first: it owns the ACL paths and the lease file. uhm.env is
# read after, so uhm's own keys win if a name ever collides.
if [ ! -r "$pydhcp_conf" ]; then
    echo "ERROR: cannot read $pydhcp_conf -- abort" >&2
    echo "ERROR: uhm reads the ACL paths and lease file from it" >&2
    exit 1
fi
load_uhm_env "$pydhcp_conf"
load_uhm_env "$uhm_conf"
for required_key in BLOCKDHCP_GRACE_SECONDS UHM_MACAUTH UHM_GRACE ACL_BLOCK_FILE ACL_MAC_PATH PYDHCPD_LEASES; do
    if [ -z "${!required_key:-}" ]; then
        echo "ERROR: $required_key not set in uhm.env or pydhcp.env -- abort" >&2
        exit 1
    fi
done
unset required_key

if ! [[ "$BLOCKDHCP_GRACE_SECONDS" =~ $UH_UINT ]]; then
    echo "ERROR: BLOCKDHCP_GRACE_SECONDS invalid in uhm.env -- abort" >&2
    exit 1
fi

if [ ! -d "$ACL_MAC_PATH" ]; then
    echo "ERROR: cannot read $ACL_MAC_PATH -- abort" >&2
    exit 1
fi

shopt -s nullglob
uhm_mac_lists=("$ACL_MAC_PATH"/*.txt)
shopt -u nullglob
if (( ${#uhm_mac_lists[@]} == 0 )); then
    echo "ERROR: no mac-*.txt in $ACL_MAC_PATH -- abort" >&2
    exit 1
fi

for check_file in "$UHM_MACAUTH" "$UHM_GRACE" "$ACL_BLOCK_FILE" "$PYDHCPD_LEASES" \
          "${uhm_mac_lists[@]}"; do
    grep -qE '' "$check_file"
    if (( $? > 1 )); then
        echo "ERROR: cannot read $check_file -- abort" >&2
        exit 1
    fi
done
unset uhm_mac_lists check_file

# Bold only -- no color, so output stays legible on light and dark terminals
if [ -t 1 ]; then
    color_bold='\033[1m'
    color_reset='\033[0m'
else
    color_bold="" color_reset=""
fi

mark_yes="${color_bold}Y${color_reset}"
mark_no="${color_bold}N${color_reset}"

# --- Helpers -----------------------------------------------------------------
warn() {
    printf " ${color_bold}[!] %s${color_reset}\n" "$*"
}

info() {
    printf " ${color_bold}[i] %s${color_reset}\n" "$*"
}

found_in() {
    grep -qiE "^a;${1};" "$2"
}

found_in_leases() {
    grep -qiF "$1" "$2"
}

found_in_acl_dir() {
    grep -rqiE "^a;${1};" "$ACL_MAC_PATH"/
}

press_enter() {
    echo ""
    read -rp " Press ENTER to continue..." _
}

# --- Shared: UniFi live query (used by check_mac) ----------------------------

# Path to the full configuration file (contains UniFi credentials). Only used
# by the UniFi-querying path below -- the local ACL/lease checks don't need it.

# Loads the UNIFI_* variables from uhm.env, but only if the file is owned by
# root and has no write permission for group/other (the same validation
# uhmd.sh performs before loading its own config). Returns 1 without loading
# anything if the validation fails, instead of continuing with potentially
# compromised credentials.
load_unifi_config() {
    # Load only known KEY=VALUE pairs instead of sourcing, so a tampered or
    # maliciously replaced config file cannot execute code -- same approach
    # as uhmleases.sh's load_env_file().
    local env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
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
            echo "ERROR: stray whitespace in a config key" >&2
            echo "ERROR: key $env_key -- abort" >&2
            exit 1
        fi
        if [[ "$env_value" == \"*\" && "$env_value" == *\" && ${#env_value} -ge 2 ]]; then
            env_value="${env_value:1:$((${#env_value}-2))}"
            env_value="${env_value//\\\"/\"}"
            env_value="${env_value//\\\$/\$}"
            env_value="${env_value//\\\`/\`}"
            env_value="${env_value//\\\\/\\}"
        fi
        case "$env_key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_TYPE|UNIFI_SITE|UNIFI_CERT_PIN|UHM_ESSID)
                printf -v "$env_key" '%s' "$env_value"
                ;;
            *)
                ;;
        esac
    done < "$uhm_conf"

    local missing_keys=()
    [[ -z "${UNIFI_CONTROLLER_URL:-}" ]] && missing_keys+=("UNIFI_CONTROLLER_URL")
    [[ -z "${UNIFI_USERNAME:-}" ]] && missing_keys+=("UNIFI_USERNAME")
    [[ -z "${UNIFI_PASSWORD:-}" ]] && missing_keys+=("UNIFI_PASSWORD")
    [[ -z "${UNIFI_TYPE:-}" ]] && missing_keys+=("UNIFI_TYPE")
    [[ -z "${UNIFI_SITE:-}" ]] && missing_keys+=("UNIFI_SITE")
    [[ -z "${UHM_ESSID:-}" ]] && missing_keys+=("UHM_ESSID")
    if (( ${#missing_keys[@]} > 0 )); then
        echo "ERROR: missing variables in uhm.env:" >&2
        local missing_key
        for missing_key in "${missing_keys[@]}"; do
            echo "ERROR: $missing_key" >&2
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
# unifi_loaded is set on the first call, so the controller is queried once
# per run and every subsequent MAC reuses the cached response. A failed
# login or query aborts the script, so there is no failure state to carry.
unifi_loaded=0
unifi_guest_ok=0
unifi_sta_json=""
unifi_guest_json=""
unifi_fetch_sta() {
    [[ "$unifi_loaded" == "1" ]] && return
    unifi_loaded=1

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

    printf " ${color_bold}Querying %s...${color_reset}\n" "$UNIFI_CONTROLLER_URL"

    local header_file auth_token login_payload cookie_name
    header_file=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    temp_files+=("$header_file")
    # Pass credentials to jq via environment and the body to curl via stdin --
    # not --arg / -d -- so the plaintext password never appears in either
    # process's argv (readable by any local user via /proc/<pid>/cmdline).
    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    curl -s "${tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -D "$header_file" -o /dev/null \
        -X POST "$login_url" \
        -H "Content-Type: application/json" \
        --data-binary @- <<< "$login_payload" 2>/dev/null
    if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
        cookie_name="TOKEN"
        auth_token=$(grep -iE '^set-cookie:[[:space:]]*TOKEN=' "$header_file" 2>/dev/null | sed -E 's/.*TOKEN=([^;]+).*/\1/' | tr -d '\r\n')
    else
        cookie_name="unifises"
        auth_token=$(grep -i '^set-cookie:' "$header_file" 2>/dev/null | grep -i 'unifises=' | sed -E 's/.*unifises=([^;]+).*/\1/' | tr -d '\r\n')
    fi

    if [[ -z "$auth_token" ]]; then
        echo "ERROR: UniFi login failed -- abort" >&2
        echo "ERROR: check UNIFI_USERNAME, UNIFI_PASSWORD, UNIFI_CONTROLLER_URL" >&2
        echo "ERROR: controller may be unavailable, try again later" >&2
        exit 1
    fi

    unifi_sta_json=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    unifi_guest_json=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    temp_files+=("$unifi_sta_json" "$unifi_guest_json")
    curl -s "${tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -b "${cookie_name}=${auth_token}" "$sta_url" -o "$unifi_sta_json" 2>/dev/null
    curl -s "${tls_opts[@]}" --connect-timeout 10 --max-time 30 \
        -b "${cookie_name}=${auth_token}" "$guest_url" -o "$unifi_guest_json" 2>/dev/null

    local sta_rc
    sta_rc=$(jq -r '.meta.rc // empty' "$unifi_sta_json" 2>/dev/null)
    if [[ "$sta_rc" != "ok" ]]; then
        echo "ERROR: UniFi stat/sta query failed -- abort" >&2
        echo "ERROR: controller may be unavailable, try again later" >&2
        exit 1
    fi

    printf " ${color_bold}Connected to UniFi API${color_reset}\n"

    local guest_rc
    guest_rc=$(jq -r '.meta.rc // empty' "$unifi_guest_json" 2>/dev/null)
    [[ "$guest_rc" == "ok" ]] && unifi_guest_ok=1
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
    local mac_addr="$1"
    unifi_fetch_sta
    printf " UniFi (stat/sta): "

    local sta_row
    sta_row=$(jq -r --arg m "$mac_addr" '
        .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase))
        | [(.essid // "n/a"), (.authorized|tostring), (.is_guest|tostring), (.ip // "n/a"), (.hostname // "n/a")]
        | @tsv
    ' "$unifi_sta_json" 2>/dev/null | head -1)

    if [[ -z "$sta_row" ]]; then
        printf "MAC not associated to any AP (no live session)\n"
        return
    fi

    local sta_essid sta_authorized is_guest client_ip client_name
    IFS=$'\t' read -r sta_essid sta_authorized is_guest client_ip client_name <<< "$sta_row"
    printf "connected\n"
    printf "   essid=%s\n" "$sta_essid"
    printf "   authorized=%s\n" "$sta_authorized"
    printf "   is_guest=%s\n" "$is_guest"
    printf "   ip=%s\n" "$client_ip"
    printf "   hostname=%s\n" "$client_name"

    if (( unifi_guest_ok == 0 )); then
        info "stat/guest unavailable, voucher_code not shown -- skip"
    else
        local voucher_code
        voucher_code=$(jq -r --arg m "$mac_addr" '
            .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase)) | .voucher_code // empty
        ' "$unifi_guest_json" 2>/dev/null | head -1)
        [[ -n "$voucher_code" ]] && printf "   voucher_code=%s\n" "$voucher_code"
    fi

    if [[ "$sta_authorized" == "false" && "$is_guest" == "true" ]]; then
        warn "UniFi reports this MAC unauthorized on a Guest WLAN"
        warn "  the AP holds it at the captive portal regardless of local ACL/DHCP state"
    fi
}

# --- Option 1: Check single MAC ----------------------------------------------
check_mac() {
    local mac_addr="$1"

    printf "${color_bold}=== %s ===${color_reset}\n" "$mac_addr"

    local in_hotspot=0 in_grace=0 in_block=0 in_acl=0 in_leases=0

    printf " %-18s" "uhm-auth.txt:"
    if found_in "$mac_addr" "$UHM_MACAUTH"; then in_hotspot=1; printf "$mark_yes\n"; else printf "$mark_no\n"; fi

    printf " %-18s" "uhm-grace.txt:"
    if found_in "$mac_addr" "$UHM_GRACE"; then in_grace=1; printf "$mark_yes\n"; else printf "$mark_no\n"; fi

    printf " %-18s" "blockdhcp.txt:"
    if found_in "$mac_addr" "$ACL_BLOCK_FILE"; then in_block=1; printf "$mark_yes\n"; else printf "$mark_no\n"; fi

    printf " %-18s" "mac/*.txt:"
    if found_in_acl_dir "$mac_addr"; then
        in_acl=1; printf "$mark_yes\n"
        grep -rliE "^a;${mac_addr};" "$ACL_MAC_PATH"/ | sed 's/^/ /'
    else
        printf "$mark_no\n"
    fi

    printf " %-18s" "pydhcpd.leases:"
    if found_in_leases "$mac_addr" "$PYDHCPD_LEASES"; then in_leases=1; printf "$mark_yes\n"; else printf "$mark_no\n"; fi

    echo ""
    print_unifi_status "$mac_addr"

    # Grace period time remaining
    if [ $in_grace -eq 1 ]; then
        local grace_line grace_ts remaining_seconds
        grace_line=$(grep -iE "^a;${mac_addr};" "$UHM_GRACE" | head -1)
        grace_ts=$(echo "$grace_line" | awk -F';' '{print $5}')
        if ! [[ "$grace_ts" =~ $UH_UINT ]]; then
            echo "ERROR: malformed line in $UHM_GRACE -- abort" >&2
            exit 1
        fi
        remaining_seconds=$(( (grace_ts + BLOCKDHCP_GRACE_SECONDS) - $(date +%s) ))
        if (( remaining_seconds > 0 )); then
            printf " %-18s${color_bold}%dh %dm${color_reset}\n" "Grace expires in:" "$((remaining_seconds/3600))" "$(( (remaining_seconds%3600)/60 ))"
        else
            printf " %-18s${color_bold}EXPIRED${color_reset}\n" "Grace expires in:"
        fi
    fi

    # Consistency checks
    if [ $in_block -eq 1 ]; then
        [ $in_acl -eq 1 ] && warn "In blockdhcp AND mac -- should be in one, not both"
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

    local total_found=$((in_hotspot + in_grace + in_block + in_acl + in_leases))
    if [ $total_found -eq 0 ]; then
        printf " ${color_bold}[!] MAC not found in any data source${color_reset}\n"
    fi

    echo ""
}

menu_check_mac() {
    echo ""
    local mac_addr
    while true; do
        read -rp " Enter MAC address (XX:XX:XX:XX:XX:XX, empty to cancel): " mac_addr
        mac_addr="${mac_addr#"${mac_addr%%[![:space:]]*}"}"
        mac_addr="${mac_addr%"${mac_addr##*[![:space:]]}"}"
        mac_addr="${mac_addr,,}"
        [[ -z "$mac_addr" ]] && return
        if [[ "$mac_addr" =~ $UH_MAC ]]; then
            break
        fi
        printf " ${color_bold}Invalid MAC format, try again${color_reset}\n"
    done
    echo ""
    check_mac "$mac_addr"
    press_enter
}

# --- Option 2: Grace period status -------------------------------------------
menu_grace_period() {
    echo ""
    if [ ! -r "$UHM_GRACE" ]; then
        echo "ERROR: cannot read $UHM_GRACE -- abort" >&2
        exit 1
    fi

    local now_epoch total_entries=0 expired_count=0 acl_status
    now_epoch=$(date +%s)

    printf " ${color_bold}%-20s %-18s %-25s %s${color_reset}\n" "MAC" "IP" "NAME" "EXPIRES IN"
    printf " %s\n" "$(printf -- '-%.0s' {1..76})"

    while IFS=';' read -r acl_status mac_addr client_ip client_name grace_ts rest_of_line; do
        [[ -z "$acl_status$mac_addr$client_ip$client_name$grace_ts" ]] && continue
        [[ "$acl_status" != "a" ]] && continue
        if [[ -z "$mac_addr" || -z "$grace_ts" ]] || ! [[ "$grace_ts" =~ $UH_UINT ]]; then
            echo "ERROR: malformed line in $UHM_GRACE -- abort" >&2
            exit 1
        fi
        total_entries=$((total_entries+1))
        local remaining_seconds=$(( (grace_ts + BLOCKDHCP_GRACE_SECONDS) - now_epoch ))
        if (( remaining_seconds > 0 )); then
            local grace_hours=$(( remaining_seconds/3600 ))
            local grace_minutes=$(( (remaining_seconds%3600)/60 ))
            printf " %-20s %-18s %-25.25s %dh %dm\n" "$mac_addr" "$client_ip" "$client_name" "$grace_hours" "$grace_minutes"
        else
            expired_count=$((expired_count+1))
            printf " %-20s %-18s %-25.25s ${color_bold}EXPIRED${color_reset}\n" "$mac_addr" "$client_ip" "$client_name"
        fi
    done < "$UHM_GRACE"

    echo ""
    printf " Total: %d | Expired: %d | Active: %d\n" "$total_entries" "$expired_count" "$((total_entries-expired_count))"
    press_enter
}

# --- Option 3: Consistency check + system summary ----------------------------
menu_consistency() {
    echo ""
    printf " ${color_bold}Collecting all MACs from all data sources...${color_reset}\n\n"

    # Collect all unique MACs
    local tmp_file
    tmp_file=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    temp_files+=("$tmp_file")

    # From semicolon-delimited files (field 2)
    local before_count
    for acl_file in "$UHM_MACAUTH" "$UHM_GRACE" "$ACL_BLOCK_FILE"; do
        before_count=$(wc -l < "$tmp_file")
        awk -F';' '$1=="a"{print tolower($2)}' "$acl_file" >> "$tmp_file"
        (( $(wc -l < "$tmp_file") == before_count )) && info "no active entries in $(basename "$acl_file")"
    done

    # From mac dir
    shopt -s nullglob
    for acl_file in "$ACL_MAC_PATH"/*.txt; do
        before_count=$(wc -l < "$tmp_file")
        grep -hioE "^a;$UH_MAC_RE" "$acl_file" | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
        (( $(wc -l < "$tmp_file") == before_count )) && info "no active entries in $(basename "$acl_file")"
    done
    shopt -u nullglob

    # From leases file
    before_count=$(wc -l < "$tmp_file")
    grep -ioE "$UH_MAC_RE" "$PYDHCPD_LEASES" \
        | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
    (( $(wc -l < "$tmp_file") == before_count )) && info "no active entries in $(basename "$PYDHCPD_LEASES")"

    local all_macs
    mapfile -t all_macs < <(sort -u "$tmp_file" | grep -E "$UH_MAC")
    rm -f "$tmp_file"

    local total_warnings=0
    local cnt_grace=0 cnt_block=0 cnt_acl=0 cnt_hotspot=0 cnt_leases=0

    for mac_addr in "${all_macs[@]}"; do
        # Single pass per MAC: these booleans feed both the summary counters
        # and the consistency warnings below.
        local warn_count=0
        local in_hotspot=0 in_grace=0 in_block=0 in_acl=0 in_leases=0
        found_in "$mac_addr" "$UHM_MACAUTH" && in_hotspot=1
        found_in "$mac_addr" "$UHM_GRACE" && in_grace=1
        found_in "$mac_addr" "$ACL_BLOCK_FILE" && in_block=1
        found_in_acl_dir "$mac_addr" && in_acl=1
        found_in_leases "$mac_addr" "$PYDHCPD_LEASES" && in_leases=1

        [ $in_hotspot -eq 1 ] && cnt_hotspot=$((cnt_hotspot+1))
        [ $in_grace -eq 1 ] && cnt_grace=$((cnt_grace+1))
        [ $in_block -eq 1 ] && cnt_block=$((cnt_block+1))
        [ $in_acl -eq 1 ] && cnt_acl=$((cnt_acl+1))
        [ $in_leases -eq 1 ] && cnt_leases=$((cnt_leases+1))

        if [ $in_block -eq 1 ]; then
            if [ $in_acl -eq 1 ]; then
                [ $warn_count -eq 0 ] && printf "${color_bold}--- %s ---${color_reset}\n" "$mac_addr"
                warn "In blockdhcp AND mac -- should be in one, not both"
                warn_count=$((warn_count+1))
            fi
            if [ $in_grace -eq 1 ]; then
                [ $warn_count -eq 0 ] && printf "${color_bold}--- %s ---${color_reset}\n" "$mac_addr"
                warn "In blockdhcp AND uhm-grace -- contradictory state"
                warn_count=$((warn_count+1))
            fi
            if [ $in_leases -eq 1 ]; then
                [ $warn_count -eq 0 ] && printf "${color_bold}--- %s ---${color_reset}\n" "$mac_addr"
                warn "In blockdhcp AND leases -- lease should have been cleared"
                warn_count=$((warn_count+1))
            fi
        fi
        if [ $in_hotspot -eq 1 ] && [ $in_grace -eq 1 ]; then
            [ $warn_count -eq 0 ] && printf "${color_bold}--- %s ---${color_reset}\n" "$mac_addr"
            warn "In uhm-auth AND uhm-grace"
            warn "  run uhmreload.sh to clear the uhm-grace entry"
            warn_count=$((warn_count+1))
        fi
        [ $warn_count -gt 0 ] && echo ""
        total_warnings=$((total_warnings+warn_count))
    done

    # Summary
    printf "${color_bold}=== SYSTEM SUMMARY ===${color_reset}\n"
    printf "  %-18s: %d\n" "MACs found total" "${#all_macs[@]}"
    printf "  %-18s: %d\n" "Grace period" "$cnt_grace"
    printf "  %-18s: %d\n" "Blocked" "$cnt_block"
    printf "  %-18s: %d\n" "ACL permanent" "$cnt_acl"
    printf "  %-18s: %d\n" "Hotspot auth" "$cnt_hotspot"
    printf "  %-18s: %d\n" "In leases file" "$cnt_leases"
    printf "  %-18s: ${color_bold}%d${color_reset}\n" "Warnings" "$total_warnings"

    press_enter
}

# --- Option 4: Search by IP or hostname --------------------------------------
menu_search() {
    echo ""
    local search_query
    read -rp " Enter IP address or hostname: " search_query
    search_query="${search_query#"${search_query%%[![:space:]]*}"}"
    search_query="${search_query%"${search_query##*[![:space:]]}"}"
    search_query="${search_query,,}"
    if [ -z "$search_query" ]; then
        printf " ${color_bold}Empty query${color_reset}\n"
        press_enter
        return
    fi

    echo ""
    printf " ${color_bold}Searching for: %s${color_reset}\n\n" "$search_query"

    local found_macs=()
    local tmp_file
    tmp_file=$(mktemp) || { echo "ERROR: cannot create temp file in /tmp" >&2; echo "ERROR: check free space, read-only mount, immutable -- abort" >&2; exit 1; }
    temp_files+=("$tmp_file")

    # Search in semicolon-delimited files (all fields)
    for acl_file in "$UHM_MACAUTH" "$UHM_GRACE" "$ACL_BLOCK_FILE"; do
        grep -iF "$search_query" "$acl_file" \
            | awk -F';' '$1=="a"{print tolower($2)}' >> "$tmp_file"
    done

    # Search in mac dir (lines containing query, extract MAC)
    shopt -s nullglob
    for acl_file in "$ACL_MAC_PATH"/*.txt; do
        grep -hiF "$search_query" "$acl_file" \
            | grep -ioE "^a;$UH_MAC_RE" | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
    done
    shopt -u nullglob

    # Search in leases file
    grep -iF "$search_query" "$PYDHCPD_LEASES" \
        | grep -ioE "$UH_MAC_RE" \
        | tr '[:upper:]' '[:lower:]' >> "$tmp_file"

    mapfile -t found_macs < <(sort -u "$tmp_file" | grep -E "$UH_MAC")
    rm -f "$tmp_file"

    if [ ${#found_macs[@]} -eq 0 ]; then
        printf " ${color_bold}No MACs found matching: %s${color_reset}\n" "$search_query"
        press_enter
        return
    fi

    printf " Found %d MAC(s):\n\n" "${#found_macs[@]}"
    for mac_addr in "${found_macs[@]}"; do
        check_mac "$mac_addr"
    done

    press_enter
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main_menu() {
    while true; do
        clear
        printf "${color_bold}#######################################${color_reset}\n"
        printf "${color_bold}# uhmacl -- Local ACL Diagnostic Tool #${color_reset}\n"
        printf "${color_bold}#######################################${color_reset}\n"
        echo ""
        printf " 1. Check MAC\n"
        printf " 2. Grace period status\n"
        printf " 3. Consistency check + system summary\n"
        printf " 4. Search by IP or hostname\n"
        printf " 5. Exit\n"
        echo ""
        read -rp " Select option [1-5]: " menu_option
        case "$menu_option" in
            1) menu_check_mac ;;
            2) menu_grace_period ;;
            3) menu_consistency ;;
            4) menu_search ;;
            5|"") echo ""; exit 0 ;;
            *) printf " ${color_bold}Invalid option${color_reset}\n"; sleep 1 ;;
        esac
    done
}

main_menu
