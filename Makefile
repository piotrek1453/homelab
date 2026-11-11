SHELL := /bin/bash

COMPOSE ?= podman-compose
ENV_FILE ?= .env
HEADSCALE_COMPOSE := $(COMPOSE) --env-file $(ENV_FILE) -p headscale -f headscale/compose.yaml
ZTNET_COMPOSE := $(COMPOSE) --env-file $(ENV_FILE) -p ztnet -f ztnet/compose.yaml
CADDY_COMPOSE := $(COMPOSE) --env-file $(ENV_FILE) -p caddy -f caddy/compose.yaml

.PHONY: network config up down restart status logs pull update backup

network:
	podman network exists edge || podman network create edge

config:
	@test -f "$(ENV_FILE)" || { echo "Missing $(ENV_FILE); copy .env.example to .env." >&2; exit 1; }
	$(CADDY_COMPOSE) config >/dev/null
	$(HEADSCALE_COMPOSE) config >/dev/null
	$(ZTNET_COMPOSE) config >/dev/null

up: network config
	$(HEADSCALE_COMPOSE) up -d
	$(ZTNET_COMPOSE) up -d
	$(CADDY_COMPOSE) up -d

down:
	$(CADDY_COMPOSE) stop
	$(ZTNET_COMPOSE) stop
	$(HEADSCALE_COMPOSE) stop

restart: down up

status:
	$(HEADSCALE_COMPOSE) ps
	$(ZTNET_COMPOSE) ps
	$(CADDY_COMPOSE) ps

logs:
	$(HEADSCALE_COMPOSE) logs --tail=100
	$(ZTNET_COMPOSE) logs --tail=100
	$(CADDY_COMPOSE) logs --tail=100

pull: config
	$(HEADSCALE_COMPOSE) pull
	$(ZTNET_COMPOSE) pull
	$(CADDY_COMPOSE) pull

update: backup pull up

backup:
	@test -f "$(ENV_FILE)" || { echo "Missing $(ENV_FILE); configure it before backing up." >&2; exit 1; }
	@set -Eeuo pipefail; \
	backup_root="$${BACKUP_ROOT:-$$HOME/homelab-backups}"; \
	backup="$$backup_root/$$(date -u +%Y%m%dT%H%M%SZ)"; \
	volumes=(headscale_headscale-data headscale_headplane-data caddy_caddy-data caddy_caddy-config ztnet_zerotier ztnet_postgres18-data); \
	for volume in "$${volumes[@]}"; do \
		podman volume exists "$$volume" || { echo "Required volume does not exist: $$volume" >&2; exit 1; }; \
	done; \
	install -d -m 700 "$$backup_root"; \
	mkdir -m 700 "$$backup"; \
	$(MAKE) down; \
	tar -C "$$(dirname "$$PWD")" -czf "$$backup/homelab.tar.gz" "$$(basename "$$PWD")"; \
	for volume in "$${volumes[@]}"; do podman volume export --output "$$backup/$$volume.tar" "$$volume"; done; \
	tar -tzf "$$backup/homelab.tar.gz" >/dev/null; \
	for volume in "$${volumes[@]}"; do tar -tf "$$backup/$$volume.tar" >/dev/null; done; \
	$(MAKE) up >/dev/null; \
	echo "Backup verified: $$backup"
