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

# Recover an interrupted expiry publication while holding the UHM cycle lock.
recover_uhm_expiry() {
    local auth="$1" queue="$2" recovery="$1.expiry"
    [[ -e "$recovery" || -L "$recovery" ]] || return 0
    [[ -d "$recovery" && ! -L "$recovery" && -n "$queue" ]] || return 1

    if [[ -f "$queue.expiry-next" && -f "$recovery/auth.before" ]]; then
        mv -fT -- "$recovery/auth.before" "$auth" || return 1
    fi
    rm -f -- "$queue.expiry-next" "$queue.expiry-stage" \
        "$recovery/auth.before" "$recovery/auth.next" &&
        rmdir -- "$recovery"
}

uhm_expiry_recovery_message() {
    if [[ -d "$1" ]]; then
        printf '%s\n' 'uhm-auth.txt is a directory; move it away to resume'
    else
        printf '%s\n' 'cannot recover expired authorizations'
    fi
}
