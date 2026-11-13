#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmiptables -- uhm firewall ruleset
# FILE: firewall/uhmiptables.sh
#
# USAGE:
# sudo bash /etc/uhm/firewall/uhmiptables.sh
#
# LOG: /var/log/uhm.log
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# logging
log_file="/var/log/uhm.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -abort"
    exit 1
fi

# dependencies
for dep_pkg in iptables ipset arptables ebtables kmod procps util-linux ulogd2 coreutils grep curl iproute2; do
    if [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" != *"ok installed"* ]]; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_BOOL='^(true|false)$'
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# ACL PREPARATION
# Canonical block -- copied byte for byte into every script that creates a
# directory or a list under /etc/acl. Prepare /etc/acl first, then only the
# subdirectory and the lists this script needs. Never recursive.
# Usage: acl_prepare <dir> <dir_mode> <file_mode> [file ...]
acl_prepare() {
    local acl_dir="$1" dir_mode="$2" file_mode="$3" acl_file
    shift 3

    # mkdir without -p fails when the directory already exists, so a success
    # means this run created it and no concurrent run did.
    if mkdir -m "$dir_mode" -- "$acl_dir" 2>/dev/null; then
        if ! chown root:root -- "$acl_dir"; then
            log "ERROR: cannot set owner of $acl_dir -abort"
            exit 1
        fi
        log "WARNING: created ACL directory $acl_dir -alert"
    elif [ -d "$acl_dir" ] && [ ! -L "$acl_dir" ]; then
        acl_fix_perms "$acl_dir" "$dir_mode"
    else
        log "ERROR: $acl_dir is not a regular directory -abort"
        exit 1
    fi

    for acl_file in "$@"; do
        # Checked before the redirection: noclobber only protects regular
        # files, and opening a FIFO for writing blocks until a reader shows up.
        if [ -L "$acl_file" ] || { [ -e "$acl_file" ] && [ ! -f "$acl_file" ]; }; then
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
        # noclobber makes the redirection fail when the file already exists,
        # and umask 077 keeps the new file closed until chmod sets its mode.
        if (set -C; umask 077; : > "$acl_file") 2>/dev/null; then
            if ! { chmod "$file_mode" -- "$acl_file" \
                && chown root:root -- "$acl_file"; }; then
                log "ERROR: cannot set perms of $(basename "$acl_file") -abort"
                exit 1
            fi
            log "WARNING: created empty $(basename "$acl_file") -alert"
        elif [ -f "$acl_file" ] && [ ! -L "$acl_file" ]; then
            acl_fix_perms "$acl_file" "$file_mode"
        else
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
    done
}

# Repairs mode and owner of an existing ACL object, per Autorreparación
acl_fix_perms() {
    local acl_path="$1" want_mode="$2" cur_mode cur_owner
    cur_mode=$(stat -c '%a' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    cur_owner=$(stat -c '%U:%G' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    [[ "$cur_mode" == "$want_mode" && "$cur_owner" == "root:root" ]] && return 0
    if ! { chmod "$want_mode" -- "$acl_path" \
        && chown root:root -- "$acl_path"; }; then
        log "ERROR: cannot fix $(basename "$acl_path") perms -abort"
        exit 1
    fi
    log "INFO: $(basename "$acl_path") perms fixed -fixed"
}

# MAC SET FILL
# Create or flush a MAC set and fill it with the valid MACs of a list
mac_set() {
    local set_name="$1" src_file="$2" mac_addr invalid_count=0
    ipset create "$set_name" hash:mac -exist
    ipset flush "$set_name"
    [ -n "$src_file" ] || return 0
    if [ ! -f "$src_file" ]; then
        log "WARNING: $(basename "$src_file") not found -alert"
        return 0
    fi
    for mac_addr in $(awk -F";" 'NF>=2 && $1 == "a" && $2 != "" {print $2}' "$src_file"); do
        if [[ "$mac_addr" =~ $UH_MAC ]]; then
            ipset add "$set_name" "$mac_addr" -exist
        else
            invalid_count=$((invalid_count + 1))
        fi
    done
    if [ "$invalid_count" -gt 0 ]; then
        log "WARNING: $invalid_count invalid MACs in $(basename "$src_file") -alert"
    fi
    return 0
}

# MACIP SET
# Add each MAC and IP pair to the macip set
create_acl() {
    local mac_addr client_ip
    while (( $# >= 2 )); do
        mac_addr="$1"
        shift
        client_ip="$1"
        shift
        # Add MAC+IP to set
        [[ "$mac_addr" =~ $UH_MAC ]] && [[ "$client_ip" =~ $UH_IPV4 ]] && ipset add macip "$client_ip,$mac_addr" -exist
    done
}

# FIREWALL SWITCH
# Succeed when a switch is on; a key missing from toggles.conf uses its default
# Usage: fw_on <KEY> <on|off>
fw_on() {
    [[ "${fw_switch[$1]:-$2}" == on ]]
}

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

# PERMS
# Owner and mode of every .env this script reads
pydhcp_env="/etc/pydhcp/pydhcp.env"
uhm_env="/etc/uhm/uhm.env"
env_specs=("$pydhcp_env root:pydhcpd 640" "$uhm_env root:root 600")
for env_spec in "${env_specs[@]}"; do
    read -r env_path env_owner_want env_perms_want <<< "$env_spec"
    if [ ! -f "$env_path" ]; then
        log "ERROR: $(basename "$env_path") not found -abort"
        exit 1
    fi
    env_owner=$(stat -c '%U:%G' "$env_path" 2>/dev/null)
    env_perms=$(stat -c '%a' "$env_path" 2>/dev/null)
    if [[ "$env_owner" != "$env_owner_want" ]] \
       || [[ "$env_perms" != "$env_perms_want" ]]; then
        if chown "$env_owner_want" "$env_path" 2>/dev/null \
           && chmod "$env_perms_want" "$env_path" 2>/dev/null; then
            log "INFO: $(basename "$env_path") perms fixed -fixed"
        else
            log "ERROR: cannot fix $(basename "$env_path") perms -abort"
            exit 1
        fi
    fi
done
unset env_specs env_spec env_path env_owner_want env_perms_want
unset env_owner env_perms

# LOAD_CONF
# Read known key=value pairs from a config file, without sourcing it
if ! source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../tools/uhmenv.sh" 2>/dev/null; then
    log "ERROR: cannot load uhmenv.sh -abort"
    exit 1
fi

# LOAD
# Load all configuration from the two env files (network, paths, interfaces).
# One file per owner: pydhcp.env holds pydhcp's network and ACL values,
# uhm.env holds uhm's own. Each reader accepts only its owner's keys.
# Safe key=value parsing -- files
# are never sourced to prevent code execution.
load_uhm_env "$pydhcp_env" 'INTERFACESv4 SERVER_IP SERV_SUBNET SERV_MASK SERV_DNS ACL_PATH ACL_MAC_LIMITED ACL_MAC_UNLIMITED WPAD_PORT' line || true
load_uhm_env "$uhm_env" 'WAN_IFACE UHM_GRACE UHM_MACAUTH UHM_TOGGLES UNIFI_HOTSPOT_ENABLED' line || true

# KEY CHECK
# Collect every failure first, then decide -- a single abort reports them all
key_errors=()
for env_key in INTERFACESv4 ACL_PATH ACL_MAC_LIMITED \
               ACL_MAC_UNLIMITED; do
    if ! grep -q "^${env_key}=" "$pydhcp_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    fi
done
for env_key in SERVER_IP SERV_SUBNET; do
    if ! grep -q "^${env_key}=" "$pydhcp_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    elif ! [[ "${!env_key}" =~ $UH_IPV4 ]]; then
        key_errors+=("$env_key invalid IPv4")
    fi
done
if ! grep -q "^SERV_MASK=" "$pydhcp_env"; then
    key_errors+=("SERV_MASK missing line")
elif [[ -z "${SERV_MASK:-}" ]]; then
    key_errors+=("SERV_MASK not set")
elif ! [[ "$SERV_MASK" =~ $UH_NETMASK ]]; then
    key_errors+=("SERV_MASK invalid netmask")
fi
if ! grep -q "^SERV_DNS=" "$pydhcp_env"; then
    key_errors+=("SERV_DNS missing line")
elif [[ -z "${SERV_DNS:-}" ]]; then
    key_errors+=("SERV_DNS not set")
elif ! [[ "$SERV_DNS" =~ $UH_DNS ]]; then
    key_errors+=("SERV_DNS invalid DNS list")
fi
if ! grep -q "^WPAD_PORT=" "$pydhcp_env"; then
    key_errors+=("WPAD_PORT missing line")
elif [[ -z "${WPAD_PORT:-}" ]]; then
    key_errors+=("WPAD_PORT not set")
elif ! [[ "$WPAD_PORT" =~ $UH_UINT ]] \
     || [ "${#WPAD_PORT}" -gt 5 ] \
     || [ "$WPAD_PORT" -lt 1 ] || [ "$WPAD_PORT" -gt 65535 ]; then
    key_errors+=("WPAD_PORT invalid port")
fi
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$pydhcp_env") -abort"
    exit 1
fi
for env_key in WAN_IFACE UHM_GRACE UHM_MACAUTH UHM_TOGGLES; do
    if ! grep -q "^${env_key}=" "$uhm_env"; then
        key_errors+=("$env_key missing line")
    elif [[ -z "${!env_key:-}" ]]; then
        key_errors+=("$env_key not set")
    fi
done
if ! grep -q "^UNIFI_HOTSPOT_ENABLED=" "$uhm_env"; then
    key_errors+=("UNIFI_HOTSPOT_ENABLED missing line")
elif [[ -z "${UNIFI_HOTSPOT_ENABLED:-}" ]]; then
    key_errors+=("UNIFI_HOTSPOT_ENABLED not set")
elif ! [[ "$UNIFI_HOTSPOT_ENABLED" =~ $UH_BOOL ]]; then
    key_errors+=("UNIFI_HOTSPOT_ENABLED invalid boolean")
fi
if (( ${#key_errors[@]} > 0 )); then
    for key_error in "${key_errors[@]}"; do
        log "WARNING: $key_error -alert"
    done
    log "ERROR: ${#key_errors[@]} key(s) invalid in $(basename "$uhm_env") -abort"
    exit 1
fi
unset key_errors key_error env_key

# KEY GUARD
# WAN and LAN must be two distinct, existing interfaces
if [ "$WAN_IFACE" = "$INTERFACESv4" ]; then
    log "ERROR: WAN and LAN must differ -abort"
    exit 1
fi
for iface in "$WAN_IFACE" "$INTERFACESv4"; do
    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        log "ERROR: interface '$iface' does not exist -abort"
        exit 1
    fi
done

wan_iface="$WAN_IFACE"
# CIDR prefix derived from SERV_MASK, already validated by KEY CHECK
[[ " $UH_PREFIX " =~ [[:space:]]${SERV_MASK//./\\.}:([0-9]+)[[:space:]] ]]
netmask_int="${BASH_REMATCH[1]}"

# ------------------------------------------------------------------------------
# OWN VALUES
# ------------------------------------------------------------------------------

# SERVICE PORTS
# Web ports of other maravento projects, opened to registered devices
proxymon_warn_port=18771
smbstack_web_port=3092

# FIREWALL SWITCHES
# On/off switches edited from FWView; a missing switch keeps its default
fw_conf="$UHM_TOGGLES"
declare -A fw_switch=()
if [ -e "$fw_conf" ] || [ -L "$fw_conf" ]; then
    if [ -L "$fw_conf" ] || [ ! -f "$fw_conf" ]; then
        log "ERROR: toggles.conf is not a regular file -abort"
        exit 1
    fi
    fw_owner=$(stat -c %u "$fw_conf") && fw_mode=$(stat -c %a "$fw_conf") || {
        log "ERROR: cannot read toggles.conf owner or mode -abort"; exit 1; }
    if [[ "$fw_owner" != 0 ]] || (( (8#$fw_mode & 022) != 0 )); then
        log "ERROR: toggles.conf: unsafe owner or permissions -abort"
        exit 1
    fi
    while IFS='=' read -r fw_key fw_value || [ -n "$fw_key" ]; do
        fw_value="${fw_value%$'\r'}"
        [[ "$fw_key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        if [[ "$fw_value" == on || "$fw_value" == off ]]; then
            fw_switch[$fw_key]="$fw_value"
        else
            log "WARNING: toggles.conf: bad $fw_key, default -fallback"
        fi
    done < "$fw_conf"
    unset fw_key fw_value fw_owner fw_mode
else
    log "ERROR: toggles.conf not found -abort"
    exit 1
fi

# SQUID MODE
# on: limited and hotspot devices browse through Squid; off: direct 80/443
squid_mode="off"
fw_on SQUID on && squid_mode="on"
# Squid default ports, used only when squid_mode is on
if [[ "$squid_mode" == on ]]; then
    squid_port="3128"
    squid_intercept_port="3129"
fi

# MACPORTS PING
# on: macports devices can ping any host; off: their ping is dropped
macports_ping="off"
fw_on PING off && macports_ping="on"

# ------------------------------------------------------------------------------
# ACL
# ------------------------------------------------------------------------------

# PATHS
# Declare the file and directory paths used below
acl_path="$ACL_PATH"
acl_mac_path="$acl_path"

# PYDHCP
# Generated by pydhcp
dhcp_conf="/etc/pydhcp/core/pydhcpd.conf"

# REQUIRED FILES
# Abort if a list this script depends on is missing
for required_file in "$ACL_MAC_LIMITED" "$ACL_MAC_UNLIMITED" "$dhcp_conf"; do
    if [ ! -f "$required_file" ]; then
        log "ERROR: required file not found: $(basename "$required_file") -abort"
        exit 1
    fi
done
unset required_file
if [ ! -d "$acl_mac_path" ]; then
    log "ERROR: ACL_PATH directory not found -abort"
    exit 1
fi

# REQUIRED DIRS
# Prepare the ACL directory before downloading port and bogon lists
acl_prepare "$acl_path" 700 600

# PORT LIST
# Build the configured port set
blockports_file="$acl_path/blockports.txt"
blockports_url="https://raw.githubusercontent.com/maravento/vault/refs/heads/master/gateproxy/acl/blockports.txt"
if [ ! -f "$blockports_file" ]; then
    # Download labels: rules.md, Etiquetas de descarga
    blockports_rc=0
    blockports_code=$(curl -sL --connect-timeout 10 --retry 3 --retry-delay 2 \
        -w '%{http_code}' -o "$blockports_file" "$blockports_url") || blockports_rc=$?
    case "${blockports_code:-000}" in
        2*) if (( blockports_rc == 0 )); then
                log "SAVED: $(basename "$blockports_url")"
            else
                log "PARTIAL: $blockports_url"
            fi ;;
        000) log "TIMEOUT: $blockports_url" ;;
        5*) log "BUSY: $blockports_code $blockports_url" ;;
        404|410) log "BROKEN: $blockports_code $blockports_url" ;;
        *) log "HTTP_ERROR: $blockports_code $blockports_url" ;;
    esac
    if [[ "${blockports_code:-000}" != 2* ]] || (( blockports_rc != 0 )); then
        rm -f "$blockports_file"
        log "ERROR: blockports.txt not available -abort"
        exit 1
    fi
    unset blockports_rc blockports_code
fi
acl_fix_perms "$blockports_file" 600

# MAC SETS
# The four MAC sets are declared and filled here, in one place, before any
# rule uses them. Their source lists are already in their final state at this
# point: uhmreload.sh runs uhmleases.sh to completion first, and nothing else
# writes them while this script runs. Any other set built from MAC addresses
# is composed from these four, never filled from a list again.

mac_set maclimited   "$ACL_MAC_LIMITED"
mac_set macunlimited "$ACL_MAC_UNLIMITED"
if [[ "$UNIFI_HOTSPOT_ENABLED" == true ]]; then
    mac_set machotspot "$UHM_MACAUTH"
    mac_set macgrace "$UHM_GRACE"
else
    mac_set machotspot ""
    mac_set macgrace ""
fi

# MACPORTS LIST
# Combine the limited and hotspot MAC sets

# Union of maclimited and machotspot
ipset create macports list:set -exist
ipset flush macports
ipset add macports maclimited -exist
ipset add macports machotspot -exist

# ------------------------------------------------------------------------------
# KERNEL RULES
# ------------------------------------------------------------------------------

# start
log "INFO: uhmiptables start..."

# Reset firewall tables before applying the configured rules

# ZERO ALL PACKETS AND COUNTERS
# Reset tables (IPv4)
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true
iptables -t raw -X 2>/dev/null || true
iptables -t security -F 2>/dev/null || true
iptables -t security -X 2>/dev/null || true
# Reset counters (IPv4)
iptables -Z 2>/dev/null || true
iptables -t nat -Z 2>/dev/null || true
iptables -t mangle -Z 2>/dev/null || true
# Reset tables (IPv6)
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
# Reset counters (IPv6)
ip6tables -Z 2>/dev/null || true
# Clear ARP and bridge
arptables -F 2>/dev/null || true
arptables -X 2>/dev/null || true
ebtables -F 2>/dev/null || true
ebtables -X 2>/dev/null || true
# Conntrack (Optional)
#conntrack -F 2>/dev/null || true

# SYSTEM OPTIMIZATION
# Apply kernel settings used by the router

# FILE HANDLE
# inotify and socket queue limits raised for a router under load
sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true
sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true

# KERNEL AND FILESYSTEM HARDENING
# Enable full ASLR (Address Space Layout Randomization)
sysctl -w kernel.randomize_va_space=2 >/dev/null 2>&1 || true
# Protect hardlinks (prevents privilege escalation attacks)
sysctl -w fs.protected_hardlinks=1 >/dev/null 2>&1 || true
# Protect symlinks (prevents unauthorized link access in shared directories)
sysctl -w fs.protected_symlinks=1 >/dev/null 2>&1 || true

# CONNECTION TRACKING
# nf_conntrack_max/buckets only exist under /proc/sys once the nf_conntrack
# kernel module is loaded. On a cold boot this script can run before
# anything else has triggered that module to load (the first -m conntrack
# rule below doesn't load it either — it's evaluated by the kernel lazily,
# not at rule-add time), so sysctl -w would silently no-op on those two
# keys until the module loads on its own. Force the module to load first
# so tuning takes effect immediately, instead of depending on boot timing.
modprobe -q nf_conntrack 2>/dev/null || true
# Increase connection tracking table size for high concurrency
sysctl -w net.netfilter.nf_conntrack_max=524288 >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_buckets=131072 >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# IPV4
# ------------------------------------------------------------------------------

# Apply the IPv4 kernel and firewall settings

# SECURITY AND NETWORK HARDENING
# Disable IP source routing (prevents IP spoofing and routing attacks)
sysctl -w net.ipv4.conf.all.accept_source_route=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_source_route=0 >/dev/null 2>&1 || true
# Disable secure redirects (protects against malicious router advertisements)
# If you experience LAN routing issues, you can temporarily set this to 1.
sysctl -w net.ipv4.conf.all.secure_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.secure_redirects=0 >/dev/null 2>&1 || true
# Log packets with impossible or spoofed source addresses ("martians")
sysctl -w net.ipv4.conf.all.log_martians=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.log_martians=1 >/dev/null 2>&1 || true
# Enable strict reverse path filtering (drops packets with spoofed source IPs)
sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null 2>&1 || true

# NETWORK PERFORMANCE AND TCP PROTECTION
# Optimized TCP/IP parameters for high-performance and secure routing
# Enable TCP SYN cookies (protects against SYN flood attacks)
sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true
# Increase SYN backlog queue and tune retries (helps prevent SYN flood)
sysctl -w net.ipv4.tcp_max_syn_backlog=20000 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_syn_retries=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_synack_retries=2 >/dev/null 2>&1 || true
# Enable RFC1337 fix (protects against TCP TIME-WAIT assassination)
sysctl -w net.ipv4.tcp_rfc1337=1 >/dev/null 2>&1 || true
# Expand available local port range (default: 32768-60999)
sysctl -w net.ipv4.ip_local_port_range="10000 65535" >/dev/null 2>&1 || true
# Reduce TCP FIN timeout (faster cleanup for orphaned sockets)
sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null 2>&1 || true
# TCP keepalive settings (balance connection stability and resource usage)
sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_intvl=15 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1 || true
# Enable TCP Fast Open (reduces latency for repeated connections)
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
# Enable TCP performance features
sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1 || true
# Increase socket buffers
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_default=262144 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_default=262144 >/dev/null 2>&1 || true
# TCP buffer auto-tuning
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1 || true
# Enable PMTU discovery (recommended: automatic MTU adjustment)
sysctl -w net.ipv4.ip_no_pmtu_disc=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
# Increase network queue size (handles bursts of incoming packets)
sysctl -w net.core.netdev_max_backlog=20000 >/dev/null 2>&1 || true
# Increase TIME_WAIT socket capacity (important for busy NAT or proxy servers)
sysctl -w net.ipv4.tcp_max_tw_buckets=1000000 >/dev/null 2>&1 || true
# Allow safe TIME_WAIT socket reuse (improves connection efficiency)
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true

# ROUTING AND FORWARDING
# Enable packet forwarding (required for NAT/routing)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
# Not a tuning value like the rest: without forwarding this host stops
# routing, and LAN clients get a lease that reaches nothing. Verified by
# its resulting state, not by sysctl's exit code, so a value already set
# by another means is accepted.
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    log "ERROR: IPv4 forwarding is off, LAN cannot route -abort"
    exit 1
fi

# ARP OPTIMIZATION
# Enable ARP filtering (prevents incorrect replies when multiple interfaces exist)
sysctl -w net.ipv4.conf.all.arp_filter=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_filter=1 >/dev/null 2>&1 || true
# ARP announce mode - only reply for local addresses
sysctl -w net.ipv4.conf.all.arp_announce=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_announce=2 >/dev/null 2>&1 || true
# ARP ignore mode - only respond to ARPs for IPs on receiving interface
sysctl -w net.ipv4.conf.all.arp_ignore=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.arp_ignore=1 >/dev/null 2>&1 || true
# ARP cache tuning: reduce broadcast frequency and improve efficiency
# gc_thresh1/2/3 are global values, exposed under neigh/default only by
# convention. Every other key here is per-interface: neigh/default is just the
# template copied to interfaces created after it is written, so an interface
# that already exists keeps the kernel defaults unless it is set by name.
sysctl -w net.ipv4.neigh.default.gc_thresh1=128 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.gc_thresh2=512 >/dev/null 2>&1 || true
sysctl -w net.ipv4.neigh.default.gc_thresh3=1024 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.neigh.${INTERFACESv4}.gc_stale_time=300" >/dev/null 2>&1 || true
# ARP solicitations before a neighbour is declared FAILED and its queued
# packets are dropped. Devices that enter deep sleep (printers, IoT) need
# seconds to answer, so this stays above the kernel default rather than below.
sysctl -w "net.ipv4.neigh.${INTERFACESv4}.ucast_solicit=6" >/dev/null 2>&1 || true
sysctl -w "net.ipv4.neigh.${INTERFACESv4}.mcast_solicit=6" >/dev/null 2>&1 || true
# Base reachable time for neighbor entries. Kept at the kernel default: this is
# how long a MAC is trusted without re-verification, and the dynamic ranges
# (hotspot pool, block pool) recycle an IP between different devices, so a
# longer window would keep sending to the previous holder's MAC.
sysctl -w "net.ipv4.neigh.${INTERFACESv4}.base_reachable_time_ms=30000" >/dev/null 2>&1 || true

# ICMP
# Disable sending ICMP redirects (prevents MITM via route manipulation)
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null 2>&1 || true
# Disable accepting ICMP redirects from other hosts (security hardening)
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_redirects=0 >/dev/null 2>&1 || true
# Allow normal ICMP echo requests (ping)
sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || true
# Ignore ICMP echo requests sent to broadcast addresses (Smurf attack prevention)
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1 >/dev/null 2>&1 || true
# Ignore bogus or malformed ICMP error responses
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1 >/dev/null 2>&1 || true
# Rate limit ICMP message generation (100 ms minimum interval)
sysctl -w net.ipv4.icmp_ratelimit=100 >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# IPV6
# ------------------------------------------------------------------------------

# Apply the IPv6 kernel and firewall settings

# WAN IPv6
# IPv6 left enabled on the WAN interface
sysctl -w "net.ipv6.conf.${wan_iface}.disable_ipv6=0" >/dev/null 2>&1 || true
# LAN IPv6
# IPv6 disabled on the LAN interface
sysctl -w "net.ipv6.conf.${INTERFACESv4}.disable_ipv6=1" >/dev/null 2>&1 || true
# WAN IPv6 TRAFFIC
# Only what the link itself needs, plus replies to what this host started
# Essential ICMPv6 (NDP, SLAAC, Path MTU)
ip6tables -A OUTPUT -o "$wan_iface" -p ipv6-icmp -j ACCEPT || true
# DHCPv6
ip6tables -A OUTPUT -o "$wan_iface" -p udp --sport 546 --dport 547 -j ACCEPT || true
# Established traffic
ip6tables -A INPUT -i "$wan_iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true

# ------------------------------------------------------------------------------
# POLICIES
# ------------------------------------------------------------------------------

# Set the default firewall chain policies

# Global policies IPv4 (ACCEPT, then explicit drops)
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Global policies IPv6 (closed by default)
ip6tables -P INPUT DROP || true
ip6tables -P FORWARD DROP || true
ip6tables -P OUTPUT DROP || true

# LOOPBACK
# Accept all traffic on the loopback interface
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT || true
ip6tables -A OUTPUT -o lo -j ACCEPT || true
iptables -A INPUT -s 127.0.0.0/8 ! -i lo -j DROP
iptables -A FORWARD -s 127.0.0.0/8 ! -i lo -j DROP

# ------------------------------------------------------------------------------
# ESSENTIAL RULES
# ------------------------------------------------------------------------------

# Allow the essential local and network traffic

# DHCP
# Let pydhcpd serve the LAN, and this host renew its own lease on the WAN
iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -p udp --dport 67 -j ACCEPT
iptables -A OUTPUT -o "$wan_iface" -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A INPUT -i "$wan_iface" -p udp --sport 67 --dport 68 -j ACCEPT
iptables -A INPUT -i "$INTERFACESv4" -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A OUTPUT -o "$INTERFACESv4" -p udp --sport 67 --dport 68 -j ACCEPT

# MASQUERADE
# NAT for LAN to share dynamic WAN IP
iptables -t nat -A POSTROUTING -s "$SERV_SUBNET/$netmask_int" -o "$wan_iface" -j MASQUERADE
#
# SNAT example for static WAN IP (more efficient)
# wan_ip=$(ip -4 -o addr show dev "$wan_iface" | awk '{print $4}' | cut -d/ -f1)
# iptables -t nat -A POSTROUTING -s "$SERV_SUBNET/$netmask_int" -o "$wan_iface" -j SNAT --to-source "$wan_ip"

# LAN ---> PROXY <--- WAN
# Configure DHCP traffic and proxy routing between LAN and WAN
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
# Squid proxy outbound traffic
iptables -A OUTPUT -o "$wan_iface" -m owner --uid-owner proxy -j ACCEPT

# MALFORMED PACKETS
# Invalid and fragmented packets
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -f -j DROP
# TCP scans / malformed packets
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
# Invalid NEW connections with SYN+ACK
iptables -A INPUT -p tcp --tcp-flags SYN,ACK SYN,ACK -m conntrack --ctstate NEW -j DROP
iptables -A FORWARD -p tcp --tcp-flags SYN,ACK SYN,ACK -m conntrack --ctstate NEW -j DROP

# DNS
# Burst limit: applies to all INTERFACESv4 sources, not just macgrace -- no MAC list
# gets a free pass on flooding the resolver, same principle as the ACCEPT/DROP
# below applying uniformly regardless of list.
iptables -A FORWARD -i "$INTERFACESv4" -p udp --dport 53 -m state --state NEW -m recent --set --name DNS_DROPPER
iptables -A FORWARD -i "$INTERFACESv4" -p udp --dport 53 -m state --state NEW -m recent --update --seconds 1 --hitcount 15 --name DNS_DROPPER -j DROP
for dns_ip in ${SERV_DNS//,/ }; do
    for proto_name in tcp udp; do
        iptables -A INPUT -i "$INTERFACESv4" -d "$dns_ip" -p "$proto_name" --dport 53 -j ACCEPT
        iptables -A FORWARD -i "$INTERFACESv4" -d "$dns_ip" -p "$proto_name" --dport 53 -j ACCEPT
    done
done

for proto_name in tcp udp; do
    iptables -A FORWARD -i "$INTERFACESv4" -p "$proto_name" --dport 53 -m hashlimit --hashlimit-name dns-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip -j NFLOG --nflog-prefix "DNS-DROP: "
    iptables -A FORWARD -i "$INTERFACESv4" -p "$proto_name" --dport 53 -j DROP
done

# ------------------------------------------------------------------------------
# UNIFI PORTS
# ------------------------------------------------------------------------------

# Allow the configured UniFi controller and portal ports
# https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference

# UNIFI WAN
# STUN responses from Ubiquiti (3478) and Google (19302) - needed for APs behind NAT
iptables -A INPUT -i "$wan_iface" -p udp -m multiport --sports 3478,19302 -j ACCEPT
# Device discovery from management LAN via WAN interface
iptables -A INPUT -i "$wan_iface" -p udp --dport 10001 -j ACCEPT

# UNIFI LAN
# Uncomment if using Ubiquiti remote access cloud service
# iptables -A INPUT -i "$wan_iface" -p tcp -s 66.203.125.0/24 --sport 443 -d "$wan_iface" -j ACCEPT
# LAN Unifi - ports required for LAN clients and APs to communicate with self-hosted controller
# 8080  TCP - AP to controller communication
# 8880  TCP - captive portal HTTP
# 8881  TCP - captive portal HTTP alternate
# 8882  TCP - captive portal HTTP alternate
# 8843  TCP - captive portal HTTPS
# 6789  TCP - UniFi speed test / throughput measurement (Podman/pasta userspace network)
# 3478  UDP - STUN for APs
# 53    UDP - DNS (local on gateway)
# 123   UDP - NTP
# 10001 UDP - device discovery
# Removed (administrative/internal only):
# 8443  TCP - GUI/API admin access
# 8444  TCP - UniFi OS HTTPS GUI admin
# 11443 TCP - UniFi OS self-hosted GUI admin
# 27117 TCP - MongoDB internal database
# 1900  UDP - UPnP optional discovery
# Unifi Portal Access
# Optional https: 8843
if [[ "$UNIFI_HOTSPOT_ENABLED" == true ]]; then
    cpd_tcp_ports="8880,8881,8882"

    # CAPTIVE PORTAL
    # The portal ports answer only to uhm's own lists, macgrace and machotspot
    iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports "$cpd_tcp_ports" -m set --match-set macunlimited src -j DROP
    iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports "$cpd_tcp_ports" -m set --match-set maclimited src -j DROP

    # MACGRACE
    # Restrict grace-period devices to portal and DNS access

    # http: Send a client still in grace to the captive portal when it browses on port 80
    iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set macgrace src -p tcp --dport 80 -j ACCEPT
    iptables -t nat -A PREROUTING -i "$INTERFACESv4" -m set --match-set macgrace src -p tcp --dport 80 -j REDIRECT --to-port 8880
    iptables -A INPUT -i "$INTERFACESv4" -m set --match-set macgrace src -p tcp --dport 8880 -j ACCEPT
    # cdp
    # Let a client still in grace reach the captive portal ports
    iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set macgrace src -p tcp -m multiport --dports "$cpd_tcp_ports" -j ACCEPT
    iptables -A INPUT -i "$INTERFACESv4" -m set --match-set macgrace src -p tcp -m multiport --dports "$cpd_tcp_ports" -j ACCEPT
fi

# ------------------------------------------------------------------------------
# MAC2IP
# ------------------------------------------------------------------------------

# Enforce the configured MAC and IPv4 address bindings

mac2ip_rules=$(awk '
    /host [^{]+ \{/ { in_block=1; mac=""; ip="" }
    in_block && /hardware ethernet/ { mac=$3; gsub(/;/, "", mac) }
    in_block && /fixed-address/ { ip=$2; gsub(/;/, "", ip) }
    in_block && /\}/ {
        if (mac != "" && ip != "") print mac, ip
        in_block=0
    }
' "$dhcp_conf")
# Lowercase MAC-only view of MAC2IP, for the classified-MAC diagnostic below
# (has no static reservation, distinct from the ip,mac pairs macip itself uses).
mac2ip_macs=$(awk '{print tolower($1)}' <<< "$mac2ip_rules")

if ! ipset list macip &>/dev/null; then
    ipset create macip hash:ip,mac -exist
else
    ipset flush macip
fi
if [ -n "$mac2ip_rules" ]; then
    # create_acl expects a flat MAC IP MAC IP ... arg list (it shifts two at a
    # time). $mac2ip_rules is one "mac ip" pair per line, so it must still be split
    # into individual args -- but building that list explicitly (instead of
    # relying on bare unquoted word-splitting) avoids any accidental glob
    # expansion of a token.
    mac2ip_args=()
    while IFS=' ' read -r m2i_mac m2i_ip; do
        [[ -n "$m2i_mac" ]] && mac2ip_args+=("$m2i_mac")
        [[ -n "$m2i_ip" ]] && mac2ip_args+=("$m2i_ip")
    done <<< "$mac2ip_rules"
    create_acl "${mac2ip_args[@]}"
    iptables -t mangle -N MACCHECK 2>/dev/null || true
    iptables -t mangle -F MACCHECK
    iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -j MACCHECK
    iptables -t mangle -A MACCHECK -m set --match-set macip src,src -j RETURN
    iptables -t mangle -A MACCHECK -j DROP

    # ARP binding: drop ARP claiming a registered static IP from any MAC other
    # than the one it's leased to. iptables/ipset only see the IP layer, not
    # how that IP got resolved to a MAC on the wire -- this closes that gap.
    for ((arp_index=0; arp_index<${#mac2ip_args[@]}; arp_index+=2)); do
        arp_mac="${mac2ip_args[arp_index]}"
        arp_ip="${mac2ip_args[arp_index+1]}"
        [[ "$arp_mac" =~ $UH_MAC ]] && [[ "$arp_ip" =~ $UH_IPV4 ]] && \
            { arptables -A INPUT -i "$INTERFACESv4" --source-ip "$arp_ip" ! --source-mac "$arp_mac" -j DROP || true; }
    done
else
    log "WARNING: no static DHCP entries in $dhcp_conf -alert"
fi

# ------------------------------------------------------------------------------
# MACUNLIMITED
# ------------------------------------------------------------------------------

# Allow traffic for the unrestricted device set

# MAC + IP for Access Points, Switch, etc.
iptables -t nat -A PREROUTING -i "$INTERFACESv4" -m set --match-set macunlimited src -j ACCEPT
iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set macunlimited src -j ACCEPT
# Unlimited devices never use the proxy — block PAC access so DHCP option 252
# (WPAD, if enabled) has no effect on them, since pydhcpd is ACL-agnostic and
# sends it to every client regardless of classification.
if [[ "$squid_mode" == on ]]; then
    iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports $squid_port,$WPAD_PORT -m set --match-set macunlimited src -j DROP
else
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$WPAD_PORT" -m set --match-set macunlimited src -j DROP
fi
for chain_name in INPUT FORWARD; do
    iptables -A "$chain_name" -i "$INTERFACESv4" -m set --match-set macunlimited src -j ACCEPT
done

# ------------------------------------------------------------------------------
# SECURITY RULES
# ------------------------------------------------------------------------------

# Apply the network traffic protection rules

# BLOCKPORTS
# path: /etc/acl/blockports.txt
# Block Direct Connections:
# - HTTPs (443) - TCP/UDP: skipped here, see HTTPS PATH
# - HTTPs Fallback (4444,9443) - TCP
# - DoT (853,8053) - TCP
# - DNS over QUIC DoQ (784) - UDP
# - DoQ Fallback (8853) - UDP
# - OpenVPN (1194) - UDP
# - L2TP/IPsec (1701) - UDP
# - IPsec IKE (500) - UDP
# - IPsec NAT-T (4500) - UDP
# - WireGuard (51820) - UDP
# - SOCKS5 proxies (1080) - TCP
# - Shadowsocks (7300) - TCP/UDP
# - HTTP-Proxy Alternative (8080,8000,3130) - TCP
# - Spotify (4070) - TCP
#
# Block legacy, risky or potentially abusive services:
# - Echo (7) - TCP/UDP
# - CHARGEN (19) - TCP/UDP
# - FTP (20,21) - TCP
# - SSH (22) - TCP
# - 6to4 (41,43,44,58,59,60,3544) - UDP
# - FINGER (79) - TCP
# - PPTP (1723) - TCP
# - TOR Ports (9001,9050,9150) - TCP
# - Brave Tor (9001:9004,9090,9101:9103,9030,9031,9050) - TCP
# - IRC (6660-6669) - TCP
# - Trojans/Metasploit (4444) - TCP
# - SQL inyection/XSS (8088,8888) - TCP
# - bittorrent (6881-6889,58251,58252,58687,6969) - TCP/UDP
# - others P2P (1000,1007,1337,2760,4662,4672,5001) - TCP/UDP
# - Cryptomining (3333,5555,6666,7777,8848,9999,14444,14433,45560) - TCP
# - WINS (42) - TCP/UDP
# - BTC/ETH (8332,8333,8545,30303) - TCP

if fw_on BLOCKPORTS on; then
    if ! ipset list blockports &>/dev/null; then
        ipset create blockports bitmap:port range 0-65535 -exist
    else
        ipset flush blockports
    fi
    # 443 is handled by HTTPS PATH below, so the list never decides it
    for blocked_ports in $(sort -V -u "$blockports_file" 2>/dev/null); do
        [[ "$blocked_ports" =~ $UH_UINT ]] && [ "${#blocked_ports}" -le 5 ] && [ "$blocked_ports" -le 65535 ] && [ "$blocked_ports" != 443 ] && ipset add blockports "$blocked_ports" -exist
    done
    for proto_name in tcp udp; do
        #iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -p "$proto_name" -m set --match-set blockports dst -m hashlimit --hashlimit-name blockports-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip,dstport -j NFLOG --nflog-prefix "BLOCKPORT DROP: "
        iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -p "$proto_name" -m set --match-set blockports dst -j DROP
    done
fi

# HTTPS PATH
# With Squid, direct HTTPS and QUIC are dropped; HTTPS goes only via CONNECT
if [[ "$squid_mode" == on ]]; then
    for proto_name in tcp udp; do
        iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -p "$proto_name" --dport 443 -j DROP
    done
fi

# 6to4 (IPv6-in-IPv4 tunneling) - prevents LAN clients from bypassing
# IPv4-based firewall rules via IPv6 tunnel encapsulation
iptables -A FORWARD -i "$INTERFACESv4" -p 41 -j DROP

# NETBIOS NMBD
# disabled in smb.conf
if fw_on WINDOWS on; then
    for chain_name in INPUT FORWARD; do
        iptables -A "$chain_name" -i "$INTERFACESv4" -p udp -m multiport --dports 137,138 -j DROP
        iptables -A "$chain_name" -i "$INTERFACESv4" -p tcp --dport 139 -j DROP
    done
fi

# COAP
# Drop CoAP/CoAPs 5683/5684 from the LAN
if fw_on BYPASS on; then
    for chain_name in INPUT FORWARD; do
        iptables -A "$chain_name" -i "$INTERFACESv4" -p udp -m multiport --dports 5683,5684 -j DROP
    done
fi

# SYNCFLOOD
# Limit incoming TCP SYN traffic before dropping excess packets
if fw_on SYNFLOOD on; then
    iptables -N syn_flood 2>/dev/null || true
    iptables -A INPUT -i "$wan_iface" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
    iptables -A FORWARD -i "$wan_iface" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
    iptables -A FORWARD -i "$INTERFACESv4" -p tcp --tcp-flags FIN,SYN,RST,ACK SYN -j syn_flood
    iptables -A syn_flood -i "$wan_iface" -m limit --limit 50/s --limit-burst 200 -j RETURN
    iptables -A syn_flood -i "$INTERFACESv4" -m limit --limit 200/s --limit-burst 500 -j RETURN
    iptables -A syn_flood -m limit --limit 1/min -j NFLOG --nflog-prefix "SYNFLOOD: "
    iptables -A syn_flood -j DROP
fi

# ICMP PING
# macports_ping on: macports pings this server and the internet, rate limited
# For nmap scans, raise the limit to 100/second or use -Pn in nmap options
if [[ "$macports_ping" == on ]]; then
    iptables -A INPUT -i "$INTERFACESv4" -p icmp --icmp-type echo-request -m set --match-set macports src -m limit --limit 10/second -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p icmp --icmp-type echo-request -m set --match-set macports src -m limit --limit 10/second -j ACCEPT
fi
# Silence ICMP forward noise
iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p icmp -j DROP

# ------------------------------------------------------------------------------
# MAC PORTS
# ------------------------------------------------------------------------------

# Allow the configured ports for registered devices

# PROXYMON: WARNING PAGE HTTP FOR BANDATA
# https://github.com/maravento/proxymon
iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$proxymon_warn_port" -m set --match-set macports src -j ACCEPT
# SMBSTACK
# https://github.com/maravento/smbstack
iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$smbstack_web_port" -m set --match-set macports src -j ACCEPT

# COMMONS PORTS
# SMB / Microsoft-DS
if fw_on SMB on; then
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport 445 -m set --match-set macports src -j ACCEPT
fi
# PRINTERS & SCANNERS
# SNMP, WSD, IPP, raw printing and Epson ENPC for macports devices
if fw_on PRINTERS on; then
    iptables -A INPUT -i "$INTERFACESv4" -p udp -m multiport --dports 161,162,3289,3702,3910,3911 -m set --match-set macports src -j ACCEPT
    iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports 631,3910,3911,9100 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p udp -m multiport --dports 161,162,3289,3910,3911 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p tcp -m multiport --dports 3910,3911,9100 -m set --match-set macports src -j ACCEPT
fi
# STUN/TURN (WebRTC, Teams, Meet, Zoom)
if fw_on CALLS on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p udp -m multiport --dports 3478:3481 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p tcp -m multiport --dports 3478,5349 -m set --match-set macports src -j ACCEPT
    # Zoom media; without it Zoom falls back to TCP 8801 and then 443
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p udp --dport 8801:8810 -m set --match-set macports src -j ACCEPT
fi
# Google STUN
if fw_on CALLS on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p udp -m multiport --dports 19302:19309 -m set --match-set macports src -j ACCEPT
fi
# Email (SMTP, IMAP, POP3)
if fw_on EMAIL on; then
    iptables -A FORWARD -i "$INTERFACESv4" -p tcp -m multiport --dports 110,143,465,587,993,995 -m set --match-set macports src -j ACCEPT
fi
# Messaging & XMPP (Jabber, FCM)
if fw_on XMPP on; then
    iptables -A FORWARD -i "$INTERFACESv4" -p tcp -m multiport --dports 5222,5223,5228,5269 -m set --match-set macports src -j ACCEPT
fi
# WSD (Web Services Discovery) - TCP
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p tcp -m multiport --dports 5357,5358 -m set --match-set macports src -j ACCEPT
fi
# mDNS LAN (noise)
if fw_on BROADCAST on; then
    iptables -A INPUT -i "$INTERFACESv4" -d 224.0.0.251 -p udp --dport 5353 -j DROP
fi
# Drop local multicast (collaboration tools, discovery, etc.)
if fw_on BROADCAST on; then
    iptables -A INPUT -i "$INTERFACESv4" -d 239.255.0.0/16 -j DROP
fi
# mDNS / Bonjour / AirPrint
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -d 224.0.0.251 -p udp --dport 5353 -m set --match-set macports src -j ACCEPT
fi
# LLMNR (Name resolution between LAN devices when there is no DNS entry)
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -d 224.0.0.252 -p udp --dport 5355 -m set --match-set macports src -j ACCEPT
fi
# SSDP / UPnP
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -d 239.255.255.250 -p udp --dport 1900 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p udp --dport 5000 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -p udp -m multiport --dports 1900,5000 -m set --match-set macports src -j DROP
fi
# WSD (Device discovery on the LAN, used by printers and scanners)
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -d 239.255.255.250 -p udp --dport 3702 -m set --match-set macports src -j ACCEPT
fi
# Multimedia & Streaming
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p tcp -m multiport --dports 2869,8200 -m set --match-set macports src -j ACCEPT
fi
# IGMP (required for multicast group management)
if fw_on DISCOVERY on; then
    iptables -A FORWARD -i "$INTERFACESv4" -o "$INTERFACESv4" -p igmp -m set --match-set macports src -j ACCEPT
fi
# NTP (Time sync out to the internet)
if fw_on NTP on; then
    iptables -A FORWARD -i "$INTERFACESv4" -p udp --dport 123 -m set --match-set macports src -j ACCEPT
fi

# COMMONS PORTS (OPTIONAL)
# Windows Update Delivery Optimization WUDO
# Allow peer-to-peer update sharing within the local network.
# Block outbound WUDO traffic to WAN and direct connections to the firewall.
if fw_on WUDO on; then
    for proto_name in tcp udp; do
        iptables -A FORWARD -i "$INTERFACESv4" -p "$proto_name" --dport 7680 -s "$SERV_SUBNET/$netmask_int" -d "$SERV_SUBNET/$netmask_int" -m set --match-set macports src -j ACCEPT
    done
    for chain_name in INPUT FORWARD; do
        for proto_name in tcp udp; do
            iptables -A "$chain_name" -i "$INTERFACESv4" -p "$proto_name" --dport 7680 -m set --match-set macports src -j DROP
        done
    done
fi
# Generic Routing Encapsulation GRE: PROTOCOL 47
if fw_on BYPASS on; then
    for chain_name in INPUT FORWARD; do
        iptables -A "$chain_name" -i "$INTERFACESv4" -p 47 -m set --match-set macports src -j DROP
    done
fi
# Block Windows Mobile Hotspot Sharing
if fw_on WINDOWS on; then
    iptables -A FORWARD -i "$INTERFACESv4" -d 192.168.137.0/24 -m set --match-set macports src -j DROP
fi
# Block WS-Discovery Unicast to Server (Windows clients noise)
if fw_on WINDOWS on; then
    iptables -A INPUT -i "$INTERFACESv4" -p udp --sport 3702 -d "$SERVER_IP" -m set --match-set macports src -j DROP
fi
# KMS Windows (activation noise)
if fw_on KMS on; then
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport 1688 -m set --match-set macports src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p tcp --dport 1688 -m set --match-set macports src -j ACCEPT
fi
# Spotify LAN sync broadcast noise
if fw_on BROADCAST on; then
    iptables -A INPUT -i "$INTERFACESv4" -p udp --dport 57621 -m set --match-set macports src -j DROP
fi
# Cisco IP phones discovery noise
if fw_on BROADCAST on; then
    iptables -A INPUT -i "$INTERFACESv4" -p udp -m multiport --dports 2007,2008 -m set --match-set macports src -j DROP
fi
# Dropbox LAN sync broadcast noise
if fw_on BROADCAST on; then
    iptables -A INPUT -i "$INTERFACESv4" -p udp --dport 17500 -m set --match-set macports src -j DROP
fi

# ------------------------------------------------------------------------------
# MAC RULES
# ------------------------------------------------------------------------------

# Apply the remaining device classification rules

# MACLIMITED
# PAC on WPAD_PORT - DHCP option 252, HTTP 80 -> Squid intercept port
# squid_mode on: through Squid and PAC; off: direct 80/443
if [[ "$squid_mode" == on ]]; then
    iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set maclimited src -p tcp -m multiport --dports $WPAD_PORT,80,$squid_port -j ACCEPT
    iptables -t nat -A PREROUTING -i "$INTERFACESv4" -p tcp --dport 80 -m set --match-set maclimited src -j REDIRECT --to-port "$squid_intercept_port"
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$squid_intercept_port" -m set --match-set maclimited src -m conntrack --ctstate DNAT -j ACCEPT
    iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports $WPAD_PORT,$squid_port -m set --match-set maclimited src -j ACCEPT
else
    # Reset the PAC at once, so browsers fall back to DIRECT without waiting
    iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$WPAD_PORT" -m set --match-set maclimited src -j REJECT --reject-with tcp-reset
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p tcp -m multiport --dports 80,443 -m set --match-set maclimited src -j ACCEPT
    iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p udp --dport 443 -m set --match-set maclimited src -j ACCEPT
fi

# MACHOTSPOT
# PAC on WPAD_PORT - DHCP option 252, HTTP 80 -> Squid intercept port
if [[ "$UNIFI_HOTSPOT_ENABLED" == true ]]; then
    if [[ "$squid_mode" == on ]]; then
        iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set machotspot src -p tcp -m multiport --dports "$cpd_tcp_ports,$WPAD_PORT,80,$squid_port" -j ACCEPT
        iptables -t nat -A PREROUTING -i "$INTERFACESv4" -p tcp --dport 80 -m set --match-set machotspot src -j REDIRECT --to-port "$squid_intercept_port"
        iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$squid_intercept_port" -m set --match-set machotspot src -m conntrack --ctstate DNAT -j ACCEPT
        iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports "$cpd_tcp_ports,$WPAD_PORT,$squid_port" -m set --match-set machotspot src -j ACCEPT
    else
        iptables -t mangle -A PREROUTING -i "$INTERFACESv4" -m set --match-set machotspot src -p tcp -m multiport --dports "$cpd_tcp_ports" -j ACCEPT
        iptables -A INPUT -i "$INTERFACESv4" -p tcp -m multiport --dports "$cpd_tcp_ports" -m set --match-set machotspot src -j ACCEPT
        # Reset the PAC at once, so browsers fall back to DIRECT without waiting
        iptables -A INPUT -i "$INTERFACESv4" -p tcp --dport "$WPAD_PORT" -m set --match-set machotspot src -j REJECT --reject-with tcp-reset
        iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p tcp -m multiport --dports 80,443 -m set --match-set machotspot src -j ACCEPT
        iptables -A FORWARD -i "$INTERFACESv4" -o "$wan_iface" -p udp --dport 443 -m set --match-set machotspot src -j ACCEPT
    fi
fi

# Diagnostic only: warn about classified MACs with no static reservation in
# pydhcpd.conf -- MACCHECK drops their traffic regardless of classification.
for check_file in "$acl_mac_path"/mac-*.txt; do
    [ -f "$check_file" ] || continue
    while IFS=';' read -r client_status client_mac client_rest; do
        [ "$client_status" = "a" ] || continue
        [[ "$client_mac" =~ $UH_MAC ]] || continue
        client_mac_lc="${client_mac,,}"
        if ! grep -qxF "$client_mac_lc" <<< "$mac2ip_macs"; then
            log "WARNING: No fixed IP configured for $client_mac -alert"
        fi
    done < "$check_file"
done

# Diagnostic only: same check for the voucher list, kept as its own loop
# because uhm-auth.txt does not exist outside uhm.
if [[ "$UNIFI_HOTSPOT_ENABLED" == true && -f "$UHM_MACAUTH" ]]; then
    while IFS=';' read -r client_status client_mac client_rest; do
        [ "$client_status" = "a" ] || continue
        [[ "$client_mac" =~ $UH_MAC ]] || continue
        client_mac_lc="${client_mac,,}"
        if ! grep -qxF "$client_mac_lc" <<< "$mac2ip_macs"; then
            log "WARNING: No fixed IP configured for $client_mac -alert"
        fi
    done < "$UHM_MACAUTH"
fi

# ------------------------------------------------------------------------------
# FINAL DROP
# ------------------------------------------------------------------------------

# FINAL DROP
# Log rate-limited drop events and reject remaining input and forwarded traffic
# FINAL off is an emergency switch: LAN traffic is no longer dropped,
# which opens the firewall for every LAN device. WAN stays closed either way.
if fw_on FINAL on; then
    drop_in=()
else
    drop_in=(-i "$wan_iface")
fi
iptables -A INPUT "${drop_in[@]}" -m hashlimit --hashlimit-name input-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip,dstport -j NFLOG --nflog-prefix "FINAL-INPUT DROP: "
iptables -A INPUT "${drop_in[@]}" -j DROP
iptables -A FORWARD "${drop_in[@]}" -m hashlimit --hashlimit-name forward-drop --hashlimit-above 3/min --hashlimit-burst 3 --hashlimit-mode srcip,dstport -j NFLOG --nflog-prefix "FINAL-FORWARD DROP: "
iptables -A FORWARD "${drop_in[@]}" -j DROP

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "INFO: uhmiptables done"
