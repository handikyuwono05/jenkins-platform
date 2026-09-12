#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers: environment-file access, Compose detection, and safe writes.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
repo_root() {
	# Resolve from this file's location so scripts work from any CWD, and do
	# not depend on git being present.
	cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

REPO_ROOT="${REPO_ROOT:-$(repo_root)}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${REPO_ROOT}/template}"
VAULT_DIR="${VAULT_DIR:-${REPO_ROOT}/vault}"
SECRET_DIR="${SECRET_DIR:-${VAULT_DIR}/secrets}"
SETTINGS_ENV="${SETTINGS_ENV:-${VAULT_DIR}/jenkins.env}"
OAUTH_ENV="${OAUTH_ENV:-${VAULT_DIR}/oauth.env}"
RECOVERY_ENV="${RECOVERY_ENV:-${VAULT_DIR}/recovery.env}"

# Secret name -> "<env file>:<KEY>". These names are also the filenames under
# /run/secrets, which is how casc/jenkins.yaml refers to them.
# shellcheck disable=SC2034 # read by the scripts that source this library
SECRET_SPECS=(
	"google_oauth_client_id:${OAUTH_ENV}:GOOGLE_OAUTH_CLIENT_ID"
	"google_oauth_client_secret:${OAUTH_ENV}:GOOGLE_OAUTH_CLIENT_SECRET"
	"recovery_admin_password:${RECOVERY_ENV}:RECOVERY_ADMIN_PASSWORD"
)

# shellcheck disable=SC2034 # read by the scripts that source this library
REQUIRED_SETTINGS=(JENKINS_URL JENKINS_ADMIN_EMAIL GOOGLE_ALLOWED_DOMAINS)

require_cmd() {
	local cmd=$1
	command -v "$cmd" >/dev/null 2>&1 || die "required command not found in PATH: ${cmd}"
}

# ---------------------------------------------------------------------------
# Environment files
#
# These are read with awk, never sourced. Sourcing a config file executes it
# (arbitrary code from a file that looks like data) and mishandles legitimate
# values containing spaces, e.g. "a.co.id, b.co.id".
# ---------------------------------------------------------------------------
env_get() {
	local file=$1 key=$2
	[ -f "$file" ] || return 0
	awk -v k="$key" '
		index($0, k "=") == 1 { sub(/^[^=]*=/, ""); v = $0 }
		END { print v }
	' "$file" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

env_require() {
	local file=$1 key=$2 value
	value=$(env_get "$file" "$key")
	[ -n "$value" ] || die "${key} is unset or empty in ${file}"
	printf '%s' "$value"
}

# Set a key atomically. awk avoids sed's metacharacter problem: a generated
# password may legitimately contain '/', '&' or '\'.
env_set() {
	local file=$1 key=$2 value=$3 tmp
	[ -f "$file" ] || die "cannot set ${key}: ${file} does not exist"
	tmp=$(mktemp "${file}.XXXXXX")
	awk -v k="$key" -v v="$value" '
		index($0, k "=") == 1 { print k "=" v; found = 1; next }
		{ print }
		END { if (!found) print k "=" v }
	' "$file" >"$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Mode of the rendered secret files. 0644 is deliberate and is NOT a weaker
# choice than 0600 here:
#
#   Compose (outside Swarm) bind-mounts a file secret into the container with
#   the host file's ownership and permissions intact. The container runs as uid
#   1000, while these files are owned by whoever ran `make init`. At 0600 the
#   container cannot read them, and Jenkins dies at boot with
#   AccessDeniedException on /run/secrets/<name>. The uid/gid/mode fields of a
#   Compose secret are Swarm-only and ignored here, so the file mode is the
#   only lever.
#
#   Host-side confidentiality comes from the directory instead: vault/secrets
#   is 0700, so no other user on the host can traverse into it. Docker resolves
#   the path once, as root, at mount time, so the container never needs that
#   traversal. Inside the container the only readers are uid 1000 and root --
#   exactly who needs the value.
SECRET_FILE_MODE=644

# Write a secret value with no trailing newline, atomically: a container
# starting concurrently must never observe a half-written secret.
# Returns 0 if the file changed, 1 if it was already correct.
write_secret_file() {
	local path=$1 value=$2 tmp
	if [ -f "$path" ] && [ "$(cat "$path")" = "$value" ]; then
		# The content is current but the mode may have drifted (or predate a
		# change to SECRET_FILE_MODE), so enforce it regardless. This is what
		# makes `make render` able to repair a file the container cannot read.
		chmod "$SECRET_FILE_MODE" "$path"
		return 1
	fi
	tmp=$(mktemp "${path}.XXXXXX")
	printf '%s' "$value" >"$tmp"
	chmod "$SECRET_FILE_MODE" "$tmp"
	mv -f "$tmp" "$path"
	return 0
}

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------
compose_cmd() {
	if [ -n "${COMPOSE:-}" ]; then
		printf '%s' "$COMPOSE"
	elif docker compose version >/dev/null 2>&1; then
		printf 'docker compose'
	elif command -v docker-compose >/dev/null 2>&1; then
		printf 'docker-compose'
	else
		die "neither 'docker compose' nor 'docker-compose' is available"
	fi
}

# Compose interpolates ${...} in docker-compose.yml from this file.
compose() {
	local cmd
	cmd=$(compose_cmd)
	# shellcheck disable=SC2086 # cmd is a deliberate two-word command
	$cmd --env-file "$SETTINGS_ENV" "$@"
}
