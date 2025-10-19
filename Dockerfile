FROM archlinux:latest

# Arch is rolling: update the base image immediately, then install needed bits.
# Ref: Arch official image notes about running pacman -Syu in containers.
# https://hub.docker.com/_/archlinux
RUN pacman -Syu --noconfirm \
 && pacman -S --noconfirm --needed \
      ca-certificates \
      openssh \
      sshpass \
      shadow \
      unison \
      curl \
 && pacman -Scc --noconfirm

## Vendor Tini (arch-specific asset) and verify checksum
ENV TINI_VERSION=v0.19.0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -euo pipefail; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  tini_arch=amd64 ;; \
      aarch64) tini_arch=arm64 ;; \
      armv7l|armv7) tini_arch=armhf ;; \
      ppc64le) tini_arch=ppc64le ;; \
      s390x)   tini_arch=s390x ;; \
      *) echo "Unsupported arch: ${arch}"; exit 1 ;; \
    esac; \
    cd /usr/local/bin; \
    curl -fsSLO "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${tini_arch}"; \
    curl -fsSLO "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${tini_arch}.sha256sum"; \
    sha256sum -c "tini-${tini_arch}.sha256sum"; \
    mv "tini-${tini_arch}" tini; \
    chmod +x tini; \
    rm "tini-${tini_arch}.sha256sum"

# Create a wrapper script for sshpass so Unison can call it as a single command.
RUN <<'EOF_SCRIPT' cat > /usr/local/bin/ssh-with-pass.sh
#!/bin/sh
# This wrapper executes ssh via sshpass, passing along all arguments.
# The SSHPASS environment variable must be set.
exec /usr/bin/sshpass -e /usr/bin/ssh "$@"
EOF_SCRIPT

# Make the wrapper script executable.
RUN chmod +x /usr/local/bin/ssh-with-pass.sh

WORKDIR /sync

ENV ROLE=client \
    LOCAL_PATH=/sync \
    REMOTE_PATH=/sync \
    COUNTERPARTY_IP="" \
    UNISON_PORT=50000 \
    REPEAT_MODE="watch" \
    UNISON_EXTRA_ARGS="-ignore 'Name @eaDir' -ignore 'Name .sync'" \
    UNISON_ARCHIVE_PATH="" \
    USER_UID="" \
    USER_GID="" \
    PREFER_PATH="newer" \
    SSH_PASSWORD="" \
    CP_SSH_PASSWORD="" \
    CP_USER_ID="" \
    RECONNECT_DELAY=300


COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Use vendored tini (static) as PID1
ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
