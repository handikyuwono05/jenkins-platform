#!/usr/bin/env bash
#
# smoke.sh -- assertions against a RUNNING controller.
#
# These are security assertions, not just liveness: a Jenkins that boots but
# serves its API to anonymous users has failed, even though it is "up".
#
#   1. GET /login returns 200                     (the realm is serving)
#   2. the login page offers Google sign-in        (the OAuth realm applied)
#   3. anonymous GET /api/json is denied           (authorisation applied)
#   4. no JCasC errors in the container logs       (config fully applied)
#
# All assertions run even if an earlier one fails, so one run reports the whole
# picture. Exit 0 only if every assertion passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="smoke"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

FAILURES=0

fail() {
	log_error "FAIL    $*"
	FAILURES=$((FAILURES + 1))
}

pass() {
	log_info "ok      $*"
}

base_url() {
	local bind port
	bind=$(env_get "$SETTINGS_ENV" JENKINS_HTTP_BIND)
	port=$(env_get "$SETTINGS_ENV" JENKINS_HTTP_PORT)
	printf 'http://%s:%s' "${bind:-127.0.0.1}" "${port:-8080}"
}

assert_login_page() {
	local base=$1 code
	code=$(curl -fsS -o /dev/null -w '%{http_code}' "${base}/login" 2>/dev/null || true)
	if [ "$code" = "200" ]; then
		pass "GET /login -> 200"
	else
		fail "GET /login returned '${code}', expected 200"
	fi
}

assert_google_signin_offered() {
	local base=$1 body
	body=$(curl -fsS "${base}/login" 2>/dev/null || true)
	if printf '%s' "$body" | grep -Eqi 'commencelogin|google'; then
		pass "login page offers Google sign-in"
	else
		fail "login page does not reference Google -- is the googleOAuth2 realm applied?"
	fi
}

# The important one. Jenkins' defaults are permissive; this proves the
# globalMatrix strategy took effect and anonymous holds no read permission.
assert_anonymous_denied() {
	local base=$1 code
	code=$(curl -s -o /dev/null -w '%{http_code}' "${base}/api/json" 2>/dev/null || true)
	case "$code" in
	401 | 403) pass "anonymous GET /api/json -> ${code} (denied)" ;;
	*) fail "anonymous GET /api/json returned '${code}' -- anonymous users can read this Jenkins" ;;
	esac
}

assert_no_casc_errors() {
	local logs
	logs=$(compose logs --no-color --tail=all jenkins 2>/dev/null || true)
	if printf '%s' "$logs" | grep -qiE 'Failed to (apply|configure)|ConfiguratorException|IllegalArgumentException: No such'; then
		fail "JCasC reported errors in the container log:"
		printf '%s' "$logs" | grep -iE 'Failed to (apply|configure)|ConfiguratorException|IllegalArgumentException: No such' |
			head -5 | sed 's/^/        /' >&2
	else
		pass "no JCasC errors in logs"
	fi
}

main() {
	require_cmd curl
	[ -f "$SETTINGS_ENV" ] || die "missing ${SETTINGS_ENV} -- run: make init"

	local base
	base=$(base_url)
	log_info "target ${base}"

	assert_login_page "$base"
	assert_google_signin_offered "$base"
	assert_anonymous_denied "$base"
	assert_no_casc_errors

	if [ "$FAILURES" -gt 0 ]; then
		log_error "smoke tests failed: ${FAILURES} assertion(s)"
		trap - ERR
		exit 1
	fi
	log_info "all smoke assertions passed"
}

main "$@"
