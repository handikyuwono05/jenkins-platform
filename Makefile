# ---------------------------------------------------------------------------
# jenkins-platform -- build and run a Configuration-as-Code Jenkins
# controller with Google OAuth login.
#
#   make init      then edit .env + secrets/, then:
#   make run       build, start, wait for healthy, print next steps
#   make help      all targets
#
# Requires GNU Make 4.x (macOS ships 3.81: brew install make, use gmake).
# ---------------------------------------------------------------------------
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Prefer the Compose v2 plugin, fall back to the standalone binary.
COMPOSE ?= $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; \
	elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; fi)

SERVICE          := jenkins
ENV_FILE         := .env
SECRET_DIR       := secrets
REQUIRED_SECRETS := google_oauth_client_id google_oauth_client_secret recovery_admin_password
REQUIRED_VARS    := JENKINS_URL JENKINS_ADMIN_EMAIL GOOGLE_ALLOWED_DOMAINS
LOCK_DIR         := .make-lock
BACKUP_DIR       := backups
RECOVERY_CASC    := /var/jenkins_conf/casc-recovery
HEALTH_TIMEOUT   ?= 300
PINNED_TAG       := 2.568.3-lts-jdk21

# Stamped into the image as an OCI label so a running container can be traced
# back to a commit.
BUILD_REVISION := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
export BUILD_REVISION

# Mutating targets take an advisory lock. Two concurrent `make up` runs, or a
# build racing a restore, both write the same JENKINS_HOME volume -- Jenkins
# assumes a single writer and will corrupt its state otherwise. mkdir is
# atomic on POSIX filesystems, which is the property we need here.
# Read one value out of .env WITHOUT sourcing it. Sourcing would execute the
# file's contents (a config file should never be code) and would also choke on
# perfectly valid values containing spaces, e.g. "a.co.id, b.co.id".
EGET = eget() { awk -v k="$$1" 'index($$0,k"=")==1{sub(/^[^=]*=/,"");v=$$0} END{print v}' \
	$(ENV_FILE) | sed -e 's/^"//' -e 's/"$$//'; };

LOCK = mkdir $(LOCK_DIR) 2>/dev/null || { \
		echo "ERROR: $(LOCK_DIR) exists -- another make target is running." >&2; \
		echo "       If you are sure it is stale: rmdir $(LOCK_DIR)" >&2; exit 1; }; \
	trap 'rmdir $(LOCK_DIR) 2>/dev/null || true' EXIT

# Targets share an advisory lock and a single Docker daemon; `make -j run`
# would have build and up contend for both. Ordering here is correctness, not
# preference.
.NOTPARALLEL:

.PHONY: help init check-tools check-env check-secrets validate build up run wait \
	down restart logs audit shell ps smoke oauth-info recovery-up recovery-down \
	recovery-rotate plugins-freeze base-digest backup restore clean nuke

help: ## Show this help
	@echo "jenkins-platform -- targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
check-tools: ## Verify docker + compose are available
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH." >&2; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "ERROR: cannot reach the Docker daemon. Is it running?" >&2; exit 1; }
	@test -n "$(COMPOSE)" || { echo "ERROR: neither 'docker compose' nor 'docker-compose' is available." >&2; exit 1; }

init: ## Create .env and secrets/ skeleton (safe to re-run; never overwrites)
	@test -f $(ENV_FILE) && echo "  keep    $(ENV_FILE) (already exists)" || { \
		cp .env.example $(ENV_FILE); chmod 600 $(ENV_FILE); echo "  create  $(ENV_FILE)"; }
	@mkdir -p $(SECRET_DIR)
	@for s in google_oauth_client_id google_oauth_client_secret; do \
		if [ -f "$(SECRET_DIR)/$$s" ]; then echo "  keep    $(SECRET_DIR)/$$s"; \
		else : > "$(SECRET_DIR)/$$s"; chmod 600 "$(SECRET_DIR)/$$s"; \
			echo "  create  $(SECRET_DIR)/$$s (EMPTY -- paste the value from Google Cloud)"; fi; \
	done
	@if [ -s "$(SECRET_DIR)/recovery_admin_password" ]; then \
		echo "  keep    $(SECRET_DIR)/recovery_admin_password"; \
	elif command -v openssl >/dev/null 2>&1; then \
		openssl rand -base64 24 | tr -d '\n' > "$(SECRET_DIR)/recovery_admin_password"; \
		chmod 600 "$(SECRET_DIR)/recovery_admin_password"; \
		echo "  create  $(SECRET_DIR)/recovery_admin_password (random, 24 bytes)"; \
	else \
		echo "ERROR: openssl not found -- create $(SECRET_DIR)/recovery_admin_password by hand." >&2; exit 1; fi
	@echo ""
	@echo "Next:"
	@echo "  1. Register an OAuth client in Google Cloud   -- see: make oauth-info"
	@echo "  2. Fill in $(SECRET_DIR)/google_oauth_client_id and _client_secret"
	@echo "  3. Edit $(ENV_FILE): JENKINS_URL, JENKINS_ADMIN_EMAIL, GOOGLE_ALLOWED_DOMAINS"
	@echo "  4. make run"

check-env: ## Validate .env (catches the misconfigurations that lock you out)
	@test -f $(ENV_FILE) || { echo "ERROR: $(ENV_FILE) missing. Run: make init" >&2; exit 1; }
	@$(EGET) \
	missing=""; \
	for v in $(REQUIRED_VARS); do [ -n "$$(eget $$v)" ] || missing="$$missing $$v"; done; \
	if [ -n "$$missing" ]; then echo "ERROR: unset in $(ENV_FILE):$$missing" >&2; exit 1; fi; \
	if grep -qE '^(JENKINS_ADMIN_EMAIL|GOOGLE_ALLOWED_DOMAINS)=.*yourdomain\.co\.id' $(ENV_FILE); then \
		echo "ERROR: $(ENV_FILE) still contains the placeholder domain yourdomain.co.id." >&2; exit 1; fi; \
	url=$$(eget JENKINS_URL); admin=$$(eget JENKINS_ADMIN_EMAIL); domains=$$(eget GOOGLE_ALLOWED_DOMAINS); \
	case "$$url" in */) ;; *) \
		echo "ERROR: JENKINS_URL must end with a trailing slash ('$$url')." >&2; \
		echo "       The OAuth redirect URI is built as <JENKINS_URL>securityRealm/finishLogin." >&2; \
		exit 1;; esac; \
	admin_domain="$${admin##*@}"; \
	if ! printf '%s' "$$domains" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$$//' \
		| grep -Fqx "$$admin_domain"; then \
		echo "ERROR: JENKINS_ADMIN_EMAIL domain '$$admin_domain' is not in GOOGLE_ALLOWED_DOMAINS" >&2; \
		echo "       ('$$domains'). The admin could never log in." >&2; exit 1; fi; \
	case "$$url" in \
		https://*) ;; \
		http://localhost*|http://127.0.0.1*) \
			echo "NOTE:  plain HTTP on localhost is accepted by Google for development only." ;; \
		*) echo "ERROR: Google requires https for any JENKINS_URL other than localhost." >&2; exit 1;; \
	esac; \
	for d in $$(printf '%s' "$$domains" | tr ',' ' '); do \
		case "$$d" in gmail.com|googlemail.com) \
			echo "WARN:  GOOGLE_ALLOWED_DOMAINS includes '$$d' -- that is every consumer" >&2; \
			echo "       Google account, i.e. effectively no restriction at all." >&2;; esac; \
	done; \
	echo "  ok      $(ENV_FILE)"

check-secrets: ## Verify runtime secret files exist, are non-empty and private
	@fail=0; \
	for s in $(REQUIRED_SECRETS); do \
		f="$(SECRET_DIR)/$$s"; \
		if [ ! -f "$$f" ]; then echo "ERROR: missing $$f (run: make init)" >&2; fail=1; continue; fi; \
		if [ ! -s "$$f" ]; then echo "ERROR: $$f is empty -- paste the value from Google Cloud." >&2; fail=1; continue; fi; \
		mode=$$(stat -c '%a' "$$f" 2>/dev/null || stat -f '%Lp' "$$f"); \
		case "$$mode" in 600|400) ;; *) echo "WARN:  $$f mode $$mode is group/world readable; chmod 600 it." >&2;; esac; \
	done; \
	if [ -s "$(SECRET_DIR)/google_oauth_client_id" ] && \
		! grep -q 'apps\.googleusercontent\.com' "$(SECRET_DIR)/google_oauth_client_id"; then \
		echo "WARN:  google_oauth_client_id does not look like a Google client ID" >&2; \
		echo "       (expected ...apps.googleusercontent.com)." >&2; fi; \
	test "$$fail" -eq 0 || exit 1; \
	echo "  ok      $(SECRET_DIR)/ ($(words $(REQUIRED_SECRETS)) files)"

validate: check-tools check-env check-secrets ## Run every preflight check without starting anything
	@$(COMPOSE) config -q && echo "  ok      docker-compose.yml"
	@python3 -c 'import yaml,glob,sys; [yaml.safe_load(open(f)) for f in glob.glob("casc*/*.yaml")]' \
		2>/dev/null && echo "  ok      casc YAML syntax" \
		|| echo "  skip    casc YAML syntax (needs python3 + PyYAML)"
	@dfile=$$(grep -oE 'jenkins/jenkins:[^ ]+' Dockerfile | head -1); \
	cfile=$$(grep -oE 'jenkins/jenkins:[^}"]+' docker-compose.yml | head -1); \
	if [ "$$dfile" != "$$cfile" ]; then \
		echo "ERROR: pinned base image drifted between files:" >&2; \
		echo "       Dockerfile:         $$dfile" >&2; \
		echo "       docker-compose.yml: $$cfile" >&2; exit 1; fi; \
	echo "  ok      base image pin matches ($$dfile)"
	@leaked=$$(git ls-files $(SECRET_DIR) 2>/dev/null | grep -vE '(README\.md|\.gitkeep)$$' || true); \
	if [ -n "$$leaked" ]; then echo "ERROR: secrets are tracked by git: $$leaked" >&2; exit 1; fi; \
	if git ls-files --error-unmatch $(ENV_FILE) >/dev/null 2>&1; then \
		echo "ERROR: $(ENV_FILE) is tracked by git. git rm --cached $(ENV_FILE)" >&2; exit 1; fi; \
	echo "  ok      no secrets tracked by git"

# ---------------------------------------------------------------------------
# Build and run
# ---------------------------------------------------------------------------
build: check-tools ## Build the controller image
	@$(LOCK); \
	$(COMPOSE) build --pull

run: validate build up wait oauth-info ## Full path: validate, build, start, wait, next steps

up: validate ## Start the controller in the background
	@$(LOCK); \
	$(COMPOSE) up -d --remove-orphans

wait: ## Block until the controller reports healthy
	@cid=$$($(COMPOSE) ps -q $(SERVICE)); \
	test -n "$$cid" || { echo "ERROR: $(SERVICE) is not running (make up)." >&2; exit 1; }; \
	printf 'waiting for healthy (timeout %ss)' '$(HEALTH_TIMEOUT)'; \
	elapsed=0; \
	while :; do \
		status=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$$cid"); \
		case "$$status" in \
			healthy) echo " -> healthy"; break;; \
			none) echo; echo "ERROR: container has no healthcheck." >&2; exit 1;; \
		esac; \
		if [ "$$(docker inspect -f '{{.State.Running}}' "$$cid")" != "true" ]; then \
			echo; echo "ERROR: container exited. Last 40 log lines:" >&2; \
			$(COMPOSE) logs --tail=40 $(SERVICE) >&2; exit 1; fi; \
		if [ "$$elapsed" -ge $(HEALTH_TIMEOUT) ]; then \
			echo; echo "ERROR: still '$$status' after $(HEALTH_TIMEOUT)s. Last 40 log lines:" >&2; \
			$(COMPOSE) logs --tail=40 $(SERVICE) >&2; exit 1; fi; \
		printf '.'; sleep 5; elapsed=$$((elapsed + 5)); \
	done

smoke: ## Assert the login page works AND anonymous access is denied
	@$(EGET) \
	bind=$$(eget JENKINS_HTTP_BIND); port=$$(eget JENKINS_HTTP_PORT); \
	base="http://$${bind:-127.0.0.1}:$${port:-8080}"; \
	code=$$(curl -fsS -o /dev/null -w '%{http_code}' "$$base/login" || true); \
	test "$$code" = "200" || { echo "FAIL: GET /login returned $$code, expected 200" >&2; exit 1; }; \
	echo "  ok      GET /login -> 200"; \
	body=$$(curl -fsS "$$base/login" || true); \
	printf '%s' "$$body" | grep -Eqi 'commencelogin|google' \
		&& echo "  ok      login page offers Google sign-in" \
		|| { echo "FAIL: login page does not reference Google -- is the realm applied?" >&2; exit 1; }; \
	anon=$$(curl -s -o /dev/null -w '%{http_code}' "$$base/api/json" || true); \
	case "$$anon" in 401|403) echo "  ok      anonymous /api/json -> $$anon (denied)";; \
		*) echo "FAIL: anonymous /api/json returned $$anon -- anonymous can read this Jenkins." >&2; exit 1;; esac; \
	if $(COMPOSE) logs --no-color $(SERVICE) 2>/dev/null | grep -qiE 'Failed to (apply|configure)|ConfiguratorException'; then \
		echo "FAIL: JCasC reported errors; see: make logs" >&2; exit 1; fi; \
	echo "  ok      no JCasC errors in logs"

oauth-info: ## Print the exact values to register in Google Cloud
	@$(EGET) \
	url=$$(eget JENKINS_URL); \
	echo ""; \
	echo "Google Cloud -> APIs & Services -> Credentials -> OAuth client ID (Web application):"; \
	echo "  Authorised redirect URI : $${url}securityRealm/finishLogin"; \
	echo "  Authorised JS origin    : $$(printf '%s' "$$url" | sed 's:/*$$::')"; \
	echo ""; \
	echo "Sign in at $${url} as $$(eget JENKINS_ADMIN_EMAIL)"; \
	echo "Allowed domains: $$(eget GOOGLE_ALLOWED_DOMAINS)"; \
	echo 

# ---------------------------------------------------------------------------
# Day-to-day operations
# ---------------------------------------------------------------------------
ps: ## Show container status
	@$(COMPOSE) ps

logs: ## Follow controller logs
	@$(COMPOSE) logs -f --tail=200 $(SERVICE)

audit: ## Show only audit-trail entries (who did what)
	@$(COMPOSE) logs --no-color --tail=all $(SERVICE) | grep -E 'AUDIT(-RECOVERY)?' || \
		echo "(no audit entries yet -- they appear once users act on the controller)"

shell: ## Interactive shell in the running container
	@$(COMPOSE) exec $(SERVICE) bash

restart: ## Restart the controller (reapplies casc/)
	@$(COMPOSE) restart -t 60 $(SERVICE)

down: ## Stop and remove the container (JENKINS_HOME volume is kept)
	@$(COMPOSE) down --remove-orphans

# ---------------------------------------------------------------------------
# Break-glass access
# ---------------------------------------------------------------------------
recovery-up: check-tools ## Restart with the local break-glass admin (OAuth off)
	@$(LOCK); \
	echo "Starting in RECOVERY MODE -- Google OAuth disabled, local admin only."; \
	echo "Username: recovery-admin"; \
	echo "Password: $$(cat $(SECRET_DIR)/recovery_admin_password)"; \
	CASC_JENKINS_CONFIG=$(RECOVERY_CASC) $(COMPOSE) up -d --force-recreate; \
	echo "Rotate the recovery password after use: make recovery-rotate"

recovery-down: check-tools ## Return to the normal Google OAuth configuration
	@$(LOCK); \
	$(COMPOSE) up -d --force-recreate

recovery-rotate: ## Generate a new break-glass password
	@openssl rand -base64 24 | tr -d '\n' > $(SECRET_DIR)/recovery_admin_password
	@chmod 600 $(SECRET_DIR)/recovery_admin_password
	@echo "  rotated $(SECRET_DIR)/recovery_admin_password (takes effect on next restart)"

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
plugins-freeze: ## Write the running plugin set + versions to plugins.lock.txt
	@$(COMPOSE) exec -T $(SERVICE) bash -c 'for d in /var/jenkins_home/plugins/*/; do \
		[ -f "$$d/META-INF/MANIFEST.MF" ] || continue; \
		n=$$(basename "$$d"); \
		v=$$(tr -d "\r" < "$$d/META-INF/MANIFEST.MF" | awk "/^Plugin-Version:/{print \$$2; exit}"); \
		echo "$$n:$$v"; done' | sort > plugins.lock.txt
	@echo "  wrote   plugins.lock.txt ($$(wc -l < plugins.lock.txt) plugins)"
	@echo "          Copy these pins into plugins.txt for reproducible builds."

base-digest: ## Compare the pinned base image digest against Docker Hub
	@pinned=$$(grep -oE 'sha256:[0-9a-f]{64}' Dockerfile | head -1); \
	current=$$(curl -fsS "https://hub.docker.com/v2/repositories/jenkins/jenkins/tags/$(PINNED_TAG)" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'); \
	echo "  pinned  $$pinned"; \
	echo "  hub     $$current"; \
	if [ "$$pinned" = "$$current" ]; then echo "  ok      pin is current for tag $(PINNED_TAG)"; \
	else echo "  DRIFT   update the digest in Dockerfile, docker-compose.yml and .env.example"; fi

backup: check-tools ## Cold backup of JENKINS_HOME (stops, archives, restarts)
	@$(LOCK); \
	mkdir -p $(BACKUP_DIR); \
	out="$(BACKUP_DIR)/jenkins_home-$$(date +%Y%m%d-%H%M%S).tar.gz"; \
	echo "Stopping the controller for a consistent archive..."; \
	$(COMPOSE) stop -t 60 $(SERVICE); \
	$(COMPOSE) run --rm --no-deps -T --entrypoint sh $(SERVICE) \
		-c 'tar czf - -C /var/jenkins_home .' > "$$out"; \
	chmod 600 "$$out"; \
	echo "  wrote   $$out ($$(du -h "$$out" | cut -f1))"; \
	echo "  NOTE    this archive contains credentials and secret keys; store it encrypted."; \
	$(COMPOSE) start $(SERVICE)

restore: check-tools ## Restore a backup: make restore ARCHIVE=backups/<file>.tar.gz CONFIRM=yes
	@test -n "$(ARCHIVE)" || { echo "ERROR: pass ARCHIVE=backups/<file>.tar.gz" >&2; exit 1; }
	@test -f "$(ARCHIVE)" || { echo "ERROR: $(ARCHIVE) not found" >&2; exit 1; }
	@test "$(CONFIRM)" = "yes" || { \
		echo "ERROR: this REPLACES the contents of JENKINS_HOME. Re-run with CONFIRM=yes" >&2; exit 1; }
	@$(LOCK); \
	$(COMPOSE) stop -t 60 $(SERVICE); \
	$(COMPOSE) run --rm --no-deps -T --entrypoint sh $(SERVICE) \
		-c 'find /var/jenkins_home -mindepth 1 -delete; tar xzf - -C /var/jenkins_home' \
		< "$(ARCHIVE)"; \
	echo "  restored from $(ARCHIVE)"; \
	$(COMPOSE) up -d

clean: ## Stop everything and remove the built image (volume kept)
	@$(COMPOSE) down --remove-orphans --rmi local

nuke: ## Delete the container, image AND all Jenkins data: make nuke CONFIRM=yes
	@test "$(CONFIRM)" = "yes" || { \
		echo "ERROR: this permanently deletes JENKINS_HOME (jobs, history, credentials)." >&2; \
		echo "       Re-run with CONFIRM=yes" >&2; exit 1; }
	@$(LOCK); \
	$(COMPOSE) down --remove-orphans --rmi local --volumes; \
	echo "  removed containers, image and the JENKINS_HOME volume"
