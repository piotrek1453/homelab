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
podman compose version
```

The commands below use rootful `podman compose`. Do not mix rootless and
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

### 2. Create secrets

Do not commit either `.env` file:

```sh
cp ztnet/.env.example ztnet/.env
cp headscale/.env.example headscale/.env
sed -i "s#replace-with-a-long-random-password#$(openssl rand -hex 32)#" ztnet/.env
sed -i "s#replace-with-a-long-random-secret#$(openssl rand -hex 32)#" ztnet/.env
sed -i "s#replace-with-a-long-random-secret#$(openssl rand -hex 16)#" headscale/.env
```

For rootful Podman, keep this in `headscale/.env`:

```dotenv
CONTAINER_SOCKET=/run/podman/podman.sock
```

### 3. Configure hostnames

Create `caddy/.env` with the real public DNS names:

```dotenv
HEADSCALE_SITE=https://headscale.example.com
HEADPLANE_SITE=https://headplane.example.com
ZTNET_SITE=https://ztnet.example.com
```

Update matching values in:

- `headscale/config/config.yaml`: `server_url` and `dns.base_domain`;
- `headscale/headplane/config.yaml`: `server.base_url` and `headscale.public_url`;
- `ztnet/.env`: `NEXTAUTH_URL`.

DNS records must point to the Rocky Linux server before Caddy starts, so that
certificate issuance can succeed. When testing without public DNS, use
`http://` values in `caddy/.env` and do not expect Let's Encrypt certificates.

### 4. Start and verify

```sh
cd /opt/homelab
podman compose -p headscale -f headscale/compose.yaml up -d
podman compose -p ztnet -f ztnet/compose.yaml up -d
podman compose -p caddy -f caddy/compose.yaml up -d

podman compose -p headscale -f headscale/compose.yaml ps
podman compose -p ztnet -f ztnet/compose.yaml ps
podman compose -p caddy -f caddy/compose.yaml ps
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
podman compose down
cd /opt/ztnet
podman compose -f docker-compose.yml down
```

The new Compose file reuses the old ZTNet volumes through the explicit names
`ztnet_postgres-data` and `ztnet_zerotier`. Do not run `down -v`.

### 2. Copy configuration

```sh
rsync -a /opt/headscale/config/ /opt/homelab/headscale/config/
rsync -a /opt/headscale/headplane/ /opt/homelab/headscale/headplane/
cp -a /opt/ztnet/.env /opt/homelab/ztnet/.env
cp /opt/homelab/headscale/.env.example /opt/homelab/headscale/.env
```

Restore the real Headplane secret and `CONTAINER_SOCKET` in
`/opt/homelab/headscale/.env`. Keep the old Headscale `server_url`, DNS and
network settings unless you intentionally want to change them. Do not copy the
old Caddyfile; configure `caddy/.env` instead.

### 3. Import Headscale, Headplane and Caddy data

Create the new volumes without starting the services:

```sh
cd /opt/homelab
podman compose -p headscale -f headscale/compose.yaml create
podman compose -p caddy -f caddy/compose.yaml create
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
podman compose -p headscale -f headscale/compose.yaml up -d
podman compose -p ztnet -f ztnet/compose.yaml up -d
podman compose -p caddy -f caddy/compose.yaml up -d
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -I https://headscale.example.com/version
curl -I https://headplane.example.com/admin/
curl -I https://ztnet.example.com/api/auth/session
```

Replace the example hostnames above with your actual names. Keep the backup
until Headscale registration, Headplane login, ZTNet login, PostgreSQL data
and ZeroTier networks have all been verified.

## Updates and rollback

```sh
podman compose -p caddy -f caddy/compose.yaml pull
podman compose -p caddy -f caddy/compose.yaml up -d
```

Update one stack at a time. Never remove named volumes unless their data has
been backed up and removal is intentional.

The GitHub Actions workflow validates all Compose files, pulls the images,
starts every stack with rootful Podman, checks healthchecks, and tests all
three Caddy routes.