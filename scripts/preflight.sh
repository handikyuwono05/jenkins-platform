#!/usr/bin/env bash
#
# preflight.sh -- validate everything that can be validated before starting
# the controller. Read-only: this script never changes configuration.
#
#   --no-docker   skip the checks that need a Docker daemon
#
# Failures are accumulated and all reported, rather than stopping at the first:
# an operator fixing configuration wants the whole list in one pass.
#
# Exit codes: 0 all checks passed (warnings allowed), 1 at least one failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="preflight"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

FAILURES=0
CHECK_DOCKER=1

fail() {
	log_error "$@"
	FAILURES=$((FAILURES + 1))
}

pass() {
	log_info "ok      $*"
}

# Report success only if the calling check added no failures. Snapshot
# $FAILURES at the top of a check and pass it here.
pass_unless_failed() {
	local before=$1
	shift
	if [ "$FAILURES" -eq "$before" ]; then
		pass "$@"
	fi
}

# ---------------------------------------------------------------------------
check_tools() {
	local missing=0
	local cmd
	for cmd in awk sed curl; do
		command -v "$cmd" >/dev/null 2>&1 || {
			fail "required command not found: ${cmd}"
			missing=1
		}
	done

	if [ "$CHECK_DOCKER" -eq 1 ]; then
		if ! command -v docker >/dev/null 2>&1; then
			fail "docker not found in PATH"
			missing=1
		elif ! docker info >/dev/null 2>&1; then
			fail "cannot reach the Docker daemon -- is it running?"
			missing=1
		fi
	fi
	[ "$missing" -eq 1 ] || pass "required tools present"
}

# ---------------------------------------------------------------------------
check_vault_files() {
	local before=$FAILURES
	[ -d "$VAULT_DIR" ] || {
		fail "vault/ not found -- run: make init"
		return 0
	}

	local f
	for f in "$SETTINGS_ENV" "$OAUTH_ENV" "$RECOVERY_ENV"; do
		if [ ! -f "$f" ]; then
			fail "missing ${f#"${REPO_ROOT}"/} -- run: make init"
			continue
		fi
		local mode
		mode=$(file_mode "$f")
		case "$mode" in
		600 | 400) ;;
		*) log_warn "${f#"${REPO_ROOT}"/} mode ${mode} is group/world readable; chmod 600 it" ;;
		esac
	done

	local dir_mode
	if [ -d "$VAULT_DIR" ]; then
		dir_mode=$(file_mode "$VAULT_DIR")
		case "$dir_mode" in
		700 | 500) ;;
		*) log_warn "vault/ mode ${dir_mode} is group/world readable; chmod 700 it" ;;
		esac
	fi
	pass_unless_failed "$before" "vault files present"
}

# ---------------------------------------------------------------------------
check_settings() {
	local before=$FAILURES
	[ -f "$SETTINGS_ENV" ] || return 0

	local key value missing=()
	for key in "${REQUIRED_SETTINGS[@]}"; do
		value=$(env_get "$SETTINGS_ENV" "$key")
		[ -n "$value" ] || missing+=("$key")
	done
	if [ ${#missing[@]} -gt 0 ]; then
		fail "unset in vault/jenkins.env: ${missing[*]}"
		return 0
	fi

	local url admin domains
	url=$(env_get "$SETTINGS_ENV" JENKINS_URL)
	admin=$(env_get "$SETTINGS_ENV" JENKINS_ADMIN_EMAIL)
	domains=$(env_get "$SETTINGS_ENV" GOOGLE_ALLOWED_DOMAINS)

	# Placeholders left in place mean the operator has not finished step 3.
	case "${admin}${domains}" in
	*yourdomain.co.id*)
		fail "vault/jenkins.env still contains the placeholder domain yourdomain.co.id"
		;;
	esac

	# The OAuth redirect URI is built as <url>securityRealm/finishLogin, so a
	# missing trailing slash silently produces a URI Google will reject.
	case "$url" in
	*/) ;;
	*) fail "JENKINS_URL must end with a trailing slash (got '${url}')" ;;
	esac

	case "$url" in
	https://*) ;;
	http://localhost* | http://127.0.0.1*)
		log_info "note    plain HTTP on localhost is accepted by Google for development only"
		;;
	*) fail "Google requires https for any JENKINS_URL other than localhost (got '${url}')" ;;
	esac

	# The lockout case: authentication succeeds but nobody holds admin.
	local admin_domain allowed
	admin_domain=${admin##*@}
	if ! printf '%s' "$domains" | tr ',' '\n' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
		grep -Fqx "$admin_domain"; then
		fail "JENKINS_ADMIN_EMAIL domain '${admin_domain}' is not in GOOGLE_ALLOWED_DOMAINS ('${domains}') -- the admin could never log in"
	fi

	while IFS= read -r allowed; do
		[ -n "$allowed" ] || continue
		case "$allowed" in
		gmail.com | googlemail.com)
			log_warn "GOOGLE_ALLOWED_DOMAINS includes '${allowed}' -- that is every consumer Google account, i.e. effectively no restriction"
			;;
		esac
	done < <(printf '%s' "$domains" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

	pass_unless_failed "$before" "vault/jenkins.env"
}

# ---------------------------------------------------------------------------
check_secrets() {
	local before=$FAILURES
	local spec name file key value
	for spec in "${SECRET_SPECS[@]}"; do
		name=${spec%%:*}
		file=${spec#*:}
		key=${file#*:}
		file=${file%%:*}

		value=$(env_get "$file" "$key")
		if [ -z "$value" ]; then
			fail "${key} is empty in ${file#"${REPO_ROOT}"/}"
			continue
		fi

		# Rendered file must exist and match, or the container would mount a
		# stale secret.
		if [ ! -s "${SECRET_DIR}/${name}" ]; then
			fail "vault/secrets/${name} is missing or empty -- run: make render"
		elif [ "$(cat "${SECRET_DIR}/${name}")" != "$value" ]; then
			fail "vault/secrets/${name} is stale (differs from ${key}) -- run: make render"
		fi
	done

	check_secret_file_permissions

	local client_id
	client_id=$(env_get "$OAUTH_ENV" GOOGLE_OAUTH_CLIENT_ID)
	if [ -n "$client_id" ]; then
		case "$client_id" in
		*apps.googleusercontent.com) ;;
		*) log_warn "GOOGLE_OAUTH_CLIENT_ID does not look like a Google client ID (expected ...apps.googleusercontent.com)" ;;
		esac
	fi
	pass_unless_failed "$before" "secrets rendered and current"
}

# Compose bind-mounts file secrets with their host ownership and permissions,
# and the container runs as uid 1000. A secret the container cannot read makes
# Jenkins die at boot with AccessDeniedException on /run/secrets/<name>, so the
# readable bit is a startup requirement, not a style preference. Host-side
# confidentiality is the directory's job (0700), not the file's.
CONTAINER_UID=1000

check_secret_file_permissions() {
	local before=$FAILURES

	if [ -d "$SECRET_DIR" ]; then
		local dir_mode
		dir_mode=$(file_mode "$SECRET_DIR")
		case "$dir_mode" in
		700 | 500) ;;
		*) log_warn "vault/secrets mode ${dir_mode} lets other host users traverse it; chmod 700 it" ;;
		esac
	fi

	local spec name f mode owner
	for spec in "${SECRET_SPECS[@]}"; do
		name=${spec%%:*}
		f="${SECRET_DIR}/${name}"
		[ -f "$f" ] || continue

		mode=$(file_mode "$f")
		owner=$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f")

		if [ $((8#$mode & 8#004)) -eq 0 ] && [ "$owner" != "$CONTAINER_UID" ]; then
			fail "vault/secrets/${name} (mode ${mode}, owner uid ${owner}) is not readable by the container user (uid ${CONTAINER_UID})"
			log_error "        Jenkins would fail at boot with AccessDeniedException on /run/secrets/${name}"
			log_error "        fix with: make render"
		fi
	done

	pass_unless_failed "$before" "secret files readable by the container user"
}

# ---------------------------------------------------------------------------
check_casc_yaml() {
	local before=$FAILURES
	if ! command -v python3 >/dev/null 2>&1 ||
		! python3 -c 'import yaml' >/dev/null 2>&1; then
		log_warn "skipping casc YAML syntax check (needs python3 + PyYAML)"
		return 0
	fi
	local f
	for f in "${REPO_ROOT}"/casc/*.yaml "${REPO_ROOT}"/casc-recovery/*.yaml; do
		[ -f "$f" ] || continue
		python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" ||
			fail "invalid YAML: ${f#"${REPO_ROOT}"/}"
	done
	pass_unless_failed "$before" "casc YAML syntax"
}

# ---------------------------------------------------------------------------
# A tag is mutable, a digest is not. The pin is duplicated in three files for
# usability, so its consistency has to be enforced rather than trusted.
check_base_image_pin() {
	local from_dockerfile from_compose from_template
	from_dockerfile=$(grep -oE 'jenkins/jenkins:[^ ]+' "${REPO_ROOT}/Dockerfile" | head -1)
	from_compose=$(grep -oE 'jenkins/jenkins:[^}"]+' "${REPO_ROOT}/docker-compose.yml" | head -1)
	from_template=$(grep -oE 'jenkins/jenkins:[^ ]+' "${REPO_ROOT}/template/jenkins.env.example" | head -1)

	if [ "$from_dockerfile" != "$from_compose" ] || [ "$from_dockerfile" != "$from_template" ]; then
		fail "pinned base image drifted between files:"
		log_error "  Dockerfile                 ${from_dockerfile}"
		log_error "  docker-compose.yml         ${from_compose}"
		log_error "  template/jenkins.env.example ${from_template}"
		return 0
	fi
	case "$from_dockerfile" in
	*@sha256:*) pass "base image pinned by digest (${from_dockerfile##*@})" ;;
	*) fail "base image is not pinned by digest: ${from_dockerfile}" ;;
	esac
}

# ---------------------------------------------------------------------------
check_git_hygiene() {
	command -v git >/dev/null 2>&1 || return 0
	git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0

	local tracked
	tracked=$(git -C "$REPO_ROOT" ls-files vault 2>/dev/null | grep -vE '\.gitkeep$' || true)
	if [ -n "$tracked" ]; then
		fail "vault contents are tracked by git:"
		log_error "  ${tracked//$'\n'/, }"
		log_error "  fix with: git rm -r --cached vault"
		return 0
	fi
	pass "no vault contents tracked by git"
}

# ---------------------------------------------------------------------------
check_compose_config() {
	[ "$CHECK_DOCKER" -eq 1 ] || {
		log_warn "skipping compose config check (--no-docker)"
		return 0
	}
	[ -f "$SETTINGS_ENV" ] || return 0
	if compose config -q >/dev/null 2>&1; then
		pass "docker-compose.yml"
	else
		fail "docker-compose.yml is invalid:"
		compose config -q 2>&1 | sed 's/^/  /' >&2 || true
	fi
}

# ---------------------------------------------------------------------------
main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--no-docker) CHECK_DOCKER=0 ;;
		-h | --help)
			sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			return 0
			;;
		*) die "unknown argument: $1" ;;
		esac
		shift
	done

	check_tools
	check_vault_files
	check_settings
	check_secrets
	check_casc_yaml
	check_base_image_pin
	check_git_hygiene
	check_compose_config

	if [ "$FAILURES" -gt 0 ]; then
		log_error "preflight failed: ${FAILURES} problem(s) above must be fixed"
		# This exit is the expected outcome of a failed check, not a crash;
		# leaving the ERR trap armed would report it as an internal error.
		trap - ERR
		exit 1
	fi
	log_info "preflight passed"
}

main "$@"
