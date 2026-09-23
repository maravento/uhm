#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmunifi - UniFi Network Hotspot - Full Client Audit & Management Tool
#
# DESCRIPTION:
# Offers actions to act on the UniFi API directly (delete/revoke vouchers,
# forget clients), and looks up a single MAC's live state. The read-only
# reports this script used to print (connection status, authorized against
# uhm-auth.txt, vouchers, guest sessions, unauthorized) are now shown by the
# web interface's ToolView tab instead, backed by tools/uhmtool.sh -- see
# uhm's README.
#
# USAGE:
# sudo bash uhmunifi.sh
#
# MENU: [1] Check MAC, [2] Actions, [q] Quit.
#
# [1] Check MAC - live UniFi state for one MAC: essid, authorized, is_guest
#     (from stat/sta) and voucher_code (from stat/guest, if present).
#     Independent of the local ACL files -- see uhmtool.sh for those
#     (mac-*.txt, uhm-auth.txt, uhm-grace.txt, blockdhcp.txt,
#     pydhcpd.leases).
#
# ACTIONS SUBMENU -- none of these ever touch a mac-*.txt MAC (see
# is_managed_mac() below); only the VOUCHER/UNKNOWN categories from
# ToolView's Guest sessions report are ever eligible.
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
#     mac-*.txt device (see ToolView's Guest sessions UNKNOWN category)
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
# DEPENDENCIES : curl, jq, mawk, coreutils, util-linux, grep, sed
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
#   Check MAC is terminal-only, on demand, same as an action's own tables.
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
# File-only variant -- the startup fetch summary is recorded here without
# also echoing to the terminal, since it happens before the menu is shown
# and would just scroll away.
log_only() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# prevent overlapping runs
# Taken before the log is truncated: a second instance must not wipe the
# log of the session already running, so it reports on stderr instead.
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    echo "ERROR: script $(basename "$0") is already running -- abort" >&2
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

# dependencies
for dep_pkg in curl jq mawk coreutils util-linux grep sed; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"

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

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
load_conf() {
    local conf_file="$1" env_key env_value env_line
    [[ ! -f "$conf_file" ]] && { log "WARNING: $conf_file not found -- fallback"; return 1; }
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ "$env_line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        if [[ ! "$env_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
           || [[ "$env_value" == [[:space:]\"\']* ]] \
           || [[ "$env_value" == *[[:space:]\"\'] ]]; then
            log "ERROR: malformed line in $conf_file: '$env_line' -- abort"
            exit 1
        fi
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
load_conf "$pydhcp_conf"
load_conf "$uhm_conf"

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
# answer before the menu is drawn, so a controller that is already down is
# caught here instead of halfway through an action. do_login's own "exit 1"
# on failed re-authentication only kills the subshell of the api_get/
# api_post call that triggered it (command substitution), so it never
# aborts this script by itself -- this loop is what stops it, from the main
# body. It only covers startup: if the controller goes away later, with the
# menu already open, api_get returns an empty body and the action reports
# no results rather than an error.
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

# CHECK MAC
# Live UniFi state for one MAC: essid, authorized, is_guest (from stat/sta)
# and voucher_code (from stat/guest, if present). Direct source of truth for
# whether the AP holds this client at the captive portal -- independent of
# the local ACL files (see the MANAGED MACS note in uhmd.sh).
print_mac_status() {
    local mac_addr="$1"
    local sta_row
    sta_row=$(echo "$sta_json" | jq -r --arg m "$mac_addr" '
        .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase))
        | [(.essid // "n/a"), (.authorized|tostring), (.is_guest|tostring), (.ip // "n/a"), (.hostname // "n/a")]
        | @tsv
    ' 2>/dev/null | head -1)

    if [[ -z "$sta_row" ]]; then
        echo "MAC not associated to any AP (no live session)"
        return
    fi

    local sta_essid sta_authorized is_guest client_ip client_name
    IFS=$'\t' read -r sta_essid sta_authorized is_guest client_ip client_name <<< "$sta_row"
    echo "connected"
    printf "  essid=%s\n" "$sta_essid"
    printf "  authorized=%s\n" "$sta_authorized"
    printf "  is_guest=%s\n" "$is_guest"
    printf "  ip=%s\n" "$client_ip"
    printf "  hostname=%s\n" "$client_name"

    if [[ "$guest_rc" != "ok" ]]; then
        echo "stat/guest unavailable, voucher_code not shown -- skip"
    else
        local voucher_code
        voucher_code=$(echo "$guest_json" | jq -r --arg m "$mac_addr" '
            .data[] | select((.mac // "" | ascii_downcase) == ($m|ascii_downcase)) | .voucher_code // empty
        ' 2>/dev/null | head -1)
        [[ -n "$voucher_code" ]] && printf "  voucher_code=%s\n" "$voucher_code"
    fi

    if [[ "$sta_authorized" == "false" && "$is_guest" == "true" ]]; then
        echo "WARNING: UniFi reports this MAC unauthorized on a Guest WLAN"
        echo "WARNING: the AP holds it at the captive portal regardless of local ACL/DHCP state"
    fi
}

check_mac_menu() {
    echo ""
    local mac_addr
    read -rp " Enter MAC address (XX:XX:XX:XX:XX:XX, empty to cancel): " mac_addr
    mac_addr="${mac_addr,,}"
    [[ -z "$mac_addr" ]] && return
    if ! [[ "$mac_addr" =~ $UH_MAC ]]; then
        echo "Invalid MAC format"
        return
    fi
    echo ""
    print_mac_status "$mac_addr"
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
                (if .create_time then (.create_time | strftime("%Y-%m-%d %H:%M:%S")) else "N/A" end)
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
            || log "WARNING: Failed to delete voucher: $voucher_code -- skip"
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
        log "WARNING: Could not fetch rest/user (rc=$all_users_rc) -- skip"
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
            | if .last_seen then (.last_seen | strftime("%Y-%m-%d %H:%M:%S")) else "N/A" end
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
            || log "WARNING: Failed to forget: $mac_addr -- skip"
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
                (if .end_time then (.end_time | strftime("%Y-%m-%d %H:%M:%S")) else "N/A" end)
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
            is_managed_mac "$mac_addr" && continue
            local unauth_rc
            unauth_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$unauth_rc" = "ok" ] \
                && log "INFO: Revoked: $mac_addr" \
                || log "INFO: no active session: $mac_addr"
        done < <(echo "$sta_json" | jq -r --arg code "$voucher_code" '
            .data[]
            | select(.voucher_code == $code)
            | (.mac | ascii_downcase)
        ' 2>/dev/null | sort -u)

        while IFS= read -r mac_addr; do
            [ -z "$mac_addr" ] && continue
            is_managed_mac "$mac_addr" && continue
            local forget_rc
            forget_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$forget_rc" = "ok" ] \
                && log "INFO: Forgotten: $mac_addr" \
                || log "WARNING: Failed to forget: $mac_addr -- skip"
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
            || log "WARNING: delete voucher failed: (rc=$delete_rc) -- skip"
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
        is_managed_mac "$mac_addr" && continue
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
                && log "INFO: Revoked: $mac_addr" \
                || log "WARNING: revoke failed: $mac_addr (rc=$unauth_rc) -- skip"
        fi

        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: forget failed: $mac_addr (rc=$forget_rc) -- skip"
    done

    log "INFO: revocation complete for code: $target_code"
}

# ACTION [5]: FORGET FLAGGED SESSIONS
# Removes the sessions ToolView's Guest sessions report marks with (!)
# Same criterion as uhmtool.sh's unifi_guests: active session (end > now) whose
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
            && log "INFO: Revoked: $mac_addr" \
            || log "INFO: no active session: $mac_addr"

        local forget_rc
        forget_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac_addr}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$forget_rc" = "ok" ] \
            && log "INFO: Forgotten: $mac_addr" \
            || log "WARNING: Failed to forget: $mac_addr -- skip"
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
            || log "WARNING: Failed to delete voucher: $voucher_code -- skip"
    done < <(echo "$voucher_json" | jq -r '.data[] | ._id' 2>/dev/null)

    local mac_addr unauth_rc
    while IFS= read -r mac_addr; do
        [ -z "$mac_addr" ] && continue
        is_managed_mac "$mac_addr" && continue
        unauth_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac_addr}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$unauth_rc" = "ok" ] \
            && log "INFO: Revoked: $mac_addr" \
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
            || log "WARNING: Failed to forget: $mac_addr -- skip"
    done < <(echo "$guest_json" | jq -r '.data[] | (.mac | ascii_downcase)' 2>/dev/null | sort -u)

    log "INFO: Purge complete."
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
        echo "[1] Check MAC"
        echo "[2] Actions"
        echo "[q] Quit"
        echo ""
        read -rp " Select option [q]: " menu_option
        menu_option="${menu_option:-q}"
        case "$menu_option" in
            1) check_mac_menu ;;
            2) actions_menu ;;
            q|Q) log "INFO: Exiting."; break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu

# end
log "uhmunifi done at: $(date '+%Y-%m-%d %H:%M:%S')"
