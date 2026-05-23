#!/usr/bin/env bash
# restore-context.sh — Upload Claude conversation transcripts from a host
# snapshot back into a sandbox. Inverse of snapshot-context.sh.
#
# Skips sessions/ by design — those are PID-keyed transient files;
# restoring stale PIDs onto a fresh sandbox is harmless but pointless.
#
# Usage:
#   restore-context.sh --name s1                   # default → from $OSK_ROOT/state/s1
#   restore-context.sh --name s1 --source /tmp/x   # from a custom location

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

NAME=""
SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)   NAME="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) osk::die "unknown arg: $1" ;;
    esac
done

[[ -n "$NAME" ]] || osk::die "--name <sandbox> is required"
[[ -z "$SOURCE" ]] && SOURCE="${OSK_ROOT}/state/${NAME}"

osk::require_cmd openshell

if ! openshell sandbox get "$NAME" >/dev/null 2>&1; then
    osk::die "sandbox '$NAME' does not exist"
fi

if [[ ! -d "${SOURCE}/projects" ]]; then
    osk::die "no snapshot found at ${SOURCE}/projects/"
fi

TRANSCRIPTS=$(find "${SOURCE}/projects" -name '*.jsonl' 2>/dev/null | wc -l)
osk::info "restoring ${TRANSCRIPTS} transcripts → ${NAME}:/sandbox/.claude/projects/"

# --no-git-ignore: explicit because /sandbox/.claude/projects is gitignored
# upstream in some workdirs; the upload path is gitignore-aware in a
# useful way — explicit is safer.
if ! openshell sandbox upload --no-git-ignore "$NAME" "${SOURCE}/projects" /sandbox/.claude/projects/ >/dev/null 2>&1; then
    osk::die "upload failed"
fi

osk::ok "restored ${TRANSCRIPTS} transcripts into ${NAME}"
