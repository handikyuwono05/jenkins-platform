# ---------------------------------------------------------------------------
# jenkins-platform -- build and run a Configuration-as-Code Jenkins
# controller with Google OAuth login.
#
#   make init      create vault/*.env from template/*.env.example
#   make run       validate, build, start, wait for healthy
#   make help      all targets
#
# This file stays deliberately thin: it sequences targets and delegates the
# work to scripts/, which are shellcheck-clean, individually runnable and
# testable. Logic does not belong in recipe strings.
#
# Requires GNU Make 4.x (macOS ships 3.81: brew install make, then use gmake).
# ---------------------------------------------------------------------------
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Targets share an advisory lock and a single Docker daemon; `make -j run`
# would have build and up contend for both. Ordering here is correctness.
.NOTPARALLEL:

SERVICE      := jenkins
VAULT_DIR    := vault
SETTINGS_ENV := $(VAULT_DIR)/jenkins.env
SCRIPTS      := scripts
LOCK_DIR     := .make-lock
RECOVERY_CASC := /var/jenkins_conf/casc-recovery

# Compose interpolates ${...} in docker-compose.yml from the settings file.
COMPOSE_BIN ?= $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; \
	elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; fi)
COMPOSE := $(COMPOSE_BIN) --env-file $(SETTINGS_ENV)

# Stamped into the image as an OCI label so a running container traces back to
# a commit.
BUILD_REVISION := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
export BUILD_REVISION

# Mutating targets take an advisory lock. Two concurrent `make up` runs, or a
# build racing a restore, both write the same JENKINS_HOME volume -- Jenkins
# assumes a single writer and will corrupt its state otherwise. mkdir is atomic
# on POSIX filesystems, which is the property we need.
LOCK = mkdir $(LOCK_DIR) 2>/dev/null || { \
		echo "ERROR: $(LOCK_DIR) exists -- another make target is running." >&2; \
		echo "       If you are sure it is stale: rmdir $(LOCK_DIR)" >&2; exit 1; }; \
	trap 'rmdir $(LOCK_DIR) 2>/dev/null || true' EXIT

.PHONY: help init render show set-oauth validate validate-offline build run up wait \
	smoke oauth-info ps logs logs-dump audit shell restart down \
	recovery-up recovery-down recovery-rotate \
	plugins-freeze base-digest backup restore lint clean nuke

help: ## Show this help
	@echo "jenkins-platform -- targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Vault: configuration and secrets
# ---------------------------------------------------------------------------
init: ## Create vault/*.env from template/*.env.example (never overwrites)
	@$(SCRIPTS)/vaultctl.sh init

render: ## Regenerate vault/secrets/* from vault/*.env
	@$(SCRIPTS)/vaultctl.sh render

show: ## Show which vault values are populated (never prints values)
	@$(SCRIPTS)/vaultctl.sh show

set-oauth: ## Set an OAuth value from stdin: make set-oauth KEY=GOOGLE_OAUTH_CLIENT_SECRET
	@test -n "$(KEY)" || { echo "ERROR: pass KEY=GOOGLE_OAUTH_CLIENT_ID|GOOGLE_OAUTH_CLIENT_SECRET" >&2; exit 1; }
	@$(SCRIPTS)/vaultctl.sh set oauth "$(KEY)" --stdin

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate: ## Run every preflight check without starting anything
	@$(SCRIPTS)/preflight.sh

validate-offline: ## Preflight checks that do not need a Docker daemon
	@$(SCRIPTS)/preflight.sh --no-docker

lint: ## Lint shell, Dockerfile and YAML (skips tools that are absent)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -S style $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh && echo "  ok      shellcheck"; \
	else echo "  skip    shellcheck (not installed)"; fi
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -s casc/ casc-recovery/ docker-compose.yml .github/ && echo "  ok      yamllint"; \
	else echo "  skip    yamllint (not installed)"; fi
	@if command -v hadolint >/dev/null 2>&1; then hadolint Dockerfile && echo "  ok      hadolint"; \
	elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then \
		docker run --rm -v "$$PWD:/repo:ro" -w /repo hadolint/hadolint:latest hadolint Dockerfile \
			&& echo "  ok      hadolint (via docker)"; \
	else echo "  skip    hadolint (not installed, no docker)"; fi
	@$(MAKE) --dry-run help >/dev/null && echo "  ok      Makefile parses"

# ---------------------------------------------------------------------------
# Build and run
# ---------------------------------------------------------------------------
build: ## Build the controller image
	@$(LOCK); \
	$(COMPOSE) build --pull

run: validate build up wait oauth-info ## Full path: validate, build, start, wait, next steps

up: render validate ## Start the controller in the background
	@$(LOCK); \
	$(COMPOSE) up -d --remove-orphans

wait: ## Block until the controller reports healthy
	@COMPOSE="$(COMPOSE_BIN)" $(SCRIPTS)/wait-healthy.sh

smoke: ## Assert login works AND anonymous access is denied
	@COMPOSE="$(COMPOSE_BIN)" $(SCRIPTS)/smoke.sh

oauth-info: ## Print the exact values to register in Google Cloud
	@$(SCRIPTS)/vaultctl.sh oauth-info

# ---------------------------------------------------------------------------
# Day-to-day operations
# ---------------------------------------------------------------------------
ps: ## Show container status
	@$(COMPOSE) ps

logs: ## Follow controller logs
	@$(COMPOSE) logs -f --tail=200 $(SERVICE)

logs-dump: ## Print recent logs and exit (CI-friendly, does not follow)
	@$(COMPOSE) logs --no-color --tail=300 $(SERVICE)

audit: ## Show only audit-trail entries (who did what)
	@$(COMPOSE) logs --no-color --tail=all $(SERVICE) | grep -E 'AUDIT(-RECOVERY)?' || \
		echo "(no audit entries yet -- they appear once users act on the controller)"

shell: ## Interactive shell in the running container
	@$(COMPOSE) exec $(SERVICE) bash

restart: render ## Restart the controller (reapplies casc/)
	@$(COMPOSE) restart -t 60 $(SERVICE)

down: ## Stop and remove the container (JENKINS_HOME volume is kept)
	@$(COMPOSE) down --remove-orphans

# ---------------------------------------------------------------------------
# Break-glass access
# ---------------------------------------------------------------------------
recovery-up: render ## Restart with the local break-glass admin (OAuth off)
	@$(LOCK); \
	echo "Starting in RECOVERY MODE -- Google OAuth disabled, local admin only."; \
	echo "Username: recovery-admin"; \
	$(SCRIPTS)/vaultctl.sh recovery-password; \
	CASC_JENKINS_CONFIG=$(RECOVERY_CASC) $(COMPOSE) up -d --force-recreate; \
	echo "Rotate the password after use: make recovery-rotate"

recovery-down: ## Return to the normal Google OAuth configuration
	@$(LOCK); \
	$(COMPOSE) up -d --force-recreate

recovery-rotate: ## Generate a new break-glass password
	@$(SCRIPTS)/vaultctl.sh rotate-recovery

# ---------------------------------------------------------------------------
# Supply chain and data
# ---------------------------------------------------------------------------
plugins-freeze: ## Write the running plugin set + versions to plugins.lock.txt
	@COMPOSE="$(COMPOSE_BIN)" $(SCRIPTS)/supply-chain.sh plugins-freeze

base-digest: ## Compare the pinned base image digest against Docker Hub
	@$(SCRIPTS)/supply-chain.sh base-digest

backup: ## Cold backup of JENKINS_HOME (stops, archives, restarts)
	@$(LOCK); \
	COMPOSE="$(COMPOSE_BIN)" $(SCRIPTS)/backup.sh create

restore: ## Restore: make restore ARCHIVE=backups/<file>.tar.gz CONFIRM=yes
	@test -n "$(ARCHIVE)" || { echo "ERROR: pass ARCHIVE=backups/<file>.tar.gz" >&2; exit 1; }
	@test "$(CONFIRM)" = "yes" || { \
		echo "ERROR: this REPLACES JENKINS_HOME. Re-run with CONFIRM=yes" >&2; exit 1; }
	@$(LOCK); \
	COMPOSE="$(COMPOSE_BIN)" $(SCRIPTS)/backup.sh restore "$(ARCHIVE)" --yes

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
clean: ## Stop everything and remove the built image (volume kept)
	@$(COMPOSE) down --remove-orphans --rmi local

nuke: ## Delete container, image AND all Jenkins data: make nuke CONFIRM=yes
	@test "$(CONFIRM)" = "yes" || { \
		echo "ERROR: this permanently deletes JENKINS_HOME (jobs, history, credentials)." >&2; \
		echo "       Re-run with CONFIRM=yes" >&2; exit 1; }
	@$(LOCK); \
	$(COMPOSE) down --remove-orphans --rmi local --volumes; \
	echo "  removed containers, image and the JENKINS_HOME volume"
