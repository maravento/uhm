#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmtool - JSON backend for the uhm web interface
#
# DESCRIPTION:
# Single privileged entry point used by the uhm web interface. Reads the
# operational log, the local ACL files and the UniFi API, and writes back
# an ACL file after validating it. Every answer is a JSON document on
# stdout. The web interface runs as www-data and reaches this script
# through sudo, so no web code ever touches a root-owned file.
#
# USAGE:
# sudo bash uhmtool.sh <group> <action> [arguments]
#
# GROUPS:
# log      tail, grep, status
# acl      list, read, write
# report   mac, grace, consistency, search
# unifi    status, authorized, vouchers, guests, unauthorized
#
# PATHS:
# /etc/pydhcp/pydhcp.env   ACL paths and lease file
# /etc/uhm/uhm.env         uhm keys and UniFi credentials
# /var/log/uhm.log         operational log read by the log group
#
# EXIT CODES:
# 0 - Normal exit, including a JSON error document
# 1 - Not root, missing dependency, or unreadable configuration
#
################################################################################

set -uo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo '{"error":"This script must be run as root"}'
    exit 1
fi

# dependencies
for dep_pkg in curl jq mawk coreutils util-linux grep sed systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        printf '{"error":"missing dependency %s"}\n' "$dep_pkg"
        exit 1
    fi
done

temp_files=()
cleanup_temp() {
    local temp_file
    for temp_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$temp_file" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

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

uhm_log_file="/var/log/uhm.log"
pydhcp_conf="/etc/pydhcp/pydhcp.env"
uhm_conf="/etc/uhm/uhm.env"
cycle_lock="/var/lock/uhmd-cycle.lock"
max_grep_lines=3000
max_upload_bytes=1048576

# ACL line formats, same definitions normalize_acl_lists() enforces in
# uhmleases.sh. A line the daemon would reject must never be written here.
acl_ip_re='[0-9.]+'
acl_host_re='[A-Za-z0-9._-]{1,63}'
commentable_no_epoch_pattern="^#?a;${UH_MAC_RE};${acl_ip_re};${acl_host_re};\$"
commentable_epoch_pattern="^#?a;${UH_MAC_RE};${acl_ip_re};${acl_host_re};[0-9]+;\$"
strict_no_epoch_pattern="^a;${UH_MAC_RE};${acl_ip_re};${acl_host_re};\$"
strict_epoch_pattern="^a;${UH_MAC_RE};${acl_ip_re};${acl_host_re};[0-9]+;\$"
bare_mac_pattern="^${UH_MAC_RE}\$"

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
load_conf() {
    local conf_file="$1" env_key env_value env_line
    [[ ! -f "$conf_file" ]] && { json_error "$(basename "$conf_file") not found"; exit 1; }
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        [[ "$env_line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        if [[ ! "$env_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
           || [[ "$env_value" == [[:space:]\"\']* ]] \
           || [[ "$env_value" == *[[:space:]\"\'] ]]; then
            json_error "malformed line in $(basename "$conf_file")"
            exit 1
        fi
        case "$env_key" in
            BLOCKDHCP_GRACE_SECONDS|UHM_MACAUTH|UHM_GRACE|UHM_QUEUE|UHM_ESSID|ACL_BLOCK_FILE|ACL_MAC_PATH|PYDHCPD_LEASES|\
            UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD|UNIFI_TYPE|UNIFI_SITE|UNIFI_CERT_PIN)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}

json_error() {
    jq -cn --arg message "$1" '{error: $message}'
}

json_escape() {
    local escaped_text="$1"
    escaped_text="${escaped_text//\\/\\\\}"
    escaped_text="${escaped_text//\"/\\\"}"
    escaped_text="${escaped_text//$'\t'/\\t}"
    escaped_text="${escaped_text//$'\n'/\\n}"
    escaped_text="${escaped_text//$'\r'/\\r}"
    escaped_text="${escaped_text//$'\b'/\\b}"
    escaped_text="${escaped_text//$'\f'/\\f}"
    printf '%s' "$escaped_text"
}

# The log group only needs the log file, which is world-readable and has no
# credentials in it. Loading the configuration is deferred to the groups
# that read ACL files or call the controller.
load_env() {
    local uhm_owner uhm_perms required_key

    if [ ! -r "$pydhcp_conf" ]; then
        json_error "cannot read $(basename "$pydhcp_conf")"
        exit 1
    fi
    if [ ! -f "$uhm_conf" ]; then
        json_error "uhm.env not found, run uhmsetup.sh"
        exit 1
    fi
    uhm_owner=$(stat -c '%U' "$uhm_conf" 2>/dev/null)
    uhm_perms=$(stat -c '%a' "$uhm_conf" 2>/dev/null)
    if [[ "$uhm_owner" != "root" ]] || [[ "$uhm_perms" != "600" ]]; then
        json_error "uhm.env must be root:root 600"
        exit 1
    fi

    load_conf "$pydhcp_conf"
    load_conf "$uhm_conf"

    for required_key in BLOCKDHCP_GRACE_SECONDS UHM_MACAUTH UHM_GRACE ACL_BLOCK_FILE ACL_MAC_PATH PYDHCPD_LEASES; do
        if [ -z "${!required_key:-}" ]; then
            json_error "$required_key not set in uhm.env or pydhcp.env"
            exit 1
        fi
    done

    if ! [[ "$BLOCKDHCP_GRACE_SECONDS" =~ $UH_UINT ]]; then
        json_error "BLOCKDHCP_GRACE_SECONDS invalid in uhm.env"
        exit 1
    fi

    if [ ! -d "$ACL_MAC_PATH" ]; then
        json_error "cannot read $ACL_MAC_PATH"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# LOG
# ------------------------------------------------------------------------------

# Emits the rows array of a log payload. Lines without a timestamp and
# separator lines are dropped, and a line with no level is reported as
# STATUS, the label the viewer groups them under.
print_log_rows() {
    local log_data="$1"
    local log_line row_ts row_level row_msg first_row=1

    printf '['
    while IFS= read -r log_line; do
        [[ -z "$log_line" ]] && continue
        [[ "$log_line" == -* ]] && continue

        row_ts="" row_level="" row_msg=""
        if [[ "$log_line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ (INFO|WARNING|ERROR|ALERT|FIX):\ (.*) ]]; then
            row_ts="${BASH_REMATCH[1]}"
            row_level="${BASH_REMATCH[2]}"
            row_msg="${BASH_REMATCH[3]}"
        elif [[ "$log_line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ (.*) ]]; then
            row_ts="${BASH_REMATCH[1]}"
            row_level="STATUS"
            row_msg="${BASH_REMATCH[2]}"
        else
            continue
        fi

        [[ $first_row -eq 0 ]] && printf ','
        first_row=0
        printf '{"ts":"%s","level":"%s","msg":"%s"}' \
            "$(json_escape "$row_ts")" "$(json_escape "$row_level")" "$(json_escape "$row_msg")"
    done <<< "$log_data"
    printf ']'
}

log_status() {
    local service_active=0 service_pid="" service_uptime="" service_mem="" service_cpu="" status_out

    status_out=$(systemctl status uhmd.service 2>&1 || true)
    if echo "$status_out" | grep -q 'Active: active (running)'; then
        service_active=1
    fi
    service_pid=$(echo "$status_out" | grep -oP 'Main PID:\s+\K\d+' || true)
    service_uptime=$(echo "$status_out" | grep -oP 'Active:.*;\s+\K.+' | sed 's/\s*$//' || true)
    service_mem=$(echo "$status_out" | grep -oP 'Memory:\s+\K[^\(]+' | sed 's/\s*$//' || true)
    service_cpu=$(echo "$status_out" | grep -oP 'CPU:\s+\K.+' | sed 's/\s*$//' || true)

    jq -cn --argjson active "$service_active" --arg pid "$service_pid" \
        --arg uptime "$service_uptime" --arg mem "$service_mem" --arg cpu "$service_cpu" \
        '{active: $active, pid: $pid, uptime: $uptime, mem: $mem, cpu: $cpu, log: "'"$uhm_log_file"'"}'
}

log_grep() {
    local search_term="$1" grep_output file_size

    if [[ -z "$search_term" ]]; then
        json_error "empty search term"
        return 0
    fi
    if [[ ! "$search_term" =~ ^[[:alnum:][:space:].:/@_-]+$ ]]; then
        json_error "invalid search term"
        return 0
    fi
    if [[ ! -f "$uhm_log_file" ]]; then
        json_error "log file not found"
        return 0
    fi

    file_size=$(stat -c%s "$uhm_log_file" 2>/dev/null || echo 0)
    grep_output=$(timeout 20 grep -Fia -e "$search_term" -- "$uhm_log_file" 2>/dev/null | tail -n "$max_grep_lines" || true)

    printf '{"rows":'
    print_log_rows "$grep_output"
    printf ',"offset":%d,"grep":true}\n' "$file_size"
}

# Reads by byte offset instead of following the file, so a request always
# returns and the viewer keeps its own position between polls.
log_tail() {
    local byte_pos="$1" log_lines="$2"
    local file_size log_data log_rotated bytes_to_read

    if [[ ! -f "$uhm_log_file" ]]; then
        json_error "log file not found"
        return 0
    fi
    file_size=$(stat -c%s "$uhm_log_file" 2>/dev/null || echo 0)

    [[ "$byte_pos" =~ $UH_UINT ]] || byte_pos=0
    [[ "$log_lines" =~ $UH_UINT ]] || log_lines=200
    (( log_lines > 5000 )) && log_lines=5000
    (( log_lines < 50 )) && log_lines=50

    if (( byte_pos == 0 )) || (( byte_pos > file_size )); then
        log_data=$(tail -n "$log_lines" "$uhm_log_file" 2>/dev/null || true)
        byte_pos=$file_size
        log_rotated=true
    else
        if (( byte_pos >= file_size )); then
            printf '{"rows":[],"pos":%d}\n' "$file_size"
            return 0
        fi
        bytes_to_read=$(( file_size - byte_pos ))
        log_data=$(tail -c +"$(( byte_pos + 1 ))" "$uhm_log_file" 2>/dev/null | head -c "$bytes_to_read" || true)
        byte_pos=$file_size
        log_rotated=false
    fi

    printf '{"rows":'
    print_log_rows "$log_data"
    printf ',"pos":%d,"rotated":%s}\n' "$byte_pos" "$log_rotated"
}

# ------------------------------------------------------------------------------
# ACL
# ------------------------------------------------------------------------------

# Resolves an editable name to its path. Only the names listed here are
# reachable, so a crafted request can never read or write another file.
acl_path_of() {
    local acl_name="$1" mac_file

    case "$acl_name" in
        uhm-auth) printf '%s' "$UHM_MACAUTH"; return 0 ;;
        uhm-grace) printf '%s' "$UHM_GRACE"; return 0 ;;
        uhm-queue) printf '%s' "${UHM_QUEUE:-}"; return 0 ;;
        blockdhcp) printf '%s' "$ACL_BLOCK_FILE"; return 0 ;;
    esac

    shopt -s nullglob
    for mac_file in "$ACL_MAC_PATH"/mac-*.txt; do
        if [[ "$(basename "$mac_file" .txt)" == "$acl_name" ]]; then
            shopt -u nullglob
            printf '%s' "$mac_file"
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

acl_pattern_of() {
    local acl_name="$1"

    case "$acl_name" in
        uhm-auth) printf '%s' "$commentable_epoch_pattern" ;;
        uhm-grace) printf '%s' "$strict_epoch_pattern" ;;
        uhm-queue) printf '%s' "$bare_mac_pattern" ;;
        blockdhcp) printf '%s' "$strict_no_epoch_pattern" ;;
        *) printf '%s' "$commentable_no_epoch_pattern" ;;
    esac
}

acl_list() {
    local mac_file entries=() acl_name acl_file

    for acl_name in uhm-auth uhm-grace uhm-queue blockdhcp; do
        acl_file=$(acl_path_of "$acl_name") || continue
        [ -n "$acl_file" ] && [ -f "$acl_file" ] && entries+=("$acl_name")
    done

    shopt -s nullglob
    for mac_file in "$ACL_MAC_PATH"/mac-*.txt; do
        entries+=("$(basename "$mac_file" .txt)")
    done
    shopt -u nullglob

    printf '%s\n' "${entries[@]+"${entries[@]}"}" | jq -Rcn '{files: [inputs | select(length > 0)]}'
}

acl_read() {
    local acl_name="$1" acl_file line_count

    if ! acl_file=$(acl_path_of "$acl_name") || [ -z "$acl_file" ]; then
        json_error "unknown ACL file"
        return 0
    fi
    if [ ! -f "$acl_file" ]; then
        json_error "$(basename "$acl_file") not found"
        return 0
    fi

    line_count=$(grep -c '' "$acl_file" 2>/dev/null || echo 0)
    jq -Rsc --arg name "$acl_name" --arg path "$acl_file" --argjson lines "$line_count" \
        '{name: $name, path: $path, lines: $lines, content: .}' < "$acl_file"
}

# Writes only after every line matches the format its own file requires.
# A single bad line rejects the whole save: a malformed line would abort
# the reload chain in uhmleases.sh on the daemon's next cycle.
acl_write() {
    local acl_name="$1" acl_file line_pattern
    local new_content line_number=0 acl_line tmp_file byte_count

    if ! acl_file=$(acl_path_of "$acl_name") || [ -z "$acl_file" ]; then
        json_error "unknown ACL file"
        return 0
    fi
    if [ ! -f "$acl_file" ]; then
        json_error "$(basename "$acl_file") not found"
        return 0
    fi

    new_content=$(cat)
    byte_count=${#new_content}
    if (( byte_count > max_upload_bytes )); then
        json_error "content too large"
        return 0
    fi

    line_pattern=$(acl_pattern_of "$acl_name")
    tmp_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$tmp_file")

    while IFS= read -r acl_line || [ -n "$acl_line" ]; do
        acl_line="${acl_line%$'\r'}"
        line_number=$((line_number + 1))
        [[ -z "$acl_line" ]] && continue
        if ! [[ "$acl_line" =~ $line_pattern ]]; then
            jq -cn --argjson line "$line_number" --arg content "$acl_line" \
                '{error: "malformed line", line: $line, content: $content}'
            return 0
        fi
        if [[ "$acl_name" != "uhm-queue" ]]; then
            local malformed_ip
            malformed_ip="$(printf '%s' "$acl_line" | cut -d';' -f3)"
            if [[ -n "$malformed_ip" ]] && ! [[ "$malformed_ip" =~ $UH_IPV4 ]]; then
                jq -cn --argjson line "$line_number" --arg content "$acl_line" \
                    '{error: "invalid IP", line: $line, content: $content}'
                return 0
            fi
        fi
        printf '%s\n' "$acl_line" >> "$tmp_file"
    done <<< "$new_content"

    # Same lock the daemon takes while it mutates the ACL files, on the same
    # descriptor 201, so a web save and a cycle never overlap.
    (umask 077; : >> "$cycle_lock")
    exec 201>"$cycle_lock"
    flock -w 10 201 || { json_error "ACL file busy"; return 0; }

    cp -f "$acl_file" "${acl_file}.bak"
    cat "$tmp_file" > "$acl_file"
    chown root:root "$acl_file"
    chmod 600 "$acl_file"
    flock -u 201

    line_number=$(grep -c '' "$acl_file" 2>/dev/null || echo 0)
    jq -cn --arg name "$acl_name" --argjson lines "$line_number" \
        '{saved: true, name: $name, lines: $lines}'
}

# ------------------------------------------------------------------------------
# REPORT
# ------------------------------------------------------------------------------

found_in() {
    grep -qiE "^a;${1};" "$2"
}

found_in_leases() {
    grep -qiF "$1" "$2"
}

found_in_acl_dir() {
    grep -qiE "^#?a;${1};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null
}

# Per-MAC presence across every local source, plus the warnings raised by
# the state combinations uhm never produces on its own.
report_mac_object() {
    local mac_addr="$1"
    local in_hotspot=0 in_grace=0 in_block=0 in_acl=0 in_leases=0
    local mac_files="" warnings=() grace_line grace_ts remaining_seconds grace_left=""

    found_in "$mac_addr" "$UHM_MACAUTH" && in_hotspot=1
    found_in "$mac_addr" "$UHM_GRACE" && in_grace=1
    found_in "$mac_addr" "$ACL_BLOCK_FILE" && in_block=1
    found_in_acl_dir "$mac_addr" && in_acl=1
    found_in_leases "$mac_addr" "$PYDHCPD_LEASES" && in_leases=1

    if (( in_acl == 1 )); then
        mac_files=$(grep -liE "^#?a;${mac_addr};" "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null | xargs -r -n1 basename | paste -sd, -)
    fi

    if (( in_grace == 1 )); then
        grace_line=$(grep -iE "^a;${mac_addr};" "$UHM_GRACE" | head -1)
        grace_ts=$(echo "$grace_line" | awk -F';' '{print $5}')
        if [[ "$grace_ts" =~ $UH_UINT ]]; then
            remaining_seconds=$(( (grace_ts + BLOCKDHCP_GRACE_SECONDS) - $(date +%s) ))
            if (( remaining_seconds > 0 )); then
                grace_left=$(printf '%dh %dm' "$((remaining_seconds/3600))" "$(( (remaining_seconds%3600)/60 ))")
            else
                grace_left="EXPIRED"
            fi
        else
            grace_left="malformed"
        fi
    fi

    if (( in_block == 1 )); then
        (( in_acl == 1 )) && warnings+=("In blockdhcp AND mac -- should be in one, not both")
        (( in_grace == 1 )) && warnings+=("In blockdhcp AND uhm-grace -- contradictory state")
        (( in_leases == 1 )) && warnings+=("In blockdhcp AND leases -- lease should have been cleared")
    fi
    if (( in_grace == 1 )) && (( in_leases == 0 )); then
        warnings+=("In uhm-grace without active lease -- normal with a short pool lease")
    fi
    if (( in_hotspot == 1 )) && (( in_grace == 1 )); then
        warnings+=("In uhm-auth AND uhm-grace -- run uhmreload.sh to clear uhm-grace")
    fi
    if (( in_hotspot + in_grace + in_block + in_acl + in_leases == 0 )); then
        warnings+=("MAC not found in any data source")
    fi

    printf '%s\n' "${warnings[@]+"${warnings[@]}"}" | jq -Rsc \
        --arg mac "$mac_addr" \
        --argjson auth "$in_hotspot" --argjson grace "$in_grace" \
        --argjson block "$in_block" --argjson acl "$in_acl" \
        --argjson leases "$in_leases" \
        --arg files "$mac_files" --arg left "$grace_left" \
        '{mac: $mac, auth: $auth, grace: $grace, block: $block, acl: $acl,
          leases: $leases, files: $files, grace_left: $left,
          warnings: (split("\n") | map(select(length > 0)))}'
}

report_mac() {
    local mac_addr="${1,,}"

    if ! [[ "$mac_addr" =~ $UH_MAC ]]; then
        json_error "invalid MAC format"
        return 0
    fi
    report_mac_object "$mac_addr" | jq -c '{rows: [.]}'
}

report_grace() {
    local now_epoch acl_status mac_addr client_ip client_name grace_ts rest_of_line
    local total_entries=0 expired_count=0 tmp_file

    now_epoch=$(date +%s)
    tmp_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$tmp_file")

    while IFS=';' read -r acl_status mac_addr client_ip client_name grace_ts rest_of_line; do
        [[ -z "$acl_status$mac_addr$client_ip$client_name$grace_ts" ]] && continue
        [[ "$acl_status" != "a" ]] && continue
        [[ "$grace_ts" =~ $UH_UINT ]] || continue
        total_entries=$((total_entries+1))
        local remaining_seconds=$(( (grace_ts + BLOCKDHCP_GRACE_SECONDS) - now_epoch ))
        if (( remaining_seconds > 0 )); then
            printf '%s\t%s\t%s\t%dh %dm\n' "$mac_addr" "$client_ip" "$client_name" \
                "$((remaining_seconds/3600))" "$(( (remaining_seconds%3600)/60 ))" >> "$tmp_file"
        else
            expired_count=$((expired_count+1))
            printf '%s\t%s\t%s\tEXPIRED\n' "$mac_addr" "$client_ip" "$client_name" >> "$tmp_file"
        fi
    done < "$UHM_GRACE"

    jq -Rsc --argjson total "$total_entries" --argjson expired "$expired_count" \
        '{total: $total, expired: $expired, active: ($total - $expired),
          rows: [split("\n")[] | select(length > 0) | split("\t")
                 | {mac: .[0], ip: .[1], name: .[2], expires: .[3]}]}' < "$tmp_file"
}

# Collects every MAC every local source knows about, then reports the ones
# whose combination of states is contradictory, plus the totals.
collect_all_macs() {
    local tmp_file="$1" acl_file

    for acl_file in "$UHM_MACAUTH" "$UHM_GRACE" "$ACL_BLOCK_FILE"; do
        awk -F';' '$1=="a"{print tolower($2)}' "$acl_file" >> "$tmp_file"
    done

    shopt -s nullglob
    for acl_file in "$ACL_MAC_PATH"/mac-*.txt; do
        grep -hioE "^#?a;$UH_MAC_RE" "$acl_file" | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
    done
    shopt -u nullglob

    grep -ioE "$UH_MAC_RE" "$PYDHCPD_LEASES" \
        | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
}

report_consistency() {
    local tmp_file rows_file all_macs=() mac_addr
    local cnt_grace=0 cnt_block=0 cnt_acl=0 cnt_hotspot=0 cnt_leases=0 total_warnings=0
    local mac_object warn_count

    tmp_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    rows_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$tmp_file" "$rows_file")

    collect_all_macs "$tmp_file"
    mapfile -t all_macs < <(sort -u "$tmp_file" | grep -E "$UH_MAC")

    for mac_addr in "${all_macs[@]+"${all_macs[@]}"}"; do
        mac_object=$(report_mac_object "$mac_addr")
        cnt_hotspot=$((cnt_hotspot + $(jq -r '.auth' <<< "$mac_object")))
        cnt_grace=$((cnt_grace + $(jq -r '.grace' <<< "$mac_object")))
        cnt_block=$((cnt_block + $(jq -r '.block' <<< "$mac_object")))
        cnt_acl=$((cnt_acl + $(jq -r '.acl' <<< "$mac_object")))
        cnt_leases=$((cnt_leases + $(jq -r '.leases' <<< "$mac_object")))
        warn_count=$(jq -r '.warnings | length' <<< "$mac_object")
        if (( warn_count > 0 )); then
            total_warnings=$((total_warnings + warn_count))
            printf '%s\n' "$mac_object" >> "$rows_file"
        fi
    done

    jq -sc --argjson total "${#all_macs[@]}" --argjson grace "$cnt_grace" \
        --argjson block "$cnt_block" --argjson acl "$cnt_acl" \
        --argjson auth "$cnt_hotspot" --argjson leases "$cnt_leases" \
        --argjson warnings "$total_warnings" \
        '{summary: {total: $total, grace: $grace, block: $block, acl: $acl,
                    auth: $auth, leases: $leases, warnings: $warnings},
          rows: .}' "$rows_file"
}

report_search() {
    local search_query="${1,,}" tmp_file rows_file acl_file found_macs=() mac_addr

    if [[ -z "$search_query" ]]; then
        json_error "empty search term"
        return 0
    fi
    if [[ ! "$search_query" =~ ^[[:alnum:].:_-]+$ ]]; then
        json_error "invalid search term"
        return 0
    fi

    tmp_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    rows_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$tmp_file" "$rows_file")

    for acl_file in "$UHM_MACAUTH" "$UHM_GRACE" "$ACL_BLOCK_FILE"; do
        grep -iF -- "$search_query" "$acl_file" \
            | awk -F';' '$1=="a"{print tolower($2)}' >> "$tmp_file"
    done

    shopt -s nullglob
    for acl_file in "$ACL_MAC_PATH"/mac-*.txt; do
        grep -hiF -- "$search_query" "$acl_file" \
            | grep -ioE "^#?a;$UH_MAC_RE" | cut -d';' -f2 \
            | tr '[:upper:]' '[:lower:]' >> "$tmp_file"
    done
    shopt -u nullglob

    grep -iF -- "$search_query" "$PYDHCPD_LEASES" \
        | grep -ioE "$UH_MAC_RE" \
        | tr '[:upper:]' '[:lower:]' >> "$tmp_file"

    mapfile -t found_macs < <(sort -u "$tmp_file" | grep -E "$UH_MAC")
    for mac_addr in "${found_macs[@]+"${found_macs[@]}"}"; do
        report_mac_object "$mac_addr" >> "$rows_file"
    done

    jq -sc --arg query "$search_query" '{query: $query, rows: .}' "$rows_file"
}

# ------------------------------------------------------------------------------
# UNIFI
# ------------------------------------------------------------------------------

session_cookie=""
csrf_token=""
api_base_url=""

unifi_require_config() {
    local missing_key

    for missing_key in UNIFI_CONTROLLER_URL UNIFI_USERNAME UNIFI_PASSWORD; do
        if [ -z "${!missing_key:-}" ]; then
            json_error "$missing_key not set in uhm.env"
            exit 1
        fi
    done
    UNIFI_SITE="${UNIFI_SITE:-default}"
    UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"

    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        api_base_url="$UNIFI_CONTROLLER_URL/api/s/$UNIFI_SITE"
    else
        api_base_url="$UNIFI_CONTROLLER_URL/proxy/network/api/s/$UNIFI_SITE"
    fi
}

# Credentials reach jq through the environment and curl through stdin, so
# the password never appears in any process argv.
do_login() {
    local login_path login_payload login_response auth_token
    local jwt_payload pad_len padded_jwt
    local tls_opts=(-k)

    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        login_path="/api/login"
    else
        login_path="/api/auth/login"
    fi

    login_payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    login_response=$(curl -si "${tls_opts[@]}" -X POST -H "Content-Type: application/json" \
        --data-binary @- \
        --connect-timeout 10 --max-time 40 \
        "$UNIFI_CONTROLLER_URL$login_path" <<< "$login_payload")

    if [[ "$UNIFI_TYPE" == "classic" ]]; then
        session_cookie=$(echo "$login_response" | grep -i "^set-cookie:" | grep -i "unifises=" | head -1 \
            | sed -E "s/.*unifises=([^;]+).*/unifises=\1/" | tr -d "\r")
        csrf_token=$(echo "$login_response" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
    else
        auth_token=$(echo "$login_response" | grep -i "^set-cookie:" | grep -i "TOKEN=" | head -1 \
            | sed -E "s/.*TOKEN=([^;]+).*/\1/" | tr -d "\r")
        if [ -z "$auth_token" ]; then
            json_error "UniFi login failed"
            exit 0
        fi
        session_cookie="TOKEN=${auth_token}"
        jwt_payload=$(echo "$auth_token" | cut -d'.' -f2 | tr '_-' '/+')
        pad_len=$(( (4 - ${#jwt_payload} % 4) % 4 ))
        padded_jwt="$jwt_payload"
        if (( pad_len > 0 )); then
            padded_jwt="${jwt_payload}$(printf '%*s' "$pad_len" '' | tr ' ' '=')"
        fi
        csrf_token=$(echo "$padded_jwt" | base64 -d 2>/dev/null \
            | jq -r '.csrfToken // empty' 2>/dev/null || true)
        if [[ -z "$csrf_token" ]]; then
            csrf_token=$(echo "$login_response" | grep -iE "^x-(updated-)?csrf-token:" | tail -1 | awk '{print $2}' | tr -d "\r")
        fi
    fi

    if [ -z "$session_cookie" ]; then
        json_error "UniFi login failed"
        exit 0
    fi
}

api_get() {
    local tls_opts=(-k)

    [[ -n "${UNIFI_CERT_PIN:-}" ]] && tls_opts=(-k --pinnedpubkey "$UNIFI_CERT_PIN")
    curl -s "${tls_opts[@]}" -X GET \
        --connect-timeout 10 --max-time 30 \
        -H "X-CSRF-Token: $csrf_token" \
        -H "Cookie: $session_cookie" \
        "$api_base_url/$1"
}

unifi_fetch() {
    local endpoint="$1" response_json response_rc

    response_json=$(api_get "$endpoint")
    response_rc=$(jq -r '.meta.rc // "error"' <<< "$response_json" 2>/dev/null)
    if [[ "$response_rc" != "ok" ]]; then
        json_error "$endpoint query failed"
        exit 0
    fi
    printf '%s' "$response_json"
}

# Writes every MAC listed in any mac-*.txt, active or commented, one per
# line. A managed device is authorized through authorize-guest by design,
# so it must never be reported as an anomaly.
managed_macs() {
    local mac_file

    shopt -s nullglob
    for mac_file in "$ACL_MAC_PATH"/mac-*.txt; do
        grep -hioE "^#?a;$UH_MAC_RE" "$mac_file" | cut -d';' -f2 | tr '[:upper:]' '[:lower:]'
    done
    shopt -u nullglob
}

unifi_status() {
    local sta_json guest_json voucher_json
    local sta_file guest_file voucher_file

    sta_json=$(unifi_fetch "stat/sta")
    guest_json=$(unifi_fetch "stat/guest")
    voucher_json=$(unifi_fetch "stat/voucher")

    sta_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    guest_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    voucher_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$sta_file" "$guest_file" "$voucher_file")
    printf '%s' "$sta_json" > "$sta_file"
    printf '%s' "$guest_json" > "$guest_file"
    printf '%s' "$voucher_json" > "$voucher_file"

    jq -cn --slurpfile sta "$sta_file" --slurpfile guest "$guest_file" --slurpfile voucher "$voucher_file" \
        --arg url "$UNIFI_CONTROLLER_URL" --arg site "$UNIFI_SITE" --arg type "$UNIFI_TYPE" \
        '$sta[0] as $sta | $guest[0] as $guest | $voucher[0] as $voucher |
         {controller: $url, site: $site, type: $type,
          rows: [{endpoint: "stat/sta", rc: ($sta.meta.rc // "error"), entries: ($sta.data|length)},
                 {endpoint: "stat/guest", rc: ($guest.meta.rc // "error"), entries: ($guest.data|length)},
                 {endpoint: "stat/voucher", rc: ($voucher.meta.rc // "error"), entries: ($voucher.data|length)}]}'
}

# Voucher resolution, same order uhmunifi.sh uses: the code written into
# the hostname field at authorization time, verified against stat/voucher,
# and stat/guest only as a fallback for a client still connected.
unifi_authorized() {
    local sta_json guest_json voucher_json auth_file
    local sta_file guest_file voucher_file

    sta_json=$(unifi_fetch "stat/sta")
    guest_json=$(unifi_fetch "stat/guest")
    voucher_json=$(unifi_fetch "stat/voucher")

    auth_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    sta_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    guest_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    voucher_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$auth_file" "$sta_file" "$guest_file" "$voucher_file")
    awk -F';' '$1=="a"{print tolower($2)"\t"$3"\t"$4"\t"$5}' "$UHM_MACAUTH" > "$auth_file"
    printf '%s' "$sta_json" > "$sta_file"
    printf '%s' "$guest_json" > "$guest_file"
    printf '%s' "$voucher_json" > "$voucher_file"

    jq -Rsc --slurpfile sta "$sta_file" --slurpfile guest "$guest_file" --slurpfile voucher "$voucher_file" '
        ($voucher[0].data // []) as $vouchers |
        ($guest[0].data // []) as $guests |
        ($sta[0].data // []) as $stations |
        {rows: [split("\n")[] | select(length > 0) | split("\t") |
            .[0] as $mac | .[1] as $ip | .[2] as $host | (.[3] // "") as $end |
            (($host | capture("-(?<code>[0-9]+)$") | .code) // "") as $hostcode |
            (first($guests[] | select((.mac // "" | ascii_downcase) == $mac) | .voucher_code) // "") as $guestcode |
            (if $hostcode != "" then $hostcode else $guestcode end) as $code |
            (first($vouchers[] | select(.code == $code)) // null) as $found |
            {mac: $mac, ip: $ip, host: $host, code: $code,
             status: (if $code == "" then "NO-VOUCHER"
                      elif $found == null then "CONSUMED"
                      else ($found.status // "N/A"
                            | sub("USED_MULTIPLE"; "MULTI")
                            | sub("VALID_MULTI"; "MULTI")
                            | sub("VALID_ONE"; "VALID")) end),
             expires: (try ($end | tonumber | localtime | strftime("%Y-%m-%d %H:%M:%S")) catch "N/A"),
             online: ([$stations[] | select((.mac // "" | ascii_downcase) == $mac)] | length > 0)}]}
    ' < "$auth_file"
}

unifi_vouchers() {
    local voucher_json

    voucher_json=$(unifi_fetch "stat/voucher")
    jq -c '{rows: [(.data // [])[] | {code: .code, quota: (.quota // 0), used: (.used // 0),
        duration: (.duration // 0), note: (.note // ""), create_time: (.create_time // 0)}]}' <<< "$voucher_json"
}

# Three mutually exclusive categories, decided by where the MAC lives and
# never by authorized_by, so a real anomaly is not buried under the
# routine mac-*.txt traffic.
unifi_guests() {
    local guest_json managed_file guest_file

    guest_json=$(unifi_fetch "stat/guest")
    managed_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    guest_file=$(mktemp) || { json_error "cannot create temp file"; return 0; }
    temp_files+=("$managed_file" "$guest_file")
    managed_macs | sort -u > "$managed_file"
    printf '%s' "$guest_json" > "$guest_file"

    jq -Rsc --slurpfile guest "$guest_file" --rawfile authfile "$UHM_MACAUTH" '
        (split("\n") | map(select(length > 0))) as $managed |
        ($authfile | split("\n") | map(select(startswith("a;")) | split(";")[1] | ascii_downcase)) as $authorized |
        {rows: [($guest[0].data // [])[] |
            (.mac // "" | ascii_downcase) as $mac |
            {mac: $mac, hostname: (.hostname // ""), authorized_by: (.authorized_by // ""),
             code: (.voucher_code // ""),
             category: (if ($managed | index($mac)) then "MANAGED"
                        elif ($authorized | index($mac)) then "VOUCHER"
                        else "UNKNOWN" end)}]}
    ' < "$managed_file"
}

unifi_unauthorized() {
    local sta_json

    sta_json=$(unifi_fetch "stat/sta")
    jq -c --arg essid "${UHM_ESSID:-}" \
        '{rows: [(.data // [])[] | select((.essid // "") == $essid and (.authorized // false) == false)
          | {mac: (.mac // "" | ascii_downcase), ip: (.ip // ""), hostname: (.hostname // ""),
             essid: (.essid // ""), is_guest: (.is_guest // false)}]}' <<< "$sta_json"
}

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") <group> <action> [arguments]

Groups and actions:
  log    tail [pos] [lines] | grep <term> | status
  acl    list | read <name> | write <name> (content on stdin)
  report mac <mac> | grace | consistency | search <query>
  unifi  status | authorized | vouchers | guests | unauthorized
EOF
}

tool_group="${1:-}"
tool_action="${2:-}"

case "$tool_group" in
    log)
        case "$tool_action" in
            tail) log_tail "${3:-0}" "${4:-200}" ;;
            grep) log_grep "${3:-}" ;;
            status) log_status ;;
            *) json_error "unknown log action" ;;
        esac
        ;;
    acl)
        load_env
        case "$tool_action" in
            list) acl_list ;;
            read) acl_read "${3:-}" ;;
            write) acl_write "${3:-}" ;;
            *) json_error "unknown acl action" ;;
        esac
        ;;
    report)
        load_env
        case "$tool_action" in
            mac) report_mac "${3:-}" ;;
            grace) report_grace ;;
            consistency) report_consistency ;;
            search) report_search "${3:-}" ;;
            *) json_error "unknown report action" ;;
        esac
        ;;
    unifi)
        load_env
        unifi_require_config
        do_login
        case "$tool_action" in
            status) unifi_status ;;
            authorized) unifi_authorized ;;
            vouchers) unifi_vouchers ;;
            guests) unifi_guests ;;
            unauthorized) unifi_unauthorized ;;
            *) json_error "unknown unifi action" ;;
        esac
        ;;
    -h|--help)
        usage
        ;;
    *)
        json_error "unknown group"
        ;;
esac

exit 0
