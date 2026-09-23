#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmbk - configuration backup for uhm
#
# DESCRIPTION:
# Creates one compressed archive containing the project installation and
# relevant system configuration. Paths that do not exist are skipped with
# a notice.
#
# Run it by hand before applying changes, or let the monthly cron entry
# do it. Restore by unzipping the archive over /.
#
# USAGE:
# sudo bash uhmbk.sh            Create a backup now
# sudo bash uhmbk.sh install    Register the @monthly cron entry
# sudo bash uhmbk.sh uninstall  Remove the cron entry (keeps archives)
#
# OUTPUT:
# /etc/bak/uhm/uhmbk_<YYYYMMDD_HHMM>.zip
#
#
# EXIT CODES:
# 0 - Archive created
# 1 - Not root, already running, missing dependency, nothing to back up,
#     or the archive could not be written
#
# LOG: /var/log/uhm.log (shared with the rest of the project)
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# path for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# logging
log_file="/var/log/uhm.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

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
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# dependencies
for dep_pkg in zip coreutils util-linux cron; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

backup_dir="/etc/bak/uhm"
backup_zip="${backup_dir}/uhmbk_$(date +%Y%m%d_%H%M).zip"
installed_path="/etc/uhm/tools/$(basename "$0")"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Monthly is the floor, not a recommendation: it exists so an untouched
# system still has a recent copy. Run it by hand before any change.
# CRON_D
# Add or replace one line in the project's single cron.d file
cron_d_set() {
    local match="$1" line="$2"
    local cron_file="/etc/cron.d/uhm"
    local cron_tmp

    cron_tmp=$(mktemp)
    [ -f "$cron_file" ] && { grep -vF "$match" "$cron_file" > "$cron_tmp" || true; }
    [ -n "$line" ] && printf '%s\n' "$line" >> "$cron_tmp"
    if [ -s "$cron_tmp" ]; then
        install -m 644 -o root -g root "$cron_tmp" "$cron_file"
    else
        rm -f "$cron_file"
    fi
    rm -f "$cron_tmp"
}

register_cron() {
    # Deploy self first: the cron entry must point at a path that exists,
    # whether this ran from the repo or from its final location.
    local script_path
    script_path="$(readlink -f "$0")"
    if [ "$script_path" != "$installed_path" ]; then
        if ! mkdir -p "$(dirname "$installed_path")"; then
            log "ERROR: cannot create $(dirname "$installed_path") -- abort"
            exit 1
        fi
        install -m 755 -o root -g root "$script_path" "$installed_path"
        log "INFO: deployed to $installed_path"
    fi

    cron_d_set "$installed_path" "@monthly root $installed_path"
    log "INFO: cron entry registered, runs @monthly"
    log "INFO: $installed_path"

    # legacy entry in root's crontab, from versions before /etc/cron.d
    crontab -l 2>/dev/null | { grep -vF "$installed_path" || true; } | crontab - 2>/dev/null || true
}

deregister_cron() {
    cron_d_set "$installed_path" ""
    log "INFO: cron entry removed, archives kept"

    # legacy entry in root's crontab, from versions before /etc/cron.d
    crontab -l 2>/dev/null | { grep -vF "$installed_path" || true; } | crontab - 2>/dev/null || true
}

case "${1:-}" in
    install)
        register_cron
        exit 0
        ;;
    uninstall)
        deregister_cron
        exit 0
        ;;
    "")
        ;;
    *)
        log "ERROR: unknown action '$1' -- abort"
        log "ERROR: use no argument, 'install' or 'uninstall'"
        exit 1
        ;;
esac

# Start
log "uhmbk start..."

# ------------------------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------------------------

if ! mkdir -p "$backup_dir"; then
    log "ERROR: cannot create $backup_dir -- abort"
    exit 1
fi

# Project files and relevant system configuration are listed explicitly
# so the project state can be restored.
backup_list=()
for backup_item in \
    /etc/uhm \
    /etc/systemd/system/uhmd.service \
    /etc/systemd/system/uhmalert.service \
    /etc/apache2/sites-available/uhmweb.conf \
    /etc/sudoers.d/uhmweb \
    /etc/logrotate.d/uhm \
    /etc/cron.d/uhm \
    /var/www/uhm
do
    if [ -e "$backup_item" ]; then
        backup_list+=("$backup_item")
    else
        log "INFO: $backup_item not present -- skip"
    fi
done

if (( ${#backup_list[@]} == 0 )); then
    log "ERROR: none of the expected paths exist"
    log "ERROR: is uhm installed? -- abort"
    exit 1
fi

if zip -r -q "$backup_zip" "${backup_list[@]}"; then
    chmod 600 "$backup_zip"
    log "INFO: backup written to $backup_zip"

    # keep only the last 3
    old_backups=("$backup_dir"/uhmbk_*.zip)
    if (( ${#old_backups[@]} > 3 )); then
        printf '%s\n' "${old_backups[@]}" | sort | head -n -3 | xargs -r rm -f
    fi
else
    rm -f "$backup_zip"
    log "ERROR: cannot write the archive"
    log "ERROR: $backup_zip"
    log "ERROR: check free space and permissions -- abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "uhmbk done at: $(date '+%Y-%m-%d %H:%M:%S')"
