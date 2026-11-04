# Homelab: rootless Podman

Three Compose projects run by the `container` user: Headscale and Headplane,
ZTNet with PostgreSQL and ZeroTier, and Caddy. The `edge` network connects Caddy
to the applications; other traffic stays on each project's own network.
This guide assumes Rocky Linux 9.8, systemd, and SELinux in **Enforcing** mode.

## Host preparation

Run the following commands as an administrator with `sudo`. The account is a
regular user, not a member of the `wheel` group, and its password remains
locked. Do not use `useradd -r`: the account needs subuid/subgid ranges.

```sh
sudo dnf install -y epel-release
sudo dnf install -y podman podman-compose netavark aardvark-dns slirp4netns fuse-overlayfs git openssl curl policycoreutils-python-utils
sudo useradd -m -U -s /bin/bash container
sudo passwd -l container
sudo loginctl enable-linger container
getent passwd container
sudo passwd -S container
grep '^container:' /etc/subuid /etc/subgid
```

Before continuing, check that both files contain ranges of at least 65536 IDs
for `container` that do not overlap with other accounts. If either range is
missing, an administrator must assign unused ranges in `/etc/subuid` and
`/etc/subgid` before running Podman for the first time. Do not use an example
range without checking for conflicts. The home directory must be on a local
filesystem that supports rootless storage and SELinux labels, not NFS.

Ports 80 and 443 require changing the system's privileged port threshold.
This affects all processes on the host, not just this user:

```sh
echo 'net.ipv4.ip_unprivileged_port_start = 80' | sudo tee /etc/sysctl.d/90-homelab-rootless-ports.conf
sudo sysctl --system
sysctl net.ipv4.ip_unprivileged_port_start
```

ZeroTier uses `/dev/net/tun`. Make sure the device exists and is readable and
writable by `container`; its standard mode is `0666`. If it is missing, enable
the `tun` module or the corresponding kernel feature. Rootless Podman mounts
the device with its host SELinux label, so configure SELinux as follows:

```sh
sudo modprobe tun
ls -lZ /dev/net/tun
sudo -u container test -r /dev/net/tun && sudo -u container test -w /dev/net/tun
sudo setsebool -P container_use_devices on
getenforce
getsebool container_use_devices
```

This boolean allows containers to access device labels and applies to the
entire host. If TUN access is granted only through a group, also configure
`keep-groups` with the `crun` runtime; adding the user to the group alone is
not enough. SELinux remains in Enforcing mode.

Before starting the stack, restrict HTTPS access to trusted administrator
addresses on every public interface, including IPv6 and any upstream router.
ZTNet grants administrator privileges to its first registered user. An
unrestricted initial deployment lets anyone claim that account. Test the
restriction from an untrusted external network before starting the services.
Keep TCP 80 reachable for Caddy's HTTP-01 certificate challenge, and allow
TCP 443 only from trusted administrator addresses during initial setup. Do not
enable public UDP 443 or UDP 9993 until setup is complete. Preserve SSH access
while changing the firewall.

The exact firewalld zone, source restrictions and router rules depend on the
host. The `https` service opens TCP 443 to the entire zone; do not enable it
in a public zone during initial setup. Check active zones with
`sudo firewall-cmd --get-active-zones`. Firewall rules must also account for
existing rules, IPv6 and other interfaces that could bypass the restriction.

## Installation

Open a shell as `container` using administrator privileges. Do not unlock the
password or run Compose with `sudo`. `sudo -i` does not usually create a
systemd user session, so set the variables pointing to the manager started by
linger:

```sh
sudo -iu container
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
export CONTAINER_SOCKET=$XDG_RUNTIME_DIR/podman/podman.sock
systemctl --user enable --now podman.socket
test -S "$CONTAINER_SOCKET"
curl --unix-socket "$CONTAINER_SOCKET" http://localhost/_ping
podman info --format '{{.Host.Security.Rootless}}'
```

The last command should return `true`. Repeat the three exports whenever you
enter through `sudo -iu container`; this socket is not the system socket at
`/run/podman/podman.sock`. Do not expose it to other users or over TCP.

```sh
git clone <PUBLIC_REPOSITORY_URL> "$HOME/homelab"
cd "$HOME/homelab"
chmod 755 headscale/config
chmod 644 headscale/config/config.yaml
umask 077
cp .env.example .env
sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=$(openssl rand -hex 32)#" .env
sed -i "s#^NEXTAUTH_SECRET=.*#NEXTAUTH_SECRET=$(openssl rand -hex 32)#" .env
sed -i "s#^HEADPLANE_COOKIE_SECRET=.*#HEADPLANE_COOKIE_SECRET=$(openssl rand -hex 16)#" .env
chmod 600 .env
```

The `.env` file contains secrets and must not be committed to Git. The
Headplane cookie secret is exactly 32 characters. The socket path is computed
in the shell or by the systemd service, not stored in `.env`. When running
Compose manually, pass `--env-file "$HOME/homelab/.env"` before `-f`: older
versions resolve relative environment-file paths from the Compose directory.
The systemd service loads it through `EnvironmentFile`.

The Headscale configuration directory must be owned by `container`: Headplane
writes UI changes there, and Headscale runs as UID `10001` and must be able to
read the file. The modes above allow that access; protect the home directory
from other users, especially if the configuration contains secrets. UI changes
modify a Git-tracked file: back it up and account for local changes before
updating the repository.

Configure public DNS records pointing to the server:

- `headscale.cdreamz.duckdns.org`
- `headplane.cdreamz.duckdns.org`
- `ztnet.cdreamz.duckdns.org`

Add AAAA records only if public IPv6 works. MagicDNS uses the private suffix
`tailnet.cdreamz.duckdns.org`, which does not need a public record. When
changing hostnames, update `caddy/Caddyfile`, both Headscale/Headplane
configuration files, and `ztnet/compose.yaml` together. The ZTNet network uses
`172.31.255.0/29`; choose another non-conflicting range in Compose and
`ZT_ALLOW_MANAGEMENT_FROM` if it overlaps with host or VPN networks.

After confirming the initial firewall restrictions, start the services and
enable them to start after a host reboot:

```sh
install -Dm644 systemd/homelab.service "$HOME/.config/systemd/user/homelab.service"
systemctl --user daemon-reload
systemctl --user enable --now homelab.service
systemctl --user status homelab.service
podman ps -a
test -S "$CONTAINER_SOCKET"
curl --fail --unix-socket "$CONTAINER_SOCKET" http://localhost/_ping
podman exec headscale_headscale_1 headscale health
podman exec ztnet_postgres_1 pg_isready -U postgres -d ztnet
podman healthcheck run ztnet_ztnet_1
podman exec ztnet_zerotier_1 zerotier-cli info
curl --fail --location --silent --show-error --output /dev/null --write-out '%{http_code}\n' --resolve headscale.cdreamz.duckdns.org:443:127.0.0.1 https://headscale.cdreamz.duckdns.org/version
curl --fail --location --silent --show-error --output /dev/null --write-out '%{http_code}\n' --resolve headplane.cdreamz.duckdns.org:443:127.0.0.1 https://headplane.cdreamz.duckdns.org/admin/login
curl --fail --location --silent --show-error --output /dev/null --write-out '%{http_code}\n' --resolve ztnet.cdreamz.duckdns.org:443:127.0.0.1 https://ztnet.cdreamz.duckdns.org/
```

Run the HTTPS checks on the host: `--resolve` connects to local Caddy while
preserving hostname and certificate validation. A successful response should
finish with a 2xx status after redirects. Services may need time to initialize
and obtain certificates; wait and retry readiness checks before declaring a
failure. Verify the same URLs from an authorized external client as well.

Also inspect `journalctl --user -u homelab.service -b` and
`podman logs <container-name>` for errors. In particular, check Headplane's
logs for a successful Docker integration, then test a configuration change and
Headscale restart from its UI. Socket availability alone does not prove that
the integration initialized correctly.

After rebooting the host, check the services, socket, and HTTPS routes again.
`homelab.service` runs detached Compose commands: its active status does not
prove container readiness, and it does not supervise each process. Some
`podman-compose` versions also ignore dependency health conditions or do not
propagate every failure. Configure independent monitoring and alerts; inspect
and recover failed containers explicitly. A failed service start may leave
some containers running, so check `podman ps -a` before retrying. Stopping the
service after a successful start stops containers without removing volumes.

The current CI checks HTTP responses and accepts redirects, which can pass
without contacting the application. Do not treat a green workflow as proof of
HTTPS routing or readiness; run the checks above and a real login and restore
test on the target Rocky Linux host with SELinux Enforcing before production.

Create a Headscale API key for your first Headplane login:

```sh
podman exec headscale_headscale_1 headscale apikeys create
```

Treat the key like a password. Configure ZTNet and ZeroTier separately and
verify network access from an actual ZeroTier client.

While HTTPS access is restricted, open the ZTNet public hostname from an
authorized administrator address and register the first account yourself.
Confirm that it has administrator privileges, secure it with a strong password
and MFA, and restrict further registrations in ZTNet according to your access
policy. Do not remove the restrictions until that is complete. See the
[ZTNet installation guide](https://ztnet.network/installation/docker-compose).

Before allowing public traffic, protect both administrative interfaces with
network restrictions or an authenticated reverse proxy. TCP 443 is shared by
Headscale, Headplane and ZTNet, so a port-only rule cannot expose Headscale
publicly while hiding the two administration hostnames. Hostname-specific
protection requires an additional trusted proxy or equivalent controls; it is
not configured by this repository. After protection is in place, an
administrator can allow the required TCP 80/443 and UDP 443/9993 traffic and
configure matching router forwarding. Do not expose the Podman API socket.

Headplane can change settings and DNS and restart Headscale through the Podman
API. The ACL policy uses `database` mode, allowing it to be edited in the UI;
it is stored in the Headscale database rather than the configuration file.
Before switching an existing installation from `file` mode, back up the active
policy and database, restrict access during migration, then import the policy
and verify its rules before making the network available again. Switching modes
does not import the file automatically. If the policy file is at
`headscale/config/policy.hujson`, run the following after starting Headscale:

```sh
podman exec headscale_headscale_1 headscale policy set --file /etc/headscale/policy.hujson
podman exec headscale_headscale_1 headscale policy get
```

A new database might not yet contain a policy; set and verify your own rules
before production use. After changing mounts in an existing installation,
recreate the containers without deleting data:

```sh
cd "$HOME/homelab"
podman-compose --env-file "$HOME/homelab/.env" -p headscale -f headscale/compose.yaml up -d --force-recreate
```

## SELinux and limitations

The Headscale configuration directory is mounted with `:z`: Headplane can
modify it, while Headscale has read-only access. The shared ZeroTier volume
also uses `:z`. Private data and configuration files use `:Z`. Podman changes
the labels of mounted files; do not use these options on system directories or
the Podman socket. Keep the repository owned by `container` and the
configuration readable by container UID `10001`.

Headplane mounts the user socket and uses `label=disable`, as recommended by
Podman for API access from a container. This disables SELinux separation **for
that container**, not for the host. Socket access grants full control of
Podman and allows code execution as `container`, even with a read-only mount.
Do not expose Headplane without appropriate protection.

This is a security trade-off, not full SELinux confinement: a compromised
Headplane can control all Podman resources and access files available to the
`container` account. Restrict its administration endpoint before deployment.
An authenticated proxy reduces exposure but does not reduce the privileges
granted by the socket; a restricted API proxy or dedicated policy would need
separate implementation and testing.

Some `podman-compose` versions print container command lines, including
environment variable values, to standard output. The systemd user journal may
therefore contain the PostgreSQL password and application secrets. Restrict
access to the journal, exported logs and log aggregation, and rotate affected
secrets if they are exposed. Avoid sharing raw Compose output. Changing the
ZTNet secret invalidates existing sessions and protected credentials; consult
the ZTNet documentation before rotating it.

ZeroTier has `NET_ADMIN` and `SYS_ADMIN` in the container's user and network
namespaces, not on the host. ZeroTier interfaces will not appear in the host
network; this setup is not a host router. Rootless forwarding can change
source addresses and NAT/UDP behavior; verify connectivity and direct
connections from external clients. Headscale's embedded DERP is disabled; if
you enable it, configure public addresses and UDP 3478.

If rootless network creation fails with `Netlink: Operation not supported`,
check kernel support for user and network namespaces and any virtualization
restrictions. Do not automatically switch services to rootful. Diagnose SELinux
errors with `sudo ausearch -m AVC -ts recent` and `ls -lZ`; do not set global
permissive mode or relabel the socket.

## Backups

Run the repository script as `container` to create a private, verified offline
backup, including the PostgreSQL logical dump:

```sh
cd "$HOME/homelab"
./scripts/backup.sh
```

The script stops `homelab.service` and restarts it only after every archive and
the dump have been verified. On failure it leaves the services stopped for
investigation. Set `BACKUP_ROOT` to change the default `$HOME/homelab-backups`
destination. The manual procedure below describes the same backup contents.

Run the following as `container` from a Bash shell with the user systemd
environment configured as described above. Backups contain secrets, private
keys, certificates, and databases. Store encrypted copies off the host and
regularly test restoration. Schedule downtime: all services must stay stopped
while their files and volumes are copied.

Stop the service and check that no homelab containers remain running. If any
were started separately, stop them before continuing:

```sh
cd "$HOME/homelab"
set -e
systemctl --user stop homelab.service
podman ps
```

Create a private backup directory. Stop immediately if a command fails; do not
use a partial backup. This archives the repository, including `.env`, local
configuration changes, Compose files, systemd unit and `.git` metadata.
It also exports the persistent volumes, including an offline PostgreSQL data
directory. The Headscale runtime socket volume is deliberately excluded.

```sh
umask 077
mkdir -p "$HOME/homelab-backups"
BACKUP="$HOME/homelab-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir "$BACKUP"
tar -C "$HOME" -czf "$BACKUP/homelab.tar.gz" homelab
for volume in headscale_headscale-data headscale_headplane-data caddy_caddy-data caddy_caddy-config ztnet_zerotier ztnet_postgres18-data; do
podman volume export --output "$BACKUP/$volume.tar" "$volume" || { echo "Backup failed: $volume" >&2; exit 1; }
done
```

Confirm that every archive exists and is readable before resuming the service:

```sh
tar -tzf "$BACKUP/homelab.tar.gz" >/dev/null
for volume in headscale_headscale-data headscale_headplane-data caddy_caddy-data caddy_caddy-config ztnet_zerotier ztnet_postgres18-data; do
tar -tf "$BACKUP/$volume.tar" >/dev/null || { echo "Invalid archive: $volume" >&2; exit 1; }
done
```

The offline PostgreSQL volume backup is for restoring the same PostgreSQL
major version. For a portable logical backup, start only PostgreSQL, wait until
it is ready, then dump the database and stop it again. Keep the other services
stopped throughout:

```sh
podman start ztnet_postgres_1
ready=0
for attempt in $(seq 1 60); do
if podman exec ztnet_postgres_1 pg_isready -q -U postgres -d ztnet; then ready=1; break; fi
sleep 1
done
if [ "$ready" -ne 1 ]; then echo 'PostgreSQL did not become ready; other services remain stopped.' >&2; exit 1; fi
podman exec ztnet_postgres_1 pg_dump -U postgres -d ztnet -Fc > "$BACKUP/ztnet.dump"
test -s "$BACKUP/ztnet.dump"
podman exec -i ztnet_postgres_1 pg_restore --list < "$BACKUP/ztnet.dump" >/dev/null
podman stop ztnet_postgres_1
systemctl --user start homelab.service
```

The dump contains the `ztnet` database, not additional databases or
cluster-wide roles. Back those up separately if you created any. If a command
fails, investigate before restarting the service and retain the incomplete
backup only for diagnosis. `set -e` causes the Bash shell to exit on failure;
reconnect as `container` to investigate. PostgreSQL may still be running if
the logical backup failed. After a successful backup, copy the
entire backup directory to encrypted storage on another machine and verify the
copy. Retain multiple generations and document their image versions.

## Restore

The following restores an offline backup to a **fresh, empty** `container`
account on a prepared host. Install the same Podman/Compose prerequisites,
enable linger and the user socket, and set the user systemd environment as in
the installation section. Use the same PostgreSQL major version as in the
backup for the physical volume. These commands do not overwrite existing data;
to recover an existing installation, stop it and restore to a separate account
or host first. Do not copy Podman storage directories between accounts.

Copy the chosen backup directory to the new host, set `BACKUP` to its absolute
path, and verify that the repository and target volumes do not exist. Use the
volume names recorded in the backup if a future Compose version changes them.
Only restore trusted archives: `tar -p` preserves their file modes. Protect
the account's home directory from other users, since Headscale's configuration
must be readable by its container UID.

```sh
set -e
umask 077
BACKUP="$HOME/path-to-backup"
test ! -e "$HOME/homelab"
tar -tzf "$BACKUP/homelab.tar.gz" >/dev/null
for volume in headscale_headscale-data headscale_headplane-data caddy_caddy-data caddy_caddy-config ztnet_zerotier ztnet_postgres18-data; do
if podman volume exists "$volume"; then echo "Volume already exists: $volume" >&2; exit 1; fi
tar -tf "$BACKUP/$volume.tar" >/dev/null
done
tar -C "$HOME" -xpzf "$BACKUP/homelab.tar.gz"
chmod 755 "$HOME/homelab/headscale/config"
chmod 644 "$HOME/homelab/headscale/config/config.yaml"
chmod 600 "$HOME/homelab/.env"
for volume in headscale_headscale-data headscale_headplane-data caddy_caddy-data caddy_caddy-config ztnet_zerotier ztnet_postgres18-data; do
podman volume create "$volume"
podman volume import "$volume" "$BACKUP/$volume.tar"
done
```

If restoration fails, do not start the service or import over the partially
restored volumes; investigate and retry with new empty volumes. The import
preserves container UID/GID mappings; the mounts apply SELinux labels on
startup. Install the restored unit and start the services:

```sh
cd "$HOME/homelab"
install -Dm644 systemd/homelab.service "$HOME/.config/systemd/user/homelab.service"
systemctl --user daemon-reload
systemctl --user enable --now homelab.service
podman ps -a
podman exec headscale_headscale_1 headscale health
podman exec ztnet_zerotier_1 zerotier-cli info
```

Verify logins, Headscale nodes and ACLs, ZTNet networks, ZeroTier connectivity,
and the three HTTPS endpoints. If restoring a PostgreSQL logical dump instead
of its physical volume, initialize an empty compatible database and follow the
PostgreSQL and application migration instructions before starting ZTNet.

## Updating containers

Start all stacks through the existing rootless user service:

```sh
cd "$HOME/homelab"
./scripts/start.sh
```

Update one stack, or all three, with a verified backup made first:

```sh
./scripts/update.sh headscale
./scripts/update.sh ztnet
./scripts/update.sh caddy
./scripts/update.sh all
```

The update script pulls only image references already declared in the selected
Compose file and recreates that project; it does not change tags or remove
volumes. Review and edit the intended image tag manually before running it.
The script refuses a ZTNet update if the PostgreSQL tag is not major version
18, because the existing data volume is specific to PostgreSQL 18. PostgreSQL
major-version migrations still require a separate migration plan.

Images are pinned to explicit release tags. `pull` alone fetches the image
already named in Compose; it does not select a newer release. For each update:

1. Make and verify a backup. Record the current tags and review the vendor release notes and migrations.
2. Check compatibility between related services. Plan downtime and test the update and restoration on a separate host.
3. Change only the intended service's `image` tag. Preserve local Headscale configuration changes when updating the repository.
4. Pull and recreate the project using the matching commands below. Compose may recreate other containers in the same project; keep named volumes and never use `down -v` or `volume prune` as an update step.
5. Check status, logs and relevant UI, API and network behavior. Retain the backup and previous images until verification is complete.

Run the matching project commands as `container` from the repository root:

```sh
cd "$HOME/homelab"
podman-compose --env-file "$HOME/homelab/.env" -p headscale -f headscale/compose.yaml pull
podman-compose --env-file "$HOME/homelab/.env" -p headscale -f headscale/compose.yaml up -d
podman-compose --env-file "$HOME/homelab/.env" -p headscale -f headscale/compose.yaml ps
podman exec headscale_headscale_1 headscale health

podman-compose --env-file "$HOME/homelab/.env" -p ztnet -f ztnet/compose.yaml pull
podman-compose --env-file "$HOME/homelab/.env" -p ztnet -f ztnet/compose.yaml up -d
podman-compose --env-file "$HOME/homelab/.env" -p ztnet -f ztnet/compose.yaml ps
podman exec ztnet_zerotier_1 zerotier-cli info

podman-compose --env-file "$HOME/homelab/.env" -p caddy -f caddy/compose.yaml pull
podman-compose --env-file "$HOME/homelab/.env" -p caddy -f caddy/compose.yaml up -d
podman-compose --env-file "$HOME/homelab/.env" -p caddy -f caddy/compose.yaml ps
```

Check `podman logs <container-name>` and the HTTPS endpoints from the
installation section. Verify Headscale/Headplane login and configuration,
ZTNet login and networks, and ZeroTier client connectivity. Review Caddy's
certificate and proxy behavior after updating it. Use the same procedure for
each service, changing only one tag at a time.

Service-specific checks:

- **Headscale:** Review configuration and SQLite schema migrations. Verify nodes, ACLs, registration and DNS.
- **Headplane:** Check Headscale compatibility and persistent data migrations. Verify login, configuration editing and Headscale restart.
- **ZTNet:** Review database migrations and compatibility with ZeroTier and PostgreSQL. Check users, networks and the controller.
- **ZeroTier:** Preserve its identity and controller data in `ztnet_zerotier`; verify its identity and connectivity from a real client.
- **PostgreSQL:** Minor updates normally use the existing volume; check release notes and verify the database first.
- **Caddy:** Verify configuration compatibility, certificate storage and all three HTTPS endpoints.

**PostgreSQL major upgrades require a separate migration.** A newer major
version cannot use the old physical data directory directly. Keep the old
volume, use the logical dump or `pg_upgrade` according to the official
[PostgreSQL upgrade documentation](https://www.postgresql.org/docs/current/upgrading.html),
restore into a new volume, and verify it before starting ZTNet. Check release
notes for required schema or data migrations for all other services too.

For rollback, stop the affected services and follow the vendor's downgrade
instructions. Reverting an image tag alone does not undo database or data
format migrations. If a downgrade is unsupported, restore the matching
pre-update backup and its image tags to an isolated account or host; verify it
before switching traffic. Keep the failed installation and backups until the
recovery is confirmed.
