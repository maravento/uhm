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
# NOTE on logging:
# - Manual/interactive script, not a daemon: the log file is truncated
#   at the start of every run, so it always reflects only the latest
#   session. It records the login/fetch summary and every action taken;
#   report tables (options 1-5) are terminal-only, on demand.
#   No rotation is needed or installed for this file.
#
################################################################################

set -uo pipefail

# logging
log_file="/var/log/uhmunifi.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}
# File-only variant -- for the startup fetch summary, which would otherwise
# scroll off screen before the menu is ever shown (see main_menu()'s status
# line, which displays this same data on every redraw instead).
log_only() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$log_file" 2>/dev/null || true
}

## root check
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
_log_stat=$(stat -c '%U %G %a' "$log_file" 2>/dev/null || true)
case "$_log_stat" in
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
unset _log_stat

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# DEPENDENCIES
for dep in curl jq bsdextrautils mawk coreutils util-linux grep sed; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: missing dependency '$dep' -- abort"
        exit 1
    fi
done

# Start
log "uhmunifi start..."

PYDHCP_CONFIG="/etc/pydhcp/pydhcp.env"
CONFIG="/etc/uhm/uhm.env"
if [ ! -f "$CONFIG" ]; then
    log "ERROR: uhm.env not found, run uhmsetup.sh -- abort"
    exit 1
fi
_owner=$(stat -c '%U' "$CONFIG" 2>/dev/null)
_perms=$(stat -c '%a' "$CONFIG" 2>/dev/null)
if [[ "$_owner" != "root" ]] || [[ "$_perms" != "600" ]]; then
    log "ERROR: uhm.env must be root:root 600 -- abort"
    exit 1
fi

load_config() {
    local file="$1" line key value raw_key raw_value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        raw_key="$key" raw_value="$value"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$key" != "$raw_key" || "$value" != "$raw_value" ]]; then
            log "ERROR: stray whitespace in a config key"
            log "ERROR: key $key -- abort"
            exit 1
        fi
        value="${value%\"}"
        value="${value#\"}"
        value="${value//\\\"/\"}"
        value="${value//\\\$/\$}"
        value="${value//\\\`/\`}"
        value="${value//\\\\/\\}"
        case "$key" in
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_SITE|UNIFI_TYPE|UNIFI_CERT_PIN|UHM_ESSID|UHM_MACAUTH|ACL_MAC_PATH)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}
# pydhcp.env first: it owns ACL_MAC_PATH. uhm.env is read after, so uhm's
# own keys win if a name ever collides.
if [ ! -r "$PYDHCP_CONFIG" ]; then
    log "ERROR: cannot read $PYDHCP_CONFIG -- abort"
    log "ERROR: uhm reads ACL_MAC_PATH from it"
    exit 1
fi
load_config "$PYDHCP_CONFIG"
load_config "$CONFIG"

for _k in UNIFI_CONTROLLER_URL UNIFI_USERNAME UNIFI_PASSWORD UHM_ESSID \
          UHM_MACAUTH ACL_MAC_PATH; do
    if [ -z "${!_k:-}" ]; then
        log "ERROR: $_k not set in uhm.env -- abort"
        exit 1
    fi
done
unset _k

SITE="${UNIFI_SITE:-default}"
TYPE="${UNIFI_TYPE:-unifi-os}"

# True if $1 (lowercase MAC) is listed in ANY mac-*.txt, active or
# commented -- same definition as is_managed_mac() in uhmd.sh. A managed
# device is authorized in UniFi via authorize-guest (authorized_by=api),
# not a voucher, by design -- see authorize_managed_macs() in uhmd.sh.
is_managed_mac() {
    local m="$1" f
    shopt -s nullglob
    local files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for f in "${files[@]}"; do
        grep -qiE "^#?a;${m};" "$f" && return 0
    done
    return 1
}
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# -- Authentication ------------------------------------------------------------
do_login() {
    local login_path
    if [[ "$TYPE" == "classic" ]]; then
        login_path="/api/login"
    else
        login_path="/api/auth/login"
    fi
    local payload
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    LOGIN=$(curl -si "${_tls_opts[@]}" -X POST -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 10 --max-time 40 \
        "$UNIFI_CONTROLLER_URL$login_path" <<< "$payload")

    if [[ "$TYPE" == "classic" ]]; then
        SESSION_COOKIE=$(echo "$LOGIN" | grep -i "^set-cookie:" | grep -i "unifises=" | head -1 \
            | sed -E "s/.*unifises=([^;]+).*/unifises=\1/" | tr -d "\r")
        CSRF_TOKEN=$(echo "$LOGIN" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
    else
        local token
        token=$(echo "$LOGIN" | grep -i "^set-cookie:" | grep -i "TOKEN=" | head -1 \
            | sed -E "s/.*TOKEN=([^;]+).*/\1/" | tr -d "\r")

        if [ -z "$token" ]; then
            log "ERROR: UniFi login failed -- abort"
            log "ERROR: check credentials and URL in uhm.env"
            log "ERROR: controller may be unavailable, try again later"
            exit 1
        fi
        SESSION_COOKIE="TOKEN=${token}"

        # UniFi OS embeds the CSRF token inside the JWT payload (csrfToken field).
        local jwt_payload pad padded
        jwt_payload=$(echo "$token" | cut -d'.' -f2 | tr '_-' '/+')
        pad=$(( (4 - ${#jwt_payload} % 4) % 4 ))
        padded="$jwt_payload"
        if (( pad > 0 )); then
            padded="${jwt_payload}$(printf '%*s' "$pad" '' | tr ' ' '=')"
        fi
        CSRF_TOKEN=$(echo "$padded" | base64 -d 2>/dev/null \
            | jq -r '.csrfToken // empty' 2>/dev/null || true)

        # Fallback: check response headers, in case a given UniFi OS version emits them.
        if [[ -z "$CSRF_TOKEN" ]]; then
            CSRF_TOKEN=$(echo "$LOGIN" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
        fi
    fi

    if [ -z "$SESSION_COOKIE" ]; then
        log "ERROR: UniFi login failed -- abort"
        log "ERROR: check credentials and URL in uhm.env"
        log "ERROR: controller may be unavailable, try again later"
        exit 1
    fi
}

do_login

# -- API helpers ---------------------------------------------------------------
if [[ "$TYPE" == "classic" ]]; then
    BASE="$UNIFI_CONTROLLER_URL/api/s/$SITE"
else
    BASE="$UNIFI_CONTROLLER_URL/proxy/network/api/s/$SITE"
fi

api_get() {
    local raw code body
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    raw=$(curl -s "${_tls_opts[@]}" -X GET \
        --connect-timeout 10 --max-time 30 \
        -w "\n__CODE__:%{http_code}" \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        -H "Cookie: $SESSION_COOKIE" \
        "$BASE/$1")
    code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    body=$(echo "$raw" | grep -v '__CODE__:')
    if [[ "$code" == "401" ]]; then
        echo "INFO: Session expired -- re-authenticating" >&2
        do_login
        raw=$(curl -s "${_tls_opts[@]}" -X GET \
            --connect-timeout 10 --max-time 30 \
            -w "\n__CODE__:%{http_code}" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            -H "Cookie: $SESSION_COOKIE" \
            "$BASE/$1")
        body=$(echo "$raw" | grep -v '__CODE__:')
    fi
    echo "$body"
}

api_post() {
    local raw code
    local _tls_opts=(-k)
    [[ -n "${UNIFI_CERT_PIN:-}" ]] && _tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    raw=$(curl -s "${_tls_opts[@]}" -X POST \
        --connect-timeout 10 --max-time 30 \
        -w "\n__CODE__:%{http_code}" \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        -H "Cookie: $SESSION_COOKIE" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "$BASE/$1")
    code=$(echo "$raw" | grep '__CODE__:' | cut -d: -f2 | tr -d '\r\n')
    if [[ "$code" == "401" ]]; then
        echo "INFO: Session expired -- re-authenticating" >&2
        do_login
        raw=$(curl -s "${_tls_opts[@]}" -X POST \
            --connect-timeout 10 --max-time 30 \
            -w "\n__CODE__:%{http_code}" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            -H "Cookie: $SESSION_COOKIE" \
            -H "Content-Type: application/json" \
            -d "$2" \
            "$BASE/$1")
    fi
    echo "$raw" | grep -v '__CODE__:'
}

# -- Fetch data from UniFi API -------------------------------------------------
STA=$(api_get "stat/sta")
GUEST=$(api_get "stat/guest")
VOUCHER=$(api_get "stat/voucher")

STA_RC=$(echo "$STA" | jq -r '.meta.rc // "error"' 2>/dev/null)
GUEST_RC=$(echo "$GUEST" | jq -r '.meta.rc // "error"' 2>/dev/null)
VCH_RC=$(echo "$VOUCHER" | jq -r '.meta.rc // "error"' 2>/dev/null)

# Startup availability check: every endpoint this script works with must
# answer before the menu is drawn, so an action can never fail halfway
# through because the controller went away. do_login's own "exit 1" on
# failed re-authentication only kills the subshell of the api_get/api_post
# call that triggered it (command substitution), so it never aborts this
# script by itself -- this loop is what stops it, from the main body.
for _pair in "stat/sta:$STA_RC" "stat/guest:$GUEST_RC" "stat/voucher:$VCH_RC"; do
    if [[ "${_pair#*:}" != "ok" ]]; then
        log "ERROR: ${_pair%%:*} query failed -- abort"
        log "ERROR: controller may be unavailable, try again later"
        exit 1
    fi
done
unset _pair

shopt -s nullglob
_uhm_mac_lists=("$ACL_MAC_PATH"/mac-*.txt)
shopt -u nullglob
if (( ${#_uhm_mac_lists[@]} == 0 )); then
    log "ERROR: no mac-*.txt in $ACL_MAC_PATH -- abort"
    exit 1
fi
for _f in "$UHM_MACAUTH" "${_uhm_mac_lists[@]}"; do
    grep -qE '' "$_f"
    if (( $? > 1 )); then
        log "ERROR: cannot read $_f -- abort"
        exit 1
    fi
done
unset _uhm_mac_lists _f

while IFS=';' read -r _s _m _rest; do
    [ "$_s" != "a" ] && continue
    if [ -z "$_m" ]; then
        log "ERROR: malformed line in $UHM_MACAUTH -- abort"
        exit 1
    fi
done < "$UHM_MACAUTH"
unset _s _m _rest

STA_COUNT=$(echo "$STA" | jq '.data|length' 2>/dev/null)
GUEST_COUNT=$(echo "$GUEST" | jq '.data|length' 2>/dev/null)
VOUCHER_COUNT=$(echo "$VOUCHER" | jq '.data|length' 2>/dev/null)
log_only "INFO: stat/sta -> $STA_RC ($STA_COUNT entries)"
log_only "INFO: stat/guest -> $GUEST_RC ($GUEST_COUNT entries)"
log_only "INFO: stat/voucher -> $VCH_RC ($VOUCHER_COUNT entries)"

press_enter() {
    echo ""
    read -rp " Press ENTER to continue..." _
}

# -- Report [2]: Authorized clients (uhm-auth.txt + stat/guest + stat/sta) -----
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
    sta_map=$(echo "$STA" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | (.mac | ascii_downcase)
    ' 2>/dev/null)

    {
        printf "MAC|IP|CODE|STATUS|EXPIRES|ON\n"
        while IFS=';' read -r status mac ip hostname end_time _; do
            [ "$status" != "a" ] && continue

            expires="N/A"
            [ -n "$end_time" ] && expires=$(date -d "@$end_time" '+%m-%d %H:%M' 2>/dev/null || echo "$end_time")

            # Step 1: extract code from hostname (guest{n}-{code})
            voucher=$(echo "$hostname" | sed -n 's/^guest[0-9]*-\([A-Za-z0-9._-]*\)$/\1/p')

            # Step 2: verify against stat/voucher API and get status
            vcode=""
            vstatus=""
            if [ -n "$voucher" ]; then
                vcode="$voucher"
                vstatus=$(echo "$VOUCHER" | jq -r --arg code "$voucher" '
                    .data[] | select(.code == $code) | .status // ""
                ' 2>/dev/null | head -1)
                [ -z "$vstatus" ] && vstatus="CONSUMED"
            else
                # Step 3: fallback to stat/guest by MAC
                vcode=$(echo "$GUEST" | jq -r --arg m "$mac" '
                    .data[]
                    | select((.mac | ascii_downcase) == $m)
                    | .voucher_code // ""
                ' 2>/dev/null | head -1)
                if [ -n "$vcode" ]; then
                    vstatus=$(echo "$VOUCHER" | jq -r --arg code "$vcode" '
                        .data[] | select(.code == $code) | .status // ""
                    ' 2>/dev/null | head -1)
                    [ -z "$vstatus" ] && vstatus="CONSUMED"
                fi
            fi

            # Step 4: nothing found -- flag an entry UniFi did not authorize
            # through the voucher flow (authorized_by != voucher)
            if [ -z "$vcode" ]; then
                aby=$(echo "$GUEST" | jq -r --arg m "$mac" '
                    .data[]
                    | select((.mac | ascii_downcase) == $m)
                    | .authorized_by // ""
                ' 2>/dev/null | head -1)
                vcode="N/A"
                [ -n "$aby" ] && [ "$aby" != "voucher" ] && vstatus="NO-VOUCHER($aby)"
            fi
            [ -z "$vstatus" ] && vstatus="N/A"
            vstatus=$(echo "$vstatus" | sed 's/USED_MULTIPLE/MULTI/;s/VALID_ONE/VALID/;s/VALID_MULTI/MULTI/')

            connected=$(echo "$sta_map" | awk -v mac="${mac}" 'tolower($1) == tolower(mac) {print "YES"; exit}')
            [ -z "$connected" ] && connected="NO"

            echo "$mac|$ip|$vcode|$vstatus|$expires|$connected"
        done < "$UHM_MACAUTH"
    } | column -t -s '|'
    echo ""
}

# -- Report [3]: Vouchers (stat/voucher) ---------------------------------------
print_voucher() {
    echo ""
    echo "============================================================================"
    echo "VOUCHERS -- stat/voucher"
    echo "============================================================================"
    {
        printf "CODE|STATUS|DURATION|QUOTA|USED|EXPIRES\n"
        echo "$VOUCHER" | jq -r '
            .data[]
            | [.code//"N/A", (.status//"N/A"), (((.duration//0)/60|floor|tostring) + "h"), (.quota//0|tostring), (.used//0|tostring), (if .end_time then (.end_time|strftime("%m-%d %H:%M")) else "N/A" end)]
            | join("|")
        ' 2>/dev/null
    } | column -t -s '|'
    echo ""
}

# -- Report [4]: Guest sessions (stat/guest) -----------------------------------
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
    local now
    now=$(date +%s)

    local managed_rows="" authorized_rows="" other_rows=""
    local gmac gorigin gcode gend gon

    while IFS='|' read -r gmac gorigin gcode gend; do
        [ -z "$gmac" ] && continue

        gon=$(echo "$STA" | jq -r --arg m "$gmac" '
            .data[] | select((.mac|ascii_downcase) == $m) | "YES"
        ' 2>/dev/null | head -1)
        [ -z "$gon" ] && gon="NO"
        [ -z "$gcode" ] && gcode="N/A"

        if is_managed_mac "$gmac"; then
            managed_rows+="$gmac|${gorigin}(managed)|$gcode|$gend|$gon
"
        elif grep -qiE "^#?a;${gmac};" "$UHM_MACAUTH"; then
            [ "$gorigin" != "voucher" ] && gorigin="${gorigin}(!)"
            authorized_rows+="$gmac|$gorigin|$gcode|$gend|$gon
"
        else
            [ "$gorigin" != "voucher" ] && gorigin="${gorigin}(!)"
            other_rows+="$gmac|$gorigin|$gcode|$gend|$gon
"
        fi
    done < <(echo "$GUEST" | jq -r --argjson now "$now" '
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

# -- Report [5]: Unauthorized clients (stat/sta) -------------------------------
print_unauthorized() {
    echo ""
    echo "============================================================================"
    printf "UNAUTHORIZED -- stat/sta, clients on %s NOT authorized by UniFi\n" "$UHM_ESSID"
    echo "============================================================================"

    local rows
    rows=$(echo "$STA" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | select(.authorized == false)
        | [(.mac), (.hostname // "no-hostname"), (.ip // "no-ip"), (.last_seen // "n/a")]
        | join("|")
    ' 2>/dev/null)

    if [ -z "$rows" ]; then
        echo " None -- all clients on $UHM_ESSID are authorized"
    else
        {
            printf "MAC|HOSTNAME|IP|LAST_SEEN\n"
            echo "$rows"
        } | column -t -s '|'
    fi
    echo ""
}

# -- Action [1]: delete unused vouchers (used == 0) ----------------------------
interactive_delete_unused() {
    echo ""
    echo "============================================================================"
    echo "DELETE UNUSED VOUCHERS - vouchers that have never been activated"
    echo "============================================================================"

    mapfile -t UNUSED_IDS < <(echo "$VOUCHER" | jq -r '
        .data[] | select(.used == 0) | ._id
    ' 2>/dev/null)

    if [ ${#UNUSED_IDS[@]} -eq 0 ]; then
        log "INFO: No unused vouchers found."
        return
    fi

    echo "Unused vouchers to delete:"
    echo ""
    for vid in "${UNUSED_IDS[@]}"; do
        local info
        info=$(echo "$VOUCHER" | jq -r --arg id "$vid" '
            .data[] | select(._id == $id)
            | [
                (.code // "N/A"),
                (((.duration // 0) / 60 | floor | tostring) + "h"),
                ("quota=" + ((.quota // 0) | tostring)),
                (if .create_time then (.create_time | strftime("%Y-%m-%d")) else "N/A" end)
              ]
            | join(" ")
        ' 2>/dev/null)
        echo "code=$info"
    done

    echo ""
    read -rp " Confirm deletion of ${#UNUSED_IDS[@]} unused voucher(s)? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for vid in "${UNUSED_IDS[@]}"; do
        local code rc
        code=$(echo "$VOUCHER" | jq -r --arg id "$vid" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)
        rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${vid}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$rc" = "ok" ] \
            && log "INFO: Deleted voucher: $code" \
            || log "WARNING: Failed to delete voucher: $code"
    done

    log "INFO: Done."
}

# -- Action [2]: forget portal clients who never submitted a voucher -----------
interactive_forget_no_voucher() {
    echo ""
    echo "============================================================================"
    echo "FORGET CLIENTS WITHOUT VOUCHER - connected to portal but never used one"
    echo "============================================================================"

    if [[ "$GUEST_RC" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$GUEST_RC) -- skip"
        return
    fi
    if [[ "$STA_RC" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$STA_RC) -- skip"
        return
    fi

    local ALLUSER
    ALLUSER=$(api_get "rest/user")
    local ALLUSER_RC
    ALLUSER_RC=$(echo "$ALLUSER" | jq -r '.meta.rc // "error"' 2>/dev/null)
    if [ "$ALLUSER_RC" != "ok" ]; then
        log "WARNING: Could not fetch rest/user (rc=$ALLUSER_RC)"
        return
    fi

    local guest_macs
    guest_macs=$(echo "$GUEST" | jq -r '
        .data[]
        | select(.voucher_code != null and .voucher_code != "")
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    local sta_macs
    sta_macs=$(echo "$STA" | jq -r --arg essid "$UHM_ESSID" '
        .data[]
        | select(.essid == $essid)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t NOVOUCHER_MACS < <(echo "$ALLUSER" | jq -r '
        .data[]
        | select(.is_guest == true)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u | while IFS= read -r mac; do
        echo "$guest_macs" | grep -qx "$mac" && continue
        echo "$sta_macs" | grep -qx "$mac" && continue
        is_managed_mac "$mac" && continue
        echo "$mac"
    done)

    if [ ${#NOVOUCHER_MACS[@]} -eq 0 ]; then
        log "INFO: No clients found matching the criteria."
        return
    fi

    echo "Clients to forget (${#NOVOUCHER_MACS[@]}):"
    echo ""
    for mac in "${NOVOUCHER_MACS[@]}"; do
        local hostname last_seen
        hostname=$(echo "$ALLUSER" | jq -r --arg m "$mac" '
            .data[] | select((.mac | ascii_downcase) == $m) | .hostname // "N/A"
        ' 2>/dev/null | head -1)
        last_seen=$(echo "$ALLUSER" | jq -r --arg m "$mac" '
            .data[] | select((.mac | ascii_downcase) == $m)
            | if .last_seen then (.last_seen | strftime("%Y-%m-%d %H:%M")) else "N/A" end
        ' 2>/dev/null | head -1)
        printf " %-20s %-25s last_seen=%s\n" "$mac" "$hostname" "$last_seen"
    done

    echo ""
    read -rp " Confirm forget of ${#NOVOUCHER_MACS[@]} client(s)? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for mac in "${NOVOUCHER_MACS[@]}"; do
        local frc
        frc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$frc" = "ok" ] \
            && log "INFO: Forgotten: $mac" \
            || log "WARNING: Failed to forget: $mac"
    done

    log "INFO: Done."
}

# -- Action [3]: delete expired vouchers + forget their clients ----------------
interactive_delete_expired() {
    local now
    now=$(date +%s)

    echo ""
    echo "============================================================================"
    echo "DELETE EXPIRED VOUCHERS + FORGET THEIR CLIENTS"
    echo "============================================================================"

    if [[ "$VCH_RC" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$VCH_RC) -- skip"
        return
    fi
    if [[ "$STA_RC" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$STA_RC) -- skip"
        return
    fi
    if [[ "$GUEST_RC" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$GUEST_RC) -- skip"
        return
    fi

    mapfile -t EXPIRED_IDS < <(echo "$VOUCHER" | jq -r \
        --argjson now "$now" '
        .data[]
        | select(.end_time != null and .end_time < $now)
        | ._id
    ' 2>/dev/null)

    if [ ${#EXPIRED_IDS[@]} -eq 0 ]; then
        log "INFO: No expired vouchers found."
        return
    fi

    echo "Expired vouchers to delete:"
    echo ""
    for vid in "${EXPIRED_IDS[@]}"; do
        local info
        info=$(echo "$VOUCHER" | jq -r --arg id "$vid" '
            .data[] | select(._id == $id)
            | [
                (.code // "N/A"),
                (((.duration // 0) / 60 | floor | tostring) + "h"),
                ("used=" + ((.used // 0) | tostring)),
                (if .end_time then (.end_time | strftime("%Y-%m-%d %H:%M")) else "N/A" end)
              ]
            | join(" ")
        ' 2>/dev/null)
        echo "code=$info"
    done

    echo ""
    read -rp " Confirm deletion of ${#EXPIRED_IDS[@]} expired voucher(s)? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""

    for vid in "${EXPIRED_IDS[@]}"; do
        local code rc
        code=$(echo "$VOUCHER" | jq -r --arg id "$vid" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)

        rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${vid}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        if [ "$rc" = "ok" ]; then
            log "INFO: Deleted voucher: $code"
        else
            log "WARNING: failed to delete voucher $code, its clients -- alert"
            continue
        fi

        while IFS= read -r mac; do
            [ -z "$mac" ] && continue
            local unauth_rc
            unauth_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac}\"}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$unauth_rc" = "ok" ] \
                && log "INFO: Unauthorized: $mac" \
                || log "INFO: no active session: $mac"
        done < <(echo "$STA" | jq -r --arg code "$code" '
            .data[]
            | select(.voucher_code == $code)
            | (.mac | ascii_downcase)
        ' 2>/dev/null | sort -u)

        while IFS= read -r mac; do
            [ -z "$mac" ] && continue
            local frc
            frc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$frc" = "ok" ] \
                && log "INFO: Forgotten: $mac" \
                || log "WARNING: Failed to forget: $mac"
        done < <(echo "$GUEST" | jq -r --arg code "$code" '
            .data[]
            | select(.voucher_code == $code)
            | (.mac | ascii_downcase)
        ' 2>/dev/null | sort -u)
    done

    log "INFO: Done."
}

# -- Action [4]: revoke voucher by code (workaround for UniFi bug) -------------
interactive_revoke_by_code() {
    echo ""
    echo "============================================================================"
    echo "REVOKE BY VOUCHER CODE -- surgical invalidation (UniFi workaround)"
    echo "============================================================================"

    if [[ "$VCH_RC" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$VCH_RC) -- skip"
        return
    fi
    if [[ "$GUEST_RC" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$GUEST_RC) -- skip"
        return
    fi
    if [[ "$STA_RC" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$STA_RC) -- skip"
        return
    fi

    mapfile -t ACTIVE_VOUCHERS < <(echo "$VOUCHER" | jq -r '
        .data[]
        | select(.used > 0)
        | [.code, (.note // "--"), (.used | tostring)]
        | @tsv
    ' 2>/dev/null | sort -t$'\t' -k2)

    if [ ${#ACTIVE_VOUCHERS[@]} -eq 0 ]; then
        log "INFO: No active vouchers found (used > 0)."
        return
    fi

    echo ""
    echo "Active vouchers:"
    echo ""
    printf " %-15s %-20s %s\n" "CODE" "NAME" "USED"
    printf " %-15s %-20s %s\n" "---------------" "--------------------" "----"
    for row in "${ACTIVE_VOUCHERS[@]}"; do
        local code note used
        code=$(echo "$row" | awk -F'\t' '{print $1}')
        note=$(echo "$row" | awk -F'\t' '{print $2}')
        used=$(echo "$row" | awk -F'\t' '{print $3}')
        printf " %-15s %-20s %s\n" "$code" "$note" "$used"
    done

    echo ""
    echo "NOTE: This list shows vouchers currently reported by stat/voucher."
    echo "Vouchers deleted manually from the UniFi UI will not appear here"
    echo "but can still be revoked -- enter their code directly if you know it."
    echo ""
    read -rp " Enter voucher code to revoke: " TARGET_CODE
    TARGET_CODE=$(echo "$TARGET_CODE" | tr -d '[:space:]')

    if [ -z "$TARGET_CODE" ]; then
        log "INFO: No code entered. Cancelled."
        return
    fi

    local target_note
    target_note=$(printf '%s\n' "${ACTIVE_VOUCHERS[@]}" | awk -F'\t' -v code="$TARGET_CODE" '$1 == code {print $2}')
    [ -z "$target_note" ] && target_note="manually deleted -- not in stat/voucher"

    echo ""
    echo "Code : $TARGET_CODE"
    echo "Name : $target_note"
    echo ""

    local voucher_id
    voucher_id=$(echo "$VOUCHER" | jq -r --arg code "$TARGET_CODE" '
        .data[] | select(.code == $code) | ._id
    ' 2>/dev/null | head -1)

    if [ -n "$voucher_id" ]; then
        local rc
        rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${voucher_id}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$rc" = "ok" ] \
            && log "INFO: Deleted voucher: $TARGET_CODE" \
            || log "WARNING: Failed to delete voucher from stat/voucher (rc=$rc)"
    else
        log "INFO: voucher $TARGET_CODE not found, proceeding with cleanup"
    fi

    mapfile -t GUEST_MACS < <(echo "$GUEST" | jq -r --arg code "$TARGET_CODE" '
        .data[]
        | select(.voucher_code == $code)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t STA_MACS < <(echo "$STA" | jq -r --arg code "$TARGET_CODE" '
        .data[]
        | select(.voucher_code == $code)
        | (.mac | ascii_downcase)
    ' 2>/dev/null | sort -u)

    mapfile -t ALL_MACS < <(printf '%s\n' "${GUEST_MACS[@]}" "${STA_MACS[@]}" | sort -u | grep -v '^$')

    if [ ${#ALL_MACS[@]} -eq 0 ]; then
        log "INFO: no client records for code: $TARGET_CODE"
        return
    fi

    echo ""
    echo "Client records linked to this code (${#ALL_MACS[@]}):"
    echo ""
    for mac in "${ALL_MACS[@]}"; do
        local hostname
        hostname=$(echo "$GUEST" | jq -r --arg m "$mac" '
            .data[] | select((.mac | ascii_downcase) == $m) | .hostname // "N/A"
        ' 2>/dev/null | head -1)
        local active_flag=""
        echo "$STA" | jq -e --arg m "$mac" \
            '.data[] | select((.mac | ascii_downcase) == $m)' &>/dev/null \
            && active_flag=" [CONNECTED]"
        printf " %-20s %-25s%s\n" "$mac" "$hostname" "$active_flag"
    done

    echo ""
    read -rp " Confirm revocation of ${#ALL_MACS[@]} client(s) for code $TARGET_CODE? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""

    for mac in "${ALL_MACS[@]}"; do
        local is_active
        is_active=$(echo "$STA" | jq -r --arg m "$mac" '
            .data[] | select((.mac | ascii_downcase) == $m) | .mac
        ' 2>/dev/null | head -1)

        if [ -n "$is_active" ]; then
            local unauth_rc
            unauth_rc=$(api_post "cmd/stamgr" \
                "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac}\"}" \
                | jq -r '.meta.rc // "error"' 2>/dev/null)
            [ "$unauth_rc" = "ok" ] \
                && log "INFO: Unauthorized: $mac" \
                || log "WARNING: Failed to unauthorize: $mac (rc=$unauth_rc)"
        fi

        local frc
        frc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$frc" = "ok" ] \
            && log "INFO: Forgotten: $mac" \
            || log "WARNING: Failed to forget: $mac (rc=$frc)"
    done

    log "INFO: revocation complete for code: $TARGET_CODE ($target_note)"
}

# -- Action [5]: forget every session marked (!) in report [3] -----------------
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

    if [[ "$GUEST_RC" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$GUEST_RC) -- skip"
        return
    fi
    if [[ "$STA_RC" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$STA_RC) -- skip"
        return
    fi

    local now
    now=$(date +%s)

    local _mac
    mapfile -t FLAGGED < <(echo "$GUEST" | jq -r --argjson now "$now" '
        .data[]
        | select(.end != null and .end > $now)
        | select((.authorized_by // "none") != "voucher")
        | [(.mac|ascii_downcase), (.authorized_by//"none")] | join("\t")
    ' 2>/dev/null | sort -u | while IFS=$'\t' read -r _mac _rest; do
        is_managed_mac "$_mac" && continue
        printf '%s\t%s\n' "$_mac" "$_rest"
    done)

    if [ ${#FLAGGED[@]} -eq 0 ]; then
        log "INFO: No sessions marked (!) found."
        return
    fi

    echo "Sessions to unauthorize + forget (${#FLAGGED[@]}):"
    echo ""
    local mac origin
    for row in "${FLAGGED[@]}"; do
        mac=$(echo "$row" | awk -F'\t' '{print $1}')
        origin=$(echo "$row" | awk -F'\t' '{print $2}')
        printf " %-20s origin=%s\n" "$mac" "$origin"
    done

    echo ""
    read -rp " Confirm unauthorize + forget of ${#FLAGGED[@]} session(s)? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    for row in "${FLAGGED[@]}"; do
        mac=$(echo "$row" | awk -F'\t' '{print $1}')

        local unauth_rc
        unauth_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$unauth_rc" = "ok" ] \
            && log "INFO: Unauthorized: $mac" \
            || log "INFO: no active session: $mac"

        local frc
        frc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$frc" = "ok" ] \
            && log "INFO: Forgotten: $mac" \
            || log "WARNING: Failed to forget: $mac"
    done

    log "INFO: Done."
}

# -- Action [6]: purge all vouchers and client history -------------------------
interactive_purge_all() {
    if [[ "$VCH_RC" != "ok" ]]; then
        log "INFO: stat/voucher data unavailable (rc=$VCH_RC) -- skip"
        return
    fi
    if [[ "$STA_RC" != "ok" ]]; then
        log "INFO: stat/sta data unavailable (rc=$STA_RC) -- skip"
        return
    fi
    if [[ "$GUEST_RC" != "ok" ]]; then
        log "INFO: stat/guest data unavailable (rc=$GUEST_RC) -- skip"
        return
    fi

    local voucher_total sta_total guest_total
    voucher_total=$(echo "$VOUCHER" | jq -r '.data | length' 2>/dev/null || echo "?")
    sta_total=$(echo "$STA" | jq -r '.data | length' 2>/dev/null || echo "?")
    guest_total=$(echo "$GUEST" | jq -r '.data | length' 2>/dev/null || echo "?")

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
    read -rp " Are you sure you want to proceed? [y/N]: " PRECONFIRM
    [[ ! "$PRECONFIRM" =~ ^[yY]$ ]] && log "INFO: Cancelled." && return

    echo ""
    echo "Final confirmation required."
    echo "Type the word YES (uppercase) to execute the purge:"
    echo ""
    read -rp " > " CONFIRM
    [[ "$CONFIRM" != "YES" ]] && log "INFO: Cancelled." && return

    echo ""

    local vid code rc
    while IFS= read -r vid; do
        [ -z "$vid" ] && continue
        code=$(echo "$VOUCHER" | jq -r --arg id "$vid" \
            '.data[] | select(._id == $id) | .code' 2>/dev/null)
        rc=$(api_post "cmd/hotspot" "{\"cmd\":\"delete-voucher\",\"_id\":\"${vid}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$rc" = "ok" ] \
            && log "INFO: Deleted voucher: $code" \
            || log "WARNING: Failed to delete voucher: $code"
    done < <(echo "$VOUCHER" | jq -r '.data[] | ._id' 2>/dev/null)

    local mac unauth_rc
    while IFS= read -r mac; do
        [ -z "$mac" ] && continue
        is_managed_mac "$mac" && continue
        unauth_rc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"unauthorize-guest\",\"mac\":\"${mac}\"}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$unauth_rc" = "ok" ] \
            && log "INFO: Unauthorized: $mac" \
            || log "INFO: no active session: $mac"
    done < <(echo "$STA" | jq -r '.data[] | (.mac | ascii_downcase)' 2>/dev/null | sort -u)

    while IFS= read -r mac; do
        [ -z "$mac" ] && continue
        is_managed_mac "$mac" && continue
        local frc
        frc=$(api_post "cmd/stamgr" \
            "{\"cmd\":\"forget-sta\",\"macs\":[\"${mac}\"]}" \
            | jq -r '.meta.rc // "error"' 2>/dev/null)
        [ "$frc" = "ok" ] \
            && log "INFO: Forgotten: $mac" \
            || log "WARNING: Failed to forget: $mac"
    done < <(echo "$GUEST" | jq -r '.data[] | (.mac | ascii_downcase)' 2>/dev/null | sort -u)

    log "INFO: Purge complete."
}

# -- Report [1]: Connection status ---------------------------------------------
print_connection_status() {
    echo ""
    echo "============================================================================"
    echo "CONNECTION STATUS -- login + fetch summary"
    echo "============================================================================"
    printf "stat/sta      -> %-6s (%s entries)\n" "$STA_RC" "$STA_COUNT"
    printf "stat/guest    -> %-6s (%s entries)\n" "$GUEST_RC" "$GUEST_COUNT"
    printf "stat/voucher  -> %-6s (%s entries)\n" "$VCH_RC" "$VOUCHER_COUNT"
    echo ""
}

# -- Submenu: Reports ----------------------------------------------------------
reports_menu() {
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
        read -rp " Select option [b]: " opt
        opt="${opt:-b}"
        case "$opt" in
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

# -- Submenu: Actions ----------------------------------------------------------
actions_menu() {
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
        read -rp " Select option [b]: " opt
        opt="${opt:-b}"
        case "$opt" in
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

# -- Main menu -----------------------------------------------------------------
main_menu() {
    while true; do
        echo ""
        echo "============================================================================"
        echo "AVAILABLE OPTIONS"
        echo "============================================================================"
        echo "[1] Reports"
        echo "[2] Actions"
        echo "[q] Quit"
        echo ""
        read -rp " Select option [q]: " opt
        opt="${opt:-q}"
        case "$opt" in
            1) reports_menu ;;
            2) actions_menu ;;
            q|Q) log "INFO: Exiting."; break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu

# End
log "uhmunifi done at: $(date)"
