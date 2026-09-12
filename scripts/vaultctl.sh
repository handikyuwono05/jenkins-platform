#!/usr/bin/env bash
#
# vaultctl.sh -- manage the local secret/configuration vault.
#
#   init             create vault/*.env from template/*.env.example (never
#                    overwrites) and generate the break-glass password
#   render           (re)write vault/secrets/* from vault/*.env for Compose
#   set <file> <KEY> [VALUE|--stdin]
#                    set one key; --stdin keeps the value out of shell history
#   rotate-recovery  generate a new break-glass password and re-render
#   show             print the vault layout and which values are populated
#                    (values themselves are never printed)
#   oauth-info       print the exact values to register in Google Cloud
#   recovery-password  print the break-glass password (only to a terminal)
#
# The *.env files are the human-editable source of truth. vault/secrets/* is
# GENERATED from them -- do not edit those by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="vaultctl"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

# Anything this script creates is secret by default.
umask 077

usage() {
	sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
cmd_init() {
	require_cmd awk
	[ -d "$TEMPLATE_DIR" ] || die "template directory not found: ${TEMPLATE_DIR}"

	local templates=("${TEMPLATE_DIR}"/*.env.example)
	[ -e "${templates[0]}" ] || die "no *.env.example files in ${TEMPLATE_DIR}"

	mkdir -p "$VAULT_DIR" "$SECRET_DIR"
	chmod 700 "$VAULT_DIR" "$SECRET_DIR"

	local tpl target created=0
	for tpl in "${templates[@]}"; do
		target="${VAULT_DIR}/$(basename "$tpl" .example)"
		if [ -f "$target" ]; then
			log_info "keep    ${target#"${REPO_ROOT}"/} (exists; not overwritten)"
			continue
		fi
		cp "$tpl" "$target"
		chmod 600 "$target"
		created=$((created + 1))
		log_info "create  ${target#"${REPO_ROOT}"/}"
	done

	generate_recovery_password_if_absent
	cmd_render --lenient

	log_info "vault initialised (${created} file(s) created)"
	cat <<'NEXT'

Next steps:
  1. Register an OAuth client in Google Cloud     -> make oauth-info
  2. Put the client ID and secret into vault/oauth.env
  3. Edit vault/jenkins.env: JENKINS_URL, JENKINS_ADMIN_EMAIL,
     GOOGLE_ALLOWED_DOMAINS
  4. make run

To avoid shell history, set the secret via stdin:
  printf '%s' 'GOCSPX-...' | ./scripts/vaultctl.sh set oauth GOOGLE_OAUTH_CLIENT_SECRET --stdin
NEXT
}

generate_recovery_password_if_absent() {
	[ -f "$RECOVERY_ENV" ] || die "missing ${RECOVERY_ENV}; run: vaultctl.sh init"

	local current
	current=$(env_get "$RECOVERY_ENV" RECOVERY_ADMIN_PASSWORD)
	if [ -n "$current" ]; then
		log_info "keep    vault/recovery.env (password already set)"
		return 0
	fi

	require_cmd openssl
	local generated
	generated=$(openssl rand -base64 24 | tr -d '\n')
	env_set "$RECOVERY_ENV" RECOVERY_ADMIN_PASSWORD "$generated"
	log_info "create  break-glass password in vault/recovery.env (random, 24 bytes)"
}

# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------
# --lenient: an empty value is a warning rather than a failure. Used while the
# vault is still being populated (init, set); `make up` always renders strictly.
cmd_render() {
	local lenient=0
	if [ "${1:-}" = "--lenient" ]; then
		lenient=1
	fi
	[ -d "$VAULT_DIR" ] || die "vault not initialised; run: make init"
	mkdir -p "$SECRET_DIR"
	chmod 700 "$SECRET_DIR"

	local spec name file key value changed=0 missing=()
	for spec in "${SECRET_SPECS[@]}"; do
		name=${spec%%:*}
		file=${spec#*:}
		key=${file#*:}
		file=${file%%:*}

		value=$(env_get "$file" "$key")
		if [ -z "$value" ]; then
			missing+=("${key} in ${file#"${REPO_ROOT}"/}")
			continue
		fi

		if write_secret_file "${SECRET_DIR}/${name}" "$value"; then
			changed=$((changed + 1))
			log_info "render  vault/secrets/${name}"
		else
			log_debug "render  vault/secrets/${name} (unchanged)"
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		local m
		for m in "${missing[@]}"; do
			if [ "$lenient" -eq 1 ]; then
				log_warn "not yet set: ${m}"
			else
				log_error "empty value: ${m}"
			fi
		done
		[ "$lenient" -eq 1 ] || die "cannot render ${#missing[@]} secret(s); fill the value(s) above"
	fi

	log_info "rendered ${#SECRET_SPECS[@]} secret file(s), ${changed} changed"
}

# ---------------------------------------------------------------------------
# set
# ---------------------------------------------------------------------------
cmd_set() {
	[ $# -ge 2 ] || die "usage: vaultctl.sh set <jenkins|oauth|recovery> <KEY> [VALUE|--stdin]"
	local target=$1 key=$2 value
	shift 2

	local file="${VAULT_DIR}/${target}.env"
	[ -f "$file" ] || die "no such vault file: ${file#"${REPO_ROOT}"/} (run: make init)"

	if [ $# -eq 0 ] || [ "${1:-}" = "--stdin" ]; then
		[ $# -gt 0 ] || log_info "reading value for ${key} from stdin"
		IFS= read -r value || true
	else
		value=$1
		log_warn "value passed as an argument: it is visible in shell history and"
		log_warn "in the process list. Prefer: printf '%s' VALUE | $0 set ${target} ${key} --stdin"
	fi

	[ -n "$value" ] || die "refusing to set ${key} to an empty value"
	env_set "$file" "$key" "$value"
	log_info "set     ${key} in ${file#"${REPO_ROOT}"/}"
	cmd_render --lenient
}

# ---------------------------------------------------------------------------
# rotate-recovery
# ---------------------------------------------------------------------------
cmd_rotate_recovery() {
	require_cmd openssl
	[ -f "$RECOVERY_ENV" ] || die "vault not initialised; run: make init"
	local generated
	generated=$(openssl rand -base64 24 | tr -d '\n')
	env_set "$RECOVERY_ENV" RECOVERY_ADMIN_PASSWORD "$generated"
	log_info "rotated break-glass password"
	cmd_render
	log_warn "takes effect on the next restart: make restart"
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------
cmd_show() {
	[ -d "$VAULT_DIR" ] || die "vault not initialised; run: make init"
	log_info "vault: ${VAULT_DIR#"${REPO_ROOT}"/} (mode $(file_mode "$VAULT_DIR"))"

	local f
	for f in "${VAULT_DIR}"/*.env; do
		[ -f "$f" ] || continue
		printf '  %-22s mode %s\n' "$(basename "$f")" "$(file_mode "$f")"
	done

	local spec name file key
	printf '\n  secret values (contents never shown):\n'
	for spec in "${SECRET_SPECS[@]}"; do
		name=${spec%%:*}
		file=${spec#*:}
		key=${file#*:}
		file=${file%%:*}
		if [ -n "$(env_get "$file" "$key")" ]; then
			printf '  %-30s SET\n' "$key"
		else
			printf '  %-30s EMPTY  <- fill in %s\n' "$key" "$(basename "$file")"
		fi
	done
}

# ---------------------------------------------------------------------------
# oauth-info
#
# The redirect URI is derived here exactly as the plugin derives it at runtime
# (root URL + "securityRealm/finishLogin"), so what is registered in Google
# Cloud cannot silently disagree with what Jenkins will send.
# ---------------------------------------------------------------------------
cmd_oauth_info() {
	local url admin domains
	url=$(env_require "$SETTINGS_ENV" JENKINS_URL)
	admin=$(env_require "$SETTINGS_ENV" JENKINS_ADMIN_EMAIL)
	domains=$(env_require "$SETTINGS_ENV" GOOGLE_ALLOWED_DOMAINS)

	cat <<INFO

Google Cloud -> APIs & Services -> Credentials -> OAuth client ID (Web application):
  Authorised redirect URI : ${url}securityRealm/finishLogin
  Authorised JS origin    : ${url%/}

Sign in at ${url} as ${admin}
Allowed domains: ${domains}

INFO
}

# Printing a secret is fine on an operator's terminal and wrong anywhere else:
# a pipe or a redirect usually means a CI log, a file, or a chat paste.
cmd_recovery_password() {
	local value
	value=$(env_require "$RECOVERY_ENV" RECOVERY_ADMIN_PASSWORD)

	if [ "${1:-}" != "--force" ] && [ ! -t 1 ]; then
		log_warn "stdout is not a terminal: refusing to print the break-glass password"
		log_warn "run '$0 recovery-password' from a terminal, or --force to override"
		return 0
	fi
	printf '%s\n' "$value"
}

main() {
	local cmd=${1:-}
	if [ $# -gt 0 ]; then
		shift
	fi
	case "$cmd" in
	init) cmd_init "$@" ;;
	render) cmd_render "$@" ;;
	set) cmd_set "$@" ;;
	rotate-recovery) cmd_rotate_recovery "$@" ;;
	show) cmd_show "$@" ;;
	oauth-info) cmd_oauth_info "$@" ;;
	recovery-password) cmd_recovery_password "$@" ;;
	-h | --help | help | "") usage ;;
	*) die "unknown command: ${cmd} (try --help)" ;;
	esac
}

main "$@"
