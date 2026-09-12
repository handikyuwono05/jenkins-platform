#!/usr/bin/env bash
#
# supply-chain.sh -- keep what we run pinned and reviewable.
#
#   base-digest      compare the pinned base-image digest against Docker Hub;
#                    exits 1 on drift so CI can gate on it
#   plugins-freeze   write the running plugin set and versions to
#                    plugins.lock.txt for reproducible rebuilds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COMPONENT="supply-chain"
# shellcheck source=scripts/lib/log.sh
. "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

install_err_trap

HUB_API="https://hub.docker.com/v2/repositories/jenkins/jenkins/tags"

cmd_base_digest() {
	require_cmd curl
	require_cmd python3

	local pinned tag current
	pinned=$(grep -oE 'sha256:[0-9a-f]{64}' "${REPO_ROOT}/Dockerfile" | head -1)
	tag=$(grep -oE 'jenkins/jenkins:[^@ ]+' "${REPO_ROOT}/Dockerfile" | head -1)
	tag=${tag#jenkins/jenkins:}
	[ -n "$pinned" ] || die "no digest pin found in Dockerfile"
	[ -n "$tag" ] || die "no base image tag found in Dockerfile"

	log_info "tag     ${tag}"
	log_info "pinned  ${pinned}"

	if ! current=$(curl -fsS --max-time 30 "${HUB_API}/${tag}" |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])' 2>/dev/null); then
		die "could not query Docker Hub for tag ${tag} (network or tag removed)"
	fi
	log_info "hub     ${current}"

	if [ "$pinned" = "$current" ]; then
		log_info "ok      the pin matches the published digest for ${tag}"
		return 0
	fi

	log_error "DRIFT   the published digest for ${tag} no longer matches the pin"
	log_error "        a mutable tag moved under us: review the change, then update"
	log_error "        Dockerfile, docker-compose.yml and template/jenkins.env.example"
	trap - ERR
	exit 1
}

cmd_plugins_freeze() {
	local out="${REPO_ROOT}/plugins.lock.txt"
	local tmp
	tmp=$(mktemp "${out}.XXXXXX")
	# shellcheck disable=SC2064 # expand $tmp now, at trap definition time
	trap "rm -f '${tmp}'" EXIT

	# Read versions from each plugin's own manifest: authoritative, and it does
	# not depend on the update centre being reachable.
	# shellcheck disable=SC2016 # must expand inside the container, not here
	compose exec -T jenkins bash -c '
		for dir in /var/jenkins_home/plugins/*/; do
			manifest="${dir}META-INF/MANIFEST.MF"
			[ -f "$manifest" ] || continue
			name=$(basename "$dir")
			version=$(tr -d "\r" < "$manifest" | awk "/^Plugin-Version:/ {print \$2; exit}")
			[ -n "$version" ] && printf "%s:%s\n" "$name" "$version"
		done
	' | sort >"$tmp"

	[ -s "$tmp" ] || die "no plugins found -- is the controller running? (make ps)"

	mv -f "$tmp" "$out"
	trap - EXIT
	log_info "wrote   plugins.lock.txt ($(wc -l <"$out" | tr -d ' ') plugins)"
	log_info "        copy these pins into plugins.txt for reproducible builds"
}

main() {
	local cmd=${1:-}
	if [ $# -gt 0 ]; then
		shift
	fi
	case "$cmd" in
	base-digest) cmd_base_digest "$@" ;;
	plugins-freeze) cmd_plugins_freeze "$@" ;;
	-h | --help | "") sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
	*) die "unknown command: ${cmd}" ;;
	esac
}

main "$@"
