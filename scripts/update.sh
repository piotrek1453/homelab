#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"

usage() {
  printf 'Usage: %s <headscale|ztnet|caddy|all>\n' "$0" >&2
}

if (( $# != 1 )); then
  usage
  exit 2
fi

case "$1" in
  headscale|ztnet|caddy) projects=("$1") ;;
  all) projects=(headscale ztnet caddy) ;;
  *) usage; exit 2 ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
  printf 'Missing %s; configure the environment before updating.\n' "$ENV_FILE" >&2
  exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  printf 'XDG_RUNTIME_DIR must be set in the user session.\n' >&2
  exit 1
fi
CONTAINER_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock"

if [[ " ${projects[*]} " == *" ztnet "* ]]; then
  postgres_image="$(awk '$1 == "image:" && $2 ~ /postgres:/ { image = $2 } END { print image }' "$ROOT/ztnet/compose.yaml")"
  postgres_tag="${postgres_image##*:}"
  if [[ ! "$postgres_tag" =~ ^([0-9]+)([.-]|$) || "${BASH_REMATCH[1]}" != 18 ]]; then
    printf 'Refusing ztnet update: PostgreSQL must remain major version 18 for the existing postgres18 volume. Use a separate major-version migration procedure.\n' >&2
    exit 1
  fi
fi

export CONTAINER_SOCKET
"$ROOT/scripts/backup.sh"
systemctl --user start podman.socket

for project in "${projects[@]}"; do
  printf 'Pulling images declared for %s...\n' "$project"
  podman-compose --env-file "$ENV_FILE" -p "$project" -f "$ROOT/$project/compose.yaml" pull
  podman-compose --env-file "$ENV_FILE" -p "$project" -f "$ROOT/$project/compose.yaml" up -d
  podman-compose --env-file "$ENV_FILE" -p "$project" -f "$ROOT/$project/compose.yaml" ps
done
