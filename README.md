# Homelab Compose stacks

This repository contains three independent Compose projects:

- `headscale/compose.yaml`: Headscale and Headplane;
- `ztnet/compose.yaml`: ZTNet, PostgreSQL and ZeroTier;
- `caddy/compose.yaml`: the public HTTP/HTTPS entrypoint.

The projects share only the external `edge` network. Each application keeps
its private traffic on its own internal network.

## Rocky Linux: prerequisites

For a Rocky Linux server, run the stacks rootful as `root`. This avoids
rootless bridge/veth restrictions and matches the system Podman socket used by
Headplane. Open a root shell first:

```sh
sudo -i
dnf install -y epel-release
dnf install -y podman podman-compose git openssl curl rsync policycoreutils-python-utils
systemctl enable --now podman.socket
podman --version
podman-compose version
```

The commands below use rootful `podman-compose`. Do not mix rootless and
rootful Podman for the same project: they have separate images, networks,
containers and volumes.

If you intentionally run rootless, start the user socket and use its path:

```sh
systemctl --user enable --now podman.socket
loginctl enable-linger "$USER"
export CONTAINER_SOCKET=/run/user/$(id -u)/podman/podman.sock
```

Rootless mode also requires working `netavark` plus `pasta` or
`slirp4netns`. If it reports `Netlink: Operation not supported` while creating
a bridge, the host does not grant the required network capabilities; use the
rootful procedure or fix the host kernel/runtime first.

## Rocky Linux: fresh installation

### 1. Install the repository and network

```sh
mkdir -p /opt
git clone <PUBLIC_REPOSITORY_URL> /opt/homelab
cd /opt/homelab
podman network exists edge || podman network create edge
```

### 2. Create secrets in the repository-level `.env`

Run all Compose commands from `/opt/homelab`. Copy the root example; do not
create a separate `.env` for each stack:

```sh
cp .env.example .env
sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=$(openssl rand -hex 32)#" .env
sed -i "s#^NEXTAUTH_SECRET=.*#NEXTAUTH_SECRET=$(openssl rand -hex 32)#" .env
sed -i "s#^HEADPLANE_COOKIE_SECRET=.*#HEADPLANE_COOKIE_SECRET=$(openssl rand -hex 16)#" .env
```

The Headplane cookie secret is 32 hexadecimal characters. For rootful Podman,
the example already sets `CONTAINER_SOCKET=/run/podman/podman.sock`; change it
only if you use a different socket. `.env` contains secrets and the socket
path, not public URLs or IP addresses. Keep it private and do not commit it.

### 3. Configure DNS and public access

The public hostnames are fixed in the service configuration:

- `headscale.cdreamz.duckdns.org`
- `headplane.cdreamz.duckdns.org`
- `ztnet.cdreamz.duckdns.org`

Headscale MagicDNS uses `tailnet.cdreamz.duckdns.org`; client names will look
like `device.tailnet.cdreamz.duckdns.org`. This is a tailnet DNS suffix and
does not need a public DNS record. The Headscale server URL is already set to
`https://headscale.cdreamz.duckdns.org` in `headscale/config/config.yaml`.

These names are hardcoded, not read from `.env`. If you change them later,
update `caddy/Caddyfile`, `headscale/headplane/config.yaml`,
`headscale/config/config.yaml` and `ztnet/compose.yaml` together.

At your DNS provider, make the three public hostnames resolve to the server's
public IPv4 address. Add `AAAA` records only if the server has working public
IPv6. If the server is behind a router, forward these ports to it and allow
them through the host firewall:

- TCP `80` and `443`, plus UDP `443` for Caddy;
- UDP `9993` for ZeroTier.

The embedded Headscale DERP server is disabled in the supplied config, so its
optional public IP fields can remain empty. If you enable it later, set its
real public IP addresses and also allow its configured STUN port, UDP `3478`.
DNS must resolve to this server before Caddy starts so certificate issuance
can succeed. Public URL overrides in `.env` are no longer supported.

### 4. Start and verify

```sh
cd /opt/homelab
podman-compose -p headscale -f headscale/compose.yaml up -d headscale
for attempt in $(seq 1 60); do podman exec headscale_headscale_1 headscale health >/dev/null 2>&1 && break; sleep 1; done
podman exec headscale_headscale_1 headscale health && podman-compose -p headscale -f headscale/compose.yaml up -d headplane
podman-compose -p ztnet -f ztnet/compose.yaml up -d
podman-compose -p caddy -f caddy/compose.yaml up -d

podman-compose -p headscale -f headscale/compose.yaml ps
podman-compose -p ztnet -f ztnet/compose.yaml ps
podman-compose -p caddy -f caddy/compose.yaml ps
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

## Migration from the old `/opt` layout

The old server layout contains live data. Make a backup first and never use
`down -v` during migration.

### 1. Back up and stop the old projects

```sh
BACKUP=/root/homelab-migration-$(date +%F)
mkdir -p "$BACKUP"
tar -C /opt -czf "$BACKUP/headscale-files.tgz" headscale
cp -a /opt/ztnet/.env "$BACKUP/ztnet.env"
podman volume ls > "$BACKUP/podman-volumes.txt"

cd /opt/headscale/compose
podman-compose down
cd /opt/ztnet
podman-compose -f docker-compose.yml down
```

The new Compose file reuses the old ZTNet volumes through the explicit names
`ztnet_postgres-data` and `ztnet_zerotier`. Do not run `down -v`.

### 2. Copy configuration

```sh
rsync -a /opt/headscale/config/ /opt/homelab/headscale/config/
rsync -a /opt/headscale/headplane/ /opt/homelab/headscale/headplane/
cp /opt/homelab/.env.example /opt/homelab/.env
vi /opt/homelab/.env
```

Copy the old `POSTGRES_PASSWORD` and `NEXTAUTH_SECRET` values from the backup
into the new root `.env`. Generate a new 32-character
`HEADPLANE_COOKIE_SECRET`; do not reuse the example value or commit `.env`.
For rootful Podman, set `CONTAINER_SOCKET=/run/podman/podman.sock`.

In `/opt/homelab/headscale/config/config.yaml`, set `server_url` to
`https://headscale.cdreamz.duckdns.org` and `dns.base_domain` to
`tailnet.cdreamz.duckdns.org`. In `headscale/headplane/config.yaml`, set
`server.base_url` to `https://headplane.cdreamz.duckdns.org` and
`headscale.public_url` to `https://headscale.cdreamz.duckdns.org`.

Do not copy the old Caddyfile; the repository version contains the fixed
hostnames. Ensure DNS for the three public hostnames points to this server.

### 3. Import Headscale, Headplane and Caddy data

Create the new volumes without starting the services:

```sh
cd /opt/homelab
podman-compose -p headscale -f headscale/compose.yaml create
podman-compose -p caddy -f caddy/compose.yaml create
```

Copy the old bind-mounted data into the named volumes:

```sh
podman run --rm -v /opt/headscale/data:/from:ro -v headscale_headscale-data:/to docker.io/library/alpine:3.20 sh -c 'cp -a /from/. /to/'
podman run --rm -v /opt/headscale/headplane/data:/from:ro -v headscale_headplane-data:/to docker.io/library/alpine:3.20 sh -c 'cp -a /from/. /to/'
podman run --rm -v /opt/headscale/caddy/data:/from:ro -v caddy_caddy-data:/to docker.io/library/alpine:3.20 sh -c 'cp -a /from/. /to/'
podman run --rm -v /opt/headscale/caddy/config:/from:ro -v caddy_caddy-config:/to docker.io/library/alpine:3.20 sh -c 'cp -a /from/. /to/'
```

The Headscale copy includes `db.sqlite` and `noise_private.key`. PostgreSQL
and ZeroTier data remain in their existing named volumes.

If the old installation was rootful, run the migration commands as `root`.
Rootful and rootless Podman do not share volumes, so copying data is safer than
assuming that a volume with the same name belongs to the same storage root.

### 4. Start and test the migration

```sh
cd /opt/homelab
podman-compose -p headscale -f headscale/compose.yaml up -d headscale
for attempt in $(seq 1 60); do podman exec headscale_headscale_1 headscale health >/dev/null 2>&1 && break; sleep 1; done
podman exec headscale_headscale_1 headscale health && podman-compose -p headscale -f headscale/compose.yaml up -d headplane
podman-compose -p ztnet -f ztnet/compose.yaml up -d
podman-compose -p caddy -f caddy/compose.yaml up -d
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -I https://headscale.cdreamz.duckdns.org/version
curl -I https://headplane.cdreamz.duckdns.org/admin/
curl -I https://ztnet.cdreamz.duckdns.org/api/auth/session
```

Keep the backup until Headscale registration, Headplane login, ZTNet login,
PostgreSQL data and ZeroTier networks have all been verified.

## Updates and rollback

```sh
podman-compose -p caddy -f caddy/compose.yaml pull
podman-compose -p caddy -f caddy/compose.yaml up -d
```

Update one stack at a time. Never remove named volumes unless their data has
been backed up and removal is intentional.

The GitHub Actions workflow validates all Compose files, pulls the images,
checks Headscale's gRPC health through `podman exec`, starts the remaining
services, checks their healthchecks, and tests all three Caddy routes. Its
Compose commands are compatible with Ubuntu's
`podman-compose` package, which does not support Docker Compose's
`--quiet` and `--no-color` options.
