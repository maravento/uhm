#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmunifi - UniFi Network Hotspot - Full Client Audit & Management Tool
#
# DESCRIPTION:
# Audits what the UniFi controller itself reports (sessions, authorizations,
# vouchers) against uhm-auth.txt, and offers actions to act on the API
# directly.
#
# USAGE:
# sudo bash uhmunifi.sh
#
# MENU: [1] Reports, [2] Actions, [q] Quit. Two submenus so the top level
# stays short:
#
# REPORTS SUBMENU
# [1] Connection status - login + fetch summary for stat/sta, stat/guest
#     and stat/voucher (rc and entry count for each)
# [2] Authorized - uhm-auth.txt enriched with voucher code and status.
#     Voucher code is extracted from the hostname field
#     (format: guest{n}-{code}) and verified against stat/voucher.
#     STATUS values: MULTI (USED_MULTIPLE), VALID (VALID_ONE),
#     CONSUMED (quota exhausted, auto-purged by UniFi),
#     NO-VOUCHER(origin) (no code in the hostname and UniFi
#     reports the session as authorized_by != voucher, i.e.
#     an authorization granted outside the voucher flow).
#     ON column: YES if client is currently connected to the AP.
# [3] Vouchers - full voucher list from stat/voucher with usage stats
# [4] Guest sessions - every active session UniFi reports in stat/guest,
#     split into three mutually exclusive categories by where the MAC
#     lives, not by authorized_by -- so a genuine anomaly is never
#     buried under the routine mac-*.txt noise:
#       - SYSADMIN MANAGED: MAC is in mac-*.txt. Authorized via
#         authorize-guest by design (see authorize_managed_macs in
#         uhmd.sh), no voucher involved. Never touched by any action.
#       - VOUCHER AUTHORIZED: not managed, MAC has a line in
#         uhm-auth.txt (has a voucher on record).
#       - UNKNOWN (warning): not managed, not in uhm-auth.txt --
#         everything else. The one to verify and, if illegitimate,
#         delete.
#     Every row is also self-labeled in the ORIGIN column, independent
#     of which section it's under: "(managed)" in SYSADMIN MANAGED,
#     "(!)" in VOUCHER AUTHORIZED/UNKNOWN for an unknown record -- so a
#     row read in isolation (e.g. copied out for a manual command) is
#     never ambiguous.
# [5] Unauthorized - clients connected to the hotspot ESSID that stat/sta
#     reports as NOT authorized
#
# ACTIONS SUBMENU -- none of these ever touch a mac-*.txt MAC (see
# is_managed_mac() below); only the VOUCHER AUTHORIZED/UNKNOWN
# categories above are ever eligible.
# [1] Delete unused vouchers - delete vouchers never activated (used=0)
# [2] Forget clients no voucher - forget guests who connected to the
#     portal but never submitted a voucher code. Excludes clients
#     currently connected to the hotspot ESSID (stat/sta), even if they
#     never used a voucher -- only disconnected/stale ones are listed
# [3] Delete expired vouchers - delete vouchers past their end_time and
#     forget all associated client history
# [4] Revoke by voucher code - surgical invalidation of a single voucher:
#     delete from stat/voucher if still present, unauthorize active
#     sessions, forget all associated MACs from stat/guest and stat/sta.
#     Workaround for UniFi bug: stat/guest does not distinguish manually
#     deleted vouchers from quota-exhausted ones
#     (community.ui.com/31faff3e)
# [5] Forget sessions marked (!) - unauthorize + forget every active
#     session whose authorized_by is not "voucher" and is not a
#     mac-*.txt device (see report [4]'s UNKNOWN category)
# [6] Purge everything - DELETE all vouchers and client history
#     (DESTRUCTIVE -- requires typing YES)
#
# AUTH
# Authenticates against UniFi OS (/api/auth/login) by default, or classic
# controllers (/api/login) when UNIFI_TYPE=classic is set in uhm.env.
# Requires UHM_ESSID, UNIFI_CONTROLLER_URL, UNIFI_USERNAME,
# UNIFI_PASSWORD in uhm.env
#
# EXIT CODES:
# 0 - Normal exit
# 1 - Not root, already running, missing dependency, unwritable log,
#     unreadable or incomplete configuration, unreadable or malformed
#     data file, failed login, or failed UniFi query
#
# DEPENDENCIES : curl, jq, bsdextrautils, mawk, coreutils, util-linux,
#                grep, sed
# CONFIG       : /etc/uhm/uhm.env
# LOG          : /var/log/uhmunifi.log
#
# GLOBALS BY DESIGN:
# session_cookie and csrf_token are set by do_login() and read by api_get()
# and api_post() on every request. They cannot be declared local.
#
# NOTE on logging:
# - Manual/interactive script, not a daemon: the log file is truncated
#   at the start of every run, so it always reflects only the latest
#   session. It records the login/fetch summary and every action taken;
#   report tables (options 1-5) are terminal-only, on demand.
#   No rotation is needed or installed for this file.
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# logging
log_file="/var/log/uhmunifi.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}
# File-only variant -- for the startup fetch summary, which would otherwise
# scroll off screen before the menu is ever shown (see main_menu()'s status
# line, which displays this same data on every redraw instead).
log_only() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

if ! : > "$log_file" 2>/dev/null; then
    echo "ERROR: cannot write $log_file -- abort" >&2
    exit 1
fi

# log file perms: this log carries client MAC addresses, hostnames and
# voucher codes, so it gets the same 640 root:adm as the shared uhm.log
# instead of whatever the umask leaves behind.
log_stat=$(stat -c '%U %G %a' "$log_file" 2>/dev/null || true)
case "$log_stat" in
    "root adm 640"|"root root 640") ;;
    *)
        if { chown root:adm "$log_file" 2>/dev/null || chown root:root "$log_file" 2>/dev/null; } &&
           chmod 640 "$log_file" 2>/dev/null; then
            log "WARNING: uhmunifi.log perms fixed -- alert"
        else
            log "WARNING: cannot fix uhmunifi.log perms -- alert"
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

# dependencies
for dep_pkg in curl jq bsdextrautils mawk coreutils util-linux grep sed; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

pydhcp_conf="/etc/pydhcp/pydhcp.env"
uhm_conf="/etc/uhm/uhm.env"
if [ ! -f "$uhm_conf" ]; then
    log "ERROR: uhm.env not found, run uhmsetup.sh -- abort"
    exit 1
fi
file_owner=$(stat -c '%U' "$uhm_conf" 2>/dev/null)
file_perms=$(stat -c '%a' "$uhm_conf" 2>/dev/null)
if [[ "$file_owner" != "root" ]] || [[ "$file_perms" != "600" ]]; then
    log "ERROR: uhm.env must be root:root 600 -- abort"
    exit 1
fi

# start
log "uhmunifi start..."

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

load_config() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
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
            log "ERROR: stray whitespace in a config key"
            log "ERROR: key $env_key -- abort"
            exit 1
        fi
        env_value="${env_value%\"}"
        env_value="${env_value#\"}"
        env_value="${env_value//\\\"/\"}"
        env_value="${env_value//\\\$/\$}"
        env_value="${env_value//\\\`/\`}"
        env_value="${env_value//\\\\/\\}"
        case "$env_key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_SITE|UNIFI_TYPE|UNIFI_CERT_PIN|UHM_ESSID|UHM_MACAUTH|ACL_MAC_PATH)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}
# pydhcp.env first: it owns ACL_MAC_PATH. uhm.env is read after, so uhm's
# own keys win if a name ever collides.
if [ ! -r "$pydhcp_conf" ]; then
    log "ERROR: cannot read $pydhcp_conf -- abort"
    log "ERROR: uhm reads ACL_MAC_PATH from it"
    exit 1
fi
load_config "$pydhcp_conf"
load_config "$uhm_conf"

for required_key in UNIFI_CONTROLLER_URL UNIFI_USERNAME UNIFI_PASSWORD UHM_ESSID \
          UHM_MACAUTH ACL_MAC_PATH; do
    if [ -z "${!required_key:-}" ]; then
        log "ERROR: $required_key not set in uhm.env -- abort"
        exit 1
    fi
done
unset required_key

UNIFI_SITE="${UNIFI_SITE:-default}"
UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"

# True if $1 (lowercase MAC) is listed in ANY mac-*.txt, active or
# commented -- same definition as is_managed_mac() in uhmd.sh. A managed
# device is authorized in UniFi via authorize-guest (authorized_by=api),
# not a voucher, by design -- see authorize_managed_macs() in uhmd.sh.
is_managed_mac() {
    local mac_addr="$1" mac_file
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for mac_file in "${mac_files[@]}"; do
        grep -qiE "^#?a;${mac_addr};" "$mac_file" && return 0
    done
    return 1
}
run_timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# ------------------------------------------------------------------------------
# AUTH
# ------------------------------------------------------------------------------

do_login() {
    local login_path
    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        login_path="/api/login"
    else
        login_path="/api/auth/login"
    fi
    local login_payload
    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    local login_response
    login_response=$(curl -si "${tls_opts[@]}" -X POST -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 10 --max-time 40 \
        "$UNIFI_CONTROLLER_URL$login_path" <<< "$login_payload")

    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        session_cookie=$(echo "$login_response" | grep -i "^set-cookie:" | grep -i "unifises=" | head -1 \
            | sed -E "s/.*unifises=([^;]+).*/unifises=\1/" | tr -d "\r")
        csrf_token=$(echo "$login_response" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
    else
        local auth_token
        auth_token=$(echo "$login_response" | grep -i "^set-cookie:" | grep -i "TOKEN=" | head -1 \
            | sed -E "s/.*TOKEN=([^;]+).*/\1/" | tr -d "\r")

        if [ -z "$auth_token" ]; then
            log "ERROR: UniFi login failed -- abort"
            log "ERROR: check credentials and URL in uhm.env"
            log "ERROR: controller may be unavailable, try again later"
            exit 1
        fi
        session_cookie="TOKEN=${auth_token}"

        # UniFi OS embeds the CSRF token inside the JWT payload (csrfToken field).
        local jwt_payload pad_len padded_jwt
        jwt_payload=$(echo "$auth_token" | cut -d'.' -f2 | tr '_-' '/+')
        pad_len=$(( (4 - ${#jwt_payload} % 4) % 4 ))
        padded_jwt="$jwt_payload"
        if (( pad_len > 0 )); then
            padded_jwt="${jwt_payload}$(printf '%*s' "$pad_len" '' | tr ' ' '=')"
        fi
        csrf_token=$(echo "$padded_jwt" | base64 -d 2>/dev/null \
            | jq -r '.csrfToken // empty' 2>/dev/null || true)

        # Fallback: check response headers, in case a given UniFi OS version emits them.
        if [[ -z "$csrf_token" ]]; then
            csrf_token=$(echo "$login_response" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
        fi
    fi

    if [ -z "$session_cookie" ]; then
        log "ERROR: UniFi login failed -- abort"
        log "ERROR: check credentials and URL in uhm.env"
        log "ERROR: controller may be unavailable, try again later"
        exit 1
    fi
}

do_login

# ------------------------------------------------------------------------------
# API
# ------------------------------------------------------------------------------

if [[ "$UNIFI_TYPE" == "classic" ]]; then
    api_base_url="$UNIFI_CONTROLLER_URL/api/s/$UNIFI_SITE"
else
    api_base_url="$UNIFI_CONTROLLER_URL/proxy/network/api/s/$UNIFI_SITE"
fi

api_get() {
    local raw_response http_code response_body
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    raw_response=$(curl -s "${tls_opts[@]}" -X GET \
        --connect-timeout 10 --max-time 30 \
        -w "\n__CODE__:%{http_code}" \
        -H "X-CSRF-Token: $csrf_token" \
        -H "Cookie: $session_cookie" \
        "$api_base_url/$1")
    http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    response_body=$(echo "$raw_response" | grep -v '__CODE__:')
    if [[ "$http_code" == "401" ]]; then
        echo "INFO: Session expired -- re-authenticating" >&2
        do_login
        raw_response=$(curl -s "${tls_opts[@]}" -X GET \
            --connect-timeout 10 --max-time 30 \
            -w "\n__CODE__:%{http_code}" \
            -H "X-CSRF-Token: $csrf_token" \
            -H "Cookie: $session_cookie" \
            "$api_base_url/$1")
        response_body=$(echo "$raw_response" | grep -v '__CODE__:')
    fi
    echo "$response_body"
}

api_post() {
    local raw_response http_code
    local tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    raw_response=$(curl -s "${tls_opts[@]}" -X POST \
        --connect-timeout 10 --max-time 30 \
        -w "\n__CODE__:%{http_code}" \
        -H "X-CSRF-Token: $csrf_token" \
        -H "Cookie: $session_cookie" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "$api_base_url/$1")
    http_code=$(echo "$raw_response" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    if [[ "$http_code" == "401" ]]; then
        echo "INFO: Session expired -- re-authenticating" >&2
        do_login
        raw_response=$(curl -s "${tls_opts[@]}" -X POST \
            --connect-timeout 10 --max-time 30 \
            -w "\n__CODE__:%{http_code}" \
            -H "X-CSRF-Token: $csrf_token" \
            -H "Cookie: $session_cookie" \
            -H "Content-Type: application/json" \
            -d "$2" \
            "$api_base_url/$1")
    fi
    echo "$raw_response" | grep -v '__CODE__:'
}

# ------------------------------------------------------------------------------
# FETCH
# ------------------------------------------------------------------------------

sta_json=$(api_get "stat/sta")
guest_json=$(api_get "stat/guest")
voucher_json=$(api_get "stat/voucher")

sta_rc=$(echo "$sta_json" | jq -r '.meta.rc // "error"' 2>/dev/null)
guest_rc=$(echo "$guest_json" | jq -r '.meta.rc // "error"' 2>/dev/null)
voucher_rc=$(echo "$voucher_json" | jq -r '.meta.rc // "error"' 2>/dev/null)

# Startup availability check: every endpoint this script works with must
# answer before the menu is drawn, so an action can never fail halfway
# through because the controller went away. do_login's own "exit 1" on
# failed re-authentication only kills the subshell of the api_get/api_post
# call that triggered it (command substitution), so it never aborts this
# script by itself -- this loop is what stops it, from the main body.
for endpoint_rc in "stat/sta:$sta_rc" "stat/guest:$guest_rc" "stat/voucher:$voucher_rc"; do
    if [[ "${endpoint_rc#*:}" != "ok" ]]; then
        log "ERROR: ${endpoint_rc%%:*} query failed -- abort"
        log "ERROR: controller may be unavailable, try again later"
        exit 1
    fi
done
unset endpoint_rc

shopt -s nullglob
uhm_mac_lists=("$ACL_MAC_PATH"/mac-*.txt)
shopt -u nullglob
if (( ${#uhm_mac_lists[@]} == 0 )); then
    log "ERROR: no mac-*.txt in $ACL_MAC_PATH -- abort"
    exit 1
fi
for check_file in "$UHM_MACAUTH" "${uhm_mac_lists[@]}"; do
    grep -qE '' "$check_file"
    if (( $? > 1 )); then
        log "ERROR: cannot read $check_file -- abort"
        exit 1
    fi
done
unset uhm_mac_lists check_file

while IFS=';' read -r acl_status auth_mac rest_of_line; do
    [ "$acl_status" != "a" ] && continue
    if [ -z "$auth_mac" ]; then
        log "ERROR: malformed line in $UHM_MACAUTH -- abort"
        exit 1
    fi
done < "$UHM_MACAUTH"
unset acl_status auth_mac rest_of_line

sta_count=$(echo "$sta_json" | jq '.data|length' 2>/dev/null)
guest_count=$(echo "$guest_json" | jq '.data|length' 2>/dev/null)
voucher_count=$(echo "$voucher_json" | jq '.data|length' 2>/dev/null)
log_only "INFO: stat/sta -> $sta_rc ($sta_count entries)"
log_only "INFO: stat/guest -> $guest_rc ($guest_count entries)"
log_only "INFO: stat/voucher -> $voucher_rc ($voucher_count entries)"

press_enter() {
    echo ""
    read -rp " Press ENTER to continue..." _
}

# REPORT [2]: AUTHORIZED CLIENTS
# Cross-references uhm-auth.txt with stat/guest and stat/sta
# VOUCHER RESOLUTION STRATEGY:
# 1. Extract voucher code from hostname field in uhm-auth.txt
#    (format: guest{n}-{voucher_code}, e.g. guest3-7708162928)
#    This is always available even when the client is disconnected,
#    because uhmd.sh writes it at authorization time.
# 2. Verify the code exists in stat/voucher (API) and enrich with status.
#    If found: show as CODE(STATUS) e.g. 7708162928(USED_MULTIPLE)
#    If not found in stat/voucher: quota exhausted and auto-purged by
#    UniFi, show as CODE(CONSUMED)
# 3. Fallback: if hostname has no voucher code, query stat/guest by MAC.
#    This covers clients still connected whose session is in stat/guest.
# 4. If neither source yields a code: show N/A, and check authorized_by
#    in that MAC's stat/guest session. Anything other than "voucher"
#    (typically "api", a cmd/stamgr authorize-guest) means the entry
#    never came from the voucher flow at all, and is reported as
#    NO-VOUCHER(origin) instead of a plain N/A status.
print_authorized() {
    echo ""
    echo "============================================================================"
    echo "AUTHORIZED -- uhm-auth.txt"
    echo "============================================================================"

    local sta_map
    sta_map=$(echo "$sta_json" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | (.mac | ascii_downcase)
    ' 2>/dev/null)

    {
        printf "MAC|IP|CODE|STATUS|EXPIRES|ON\n"
        while IFS=';' read -r acl_status mac_addr client_ip client_name end_time _; do
            [ "$acl_status" != "a" ] && continue
            local expires_at voucher_field voucher_code voucher_status
            local authorized_by is_connected

            expires_at="N/A"
            [ -n "$end_time" ] && expires_at=$(date -d "@$end_time" '+%m-%d %H:%M' 2>/dev/null || echo "$end_time")

            # Step 1: extract code from hostname (guest{n}-{code})
            voucher_field=$(echo "$client_name" | sed -n 's/^guest[0-9]*-\([A-Za-z0-9._-]*\)$/\1/p')

            # Step 2: verify against stat/voucher API and get status
            voucher_code=""
            voucher_status=""
            if [ -n "$voucher_field" ]; then
                voucher_code="$voucher_field"
                voucher_status=$(echo "$voucher_json" | jq -r --arg code "$voucher_field" '
                    .data[] | select(.code == $code) | .status // ""
                ' 2>/dev/null | head -1)
                [ -z "$voucher_status" ] && voucher_status="CONSUMED"
            else
                # Step 3: fallback to stat/guest by MAC
                voucher_code=$(echo "$guest_json" | jq -r --arg m "$mac_addr" '
                    .data[]
                    | select((.mac | ascii_downcase) == $m)
                    | .voucher_code // ""
                ' 2>/dev/null | head -1)
                if [ -n "$voucher_code" ]; then
                    voucher_status=$(echo "$voucher_json" | jq -r --arg code "$voucher_code" '
                        .data[] | select(.code == $code) | .status // ""
                    ' 2>/dev/null | head -1)
                    [ -z "$voucher_status" ] && voucher_status="CONSUMED"
                fi
            fi

            # Step 4: nothing found -- flag an entry UniFi did not authorize
            # through the voucher flow (authorized_by != voucher)
            if [ -z "$voucher_code" ]; then
                authorized_by=$(echo "$guest_json" | jq -r --arg m "$mac_addr" '
                    .data[]
                    | select((.mac | ascii_downcase) == $m)
                    | .authorized_by // ""
                ' 2>/dev/null | head -1)
                voucher_code="N/A"
                [ -n "$authorized_by" ] && [ "$authorized_by" != "voucher" ] && voucher_status="NO-VOUCHER($authorized_by)"
            fi
            [ -z "$voucher_status" ] && voucher_status="N/A"
            voucher_status=$(echo "$voucher_status" | sed 's/USED_MULTIPLE/MULTI/;s/VALID_ONE/VALID/;s/VALID_MULTI/MULTI/')

            is_connected=$(echo "$sta_map" | awk -v mac_addr="${mac_addr}" 'tolower($1) == tolower(mac_addr) {print "YES"; exit}')
            [ -z "$is_connected" ] && is_connected="NO"

            echo "$mac_addr|$client_ip|$voucher_code|$voucher_status|$expires_at|$is_connected"
        done < "$UHM_MACAUTH"
    } | column -t -s '|'
    echo ""
}

# REPORT [3]: VOUCHERS
# Lists every voucher known to the controller
print_voucher() {
    echo ""
    echo "============================================================================"
    echo "VOUCHERS -- stat/voucher"
    echo "============================================================================"
    {
        printf "CODE|STATUS|DURATION|QUOTA|USED|EXPIRES\n"
        echo "$voucher_json" | jq -r '
            .data[]
            | [.code//"N/A", (.status//"N/A"), (((.duration//0)/60|floor|tostring) + "h"), (.quota//0|tostring), (.used//0|tostring), (if .end_time then (.end_time|strftime("%m-%d %H:%M")) else "N/A" end)]
            | join("|")
        ' 2>/dev/null
    } | column -t -s '|'
    echo ""
}

# REPORT [4]: GUEST SESSIONS
# Lists the portal sessions the controller holds
# Reports [1]/[2] audit what is already in uhm-auth.txt or in the voucher
# inventory. This one audits the source UniFi itself reports, so an
# authorization that never came from a voucher -- and therefore never
# reaches uhm-auth.txt -- is still visible instead of going unnoticed.
# ORIGIN is UniFi's own authorized_by. IN-LIST tells whether that MAC has a
# line in uhm-auth.txt: an "api" origin is expected for mac-*.txt devices
# (authorize_managed_macs in uhmd.sh) and must show IN-LIST=no; an "api"
# origin with IN-LIST=yes is a leftover from before uhmd.sh filtered by
# origin (see uhmd.sh's SESSIONS step).
print_guest_sessions() {
    local now_epoch
    now_epoch=$(date +%s)

    local managed_rows="" authorized_rows="" other_rows=""
    local guest_mac guest_origin guest_code guest_end guest_online

    while IFS='|' read -r guest_mac guest_origin guest_code guest_end; do
        [ -z "$guest_mac" ] && continue

        guest_online=$(echo "$sta_json" | jq -r --arg m "$guest_mac" '
            .data[] | select((.mac|ascii_downcase) == $m) | "YES"
        ' 2>/dev/null | head -1)
        [ -z "$guest_online" ] && guest_online="NO"
        [ -z "$guest_code" ] && guest_code="N/A"

        if is_managed_mac "$guest_mac"; then
            managed_rows+="$guest_mac|${guest_origin}(managed)|$guest_code|$guest_end|$guest_online
"
        elif grep -qiE "^#?a;${guest_mac};" "$UHM_MACAUTH"; then
            [ "$guest_origin" != "voucher" ] && guest_origin="${guest_origin}(!)"
            authorized_rows+="$guest_mac|$guest_origin|$guest_code|$guest_end|$guest_online
"
        else
            [ "$guest_origin" != "voucher" ] && guest_origin="${guest_origin}(!)"
            other_rows+="$guest_mac|$guest_origin|$guest_code|$guest_end|$guest_online
"
        fi
    done < <(echo "$guest_json" | jq -r --argjson now "$now_epoch" '
        .data[]
        | select(.end != null and .end > $now)
        | [(.mac|ascii_downcase), (.authorized_by//"none"), (.voucher_code//""), (.end|strftime("%m-%d %H:%M"))]
        | join("|")
    ' 2>/dev/null | sort -t'|' -k2,2 -k1,1)

    echo ""
    echo "============================================================================"
    echo "GUEST SESSIONS -- SYSADMIN MANAGED (mac-*.txt)"
    echo "============================================================================"
    if [ -z "$managed_rows" ]; then
        echo " None."
    else
        { printf "MAC|ORIGIN|CODE|EXPIRES|ON\n"; printf '%s' "$managed_rows"; } | column -t -s '|'
    fi

    echo ""
    echo "============================================================================"
    echo "GUEST SESSIONS -- VOUCHER AUTHORIZED (uhm-auth.txt)"
    echo "============================================================================"
    if [ -z "$authorized_rows" ]; then
        echo " None."
    else
        { printf "MAC|ORIGIN|CODE|EXPIRES|ON\n"; printf '%s' "$authorized_rows"; } | column -t -s '|'
    fi

    echo ""
    echo "============================================================================"
    echo "GUEST SESSIONS -- UNKNOWN (warning)"
    echo "============================================================================"
    if [ -z "$other_rows" ]; then
        echo " None."
    else
        { printf "MAC|ORIGIN|CODE|EXPIRES|ON\n"; printf '%s' "$other_rows"; } | column -t -s '|'
    fi
    echo ""
    echo "LEGEND:"
    echo "  (managed) mac-*.txt, never touched"
    echo "  (!) unknown record, verify and delete"
    echo ""
}

# REPORT [5]: UNAUTHORIZED CLIENTS
# Lists clients on the ESSID with no authorization
print_unauthorized() {
    echo ""
    echo "============================================================================"
    printf "UNAUTHORIZED -- stat/sta, clients on %s NOT authorized by UniFi\n" "$UHM_ESSID"
    echo "============================================================================"

    local sta_rows
    sta_rows=$(echo "$sta_json" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | select(.authorized == false)
        | [(.mac), (.hostname // "no-hostname"), (.ip // "no-ip"), (.last_seen // "n/a")]
        | join("|")
    ' 2>/dev/null)

    if [ -z "$sta_rows" ]; then
        echo " None -- all clients on $UHM_ESSID are authorized"
    else
        {
            printf "MAC|HOSTNAME|IP|LAST_SEEN\n"
            echo "$sta_rows"
        } | column -t -s '|'
    fi
    echo ""
}

# ACTION [1]: DELETE UNUSED VOUCHERS
# Removes vouchers nobody ever redeemed
interactive_delete_unused() {
    echo ""
    echo "============================================================================"
    echo "DELETE UNUSED VOUCHERS - vouchers that have never been activated"
    echo "============================================================================"

    mapfile -t unused_ids < <(echo "$voucher_json" | jq -r '
        .data[] | select(.used == 0) | ._id
    ' 2>/dev/null)

    if [ ${#unused_ids[@]} -eq 0 ]; then
        log "INFO: No unused vouchers found."
        return
    fi

    echo "Unused vouchers to delete:"
    echo ""
    for voucher_id in "${unused_ids[@]}"; do
        local voucher_info
        voucher_info=$(echo "$voucher_json" | jq -r --arg id "$voucher_id" '
            .data[] | select(._id == $id)
            | [
                (.code // "N/A"),
                (((.duration // 0) / 60 | floor | tostring) + "h"),
                ("quota=" + ((.quota // 0) | tostring)),
                (if .create_time then (.create_time | strftime("%Y-%m-%d")) else "N/A" end)
              ]
            | join(" ")
        ' 2>/dev/null)
        echo "code=$voucher_info"
    done

    echo ""
    read -rp " Confirm deletion of ${#unused_ids[@]} unused voucher(s)? [y/N]: " confirm_answer
    [[ ! "$confirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for voucher_id in "${unused_ids[@]}"; do
        local voucher_code delete_rc
        voucher_code=$(echo "$voucher_json" | jq -r --arg id "$voucher_id" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)
        delete_rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${voucher_id}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$delete_rc" = "ok" ] \
            && log "INFO: Deleted voucher: $voucher_code" \
            || log "WARNING: Failed to delete voucher: $voucher_code"
    done

    log "INFO: Done."
}

# ACTION [2]: FORGET CLIENTS WITHOUT VOUCHER
# Removes client history for devices that never passed the portal
interactive_forget_no_voucher() {
    echo ""
    echo "============================================================================"
    echo "FORGET CLIENTS WITHOUT VOUCHER - connected to portal but never used one"
    echo "============================================================================"

    if [[ "$guest_rc" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$guest_rc) -- skip"
        return
    fi
    if [[ "$sta_rc" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$sta_rc) -- skip"
        return
    fi

    local all_users_json
    all_users_json=$(api_get "rest/user")
    local all_users_rc
    all_users_rc=$(echo "$all_users_json" | jq -r '.meta.rc // "error"' 2>/dev/null)
    if [ "$all_users_rc" != "ok" ]; then
        log "WARNING: Could not fetch rest/user (rc=$all_users_rc)"
        return
    fi

    local guest_macs
    guest_macs=$(echo "$guest_json" | jq -r '
        .data[]
        | select(.voucher_code != null and .voucher_code != "")
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    local sta_macs
    sta_macs=$(echo "$sta_json" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t novoucher_macs < <(echo "$all_users_json" | jq -r '
        .data[]
        | select(.is_guest == true)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u | while IFS= read -r mac_addr; do
        echo "$guest_macs" | grep -qx "$mac_addr" && continue
        echo "$sta_macs" | grep -qx "$mac_addr" && continue
        is_managed_mac "$mac_addr" && continue
        echo "$mac_addr"
    done)

    if [ ${#novoucher_macs[@]} -eq 0 ]; then
        log "INFO: No clients found matching the criteria."
        return
    fi

    echo "Clients to forget (${#novoucher_macs[@]}):"
    echo ""
    for mac_addr in "${novoucher_macs[@]}"; do
        local client_name last_seen
        client_name=$(echo "$all_users_json" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac | ascii_downcase) == $m) | .hostname // "N/A"
        ' 2>/dev/null | head -1)
        last_seen=$(echo "$all_users_json" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac | ascii_downcase) == $m)
            | if .last_seen then (.last_seen | strftime("%Y-%m-%d %H:%M")) else "N/A" end
        ' 2>/dev/null | head -1)
        printf " %-20s %-25s last_seen=%s\n" "$mac_addr" "$client_name" "$last_seen"
    done

    echo ""
    read -rp " Confirm forget of ${#novoucher_macs[@]} client(s)? [y/N]: " confirm_answer
    [[ ! "$confirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for mac_addr in "${novoucher_macs[@]}"; do
        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: Failed to forget: $mac_addr"
    done

    log "INFO: Done."
}

# ACTION [3]: DELETE EXPIRED VOUCHERS
# Removes expired vouchers and the client history they left behind
interactive_delete_expired() {
    local now_epoch
    now_epoch=$(date +%s)

    echo ""
    echo "============================================================================"
    echo "DELETE EXPIRED VOUCHERS + FORGET THEIR CLIENTS"
    echo "============================================================================"

    if [[ "$voucher_rc" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$voucher_rc) -- skip"
        return
    fi
    if [[ "$sta_rc" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$sta_rc) -- skip"
        return
    fi
    if [[ "$guest_rc" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$guest_rc) -- skip"
        return
    fi

    mapfile -t expired_ids < <(echo "$voucher_json" | jq -r \
        --argjson now "$now_epoch" '
        .data[]
        | select(.end_time != null and .end_time < $now)
        | ._id
    ' 2>/dev/null)

    if [ ${#expired_ids[@]} -eq 0 ]; then
        log "INFO: No expired vouchers found."
        return
    fi

    echo "Expired vouchers to delete:"
    echo ""
    for voucher_id in "${expired_ids[@]}"; do
        local voucher_info
        voucher_info=$(echo "$voucher_json" | jq -r --arg id "$voucher_id" '
            .data[] | select(._id == $id)
            | [
                (.code // "N/A"),
                (((.duration // 0) / 60 | floor | tostring) + "h"),
                ("used=" + ((.used // 0) | tostring)),
                (if .end_time then (.end_time | strftime("%Y-%m-%d %H:%M")) else "N/A" end)
              ]
            | join(" ")
        ' 2>/dev/null)
        echo "code=$voucher_info"
    done

    echo ""
    read -rp " Confirm deletion of ${#expired_ids[@]} expired voucher(s)? [y/N]: " confirm_answer
    [[ ! "$confirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""

    for voucher_id in "${expired_ids[@]}"; do
        local voucher_code delete_rc
        voucher_code=$(echo "$voucher_json" | jq -r --arg id "$voucher_id" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)

        delete_rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${voucher_id}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        if [ "$delete_rc" = "ok" ]; then
            log "INFO: Deleted voucher: $voucher_code"
        else
            log "WARNING: voucher $voucher_code and clients not deleted -- alert"
            continue
        fi

        while IFS= read -r mac_addr; do
            [ -z "$mac_addr" ] && continue
            local unauth_rc
            unauth_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$unauth_rc" = "ok" ] \
                && log "INFO: Unauthorized: $mac_addr" \
                || log "INFO: no active session: $mac_addr"
        done < <(echo "$sta_json" | jq -r --arg code "$voucher_code" '
            .data[]
            | select(.voucher_code == $code)
            | (.mac | ascii_downcase)
        ' 2>/dev/null | sort -u)

        while IFS= read -r mac_addr; do
            [ -z "$mac_addr" ] && continue
            local forget_rc
            forget_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$forget_rc" = "ok" ] \
                && log "INFO: Forgotten: $mac_addr" \
                || log "WARNING: Failed to forget: $mac_addr"
        done < <(echo "$guest_json" | jq -r --arg code "$voucher_code" '
            .data[]
            | select(.voucher_code == $code)
            | (.mac | ascii_downcase)
        ' 2>/dev/null | sort -u)
    done

    log "INFO: Done."
}

# ACTION [4]: REVOKE VOUCHER BY CODE
# Works around a UniFi bug that leaves a revoked code usable
interactive_revoke_by_code() {
    echo ""
    echo "============================================================================"
    echo "REVOKE BY VOUCHER CODE -- surgical invalidation (UniFi workaround)"
    echo "============================================================================"

    if [[ "$voucher_rc" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$voucher_rc) -- skip"
        return
    fi
    if [[ "$guest_rc" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$guest_rc) -- skip"
        return
    fi
    if [[ "$sta_rc" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$sta_rc) -- skip"
        return
    fi

    mapfile -t active_vouchers < <(echo "$voucher_json" | jq -r '
        .data[]
        | select(.used > 0)
        | [.code, (.note // "--"), (.used | tostring)]
        | @tsv
    ' 2>/dev/null | sort -t$'\t' -k2)

    if [ ${#active_vouchers[@]} -eq 0 ]; then
        log "INFO: No active vouchers found (used > 0)."
        return
    fi

    echo ""
    echo "Active vouchers:"
    echo ""
    printf " %-15s %-20s %s\n" "CODE" "NAME" "USED"
    printf " %-15s %-20s %s\n" "---------------" "--------------------" "----"
    for sta_row in "${active_vouchers[@]}"; do
        local voucher_code voucher_note used_count
        voucher_code=$(echo "$sta_row" | awk -F'\t' '{print $1}')
        voucher_note=$(echo "$sta_row" | awk -F'\t' '{print $2}')
        used_count=$(echo "$sta_row" | awk -F'\t' '{print $3}')
        printf " %-15s %-20s %s\n" "$voucher_code" "$voucher_note" "$used_count"
    done

    echo ""
    echo "NOTE: This list shows vouchers currently reported by stat/voucher."
    echo "Vouchers deleted manually from the UniFi UI will not appear here"
    echo "but can still be revoked -- enter their code directly if you know it."
    echo ""
    local target_code
    read -rp " Enter voucher code to revoke: " target_code
    target_code=$(echo "$target_code" | tr -d '[:space:]')

    if [ -z "$target_code" ]; then
        log "INFO: No code entered. Cancelled."
        return
    fi

    local target_note
    target_note=$(printf '%s\n' "${active_vouchers[@]}" | awk -F'\t' -v code="$target_code" '$1 == code {print $2}')
    [ -z "$target_note" ] && target_note="manually deleted -- not in stat/voucher"

    echo ""
    echo "Code : $target_code"
    echo "Name : $target_note"
    echo ""

    local voucher_id
    voucher_id=$(echo "$voucher_json" | jq -r --arg code "$target_code" '
        .data[] | select(.code == $code) | ._id
    ' 2>/dev/null | head -1)

    if [ -n "$voucher_id" ]; then
        local delete_rc
        delete_rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${voucher_id}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$delete_rc" = "ok" ] \
            && log "INFO: Deleted voucher: $target_code" \
            || log "WARNING: Failed to delete voucher from stat/voucher (rc=$delete_rc)"
    else
        log "INFO: voucher $target_code not found, proceeding with cleanup"
    fi

    mapfile -t guest_macs < <(echo "$guest_json" | jq -r --arg code "$target_code" '
        .data[]
        | select(.voucher_code == $code)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t sta_macs < <(echo "$sta_json" | jq -r --arg code "$target_code" '
        .data[]
        | select(.voucher_code == $code)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t all_macs < <(printf '%s\n' "${guest_macs[@]}" "${sta_macs[@]}" | sort -u | grep -v '^$')

    if [ ${#all_macs[@]} -eq 0 ]; then
        log "INFO: no client records for code: $target_code"
        return
    fi

    echo ""
    echo "Client records linked to this code (${#all_macs[@]}):"
    echo ""
    for mac_addr in "${all_macs[@]}"; do
        local client_name
        client_name=$(echo "$guest_json" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac | ascii_downcase) == $m) | .hostname // "N/A"
        ' 2>/dev/null | head -1)
        local active_flag=""
        echo "$sta_json" | jq -e --arg m "$mac_addr" \
            '.data[] | select((.mac | ascii_downcase) == $m)' &>/dev/null \
            && active_flag=" [CONNECTED]"
        printf " %-20s %-25s%s\n" "$mac_addr" "$client_name" "$active_flag"
    done

    echo ""
    read -rp " Confirm revocation of ${#all_macs[@]} client(s) for code $target_code? [y/N]: " confirm_answer
    [[ ! "$confirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""

    for mac_addr in "${all_macs[@]}"; do
        local is_active
        is_active=$(echo "$sta_json" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac | ascii_downcase) == $m) | .mac
        ' 2>/dev/null | head -1)

        if [ -n "$is_active" ]; then
            local unauth_rc
            unauth_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$unauth_rc" = "ok" ] \
                && log "INFO: Unauthorized: $mac_addr" \
                || log "WARNING: Failed to unauthorize: $mac_addr (rc=$unauth_rc)"
        fi

        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: Failed to forget: $mac_addr (rc=$forget_rc)"
    done

    log "INFO: revocation complete for code: $target_code"
}

# ACTION [5]: FORGET FLAGGED SESSIONS
# Removes the sessions report [4] marks with (!)
# Same criterion as print_guest_sessions: active session (end > now) whose
# authorized_by is not "voucher", excluding mac-*.txt devices -- those are
# authorized via authorize-guest by design (authorize_managed_macs in
# uhmd.sh) and must never be unauthorized/forgotten here. Independent of
# whether it made it into uhm-auth.txt -- if it did, the next uhmd.sh cycle
# removes it from the ACL once revoke_unauthorized sees it unauthorized in
# UniFi.
interactive_forget_flagged() {
    echo ""
    echo "============================================================================"
    echo "FORGET SESSIONS MARKED (!) -- authorized_by != voucher, not a managed MAC"
    echo "============================================================================"

    if [[ "$guest_rc" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$guest_rc) -- skip"
        return
    fi
    if [[ "$sta_rc" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$sta_rc) -- skip"
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)

    local forget_mac
    mapfile -t flagged_sessions < <(echo "$guest_json" | jq -r --argjson now "$now_epoch" '
        .data[]
        | select(.end != null and .end > $now)
        | select((.authorized_by // "none") != "voucher")
        | [(.mac|ascii_downcase), (.authorized_by//"none")] | join("\t")
    ' 2>/dev/null | sort -u | while IFS=$'\t' read -r forget_mac rest_of_line; do
        is_managed_mac "$forget_mac" && continue
        printf '%s\t%s\n' "$forget_mac" "$rest_of_line"
    done)

    if [ ${#flagged_sessions[@]} -eq 0 ]; then
        log "INFO: No sessions marked (!) found."
        return
    fi

    echo "Sessions to unauthorize + forget (${#flagged_sessions[@]}):"
    echo ""
    local mac_addr auth_origin
    for sta_row in "${flagged_sessions[@]}"; do
        mac_addr=$(echo "$sta_row" | awk -F'\t' '{print $1}')
        auth_origin=$(echo "$sta_row" | awk -F'\t' '{print $2}')
        printf " %-20s origin=%s\n" "$mac_addr" "$auth_origin"
    done

    echo ""
    read -rp " Confirm unauthorize + forget of ${#flagged_sessions[@]} session(s)? [y/N]: " confirm_answer
    [[ ! "$confirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for sta_row in "${flagged_sessions[@]}"; do
        mac_addr=$(echo "$sta_row" | awk -F'\t' '{print $1}')

        local unauth_rc
        unauth_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$unauth_rc" = "ok" ] \
            && log "INFO: Unauthorized: $mac_addr" \
            || log "INFO: no active session: $mac_addr"

        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: Failed to forget: $mac_addr"
    done

    log "INFO: Done."
}

# ACTION [6]: PURGE EVERYTHING
# Removes every voucher and all client history
interactive_purge_all() {
    if [[ "$voucher_rc" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$voucher_rc) -- skip"
        return
    fi
    if [[ "$sta_rc" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$sta_rc) -- skip"
        return
    fi
    if [[ "$guest_rc" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$guest_rc) -- skip"
        return
    fi

    local voucher_total sta_total guest_total
    voucher_total=$(echo "$voucher_json" | jq -r '.data | length' 2>/dev/null || echo "?")
    sta_total=$(echo "$sta_json" | jq -r '.data | length' 2>/dev/null || echo "?")
    guest_total=$(echo "$guest_json" | jq -r '.data | length' 2>/dev/null || echo "?")

    echo ""
    echo "============================================================================"
    echo "PURGE ALL -- THIS WILL DESTROY ALL VOUCHERS AND CLIENT HISTORY"
    echo "============================================================================"
    echo ""
    echo "Impact summary:"
    echo "- Vouchers to delete : $voucher_total (stat/voucher)"
    echo "- Active sessions to cut: $sta_total (stat/sta)"
    echo "- Client records to erase: $guest_total (stat/guest)"
    echo ""
    echo "This action will:"
    echo "- DELETE all vouchers -- all codes become immediately invalid"
    echo "- DISCONNECT all currently connected guests"
    echo "- ERASE all guest history -- clients will be unknown to UniFi"
    echo ""
    echo "============================================================================"
    echo "!! THIS ACTION CANNOT BE UNDONE !!"
    echo "============================================================================"
    echo ""
    read -rp " Are you sure you want to proceed? [y/N]: " preconfirm_answer
    [[ ! "$preconfirm_answer" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    echo "Final confirmation required."
    echo "Type the word YES (uppercase) to execute the purge:"
    echo ""
    read -rp " > " confirm_answer
    [[ "$confirm_answer" != "YES" ]] && log "INFO: Cancelled." && return

    echo ""

    local voucher_id voucher_code delete_rc
    while IFS= read -r voucher_id; do
        [ -z "$voucher_id" ] && continue
        voucher_code=$(echo "$voucher_json" | jq -r --arg id "$voucher_id" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)
        delete_rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${voucher_id}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$delete_rc" = "ok" ] \
            && log "INFO: Deleted voucher: $voucher_code" \
            || log "WARNING: Failed to delete voucher: $voucher_code"
    done < <(echo "$voucher_json" | jq -r '.data[] | ._id' 2>/dev/null)

    local mac_addr unauth_rc
    while IFS= read -r mac_addr; do
        [ -z "$mac_addr" ] && continue
        is_managed_mac "$mac_addr" && continue
        unauth_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$unauth_rc" = "ok" ] \
            && log "INFO: Unauthorized: $mac_addr" \
            || log "INFO: no active session: $mac_addr"
    done < <(echo "$sta_json" | jq -r '.data[] | (.mac | ascii_downcase)' 2>/dev/null | sort -u)

    while IFS= read -r mac_addr; do
        [ -z "$mac_addr" ] && continue
        is_managed_mac "$mac_addr" && continue
        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: Failed to forget: $mac_addr"
    done < <(echo "$guest_json" | jq -r '.data[] | (.mac | ascii_downcase)' 2>/dev/null | sort -u)

    log "INFO: Purge complete."
}

# REPORT [1]: CONNECTION STATUS
# Shows what the controller answered for each endpoint
print_connection_status() {
    echo ""
    echo "============================================================================"
    echo "CONNECTION STATUS -- login + fetch summary"
    echo "============================================================================"
    printf "stat/sta      -> %-6s (%s entries)\n" "$sta_rc" "$sta_count"
    printf "stat/guest    -> %-6s (%s entries)\n" "$guest_rc" "$guest_count"
    printf "stat/voucher  -> %-6s (%s entries)\n" "$voucher_rc" "$voucher_count"
    echo ""
}

# SUBMENU: REPORTS
# Read-only options, none of them writes to the controller
reports_menu() {
    local menu_option
    while true; do
        echo ""
        echo "============================================================================"
        echo "REPORTS"
        echo "============================================================================"
        printf "%-5s%-26s- %s\n" "[1]" "Connection status" "login + fetch summary"
        printf "%-5s%-26s- %s\n" "[2]" "Authorized" "uhm-auth.txt"
        printf "%-5s%-26s- %s\n" "[3]" "Vouchers" "stat/voucher"
        printf "%-5s%-26s- %s\n" "[4]" "Guest sessions" "stat/guest, by category"
        printf "%-5s%-26s- %s\n" "[5]" "Unauthorized" "stat/sta, authorized=false"
        echo "[b] Back"
        echo ""
        read -rp " Select option [b]: " menu_option
        menu_option="${menu_option:-b}"
        case "$menu_option" in
            1) print_connection_status; press_enter ;;
            2) print_authorized; press_enter ;;
            3) print_voucher; press_enter ;;
            4) print_guest_sessions; press_enter ;;
            5) print_unauthorized; press_enter ;;
            b|B) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# SUBMENU: ACTIONS
# Options that modify vouchers or client history
actions_menu() {
    local menu_option
    while true; do
        echo ""
        echo "============================================================================"
        echo "ACTIONS"
        echo "============================================================================"
        printf "%-5s%-26s- %s\n" "[1]" "Delete unused vouchers" "never activated"
        printf "%-5s%-26s- %s\n" "[2]" "Forget clients no voucher" "never used, not connected now"
        printf "%-5s%-26s- %s\n" "[3]" "Delete expired vouchers" "remove + forget clients"
        printf "%-5s%-26s- %s\n" "[4]" "Revoke by voucher code" "invalidate one voucher"
        printf "%-5s%-26s- %s\n" "[5]" "Forget sessions (!)" "unauthorize + forget non-voucher"
        printf "%-5s%-26s- %s\n" "[6]" "Purge everything" "DELETE all vouchers + history"
        echo "[b] Back"
        echo ""
        read -rp " Select option [b]: " menu_option
        menu_option="${menu_option:-b}"
        case "$menu_option" in
            1) interactive_delete_unused; press_enter ;;
            2) interactive_forget_no_voucher; press_enter ;;
            3) interactive_delete_expired; press_enter ;;
            4) interactive_revoke_by_code; press_enter ;;
            5) interactive_forget_flagged; press_enter ;;
            6) interactive_purge_all; press_enter ;;
            b|B) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main_menu() {
    local menu_option
    while true; do
        echo ""
        echo "============================================================================"
        echo "AVAILABLE OPTIONS"
        echo "============================================================================"
        echo "[1] Reports"
        echo "[2] Actions"
        echo "[q] Quit"
        echo ""
        read -rp " Select option [q]: " menu_option
        menu_option="${menu_option:-q}"
        case "$menu_option" in
            1) reports_menu ;;
            2) actions_menu ;;
            q|Q) log "INFO: Exiting."; break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu

# end
log "uhmunifi done at: $(date)"
