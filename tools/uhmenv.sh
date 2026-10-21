#!/bin/bash
# maravento.com
#
################################################################################
#
# uhmenv -- shared Bash configuration reader
# FILE: tools/uhmenv.sh
#
# USAGE:
# Loaded by callers with source. Not a standalone command or cron job.
#
################################################################################

load_uhm_env() {
    local conf_file="$1" conf_keys="$2" env_key env_value env_line env_count=0
    local conf_errors="${3:-line}"
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
        env_count=$((env_count + 1))
        [[ "$env_line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        if [[ ! "$env_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
           || [[ "$env_value" == [[:space:]\"\']* ]] \
           || [[ "$env_value" == *[[:space:]\"\'] ]]; then
            case "$conf_errors" in
                json)
                    env_key="${env_key%%[[:space:]]*}"
                    json_error "$env_key malformed in $(basename "$conf_file")"
                    ;;
                *)
                    if [[ ! "$env_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                        log "ERROR: $(basename "$conf_file"):$env_count not key=value -abort"
                    else
                        log "ERROR: $(basename "$conf_file"):$env_count space or quote in value -abort"
                    fi
                    ;;
            esac
            exit 1
        fi
        case " $conf_keys " in
            *" $env_key "*)
                printf -v "$env_key" '%s' "$env_value"
                ;;
        esac
    done < "$conf_file"
}
