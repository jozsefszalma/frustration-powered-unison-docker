#!/usr/bin/env bash
set -euo pipefail

ROLE=${ROLE:-client}
LOCAL_PATH=${LOCAL_PATH:-/sync}
REMOTE_PATH=${REMOTE_PATH:-/sync}
COUNTERPARTY_IP=${COUNTERPARTY_IP:-}
UNISON_PORT=${UNISON_PORT:-50000}
REPEAT_MODE=${REPEAT_MODE:-watch}
REPEAT_INTERVAL=${REPEAT_INTERVAL:-300}
UNISON_EXTRA_ARGS=${UNISON_EXTRA_ARGS:-}
UNISON_ARCHIVE_PATH=${UNISON_ARCHIVE_PATH:-}

log() {
    echo "[$(date --iso-8601=seconds)] $*"
}
PREFER_PATH=${PREFER_PATH:-}
SSH_PASSWORD=${SSH_PASSWORD:-}
CP_SSH_PASSWORD=${CP_SSH_PASSWORD:-}

extra_args=()
if [[ -n "$UNISON_EXTRA_ARGS" ]]; then
    set -f
    if ! eval "extra_args=( $UNISON_EXTRA_ARGS )"; then
        set +f
        log "ERROR: Failed to parse UNISON_EXTRA_ARGS; check your quoting."
        exit 1
    fi
    set +f
fi

prefer_args=()
if [[ -n "$PREFER_PATH" ]]; then
    prefer_args=(-prefer "$PREFER_PATH")
fi

configure_unison_archive() {
    local target="$1"
    local default_path="/root/.unison"

    if [[ -z "$target" ]]; then
        return
    fi

    if [[ "$target" == "$default_path" ]]; then
        log "UNISON_ARCHIVE_PATH points to the default location; using in-container archive."
        return
    fi

    ensure_path "$target"

    if [[ ! -d "$target" ]]; then
        log "ERROR: UNISON_ARCHIVE_PATH must reference a directory."
        exit 1
    fi

    if [[ -e "$default_path" && ! -L "$default_path" ]]; then
        shopt -s dotglob nullglob
        local contents=("$default_path"/*)
        if (( ${#contents[@]} > 0 )); then
            log "Migrating existing Unison archive contents to $target"
            mv "${contents[@]}" "$target/"
        fi
        shopt -u dotglob nullglob
        rmdir "$default_path"
    fi

    ln -sfn "$target" "$default_path"
    log "Using persistent Unison archive directory at $target"
}

require_var() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        log "ERROR: Environment variable $name must be set."
        exit 1
    fi
}

ensure_path() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        log "Creating missing directory $path"
        mkdir -p "$path"
    fi
}

build_repeat_args() {
    local mode="${1,,}"
    local interval="$2"
    case "$mode" in
        watch)
            printf '%s\n' "-repeat" "watch"
            ;;
        none|manual)
            ;;
        *)
            if [[ "$mode" =~ ^[0-9]+$ ]]; then
                printf '%s\n' "-repeat" "$mode"
            elif [[ "$interval" =~ ^[0-9]+$ ]]; then
                printf '%s\n' "-repeat" "$interval"
            else
                log "ERROR: REPEAT_MODE must be 'watch', 'manual', or an integer number of seconds."
                exit 1
            fi
            ;;
    esac
}

ensure_path "$LOCAL_PATH"
configure_unison_archive "$UNISON_ARCHIVE_PATH"

case "${ROLE,,}" in
    server)
        require_var "SSH_PASSWORD" "$SSH_PASSWORD"
        if ! command -v sshd >/dev/null; then
            log "ERROR: OpenSSH server is not available in the container image."
            exit 1
        fi

        log "Configuring root account password"
        echo "root:$SSH_PASSWORD" | chpasswd

        mkdir -p /run/sshd
        ssh-keygen -A

        sshd_bin="$(command -v sshd)"
        sshd_opts=(-D -e -p "$UNISON_PORT" -o "PasswordAuthentication yes" -o "UseDNS no" -o "PermitRootLogin yes")

        log "Starting OpenSSH server on port $UNISON_PORT for root"
        exec "$sshd_bin" "${sshd_opts[@]}"
        ;;
    client)
        require_var "COUNTERPARTY_IP" "$COUNTERPARTY_IP"
        require_var "CP_SSH_PASSWORD" "$CP_SSH_PASSWORD"
        repeat_args=()
        if ! mapfile -t repeat_args < <(build_repeat_args "$REPEAT_MODE" "$REPEAT_INTERVAL"); then
            repeat_args=()
        fi
        remote_clean="${REMOTE_PATH#/}"
        if [[ -z "$remote_clean" ]]; then
            log "ERROR: REMOTE_PATH must not be empty."
            exit 1
        fi
        remote_uri="ssh://root@${COUNTERPARTY_IP}//${remote_clean}"
        ssh_args="-p ${UNISON_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        export SSHPASS="$CP_SSH_PASSWORD"
        RECONNECT_DELAY=${RECONNECT_DELAY:-300}
        if [[ ! "$RECONNECT_DELAY" =~ ^[0-9]+$ ]]; then
            log "ERROR: RECONNECT_DELAY must be a non-negative integer."
            exit 1
        fi

        unison_args=(
            "$LOCAL_PATH"
            "$remote_uri"
            -auto -batch -confirmbigdel=false
            -sshcmd /usr/local/bin/ssh-with-pass.sh
            -sshargs "$ssh_args"
        )
        unison_args+=("${prefer_args[@]}")
        unison_args+=("${repeat_args[@]}")
        unison_args+=("${extra_args[@]}")

        log "Starting Unison client between $LOCAL_PATH and $remote_uri via SSH on port $UNISON_PORT"
        formatted_cmd="unison"
        if (( ${#unison_args[@]} > 0 )); then
            for arg in "${unison_args[@]}"; do
                printf -v formatted_cmd '%s %q' "$formatted_cmd" "$arg"
            done
        fi
        log "Effective Unison command: $formatted_cmd"

        attempt=0
        while true; do
            attempt=$((attempt + 1))
            log "Launching Unison (attempt $attempt)"
            if unison "${unison_args[@]}"; then
                log "Unison exited cleanly; stopping client loop."
                break
            else
                exit_code=$?
                log "Unison exited with status $exit_code; sleeping for ${RECONNECT_DELAY}s before retrying."
                sleep "$RECONNECT_DELAY"
            fi
        done

        exit 0
        ;;
    *)
        log "ERROR: ROLE must be either 'server' or 'client'"
        exit 1
        ;;
esac
