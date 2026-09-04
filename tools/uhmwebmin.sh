#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmwebmin - module installation/uninstallation script for Webmin
#
# DESCRIPTION:
# This script installs or uninstalls the UHM Log Viewer module for Webmin.
# Provides real-time log monitoring for the uhmd daemon with live polling,
# filtering, and full-log search.
#
# FEATURES:
# - Real-time log viewer with AJAX polling (no tail -f)
# - Live/Pause toggle
# - Full-log grep search
# - Filter by level (INFO/WARNING/ERROR/FIX/ALERT/STATUS), one color each:
#   INFO blue, WARNING amber, ERROR red, FIX green, ALERT purple,
#   STATUS grey
# - Text filter with highlighting
# - Cycle stats dashboard (vouchers, authorized, grace, etc.)
# - Service status indicator
# - Multi-language support (English and Spanish)
#
# USAGE:
# sudo ./uhmwebmin.sh [OPTIONS]
#
# OPTIONS:
# install      Install the module
# uninstall    Uninstall the module
# -h, --help   Show help message
#
# EXIT CODES:
# 0 - Normal exit, or module installed/uninstalled successfully
# 1 - Not root, already running, missing dependency, Webmin not
#     installed, or invalid option
#
################################################################################

set -uo pipefail

# USAGE
# Answered before any check: --help must work without root
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  install      Install the module"
    echo "  uninstall    Uninstall the module"
    echo "  -h, --help   Show this help message"
    echo ""
}

case "${1:-}" in
    -h|--help)
        show_usage
        exit 0
        ;;
esac

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

# dependencies
for dep_pkg in coreutils util-linux ncurses-bin grep sed systemd mawk; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        echo "ERROR: missing dependency '$dep_pkg' -- abort" >&2
        exit 1
    fi
done

# dependencies (external repo)
for dep_pkg in webmin; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        echo "ERROR: 'webmin' is not installed -- abort" >&2
        exit 1
    fi
done

# local_user detection
detect_local_user() {
    local uid_min uid_max
    local user uid best_user="" best_uid=999999

    uid_min=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_max=$(awk '/^UID_MAX/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    uid_max=${uid_max:-60000}

    while IFS=: read -r user _ uid _ _ _ shell; do
        [ "$user" = "root" ] && continue
        [ -z "$uid" ] && continue
        [ "$uid" -lt "$uid_min" ] && continue
        [ "$uid" -gt "$uid_max" ] && continue

        case "$shell" in
            */false|*/nologin) continue ;;
        esac

        id -nG "$user" 2>/dev/null | grep -qw sudo || continue

        if [ "$uid" -lt "$best_uid" ]; then
            best_uid="$uid"
            best_user="$user"
        fi
    done </etc/passwd

    [ -n "$best_user" ] || return 1
    echo "$best_user"
}

# The Webmin module is a read-only log viewer, so a missing local user is not
# fatal: the module stays installed and usable by the Webmin root account.
if ! local_user=$(detect_local_user); then
    local_user=""
    echo "WARNING: no local user with sudo found -- alert" >&2
fi

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

module_name="uhm"
module_dir="/usr/share/webmin/$module_name"
module_conf_dir="/etc/webmin/$module_name"

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

install_module() {
    echo ""
    echo "=========================================="
    echo "Installing UHM Log Viewer Module"
    echo "=========================================="
    echo ""

    echo "Creating module structure..."

    for module_subdir in "$module_dir/images" "$module_dir/lang" "$module_conf_dir"; do
        if ! mkdir -p "$module_subdir"; then
            echo "ERROR: cannot create $module_subdir -- abort" >&2
            exit 1
        fi
    done
    unset module_subdir

    # api.cgi -- AJAX endpoint for log polling, in bash
    cat > "$module_dir/api.cgi" <<'APICGI'
#!/bin/bash
# api.cgi -- AJAX endpoint for uhmd log viewer
# Reads /var/log/uhm.log via byte offset (never stalls like tail -f)
#
# Params (via QUERY_STRING):
# action=tail&pos=N&lines=N -- read from byte offset (polling)
# action=grep&q=TERM -- full-file grep search
# action=status -- service status

set -uo pipefail

# Fixed, not configurable from Webmin: every uhm component writes to this
# path hardcoded, so a value changed here could only ever point the viewer
# at a file nothing writes.
log_file="/var/log/uhm.log"
max_grep_lines=3000

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

# Parse QUERY_STRING
declare -A params
IFS='&' read -ra query_pairs <<< "${QUERY_STRING:-}"
for query_pair in "${query_pairs[@]}"; do
    IFS='=' read -r param_key param_value <<< "$query_pair"
    param_value="${param_value//+/ }"
    param_value=$(printf '%b' "$(printf '%s' "$param_value" | sed -E 's/%([0-9A-Fa-f]{2})/\\x\1/g')" 2>/dev/null || printf '%s' "$param_value")
    params["$param_key"]="$param_value"
done

api_action="${params[action]:-tail}"

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

# -- Status ----------------------------------------------------
if [[ "$api_action" == "status" ]]; then
    service_active=0
    service_pid=""
    service_uptime=""
    service_mem=""
    service_cpu=""
    status_out=$(systemctl status uhmd.service 2>&1 || true)
    if echo "$status_out" | grep -q 'Active: active (running)'; then
        service_active=1
    fi
    service_pid=$(echo "$status_out" | grep -oP 'Main PID:\s+\K\d+' || true)
    service_uptime=$(echo "$status_out" | grep -oP 'Active:.*;\s+\K.+' | sed 's/\s*$//' || true)
    service_mem=$(echo "$status_out" | grep -oP 'Memory:\s+\K[^\(]+' | sed 's/\s*$//' || true)
    service_cpu=$(echo "$status_out" | grep -oP 'CPU:\s+\K.+' | sed 's/\s*$//' || true)
    printf '{"active":%d,"pid":"%s","uptime":"%s","mem":"%s","cpu":"%s"}' \
        "$service_active" "$(json_escape "$service_pid")" "$(json_escape "$service_uptime")" \
        "$(json_escape "$service_mem")" "$(json_escape "$service_cpu")"
    exit 0
fi

# -- File checks -----------------------------------------------
if [[ ! -f "$log_file" ]]; then
    echo '{"error":"Log file not found","rows":[]}'
    exit 0
fi

file_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)

# -- Grep ------------------------------------------------------
if [[ "$api_action" == "grep" ]]; then
    search_term="${params[q]:-}"
    if [[ -z "$search_term" ]]; then
        echo '{"error":"Empty search term","rows":[]}'
        exit 0
    fi
    # Sanitize
    if [[ ! "$search_term" =~ ^[[:alnum:][:space:].:/@_-]+$ ]]; then
        echo '{"error":"Invalid search term","rows":[]}'
        exit 0
    fi

    grep_output=$(timeout 20 grep -Fia -e "$search_term" -- "$log_file" 2>/dev/null | tail -n "$max_grep_lines" || true)

    printf '{"rows":['
    first_row=1
    while IFS= read -r log_line; do
        [[ -z "$log_line" ]] && continue
        # Skip separator lines
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
    done <<< "$grep_output"

    printf '],"offset":%d,"grep":true}\n' "$file_size"
    exit 0
fi

# -- Tail (polling by byte offset) ----------------------------
UH_UINT='^(0|[1-9][0-9]*)$'

byte_pos="${params[pos]:-0}"
log_lines="${params[lines]:-200}"

# Validate
[[ "$byte_pos" =~ $UH_UINT ]] || byte_pos=0
[[ "$log_lines" =~ $UH_UINT ]] || log_lines=200
(( log_lines > 5000 )) && log_lines=5000
(( log_lines < 50 )) && log_lines=50

# First load or log rotated: read last N lines
if (( pos == 0 )) || (( pos > file_size )); then
    log_data=$(tail -n "$log_lines" "$log_file" 2>/dev/null || true)
    byte_pos=$file_size
    log_rotated=true
else
    # No new data
    if (( pos >= file_size )); then
        printf '{"rows":[],"pos":%d}\n' "$file_size"
        exit 0
    fi
    # Read from last position
    bytes_to_read=$(( file_size - pos ))
    log_data=$(tail -c +"$(( pos + 1 ))" "$log_file" 2>/dev/null | head -c "$bytes_to_read" || true)
    byte_pos=$file_size
    log_rotated=false
fi

printf '{"rows":['
first_row=1
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

printf '],"pos":%d,"rotated":%s}\n' "$byte_pos" "$log_rotated"
APICGI

    chmod 755 "$module_dir/api.cgi"

    # index.cgi -- main page with Webmin header/footer, in Perl
    cat > "$module_dir/index.cgi" <<'INDEXCGI'
#!/usr/bin/perl
# UHM Log Viewer -- Main interface
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();
&ReadParse();

our $module_name;
our %text;

&load_language($module_name);

print "Cache-Control: no-cache, no-store, must-revalidate, max-age=0\r\n";
print "Pragma: no-cache\r\n";

&ui_print_header(undef, $text{'index_title'}, "", undef, 1, 1);

print <<'HTMLBLOCK';
<style>
/* -- Variables -- Light (default) ----------------------------- */
#uhmod{
  --bg: #ffffff;
  --bg2: #f8f9fa;
  --bg3: #f1f3f5;
  --border: #dee2e6;
  --border2: #e9ecef;
  --text: #212529;
  --text2: #495057;
  --text3: #868e96;
  --ts-color: #6c757d;
  --msg-color:#212529;
  --mc-color: #1565c0;
  --ip-color: #6a1b9a;
  --kw-color: #1b5e20;
  --hl-bg: #fff176;
  --hl-color: #333;
  --row-hover:#f1f3f5;
  --row-new: #d4edda;
  --th-bg: #f1f3f5;
  --th-color: #495057;
  --scroll-track:#f1f3f5;
  --scroll-thumb:#ced4da;
  --sb-text: #6c757d;
  --cb-bg: #f8f9fa;
  --stats-bg: #f1f3f5;
  --grep-bg: #e8f4fd;
  --grep-border:#90caf9;
  --grep-text:#0d47a1;
  --cap-color:#e65100;
  --st-color: #2e7d32;
}
/* -- Variables -- Dark ----------------------------------------- */
#uhmod.dark{
  --bg: #0d1117;
  --bg2: #161b22;
  --bg3: #1c2128;
  --border: #21262d;
  --border2: #30363d;
  --text: #e6edf3;
  --text2: #c9d1d9;
  --text3: #8b949e;
  --ts-color: #4a6880;
  --msg-color:#c9d1d9;
  --mc-color: #79c0ff;
  --ip-color: #d2a8ff;
  --kw-color: #7ee787;
  --hl-bg: #3d2e00;
  --hl-color: #ffd700;
  --row-hover:#161b22;
  --row-new: #1a3a1a;
  --th-bg: #161b22;
  --th-color: #8b949e;
  --scroll-track:#0d1117;
  --scroll-thumb:#30363d;
  --sb-text: #8b949e;
  --cb-bg: #111827;
  --stats-bg: #111827;
  --grep-bg: #0d2137;
  --grep-border:#1565c0;
  --grep-text:#90caf9;
  --cap-color:#ffb74d;
  --st-color: #66bb6a;
}

#uhmod *{box-sizing:border-box}
#uhmod{font-family:'Segoe UI',system-ui,sans-serif;display:flex;flex-direction:column;height:calc(100vh - 120px);min-height:500px;background:var(--bg)}

/* -- Toolbar (always dark) ------------------------------------ */
.uh-toolbar{background:#1e2a35;padding:10px 14px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;flex-shrink:0;border-bottom:3px solid #3498db;border-radius:6px 6px 0 0}
.uh-toolbar .title{font-size:13px;font-weight:700;color:#fff;display:flex;align-items:center;gap:6px;white-space:nowrap}
.uh-toolbar .title .icon{background:rgba(255,255,255,.1);border-radius:5px;padding:3px 6px;font-size:12px}
.uh-search{position:relative;flex:1;min-width:200px;display:flex;gap:5px;align-items:center}
.uh-search input{flex:1;background:#253545;border:1px solid #3a4f63;color:#e6eef8;padding:7px 10px 7px 10px;border-radius:6px;font-size:12px;outline:none}
.uh-search input::placeholder{color:#607d8b}
.uh-search input:focus{border-color:#3498db}
.uh-bgrep{background:#1565c0;color:#fff;padding:6px 12px;border-radius:6px;font-size:11px;font-weight:600;cursor:pointer;border:none;white-space:nowrap}
.uh-bgrep:hover{background:#1976d2}
.uh-bgrep.grep-on{background:#e65100;animation:uhP 2s infinite}
.uh-bgrep.grep-on:hover{background:#bf360c}
@keyframes uhP{0%,100%{box-shadow:0 0 0 2px #ffb74d}50%{box-shadow:0 0 0 4px rgba(230,81,0,.3)}}
.uh-toolbar select{background:#253545;border:1px solid #3a4f63;color:#e6eef8;padding:7px 8px;border-radius:6px;font-size:11px;outline:none;cursor:pointer}
.uh-toolbar select option{background:#1e2a35}
.uh-btn{padding:6px 12px;border-radius:6px;font-size:11px;font-weight:600;cursor:pointer;border:none;white-space:nowrap;background:#37474f;color:#e6eef8}
.uh-btn:hover{background:#455a64}
.uh-btn-dm{padding:5px 10px;border-radius:6px;font-size:13px;font-weight:600;cursor:pointer;border:1px solid #3a4f63;background:#253545;color:#e6eef8;line-height:1;transition:background .2s}
.uh-btn-dm:hover{background:#37474f}
.uh-live{display:flex;align-items:center;gap:5px;background:#1a3a1a;border:1px solid #2e7d32;padding:4px 10px;border-radius:99px;font-size:10px;font-weight:700;color:#66bb6a;white-space:nowrap;cursor:pointer;user-select:none}
.uh-live.paused{background:#3a1a1a;border-color:#7d2e2e;color:#ef9a9a}
.uh-live .dot{width:6px;height:6px;border-radius:50%;background:#66bb6a}
.uh-live .dot.pulse{animation:uhD 1.2s infinite}
.uh-live.paused .dot{background:#ef9a9a;animation:none}
@keyframes uhD{0%,100%{opacity:1}50%{opacity:.25}}

/* -- Grep banner ---------------------------------------------- */
.uh-grepbar{background:var(--grep-bg);border-bottom:2px solid var(--grep-border);padding:5px 14px;font-size:11px;color:var(--grep-text);display:none;align-items:center;gap:8px;flex-shrink:0}
.uh-grepbar b{color:var(--grep-text)}
.uh-grepbar .cg{margin-left:auto;cursor:pointer;font-size:13px;color:var(--grep-text);background:none;border:none;font-weight:700}

/* -- Stats bar ------------------------------------------------ */
.uh-stats{background:var(--stats-bg);padding:5px 14px;display:flex;gap:14px;align-items:center;font-size:10px;color:var(--sb-text);flex-shrink:0;flex-wrap:wrap;border-bottom:1px solid var(--border)}
.uh-stats b{color:var(--text2)}
.uh-stats .sd{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:3px;vertical-align:middle}
.uh-stats .sd.on{background:#28a745}
.uh-stats .sd.off{background:#dc3545}
.uh-stats .cap{color:var(--cap-color)}
.uh-stats .st{color:var(--st-color);font-weight:700}
.uh-stats .lp{color:var(--text3);margin-left:auto;font-size:10px}

/* -- Cycle pills bar ------------------------------------------ */
.uh-cbar{background:var(--cb-bg);padding:5px 14px;display:flex;gap:6px;align-items:center;font-size:11px;flex-shrink:0;flex-wrap:wrap;border-bottom:1px solid var(--border)}
.uh-cbar:empty{display:none;padding:0}
.uh-cp{padding:3px 10px;border-radius:12px;font-weight:600;font-size:11px}
.uh-cp-ok{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
.uh-cp-w{background:#fff3cd;color:#856404;border:1px solid #ffeeba}
.uh-cp-i{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}
.uh-cp-d{background:#e2e3e5;color:#383d41;border:1px solid #d6d8db}
#uhmod.dark .uh-cp-ok{background:#1a3a1a;color:#66bb6a;border-color:#2e7d32}
#uhmod.dark .uh-cp-w{background:#3a2a00;color:#ffb74d;border-color:#f57f17}
#uhmod.dark .uh-cp-i{background:#1a2a3a;color:#90caf9;border-color:#1565c0}
#uhmod.dark .uh-cp-d{background:#1a1d2e;color:#8b949e;border-color:#30363d}

/* -- Table ---------------------------------------------------- */
.uh-tw{flex:1;overflow:auto;background:var(--bg);border-radius:0 0 6px 6px}
.uh-tw table{width:100%;border-collapse:collapse;font-size:12.5px}
.uh-tw thead{position:sticky;top:0;z-index:5}
.uh-tw thead th{background:var(--th-bg);color:var(--th-color);font-weight:600;padding:9px 12px;text-align:left;border-bottom:2px solid var(--border);white-space:nowrap;font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.uh-tw tbody tr{border-bottom:1px solid var(--border2);transition:background .1s}
.uh-tw tbody tr:hover{background:var(--row-hover)}
.uh-tw tbody tr.nr{animation:uhS .4s ease}
@keyframes uhS{from{background:var(--row-new);opacity:0;transform:translateX(-3px)}to{background:transparent;opacity:1;transform:translateX(0)}}
.uh-tw td{padding:7px 12px;white-space:nowrap;color:var(--text)}
.uh-tw td.cm{white-space:normal;word-break:break-all;max-width:700px;color:var(--msg-color)}

/* -- Cell styles ---------------------------------------------- */
.ct{color:var(--ts-color);font-size:11px;font-family:'Consolas','Liberation Mono',monospace}

/* Level badges -- one distinctive color per level:
   lI INFO blue, lW WARNING amber, lE ERROR red,
   lF FIX green, lA ALERT purple, lR STATUS grey */
.cl{display:inline-block;padding:2px 8px;border-radius:10px;font-weight:700;font-size:10px;text-transform:uppercase;letter-spacing:.4px;min-width:60px;text-align:center}
.cl.lI{background:#d1ecf1;color:#0c5460;border:1px solid #bee5eb}
.cl.lW{background:#fff3cd;color:#856404;border:1px solid #ffeeba}
.cl.lE{background:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
.cl.lF{background:#d4edda;color:#155724;border:1px solid #c3e6cb}
.cl.lA{background:#e2d9f3;color:#432874;border:1px solid #d3c6ec}
.cl.lR{background:#e2e3e5;color:#383d41;border:1px solid #d6d8db}
#uhmod.dark .cl.lI{background:#1a2a3a;color:#90caf9;border-color:#1565c0}
#uhmod.dark .cl.lW{background:#3a2a00;color:#ffc107;border-color:#d29922}
#uhmod.dark .cl.lE{background:#3a1a1a;color:#f85149;border-color:#6e1a1a}
#uhmod.dark .cl.lF{background:#12261a;color:#56d364;border-color:#238636}
#uhmod.dark .cl.lA{background:#2a1a3a;color:#bc8cff;border-color:#8957e5}
#uhmod.dark .cl.lR{background:#1c2128;color:#8b949e;border-color:#30363d}

.hl{background:var(--hl-bg);border-radius:2px;color:var(--hl-color)}
.mc{color:var(--mc-color);font-weight:600}
.ip{color:var(--ip-color)}
/* Colorblind-safe palette: blue = positive, amber = negative, grey = neutral -- never green/red. */
.kw-ok{color:var(--mc-color);font-weight:600}
.kw-w{color:var(--cap-color);font-weight:600}
.kw-n{color:var(--ts-color);font-weight:600}
.fld-ok{color:var(--kw-color);font-weight:600}
.fld-w{color:var(--cap-color);font-weight:600}
.fld-i{color:var(--mc-color);font-weight:600}
.uh-empty{text-align:center;padding:50px 20px;color:var(--text3);background:var(--bg)}

/* -- New rows banner ------------------------------------------ */
.uh-nb{position:fixed;bottom:14px;right:14px;background:#28a745;color:#fff;padding:7px 14px;border-radius:7px;font-size:11px;font-weight:600;box-shadow:0 2px 12px rgba(0,0,0,.2);cursor:pointer;display:none;z-index:100;border:1px solid #218838}
.uh-nb:hover{background:#218838}
.uh-sp{display:inline-block;width:10px;height:10px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:uhSp .6s linear infinite;vertical-align:middle}
@keyframes uhSp{to{transform:rotate(360deg)}}
.uh-tw::-webkit-scrollbar{width:6px;height:6px}
.uh-tw::-webkit-scrollbar-track{background:var(--scroll-track)}
.uh-tw::-webkit-scrollbar-thumb{background:var(--scroll-thumb);border-radius:3px}
</style>

<div id="uhmod">
<div class="uh-toolbar">
  <div class="title"><span class="icon">&#9685;</span> uhmd</div>
  <div class="uh-search">
    <span class="sicon">&#128269;</span>
    <input id="uhQ" type="text" placeholder="Filter by MAC, IP, message..." onkeydown="if(event.key==='Enter')uhGS()">
    <button class="uh-bgrep" id="uhBG" onclick="uhTG()" title="Search entire log file">Full log</button>
  </div>
  <select id="uhLv" onchange="uhAF()"><option value="">All levels</option><option value="INFO">INFO</option><option value="WARNING">WARNING</option><option value="ERROR">ERROR</option><option value="ALERT">ALERT</option><option value="FIX">FIX</option><option value="STATUS">STATUS</option></select>
  <select id="uhLn" onchange="uhRL()"><option value="200">Last 200</option><option value="500" selected>Last 500</option><option value="1000">Last 1000</option><option value="2000">Last 2000</option></select>
  <select id="uhIv" onchange="uhCI()"><option value="1000">1s</option><option value="3000">3s</option><option value="5000" selected>5s</option><option value="10000">10s</option><option value="30000">30s</option></select>
  <button class="uh-btn" onclick="uhRL()" title="Reload log">Reload</button>
  <button class="uh-btn-dm" id="uhDM" onclick="uhTDM()" title="Toggle dark mode">&#9790;</button>
  <div class="uh-live" id="uhLB" onclick="uhTL()" title="Click to pause/resume"><span class="dot pulse" id="uhDt"></span><span id="uhLL">LIVE</span></div>
</div>
<div class="uh-grepbar" id="uhGB">Full-log search: <b id="uhGT"></b> -- <span id="uhGC">0</span> results <button class="cg" onclick="uhCG()">&#10005; Back to live</button></div>
<div class="uh-stats">
  <span><span class="sd" id="uhSD"></span><span id="uhSL">...</span></span>
  <span style="color:#37474f">|</span>
  Showing <b id="uhSh">0</b> of <b id="uhTo">0</b>
  <span id="uhCN" class="cap" style="display:none"> (max 1000)</span>
  <span style="color:#37474f">|</span>
  <span class="st" id="uhST">--</span>
  <span class="lp">/var/log/uhm.log</span>
</div>
<div class="uh-cbar" id="uhCB"></div>
<div class="uh-tw" id="uhTW">
  <table><thead><tr><th style="width:145px">Timestamp</th><th style="width:70px">Level</th><th>Message</th></tr></thead><tbody id="uhTB"></tbody></table>
  <div id="uhEM" class="uh-empty" style="display:none">No log entries match</div>
</div>
<div class="uh-nb" id="uhNB" onclick="uhJT()">^ <span id="uhNC">0</span> new rows -- click to view</div>
</div>

<script>
(function(){
var ALL=[],CUR=[],fOff=0,live=true,pTmr=null,grep=false,loading=false,nrc=0;
var PI=5000,MR=5000,RC=1000;

// Dark mode
var dm=false;
function uhTDM(){
  dm=!dm;
  var mod=document.getElementById('uhmod');
  var btn=document.getElementById('uhDM');
  if(dm){mod.classList.add('dark');btn.textContent='\u2600';}
  else{mod.classList.remove('dark');btn.textContent='\u263D';}
  try{localStorage.setItem('uh_dm',dm?'1':'0')}catch(e){}
}
try{if(localStorage.getItem('uh_dm')==='1'){dm=true;document.getElementById('uhmod').classList.add('dark');document.getElementById('uhDM').textContent='\u2600';}}catch(e){}

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function hl(t,q){if(!q)return esc(t);try{var r=new RegExp('('+q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+')','gi');return esc(t).replace(r,'<span class="hl">$1</span>')}catch(e){return esc(t)}}
var UH_MAC_RE=/([0-9a-f]{2}(?::[0-9a-f]{2}){5})/gi;
function cm(m,q){var s=q?hl(m,q):esc(m);s=s.replace(UH_MAC_RE,'<span class="mc">$1</span>');s=s.replace(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/g,'<span class="ip">$1</span>');s=s.replace(/\b(authorized|voucher|guest|sta|managed)\b/gi,'<span class="kw-ok">$1</span>');s=s.replace(/\b(unauthorized|expired|evicting)\b/gi,'<span class="kw-w">$1</span>');s=s.replace(/\b(pending|skipping|reload)\b/gi,'<span class="kw-n">$1</span>');s=s.replace(/(^|\|)(auth|new_auth|unlimited)=/gi,'$1<span class="fld-ok">$2</span>=');s=s.replace(/(^|\|)(grace|revoked|blockdhcp)=/gi,'$1<span class="fld-w">$2</span>=');s=s.replace(/(^|\|)(vouchers|limited|hotspot)=/gi,'$1<span class="fld-i">$2</span>=');return s}
function bi(rows){return rows.map(function(r){r._i=(r.ts+' '+r.level+' '+r.msg).toLowerCase();return r})}
function mf(r){var lv=document.getElementById('uhLv').value;if(lv&&r.level!==lv)return false;var q=(document.getElementById('uhQ').value||'').toLowerCase().trim();if(!grep&&q&&r._i.indexOf(q)===-1)return false;return true}

function uhAF(an){
  var q=(document.getElementById('uhQ').value||'').toLowerCase().trim();
  var t0=performance.now();CUR=ALL.filter(mf);
  document.getElementById('uhST').textContent=(performance.now()-t0).toFixed(1)+' ms';
  var sh=Math.min(CUR.length,RC);
  document.getElementById('uhSh').textContent=sh;
  document.getElementById('uhTo').textContent=ALL.length;
  document.getElementById('uhCN').style.display=CUR.length>RC?'':'none';
  rt(grep?q:q,an||0);
}

function rt(q,an){
  var tb=document.getElementById('uhTB'),em=document.getElementById('uhEM');q=q||'';an=an||0;
  if(!CUR.length){tb.innerHTML='';em.style.display='block';return}
  em.style.display='none';
  var sl=CUR.slice(0,RC);
  tb.innerHTML=sl.map(function(r,i){
    var c=i<an?'nr':'';
    var lc=r.level==='INFO'?'lI':r.level==='WARNING'?'lW':r.level==='ERROR'?'lE':r.level==='FIX'?'lF':r.level==='ALERT'?'lA':'lR';
    return '<tr class="'+c+'"><td class="ct">'+esc(r.ts)+'</td><td class="cl '+lc+'">'+esc(r.level)+'</td><td class="cm">'+cm(r.msg,q)+'</td></tr>'
  }).join('');
}

function ucs(){
  var bar=document.getElementById('uhCB');
  for(var i=0;i<ALL.length;i++){
    var m=ALL[i].msg.match(/vouchers=(\d+)\|auth=(\d+)\|grace=(\d+)\|new_auth=(\d+)\|revoked=(\d+)/);
    if(m){bar.innerHTML='<span class="uh-cp uh-cp-i">Vouchers '+m[1]+'</span><span class="uh-cp uh-cp-ok">Authorized '+m[2]+'</span><span class="uh-cp uh-cp-w">Grace '+m[3]+'</span><span class="uh-cp uh-cp-ok">New Auth '+m[4]+'</span><span class="uh-cp '+(parseInt(m[5])>0?'uh-cp-w':'uh-cp-d')+'">Revoked '+m[5]+'</span>';return}
  }
}

window.uhRL=function(){
  if(loading)return;uhCG(true);loading=true;cP();ALL=[];CUR=[];fOff=0;nrc=0;
  document.getElementById('uhTB').innerHTML='<tr><td colspan="3" style="text-align:center;padding:40px;color:#90a4ae">Loading...</td></tr>';
  var ln=document.getElementById('uhLn').value;
  fetch('api.cgi?action=tail&pos=0&lines='+ln).then(function(r){return r.json()}).then(function(d){
    if(d.error){loading=false;return}ALL=bi(d.rows||[]).reverse();fOff=d.pos||0;uhAF();ucs();loading=false;if(live)sP();
  }).catch(function(){loading=false});
};

function poll(){
  if(!live||grep)return;
  var tw=document.getElementById('uhTW'),sp=tw.scrollTop;
  fetch('api.cgi?action=tail&pos='+fOff+'&lines=200').then(function(r){return r.json()}).then(function(d){
    if(!d.rows||!d.rows.length)return;
    var nr=bi(d.rows.reverse());fOff=d.pos;
    if(!nr.length)return;
    ALL=nr.concat(ALL);if(ALL.length>MR)ALL=ALL.slice(0,MR);nrc+=nr.length;
    uhAF(nr.length);ucs();if(sp>50){document.getElementById('uhNC').textContent=nrc;document.getElementById('uhNB').style.display='block'}
  }).catch(function(){});
}
function sP(){cP();pTmr=setInterval(poll,PI)}
function cP(){if(pTmr){clearInterval(pTmr);pTmr=null}}

window.uhTL=function(){
  live=!live;var el=document.getElementById('uhLB'),dt=document.getElementById('uhDt'),ll=document.getElementById('uhLL');
  if(live){el.className='uh-live';dt.className='dot pulse';ll.textContent='LIVE';if(!grep)sP()}
  else{el.className='uh-live paused';dt.className='dot';ll.textContent='PAUSED';cP()}
};
window.uhCI=function(){PI=parseInt(document.getElementById('uhIv').value);if(live&&!grep)sP()};

window.uhTG=function(){if(grep)uhCG(false);else uhGS()};
window.uhGS=function(){
  var q=document.getElementById('uhQ').value.trim();if(!q){uhRL();return}
  if(loading)return;loading=true;cP();ALL=[];CUR=[];nrc=0;grep=true;
  var btn=document.getElementById('uhBG');btn.innerHTML='<span class="uh-sp"></span> Searching...';
  document.getElementById('uhTB').innerHTML='<tr><td colspan="3" style="text-align:center;padding:40px;color:#90a4ae">Searching entire log...</td></tr>';
  fetch('api.cgi?action=grep&q='+encodeURIComponent(q)).then(function(r){return r.json()}).then(function(d){
    if(d.error){loading=false;rgB();return}ALL=bi(d.rows||[]).reverse();fOff=d.offset||0;
    document.getElementById('uhGT').textContent=q;document.getElementById('uhGC').textContent=ALL.length;
    document.getElementById('uhGB').style.display='flex';uhAF();ucs();loading=false;sgB();
  }).catch(function(){loading=false;rgB();grep=false});
};
function sgB(){var b=document.getElementById('uhBG');b.classList.add('grep-on');b.innerHTML='&#10005; Live mode'}
function rgB(){var b=document.getElementById('uhBG');b.classList.remove('grep-on');b.innerHTML='Full log'}
window.uhCG=function(s){grep=false;document.getElementById('uhGB').style.display='none';rgB();if(!s)uhRL()};
window.uhJT=function(){nrc=0;uhAF(0);requestAnimationFrame(function(){document.getElementById('uhTW').scrollTop=0;document.getElementById('uhNB').style.display='none'})};
window.uhTDM=uhTDM;

function pS(){
  fetch('api.cgi?action=status').then(function(r){return r.json()}).then(function(d){
    var dt=document.getElementById('uhSD'),lb=document.getElementById('uhSL');
    if(d.active){dt.className='sd on';lb.innerHTML='PID '+d.pid+(d.uptime?' . '+d.uptime:'')+(d.mem?' . '+d.mem:'')}
    else{dt.className='sd off';lb.textContent='stopped'}
  }).catch(function(){});
}

document.getElementById('uhQ').addEventListener('input',function(){if(!grep)uhAF()});
document.getElementById('uhLv').addEventListener('change',function(){uhAF()});

pS();setInterval(pS,30000);uhRL();
})();
</script>
HTMLBLOCK

&ui_print_footer("/", $text{'index'});
INDEXCGI

    chmod 755 "$module_dir/index.cgi"

    # module.info
    cat > "$module_dir/module.info" <<'EOF'
desc=UHM Log Viewer
longdesc=Real-time log viewer for the uhmd daemon
category=net
os_support=*-linux
version=1.0
depends=webmin
EOF

    cat > "$module_dir/module.info.es" <<'EOF'
desc=Visor de Log del Hotspot UniFi
longdesc=Visor de log en tiempo real para el demonio uhmd
category=net
os_support=*-linux
version=1.0
depends=webmin
EOF

    # language files
    cat > "$module_dir/lang/en" <<'EOF'
index_title=UHM Log Viewer
index=Webmin Index
EOF

    cat > "$module_dir/lang/es" <<'EOF'
index_title=Visor de Log del Hotspot UniFi
index=Indice de Webmin
EOF

    # icon in base64 -- UH (UniFi Hotspot) 48x48
    if ! base64 -d > "$module_dir/images/icon.gif" << 'ICONEOF'
R0lGODdhMAAwAIUAAP////v8/vv8/fj6/Ovw9+rv9uPq8+Hn8tfh78LR5rnK4rTH4LLF37DD3qO62aO52aG42IKhy32dyXiZx3eZx3SWxW6Sw22QwmOJvmCHvT5trzpqrTNlqjJkqi5hqCpepyBXox1UoRxToRpSoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACwAAAAAMAAwAEAI+QBHCBxIsKDBgwgTKlzIsGFDDQAiPiB4ISIACgIhSix4IGIBhwQ1Apg4sGJEjCNEkhzYEcBHkDBjypxJs6bNmzgdqqRoEeVOgi1fxoxgEQKHDxMCRFQw8CdLjzmjSp1KtarVq1izLnQ6wuTFjBZXCgwqk6tXnxbTqhUK8oNFBgQlWMQAdiNQqDQzLDAwQACBBBNAhAzLEa/Ww4gTK17MuLHjx5AjS568lXDJnnVHFnZZ1rLAs5nFjiAb0yzmlJ7HGgZp+mRmtWnZOtxg0QFBCxYrhN4s22FLAyIGNrDYYfddzjJDMIAdEYGHpqlHr6ZMvbr169iza5cZEAA7
ICONEOF
    then
        rm -f "$module_dir/images/icon.gif"
        echo "INFO: could not write module icon -- degraded" >&2
    fi

    # library required by the Webmin config system
    cat > "$module_dir/uhm-lib.pl" <<'EOF'
#!/usr/bin/perl
# uhm-lib.pl

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

1;
EOF
    chmod 755 "$module_dir/uhm-lib.pl"

    # config -- no settings, the log path is fixed in the viewer
    : > "$module_conf_dir/config"

    # permissions and registration
    chown -R root:root "$module_dir" "$module_conf_dir"
    chmod -R 755 "$module_dir"
    chmod 644 "$module_dir"/*.info* "$module_dir/lang/"* 2>/dev/null || true
    chmod 755 "$module_dir"/*.cgi "$module_dir/uhm-lib.pl" 2>/dev/null || true
    chmod 644 "$module_dir/images/"* 2>/dev/null || true

    if [[ -f /etc/webmin/webmin.acl ]]; then
        for webmin_account in root "$local_user"; do
            [ -z "$webmin_account" ] && continue
            if ! grep -qE "^${webmin_account}:" /etc/webmin/webmin.acl; then
                echo "INFO: no ${webmin_account}: line in webmin.acl -- skip"
                continue
            fi
            grep -qE "^${webmin_account}:.*\\b${module_name}\\b" /etc/webmin/webmin.acl && continue
            sed -i "s/\\(^${webmin_account}:.*\\)/\\1 ${module_name}/" /etc/webmin/webmin.acl
            echo "Module added to webmin.acl for ${webmin_account}"
        done
        unset webmin_account
    else
        echo "WARNING: webmin.acl not found -- alert" >&2
    fi

    rm -f /var/webmin/module.infos.cache

    echo "Restarting Webmin service..."
    systemctl restart webmin.service 2>/dev/null || /etc/webmin/restart 2>/dev/null || true

    echo ""
    echo "=========================================="
    echo "UHM Log Viewer installed!"
    echo "=========================================="
    echo ""
    echo "Module location: $module_dir"
    echo "Category: Networking"
    echo "URL: https://localhost:10000/$module_name/"
    echo ""
    echo "Please log out and log back into Webmin."
    echo ""
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

uninstall_module() {
    echo ""
    echo "=========================================="
    echo "Uninstalling UHM Log Viewer"
    echo "=========================================="
    echo ""

    if [ ! -d "$module_dir" ]; then
        echo "Module is not installed."
        return 1
    fi

    rm -rf "$module_dir"
    rm -rf "$module_conf_dir"
    echo "Module directories removed"

    if [[ -f /etc/webmin/webmin.acl ]] && grep -q "$module_name" /etc/webmin/webmin.acl; then
        sed -i.bak "s/[[:space:]]\+${module_name}\b//g" /etc/webmin/webmin.acl
        rm -f /etc/webmin/webmin.acl.bak
        echo "Module removed from webmin.acl"
    fi

    rm -f /var/webmin/module.infos.cache
    systemctl restart webmin.service 2>/dev/null || /etc/webmin/restart 2>/dev/null || true

    echo ""
    echo "=========================================="
    echo "Module uninstalled"
    echo "=========================================="
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

show_menu() {
    clear
    echo "============================================================"
    echo "UNIFI HOTSPOT LOG VIEWER - WEBMIN MODULE"
    echo "Installation Menu"
    echo "============================================================"
    echo ""
    echo "1) Install module"
    echo "2) Uninstall module"
    echo "3) Exit"
    echo ""
    echo -n "Select an option [1-3] [3]: "
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            install) install_module; exit 0 ;;
            uninstall) uninstall_module || true; exit 0 ;;
            *) echo "ERROR: invalid option '$1' -- abort" >&2; show_usage; exit 1 ;;
        esac
    fi

    while true; do
        show_menu
        read -r menu_option
        case $menu_option in
            1) install_module; echo ""; read -rp "Press Enter to continue..." _ ;;
            2) uninstall_module || true; echo ""; read -rp "Press Enter to continue..." _ ;;
            3|"") echo ""; exit 0 ;;
            *) echo "Invalid option."; sleep 2 ;;
        esac
    done
}

main "$@"
