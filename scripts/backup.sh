#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/homelab-backups}"
VOLUMES=(
  headscale_headscale-data
  headscale_headplane-data
  caddy_caddy-data
  caddy_caddy-config
  ztnet_zerotier
  ztnet_postgres18-data
)
POSTGRES_CONTAINER=ztnet_postgres_1
postgres_started=0
resume_service=0

cleanup() {
  local exit_code=$?
  trap - EXIT

  if (( postgres_started )); then
    podman stop "$POSTGRES_CONTAINER" >/dev/null || true
  fi
  if (( resume_service )); then
    if ! systemctl --user start homelab.service; then
      printf 'Backup succeeded, but homelab.service did not restart.\n' >&2
      exit_code=1
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT

if [[ ! -f "$ROOT/.env" ]]; then
  printf 'Missing %s; configure the environment before backing up.\n' "$ROOT/.env" >&2
  exit 1
fi

for volume in "${VOLUMES[@]}"; do
  podman volume exists "$volume" || {
    printf 'Required volume does not exist: %s\n' "$volume" >&2
    exit 1
  }
done
podman container exists "$POSTGRES_CONTAINER" || {
  printf 'Required PostgreSQL container does not exist: %s\n' "$POSTGRES_CONTAINER" >&2
  exit 1
}

install -d -m 700 "$BACKUP_ROOT"
BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$BACKUP"

systemctl --user stop homelab.service
running="$(podman ps --format '{{.Names}}')"
while IFS= read -r name; do
  case "$name" in
    headscale_*|ztnet_*|caddy_*)
      printf 'Homelab container is still running: %s\n' "$name" >&2
      exit 1
      ;;
  esac
done <<< "$running"

tar -C "$(dirname -- "$ROOT")" -czf "$BACKUP/homelab.tar.gz" "$(basename -- "$ROOT")"
for volume in "${VOLUMES[@]}"; do
  podman volume export --output "$BACKUP/$volume.tar" "$volume"
done

tar -tzf "$BACKUP/homelab.tar.gz" >/dev/null
for volume in "${VOLUMES[@]}"; do
  tar -tf "$BACKUP/$volume.tar" >/dev/null
done

podman start "$POSTGRES_CONTAINER" >/dev/null
postgres_started=1
ready=0
for attempt in $(seq 1 60); do
  if podman exec "$POSTGRES_CONTAINER" pg_isready -q -U postgres -d ztnet; then
    ready=1
    break
  fi
  sleep 1
done
if (( ! ready )); then
  printf 'PostgreSQL did not become ready after %s attempts; services will remain stopped.\n' "$((attempt - 1))" >&2
  exit 1
fi

podman exec "$POSTGRES_CONTAINER" pg_dump -U postgres -d ztnet -Fc > "$BACKUP/ztnet.dump"
test -s "$BACKUP/ztnet.dump"
podman exec -i "$POSTGRES_CONTAINER" pg_restore --list < "$BACKUP/ztnet.dump" >/dev/null
podman stop "$POSTGRES_CONTAINER" >/dev/null
postgres_started=0

resume_service=1
printf 'Backup verified: %s\n' "$BACKUP"