#!/usr/bin/env bash
#
# backup.sh -- archive and restore JENKINS_HOME.
#
#   create                    stop the controller, archive, restart
#   restore <archive> --yes   replace JENKINS_HOME from an archive
#
# Backups are COLD by design: archiving a live JENKINS_HOME yields a
# crash-consistent copy that can restore into a broken state. The controller is
# stopped for the duration and restarted afterwards, including on failure.
#
# The archive contains the credential store AND the key that decrypts it.
# Treat it as a secret: it is written 0600, and it belongs in encrypted storage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="backup"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"

# Leave the operator with a running controller whatever happened.
restart_controller() {
	log_info "restarting the controller"
	compose up -d >/dev/null || log_error "could not restart the controller -- check: make ps"
}

cmd_create() {
	require_cmd docker
	umask 077
	mkdir -p "$BACKUP_DIR"

	local out
	out="${BACKUP_DIR}/jenkins_home-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"

	log_info "stopping the controller for a consistent archive"
	compose stop -t "$STOP_TIMEOUT" jenkins
	trap restart_controller EXIT

	# A temporary file first: a partial archive that looks complete is worse
	# than no archive.
	local tmp="${out}.partial"
	compose run --rm --no-deps -T --entrypoint sh jenkins \
		-c 'tar czf - -C /var/jenkins_home .' >"$tmp"
	[ -s "$tmp" ] || die "the archive is empty -- refusing to keep it"
	chmod 600 "$tmp"
	mv -f "$tmp" "$out"

	log_info "wrote   ${out#"${REPO_ROOT}"/} ($(du -h "$out" | cut -f1 | tr -d ' '))"
	log_warn "this archive contains credentials and the key that decrypts them:"
	log_warn "store it encrypted and off-host"
}

cmd_restore() {
	local archive=${1:-} confirm=${2:-}
	[ -n "$archive" ] || die "usage: backup.sh restore <archive.tar.gz> --yes"
	[ -f "$archive" ] || die "no such archive: ${archive}"
	[ "$confirm" = "--yes" ] ||
		die "this REPLACES the contents of JENKINS_HOME; re-run with --yes to confirm"

	require_cmd docker
	log_info "stopping the controller"
	compose stop -t "$STOP_TIMEOUT" jenkins
	trap restart_controller EXIT

	log_info "replacing JENKINS_HOME from ${archive}"
	# find -delete rather than a glob: a glob silently misses dotfiles, which
	# would leave stale state (e.g. .owner, .java) behind.
	compose run --rm --no-deps -T --entrypoint sh jenkins \
		-c 'find /var/jenkins_home -mindepth 1 -delete && tar xzf - -C /var/jenkins_home' \
		<"$archive"

	log_info "restored from ${archive}"
}

main() {
	local cmd=${1:-}
	if [ $# -gt 0 ]; then
		shift
	fi
	case "$cmd" in
	create) cmd_create "$@" ;;
	restore) cmd_restore "$@" ;;
	-h | --help | "") sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
	*) die "unknown command: ${cmd}" ;;
	esac
}

main "$@"
