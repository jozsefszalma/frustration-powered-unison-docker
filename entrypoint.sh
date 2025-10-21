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
cp_ssh_user_name_explicit=false
if [[ -n ${CP_SSH_USER_NAME+x} ]]; then
    cp_ssh_user_name_explicit=true
fi

USER_UID=${USER_UID:-}
USER_GID=${USER_GID:-}
SSH_USER_NAME=${SSH_USER_NAME:-}
CP_SSH_USER_NAME=${CP_SSH_USER_NAME:-}
CP_USER_ID=${CP_USER_ID:-}

log() {
    echo "[$(date --iso-8601=seconds)] $*"
}

if [[ -n "$CP_USER_ID" && -z "$CP_SSH_USER_NAME" ]]; then
    log "WARNING: CP_USER_ID is deprecated; use CP_SSH_USER_NAME instead."
    CP_SSH_USER_NAME="$CP_USER_ID"
    cp_ssh_user_name_explicit=true
fi
PREFER_PATH=${PREFER_PATH:-}
SSH_PASSWORD=${SSH_PASSWORD:-}
CP_SSH_PASSWORD=${CP_SSH_PASSWORD:-}
EFFECTIVE_USER=root
EFFECTIVE_GROUP=root
EFFECTIVE_HOME=/root

if [[ -z "$USER_UID" && -z "$USER_GID" && "$CP_SSH_USER_NAME" == "unison" && $cp_ssh_user_name_explicit == false ]]; then
    CP_SSH_USER_NAME=""
fi

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

setup_effective_identity() {
    EFFECTIVE_USER=root
    EFFECTIVE_GROUP=root
    EFFECTIVE_HOME=/root

    if [[ -n "$USER_UID" || -n "$USER_GID" ]]; then
        if [[ -z "$USER_UID" || -z "$USER_GID" ]]; then
            log "ERROR: USER_UID and USER_GID must be provided together."
            exit 1
        fi

        if [[ ! "$USER_UID" =~ ^[0-9]+$ ]]; then
            log "ERROR: USER_UID must be a non-negative integer."
            exit 1
        fi

        if [[ ! "$USER_GID" =~ ^[0-9]+$ ]]; then
            log "ERROR: USER_GID must be a non-negative integer."
            exit 1
        fi

        local desired_home
        if [[ -n "$UNISON_ARCHIVE_PATH" ]]; then
            desired_home="$UNISON_ARCHIVE_PATH"
        else
            desired_home="/home/unison"
        fi

        ensure_path "$desired_home"

        local group_name
        local group_entry
        if group_entry="$(getent group "$USER_GID")"; then
            group_name="${group_entry%%:*}"
            log "Reusing existing group $group_name (GID $USER_GID)"
        else
            group_name="unison"
            if getent group "$group_name" >/dev/null; then
                group_name="unison-$USER_GID"
            fi
            log "Creating group $group_name (GID $USER_GID)"
            groupadd --gid "$USER_GID" "$group_name"
        fi

        local user_entry
        local user_name=""
        local requested_user_name
        if [[ -n "$SSH_USER_NAME" ]]; then
            requested_user_name="$SSH_USER_NAME"
        else
            requested_user_name="unison"
        fi
        if user_entry="$(getent passwd "$USER_UID")"; then
            user_name="${user_entry%%:*}"
            log "Reusing existing user $user_name (UID $USER_UID)"
            usermod --gid "$group_name" "$user_name"
            usermod --home "$desired_home" "$user_name"
            usermod --shell /bin/bash "$user_name"
            if [[ -n "$SSH_USER_NAME" && "$SSH_USER_NAME" != "$user_name" ]]; then
                log "WARNING: Ignoring SSH_USER_NAME=$SSH_USER_NAME because UID $USER_UID already belongs to $user_name"
            fi
        else
            if [[ -z "$requested_user_name" ]]; then
                log "ERROR: SSH_USER_NAME must be set when providing USER_UID/USER_GID and no existing user is found."
                exit 1
            fi
            if getent passwd "$requested_user_name" >/dev/null; then
                log "ERROR: Requested SSH user $requested_user_name already exists with a different UID."
                exit 1
            fi
            user_name="$requested_user_name"
            log "Creating user $user_name (UID $USER_UID, GID $USER_GID)"
            useradd --uid "$USER_UID" --gid "$group_name" --home-dir "$desired_home" --shell /bin/bash --no-create-home "$user_name"
        fi

        chown "$user_name:$group_name" "$desired_home"

        EFFECTIVE_USER="$user_name"
        EFFECTIVE_GROUP="$group_name"
        EFFECTIVE_HOME="$desired_home"
    elif [[ -n "$UNISON_ARCHIVE_PATH" ]]; then
        ensure_path "$UNISON_ARCHIVE_PATH"
        EFFECTIVE_HOME="$UNISON_ARCHIVE_PATH"
    elif [[ -n "$SSH_USER_NAME" && "$SSH_USER_NAME" != "unison" ]]; then
        log "WARNING: Ignoring SSH_USER_NAME=$SSH_USER_NAME because container is running as root."
    fi

    ensure_path "$EFFECTIVE_HOME/.unison"
    if [[ "$EFFECTIVE_USER" != "root" ]]; then
        chown "$EFFECTIVE_USER:$EFFECTIVE_GROUP" "$EFFECTIVE_HOME"
        chown "$EFFECTIVE_USER:$EFFECTIVE_GROUP" "$EFFECTIVE_HOME/.unison"
    fi
    export HOME="$EFFECTIVE_HOME"

    local effective_uid
    local effective_gid
    effective_uid="$(id -u "$EFFECTIVE_USER")"
    effective_gid="$(id -g "$EFFECTIVE_USER")"
    log "Configured Unison home $EFFECTIVE_HOME for $EFFECTIVE_USER (UID $effective_uid, GID $effective_gid)"
}

run_as_effective_user() {
    if [[ "$EFFECTIVE_USER" == "root" ]]; then
        HOME="$EFFECTIVE_HOME" "$@"
    else
        runuser -u "$EFFECTIVE_USER" -- env HOME="$EFFECTIVE_HOME" "$@"
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
setup_effective_identity

case "${ROLE,,}" in
    server)
        require_var "SSH_PASSWORD" "$SSH_PASSWORD"
        if ! command -v sshd >/dev/null; then
            log "ERROR: OpenSSH server is not available in the container image."
            exit 1
        fi

        sshd_opts=(-D -e -p "$UNISON_PORT" -o "PasswordAuthentication yes" -o "UseDNS no")

        if [[ "$EFFECTIVE_USER" == "root" ]]; then
            log "Configuring root account password"
            echo "root:$SSH_PASSWORD" | chpasswd
            sshd_opts+=(-o "PermitRootLogin yes")
        else
            log "Skipping root password configuration because effective user is $EFFECTIVE_USER"
            sshd_opts+=(-o "PermitRootLogin no")
            log "Configuring password for $EFFECTIVE_USER"
            echo "$EFFECTIVE_USER:$SSH_PASSWORD" | chpasswd
        fi

        mkdir -p /run/sshd
        ssh-keygen -A

        sshd_bin="$(command -v sshd)"

        log "Starting OpenSSH server on port $UNISON_PORT for user $EFFECTIVE_USER"
        exec "$sshd_bin" "${sshd_opts[@]}"
        ;;
    client)
        require_var "COUNTERPARTY_IP" "$COUNTERPARTY_IP"
        require_var "CP_SSH_PASSWORD" "$CP_SSH_PASSWORD"
        remote_user="$EFFECTIVE_USER"
        if [[ -n "$CP_SSH_USER_NAME" ]]; then
            remote_user="$CP_SSH_USER_NAME"
        fi
        repeat_args=()
        if ! mapfile -t repeat_args < <(build_repeat_args "$REPEAT_MODE" "$REPEAT_INTERVAL"); then
            repeat_args=()
        fi
        remote_clean="${REMOTE_PATH#/}"
        if [[ -z "$remote_clean" ]]; then
            log "ERROR: REMOTE_PATH must not be empty."
            exit 1
        fi
        remote_uri="ssh://$remote_user@${COUNTERPARTY_IP}//${remote_clean}"
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
            -perms 0
            -dontchmod
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
            if run_as_effective_user unison "${unison_args[@]}"; then
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
