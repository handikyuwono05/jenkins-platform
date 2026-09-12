#!/usr/bin/env bash
# shellcheck shell=bash
#
# Leveled, timestamped logging shared by every script in this repository.
#
# Design notes:
#   - Everything is written to STDERR. A script's STDOUT stays reserved for
#     data a caller may legitimately pipe (e.g. a rendered value, a tar
#     stream), so logging can never corrupt it.
#   - LOG_FORMAT=json emits one JSON object per line for log shippers;
#     the default text format is for humans at a terminal.
#   - LOG_LEVEL filters output (debug|info|warn|error).
#   - Colour is used only when STDERR is a TTY and NO_COLOR is unset.

LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FORMAT="${LOG_FORMAT:-text}"
LOG_COMPONENT="${LOG_COMPONENT:-jenkins-platform}"

_log_level_num() {
	case "$1" in
	debug) printf '10' ;;
	info) printf '20' ;;
	warn) printf '30' ;;
	error) printf '40' ;;
	*) printf '20' ;;
	esac
}

# Escape the characters that would otherwise produce invalid JSON.
_log_json_escape() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

_log() {
	local level=$1
	shift
	local msg="$*"

	[ "$(_log_level_num "$level")" -ge "$(_log_level_num "$LOG_LEVEL")" ] || return 0

	local ts
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	if [ "$LOG_FORMAT" = "json" ]; then
		printf '{"ts":"%s","level":"%s","component":"%s","msg":"%s"}\n' \
			"$ts" "$level" "$LOG_COMPONENT" "$(_log_json_escape "$msg")" >&2
		return 0
	fi

	local colour='' reset=''
	if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
		case "$level" in
		debug) colour='\033[2m' ;;
		info) colour='\033[36m' ;;
		warn) colour='\033[33m' ;;
		error) colour='\033[31m' ;;
		esac
		reset='\033[0m'
	fi
	printf '%s %b%-5s%b %s\n' "$ts" "$colour" "$level" "$reset" "$msg" >&2
}

log_debug() { _log debug "$@"; }
log_info() { _log info "$@"; }
log_warn() { _log warn "$@"; }
log_error() { _log error "$@"; }

# Log at error level and terminate. Use for conditions the caller cannot fix
# by retrying -- misconfiguration, a missing dependency, a refused guard.
die() {
	log_error "$@"
	exit 1
}

# Report the exact location and command that failed. Without this, `set -e`
# aborts silently and the operator is left guessing which line died.
_on_err() {
	local exit_code=$1 line=$2 cmd=$3 src=$4
	log_error "unexpected failure at ${src}:${line} (exit ${exit_code}) while running: ${cmd}"
	exit "$exit_code"
}

install_err_trap() {
	trap '_on_err "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
}
