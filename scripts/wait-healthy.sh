#!/usr/bin/env bash
#
# wait-healthy.sh -- block until the controller's healthcheck reports healthy.
#
# Environment: HEALTH_TIMEOUT (seconds, default 300), HEALTH_INTERVAL (default 5)
#
# Exits non-zero and dumps recent logs if the container exits, loses its
# healthcheck, or does not become healthy in time -- a silent timeout tells the
# operator nothing about why.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="wait-healthy"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
LOG_TAIL="${LOG_TAIL:-40}"

dump_logs() {
	log_error "last ${LOG_TAIL} log lines:"
	compose logs --no-color --tail="$LOG_TAIL" jenkins >&2 || true
}

main() {
	require_cmd docker

	local cid
	cid=$(compose ps -q jenkins)
	[ -n "$cid" ] || die "the jenkins service is not running -- start it with: make up"

	log_info "waiting for the controller to become healthy (timeout ${HEALTH_TIMEOUT}s)"

	local elapsed=0 status running
	while true; do
		status=$(docker inspect -f \
			'{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")

		case "$status" in
		healthy)
			log_info "controller is healthy after ${elapsed}s"
			return 0
			;;
		none)
			dump_logs
			die "container has no healthcheck -- was the image built from this Dockerfile?"
			;;
		esac

		running=$(docker inspect -f '{{.State.Running}}' "$cid")
		if [ "$running" != "true" ]; then
			dump_logs
			die "container exited while starting (status '${status}')"
		fi

		# With restart: unless-stopped a fatal startup error does not leave an
		# exited container -- Docker keeps restarting it, so the check above
		# never trips and we would burn the whole timeout. A restart count
		# above zero means it is crash-looping: fail now, with the reason.
		restarts=$(docker inspect -f '{{.RestartCount}}' "$cid")
		if [ "$restarts" -gt 0 ]; then
			dump_logs
			die "container has restarted ${restarts} time(s): it is crash-looping, not starting slowly"
		fi

		if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
			dump_logs
			die "still '${status}' after ${HEALTH_TIMEOUT}s -- JCasC usually names the offending key in the logs above"
		fi

		log_debug "status=${status} elapsed=${elapsed}s"
		sleep "$HEALTH_INTERVAL"
		elapsed=$((elapsed + HEALTH_INTERVAL))
	done
}

main "$@"
