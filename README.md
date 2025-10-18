# Frustration-Powered Unison Sync Containers

## Introduction
This repo was born out of the need 
- to keep two NAS appliances in bidirectional sync even though they live on different networks
- to be able to migrate away from the Synology-native app ecosystem, as I have a problem with them e.g. see [Synology Lost the Plot with Hard Drive Locking Move](https://www.servethehome.com/synology-lost-the-plot-with-hard-drive-locking-move/) and [Synology Removes Graphics Drivers and HEVC & H.264 HW Transcoding Support](https://www.geeky-gadgets.com/synology-nas-hevc-support-removal-2025/)

Both NAS devices are already connected through Tailscale, but they run different operating systems, which makes it difficult to find a synchronisation solution that is supported on both sides. Rather than relying on an assortment of unofficial Unison Docker images - and because Unison is not available natively on Synology - I created this repository so both NASes can run the exact same container image.

This project packages Unison, OpenSSH, and a small helper entrypoint so that two remote hosts can exchange files securely over Tailscale. You can run the image unchanged on any Linux host that supports Docker or containerd.

## Highlights
- **Same Unison build everywhere** – The Dockerfile installs Unison on the latest Arch Linux, giving both ends of the connection an identical protocol implementation.
- **SSH transport baked in** – A bundled OpenSSH server and client allow Unison to connect over Tailscale without exposing services to the public Internet.
- **Flexible scheduling** – Watch for filesystem changes, poll at a fixed interval, or run one-off synchronisations.
- **Single image for mixed environments** – Run one container on each NAS, even if they use very different host operating systems.
- **Optional persistent archives** – Keep Unison's archive database on a host path so reconnects stay smooth across container upgrades.

## Repository Layout
- `Dockerfile` – Builds the Arch Linux-based image with Unison, OpenSSH, sshpass, and tini.
- `entrypoint.sh` – Configures either the Unison server or client role depending on environment variables.
- `README.md` – Public documentation, including build and deployment guides.

## Prerequisites
1. Both NAS devices are online in your Tailscale network.
   - In the examples we will call them **NAS1** and **NAS2**.
   - If NAS1 happens to be a Synology system, install the **Container Manager** (DSM 7.2+) or **Docker** (DSM 6.x/7.0) package.
   - If NAS2 is an Unraid system, enable Docker from **Settings → Docker**.
2. Docker or containerd is installed on each host.
3. The directories you intend to synchronise are available on both hosts (bind-mount them into the container):
   - Example for NAS1 (Synology): `/volume1/share`
   - Example for NAS2 (Unraid): `/mnt/user/share`
4. Decide which host will act as the **Unison server** (listens for connections) and which will act as the **client** (initiates synchronisation). Only one side should run in server mode.
5. Optionally choose a Docker registry (e.g. `<your dockerhub username>/tailscale-unison`) if you plan to publish the image.
6. Ensure Tailscale is already running on the host OS. The container reuses the host's Tailscale network stack and does not start its own Tailscale instance.

## Build the Image 
You can build and publish the image from any machine with Docker BuildKit support. Replace `<your dockerhub username>` with your account name if you intend to push to Docker Hub.

```bash
git clone https://github.com/jozsefszalma/frustration-powered-unison-docker.git
cd frustration-powered-unison-docker
# Ensure Docker BuildKit is enabled
docker buildx create --use --name unison-builder 
docker buildx use unison-builder
# Build and push to Docker Hub
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t <your dockerhub username>/tailscale-unison:latest --push . 
```

> **Note:** On Windows, run the commands inside a WSL2 shell or a PowerShell session with Docker Desktop installed.

## Configuration
The container is configured entirely through environment variables; you do not need to rebuild the image when parameters change.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `ROLE` | No | `client` | Set to `server` on the host that listens for incoming Unison connections. Use `client` on the initiating side. |
| `LOCAL_PATH` | No | `/sync` | Absolute path inside the container where the local share is mounted. Bind your host share to this path. |
| `REMOTE_PATH` | No | `/sync` | Path on the remote container that should be synchronised. Only used by the client. |
| `COUNTERPARTY_IP` | Yes (client) | — | The **Tailscale IP** of the remote host. Required on the client side to reach the server. Optional on the server for reference. |
| `UNISON_PORT` | No | `50000` | TCP port used for SSH between the two containers. Must match on both sides. |
| `SSH_PASSWORD` | Yes (server) | — | Password for the root account inside the container. Required on the server so the client can authenticate. |
| `CP_SSH_PASSWORD` | Yes (client) | — | Password to use when connecting to the remote container. Must match the remote container's `SSH_PASSWORD`. |
| `REPEAT_MODE` | No | `watch` | Synchronisation schedule: `watch` (inotify-based), any integer number of seconds (e.g. `300`), or `manual` to run once. |
| `REPEAT_INTERVAL` | No | `300` | Fallback interval in seconds when `REPEAT_MODE` is not numeric. Ignored for `watch` and `manual`. |
| `PREFER_PATH` | No | — | Optional argument passed to `unison -prefer` (e.g. `newer`, `/sync`). Leave unset to accept Unison’s default conflict handling. |
| `UNISON_EXTRA_ARGS` | No | — | Additional flags appended to the Unison command on both server and client. Quoted values (e.g. `-ignore "Name *.tmp"`) are now parsed correctly, but the string is evaluated by the entrypoint and should be treated as trusted input. |
| `UNISON_ARCHIVE_PATH` | No | — | Absolute path to persist Unison’s archive database outside the container (e.g. `/config/unison`). When set, `/root/.unison` is symlinked to this directory. |
| `RECONNECT_DELAY` | No | `300` | Seconds to wait before retrying the Unison connection after an error. Applies to the client role and retries indefinitely. |

Both containers run as the `root` user. SSH connections therefore always target the `root` account; only the password needs to be provided.

## Networking Guidance
- Run the container in **host network** mode so inbound connections retain the remote Tailscale IP, which simplifies firewall rules.
- Expose or map `UNISON_PORT` if you cannot use host networking, and apply equivalent host-level firewall rules.
- Ensure the selected port is allowed by any system-level firewall running on NAS1, NAS2, or other hosts you deploy on.
- If you must map the SSH port instead of using host networking, map the container's `UNISON_PORT` (default `50000`) to a free port on the host. Update the client container's `UNISON_PORT` to match the port you exposed.

### Lock down the host firewall
Restrict access to the Unison SSH port on each Docker host so only the remote Tailscale peer can connect.

**NAS1 (Synology example)**

1. Open **Control Panel → Security → Firewall** and ensure the firewall is enabled.
2. Select the relevant network interface (typically your primary LAN interface) and click **Edit Rules**.
3. Create a new rule:
   - **Source IP**: *Custom* → add the remote Tailscale IP address of NAS2.
   - **Ports**: *Custom* → TCP → *Single port* → `50000`.
   - **Action**: *Allow*.
4. Move the rule near the top so it is evaluated before broader deny rules.
5. Add a second rule below it that blocks the same port for **All** source IPs.
6. Apply the changes. DSM may warn that active connections can be reset—acknowledge to continue.

**NAS2 (Unraid example or any other Linux host)**

```bash
iptables -A INPUT -p tcp --dport 50000 -s <remote_tailscale_ip> -j ACCEPT
iptables -A INPUT -p tcp --dport 50000 -j DROP
```

Persist the rules using your distribution’s tooling (e.g. `iptables-save` on Unraid, or translate them to `nftables`). Adjust the port number if you changed `UNISON_PORT`.

## Running the Containers
1. Pick which side will act as `ROLE=server` and which will be `ROLE=client`.
2. Bind-mount the desired directory on each NAS into the container at `/sync` (or match `LOCAL_PATH`).
3. Configure environment variables according to the table above.
4. Start the containers. The server exposes an OpenSSH daemon on `UNISON_PORT`, and the client runs Unison to connect over SSH.

### Example: NAS1 (Synology) as the Unison server
1. Open **Container Manager → Project → Create → Single Container** (or **Docker → Image → Launch** on older DSM releases).
2. Choose the image `<your dockerhub username>/tailscale-unison:latest` (or the tag you built) and open **Advanced Settings**.
3. Networking: enable **Use the same network as Docker host** (host network mode).
4. Volume: map `/volume1/share` (host) to `/sync` (container).
5. Environment variables:
   - `ROLE=server`
   - `SSH_PASSWORD=<strong password>`
   - Optional: `UNISON_PORT=50000`
6. Start the container. The logs should show the OpenSSH server listening on the chosen port.

### Example: NAS2 (Unraid) as the Unison client
1. Open the Unraid web UI → **Docker → Add Container → Template: Custom**.
2. Set the repository to `<your dockerhub username>/tailscale-unison:latest`.
3. Enable **Host access to custom networks** if required (Settings → Docker) and configure the container to use **Host** network mode.
4. In **Volume Mappings**, add the Unraid share:
   - Container Path: `/sync`
   - Host Path: `/mnt/user/share`
5. Add environment variables:
   - `ROLE=client`
   - `COUNTERPARTY_IP=<Tailscale IP of NAS1>`
   - `REMOTE_PATH=/sync`
   - `UNISON_PORT=50000`
   - `CP_SSH_PASSWORD=<value of SSH_PASSWORD on NAS1>`
   - Optional scheduling variables such as `REPEAT_MODE=300` to sync every five minutes instead of watching.
6. Apply/start the container. Monitor the logs for successful SSH connections and Unison activity.

> These examples illustrate Synology and Unraid deployments, but any pair of hosts that meet the prerequisites can act as NAS1 and NAS2.

### Manual `docker run` quick start
If you prefer the command line, the following example runs NAS1 as the server and NAS2 as the client. Update the bind mounts, passwords, and Tailscale IPs for your environment.

```bash
# NAS1 (server)
docker run -d \
  --name tailscale-unison-server \
  --network host \
  -e ROLE=server \
  -e SSH_PASSWORD="change-me" \
  -e UNISON_PORT=50000 \
  -v /volume1/share:/sync \
  <your dockerhub username>/tailscale-unison:latest

# NAS2 (client)
docker run -d \
  --name tailscale-unison-client \
  --network host \
  -e ROLE=client \
  -e COUNTERPARTY_IP=100.x.y.z \
  -e CP_SSH_PASSWORD="change-me" \
  -e UNISON_PORT=50000 \
  -e REMOTE_PATH=/sync \
  -v /mnt/user/share:/sync \
  <your dockerhub username>/tailscale-unison:latest
```

### Persist the Unison archive database
By default Unison stores its archive files under `/root/.unison` inside the container. To keep this database across container upgrades, mount a host directory and point `UNISON_ARCHIVE_PATH` at it:

```bash
-v /volume1/unison-archive:/unison-archive \
-e UNISON_ARCHIVE_PATH=/unison-archive
```

The entrypoint will migrate existing archives on first start and symlink `/root/.unison` to the provided path.

## Verifying the Synchronisation
1. Confirm that the server log shows the OpenSSH server listening on `UNISON_PORT`.
2. Check the client log for successful SSH connection messages and the absence of errors.
3. Create a test file on either share and ensure it appears on the other side. With `REPEAT_MODE=watch`, synchronisation occurs on change. With numeric repeat mode, Unison runs every _n_ seconds.
4. Run only a single instance of the container per side to avoid overlapping synchronisations.

## Maintenance Tips
- Update container environment variables and restart if you change any settings; rebuilding is unnecessary.
- Use `UNISON_EXTRA_ARGS` to tune behaviour (e.g. ignore patterns, owner/group preservation).
- Keep Tailscale updated on each NAS; the container relies on the host Tailscale interface for connectivity. The container itself does **not** start a Tailscale daemon.
- Persist the Unison archive by bind-mounting a directory and setting `UNISON_ARCHIVE_PATH` so reconnects reuse the existing database.
- Monitor the container logs in your platform UI or via Docker (e.g. `docker logs tailscale-unison-client`). Consider configuring a log driver if you need persistent logs.

## Troubleshooting
| Symptom | Possible Cause | Resolution |
| --- | --- | --- |
| Client reports `Connection refused` | Server not running or port blocked | Ensure the server container is running in host mode and that the port is open. |
| Client log shows `Permission denied` errors | Wrong SSH credentials or the container user lacks access to the share | Verify `CP_SSH_PASSWORD` matches the server settings and adjust share permissions as needed. |
| Synchronisation loops endlessly | Conflicting changes | Review the Unison logs, adjust `PREFER_PATH`, or add ignore rules via `UNISON_EXTRA_ARGS`. |
| Firewall blocks all connections | Host firewall missing an allow rule for the remote Tailscale IP | Update the host firewall rule to permit the remote Tailscale IP on `UNISON_PORT`. |
| Synology startup fails with `/usr/bin/env: 'bash\r'` | Windows Git checkout converted scripts to CRLF endings | Update to the latest commit, then run `git checkout -- entrypoint.sh` (or reclone) so Git reapplies the LF endings. |

## Known Issues
- This method has more single-core overhead than e.g. Synology Drive ShareSync and could become CPU-bottlenecked on underpowered NAS appliances.
- When `REPEAT_MODE=watch`, Unison relies on `unison-fsmonitor`/inotify watches. Very large directory trees may consume noticeable CPU and memory and can hit kernel watcher limits.
- For sake of simplicity I'm using host network, thus the firewall need to be set up on the host and you should use strong SSH passwords.
- Environment variables (including passwords) can often be viewed via `docker inspect` or your NAS UI. Rotate credentials periodically and avoid reusing passwords used elsewhere.

## License
- Distributed under the terms of the [MIT License](LICENSE.md).
- I built this for myself thus no support will be provided, you are on your own.
