#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$ROOT/.env" ]]; then
  printf 'Missing %s; copy .env.example to .env and configure it first.\n' "$ROOT/.env" >&2
  exit 1
fi

systemctl --user start homelab.service
systemctl --user --no-pager status homelab.service