# SigNoz self-hosting — common operations.
#
#   make help                 list targets
#   make up                   bring up the standalone stack
#   make STACK=ha up          bring up the HA stack
#
# Every target takes STACK=standalone (default) or STACK=ha.

STACK       ?= standalone
STACK_DIR   := deploy/$(STACK)
COMPOSE     := docker compose -f $(STACK_DIR)/docker-compose.yaml
COMPOSE_SEC := $(COMPOSE) -f $(STACK_DIR)/compose.security.yaml

# Use the security overlay automatically once a generated config exists, so
# `make up` does not silently drop the auth you just configured.
ifneq (,$(wildcard $(STACK_DIR)/collector/config.generated.yaml))
  DC := $(COMPOSE_SEC)
  SECURITY_NOTE := (security overlay active)
else
  DC := $(COMPOSE)
  SECURITY_NOTE :=
endif

.DEFAULT_GOAL := help
.PHONY: help init up down restart ps logs pull bootstrap validate smoke backup restore \
        config clean nuke keeper-status cluster-status replication-status

help: ## Show this help
	@printf '\033[1mSigNoz self-hosting\033[0m  (STACK=$(STACK))\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf '\nStacks: standalone (default), ha   e.g. make STACK=ha up\n'

$(STACK_DIR)/.env:
	@cp $(STACK_DIR)/.env.example $(STACK_DIR)/.env
	@printf '\033[33mcreated %s from the example.\033[0m\n' '$(STACK_DIR)/.env'
	@printf 'Set CLICKHOUSE_PASSWORD before exposing this beyond localhost.\n'

init: $(STACK_DIR)/.env ## Create .env from the example if missing

up: init ## Start the stack in the background
	@printf 'starting %s %s\n' '$(STACK)' '$(SECURITY_NOTE)'
	$(DC) up -d
	@printf '\nUI: http://localhost:$${SIGNOZ_UI_PORT:-8080}   (make logs to follow startup)\n'

down: ## Stop the stack, keeping all data
	$(DC) down

restart: ## Restart every service
	$(DC) restart

ps: ## Show service status
	$(DC) ps

logs: ## Follow logs (SERVICE=name to narrow)
	$(DC) logs -f --tail=200 $(SERVICE)

pull: init ## Pull the pinned images
	$(DC) pull

config: init ## Print the fully resolved compose configuration
	$(DC) config

bootstrap: ## Create the organization and admin account (REQUIRED before ingestion)
	@./scripts/bootstrap.sh $(STACK)

validate: ## Run all static checks (no daemon needed)
	@./scripts/validate.sh

smoke: ## Run the end-to-end check against a running stack
	@./scripts/smoke-test.sh $(STACK)

backup: ## Back up config, metastore and ClickHouse
	@./scripts/backup.sh $(STACK)

restore: ## Restore from a backup: make restore FROM=backups/standalone-...
	@test -n "$(FROM)" || { echo "usage: make restore FROM=backups/<dir>"; exit 1; }
	@./scripts/restore.sh $(STACK) $(FROM)

# ── Diagnostics ──────────────────────────────────────────────────────────────

keeper-status: ## Keeper quorum: who is leader, who is following
	@if [ "$(STACK)" = "ha" ]; then \
	  for n in 1 2 3; do \
	    printf '\033[1mkeeper-%s\033[0m\n' "$$n"; \
	    docker exec signoz-keeper-$$n clickhouse-keeper-client -h localhost -p 9181 -q mntr \
	      2>/dev/null | grep -E 'zk_server_state|zk_followers|zk_synced_followers|zk_znode_count' \
	      | sed 's/^/  /' || echo '  unreachable'; \
	  done; \
	else \
	  docker exec signoz-clickhouse-keeper clickhouse-keeper-client -h localhost -p 9181 -q mntr \
	    | grep -E 'zk_server_state|zk_znode_count' | sed 's/^/  /'; \
	fi

# Credentials are read from the stack's .env at run time rather than requiring
# the caller to export them. Not a $(call) function: make splits $(call)
# arguments on commas, which would truncate every one of these queries at its
# first column.
CH_NODE  := $(if $(filter ha,$(STACK)),signoz-clickhouse-1,signoz-clickhouse)
CH_QUERY  = set -a; . $(STACK_DIR)/.env; set +a; \
            docker exec $(CH_NODE) clickhouse-client \
              --user "$$CLICKHOUSE_USER" --password "$$CLICKHOUSE_PASSWORD" --query

cluster-status: ## ClickHouse cluster membership as the servers see it
	@$(CH_QUERY) "SELECT cluster, shard_num, replica_num, host_name, errors_count \
	  FROM system.clusters WHERE cluster = 'cluster' FORMAT PrettyCompact"

replication-status: ## Replica health and lag (HA)
	@$(CH_QUERY) "SELECT database, table, replica_name, is_readonly, absolute_delay, \
	  active_replicas, total_replicas FROM system.replicas \
	  WHERE database LIKE 'signoz%' ORDER BY absolute_delay DESC LIMIT 20 FORMAT PrettyCompact"

# ── Destructive ──────────────────────────────────────────────────────────────

clean: ## Remove the generated security config, reverting to the base config
	@./scripts/apply-security.sh $(STACK) --reset

nuke: ## Stop the stack and DELETE ALL DATA (volumes included)
	@printf '\033[31mThis deletes every volume in the %s stack: telemetry, dashboards, alerts.\033[0m\n' '$(STACK)'
	@printf 'Type "nuke" to confirm: ' && read reply && [ "$$reply" = "nuke" ]
	$(DC) down -v
