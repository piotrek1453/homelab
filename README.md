# Homelab: rootless Podman

This repository runs three independent `podman-compose` projects as a regular
user:

- **Headscale + Headplane**,
- **ZTNet + PostgreSQL + ZeroTier**,
- **Caddy** as the shared reverse proxy.

The [Makefile](./Makefile) is the central management mechanism.

## Network architecture

`edge` is a shared external Podman network. Caddy and the public-facing
services are attached to it, allowing Caddy to use the service names
`headscale`, `headplane`, and `ztnet` as backends.

Internal traffic is isolated:

- Headscale and Headplane use the private `headscale_internal` network;
- ZTNet, PostgreSQL, and ZeroTier use the private `ztnet_internal` network;
- Caddy is not attached to either private network, and PostgreSQL and ZeroTier
  are not attached to `edge`;
- only Caddy publishes HTTP/HTTPS ports, while ZeroTier publishes UDP `9993`.

Headplane communicates with Headscale over HTTP at `http://headscale:8080` on
`headscale_internal`. Its Docker integration uses only the Podman API socket
mounted as `/var/run/docker.sock`; it does not use the Headscale gRPC socket.

## Requirements

This guide assumes Linux with SELinux in **Enforcing** mode, rootless Podman,
and a user account with subuid/subgid ranges.

```sh
sudo dnf install -y podman podman-compose buildah skopeo netavark \
  aardvark-dns slirp4netns fuse-overlayfs git openssl curl \
  policycoreutils-python-utils
sudo loginctl enable-linger "$USER"
systemctl --user enable --now podman.socket
```

The following are also required:

- GNU Make,
- `podman-compose`,
- a working rootless Podman socket,
- `/dev/net/tun` for ZeroTier,
- permission for rootless Podman to use ports 80/443, for example through an
  appropriate `net.ipv4.ip_unprivileged_port_start` setting,
- valid `/etc/subuid` and `/etc/subgid` ranges.

Do not run Compose through `sudo`. Check the user session:

```sh
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export CONTAINER_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock"
test -S "$CONTAINER_SOCKET"
test "$(podman info --format '{{.Host.Security.Rootless}}')" = true
```

Do not disable SELinux. The `:z` and `:Z` options in Compose apply the
appropriate labels to mounts. ZeroTier access to TUN may require:

```sh
sudo modprobe tun
sudo setsebool -P container_use_devices on
```

## First startup

```sh
cp .env.example .env
sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=$(openssl rand -hex 32)#" .env
sed -i "s#^NEXTAUTH_SECRET=.*#NEXTAUTH_SECRET=$(openssl rand -hex 32)#" .env
sed -i "s#^HEADPLANE_COOKIE_SECRET=.*#HEADPLANE_COOKIE_SECRET=$(openssl rand -hex 16)#" .env
chmod 600 .env
podman network create edge
make config
make up
make status
```

`make network` is safe to repeat and creates `edge` if it does not exist. Do
not remove volumes during initial setup or upgrades. Before exposing the
services, configure DNS for the names in the [Caddyfile](./caddy/Caddyfile)
and restrict administrative access to Headplane and ZTNet with firewall rules.

Startup order is fixed: Headscale/Headplane first, then ZTNet, and Caddy last.
Shutdown happens in reverse order. The user service
[homelab.service](./systemd/homelab.service) invokes the same Makefile targets
and can be enabled after manual verification:

```sh
install -Dm644 systemd/homelab.service \
  "$HOME/.config/systemd/user/homelab.service"
systemctl --user daemon-reload
systemctl --user enable --now homelab.service
```

## Makefile commands

Run these commands from the repository root as the rootless user:

| Command | Description |
| --- | --- |
| `make network` | Create the shared `edge` network if it does not exist. |
| `make config` | Validate interpolation and syntax for all Compose files. |
| `make up` | Start all stacks in the required order. |
| `make down` | Stop Caddy, then ZTNet, then Headscale. |
| `make restart` | Run `down`, followed by `up`. |
| `make status` | Show the status of containers in all projects. |
| `make logs` | Show the last 100 log lines for each project. |
| `make pull` | Pull the image tags declared in Compose. |
| `make update` | Run backup, `pull`, and restart the stacks. |
| `make backup` | Stop the stacks, archive the repository and volumes, verify the archives, and start the stacks again. |

`make update` does not select newer image versions and does not perform
PostgreSQL migrations. Change image tags manually after reviewing the
vendor's release notes, make a backup, and then run `make update`. Backups
contain secrets and authentication data; set `BACKUP_ROOT` to choose another
location:

```sh
BACKUP_ROOT="$HOME/homelab-backups" make backup
```

## Migration from the previous configuration

1. Stop the previous service:
   `systemctl --user stop homelab.service`.
2. Create and verify a backup. Do not use `down -v`, `podman volume prune`, or
   remove data volumes.
3. Update the repository and copy `.env`, preserving local Headscale
   configuration changes.
4. Create the `edge` network with `make network`.
5. Run `make config`, followed by `make up`.
6. Verify `make status`, logs, Headplane and ZTNet logins, existing Headscale
   nodes, and ZeroTier networks.

On the first startup after this change, Compose may create
`headscale_internal` and `ztnet_internal`. These are network metadata only;
Headscale SQLite data, Headplane data, PostgreSQL data, and the ZeroTier
identity remain in their existing volumes.

## Headscale troubleshooting

### gRPC Unix socket error

The Headscale configuration contains:

```yaml
grpc_listen_addr: 127.0.0.1:50443
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
```

The Unix socket is required by the local Headscale CLI, including
`headscale health`; Headplane does not use it. TCP gRPC remains private
(`127.0.0.1` inside the container) and is not published to the host or the
Internet.

The `bind: permission denied` error was caused by the combination of
`user: "10001:10001"` and a named volume mounted without changing its owner.
Rootless Podman creates an empty volume directory as `root:root` with mode
`0755`; the `:Z` label fixes SELinux labeling but not POSIX permissions.
The `headscale-run:/var/run/headscale:Z,U` mount changes ownership of this
runtime-only volume to the process UID. It does not change the data volume or
run Headscale as root.

After migration or a mount change, check:

```sh
podman inspect headscale_headscale_1 \
  --format '{{range .Mounts}}{{if eq .Destination "/var/run/headscale"}}{{.Source}} {{.RW}} {{.Options}}{{end}}{{end}}'
podman unshare stat -c '%n mode=%a uid=%u gid=%g' \
  "$(podman volume inspect --format '{{.Mountpoint}}' headscale_headscale-run)"
podman exec headscale_headscale_1 id
podman exec headscale_headscale_1 ls -ldZ /var/run/headscale
podman exec headscale_headscale_1 ls -lZ /var/run/headscale
sudo ausearch -m AVC -ts recent
podman logs headscale_headscale_1
```

The expected process UID/GID is `10001:10001`, and the runtime directory must
be writable by that UID. If the host path, SELinux label, or an existing
socket is incorrect, first stop the stack with `make down` and inspect the
specific volume. Do not remove `headscale-data` or the SQLite database. Only
remove the socket after confirming that it is not in use; `make up` will
recreate it.

### Caddy and backend connectivity

Check that all services are attached to `edge` and that Caddy can resolve the
backends:

```sh
podman network inspect edge
make logs
curl --resolve headscale.cdreamz.duckdns.org:443:127.0.0.1 \
  https://headscale.cdreamz.duckdns.org/version
curl --resolve headplane.cdreamz.duckdns.org:443:127.0.0.1 \
  https://headplane.cdreamz.duckdns.org/admin/
curl --resolve ztnet.cdreamz.duckdns.org:443:127.0.0.1 \
  https://ztnet.cdreamz.duckdns.org/
```

A 502 usually means that the backend is not attached to `edge`, the service
name is incorrect, or the service is not listening yet. Do not attach Caddy
to private networks just to bypass a DNS problem; inspect network membership
and logs instead.

### Verifying Headscale ↔ Headplane

```sh
podman exec headscale_headscale_1 headscale health
podman logs headscale_headplane_1
```

Headplane should connect to `http://headscale:8080`. The
`/var/run/docker.sock` socket in Headplane is the Podman API socket and must
not be confused with `/var/run/headscale/headscale.sock`. For HTTP
communication failures, check both container statuses, membership in
`headscale_internal`, and Headplane logs. Do not publish the gRPC port to the
host.

There is currently no running Headscale container in this checkout, so the
current SELinux label and historical ownership of an existing volume cannot be
confirmed from the repository alone. Run the commands above on the host where
the error occurred. The configuration and reproduction of the default rootless
named volume nevertheless establish that the `Z,U` fix removes the permission
conflict without affecting data.
