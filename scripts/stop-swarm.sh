#!/usr/bin/env bash
# stop-swarm.sh — Tear down the swarm tmux session (if any) and delete
# the swarm sandboxes.
#
# Usage:
#   ./scripts/stop-swarm.sh                    # kill tmux + delete swarm-* sandboxes (prompts)
#   ./scripts/stop-swarm.sh -y                 # skip confirmation
#   ./scripts/stop-swarm.sh --tmux-only        # close the windows, keep the sandboxes
#   ./scripts/stop-swarm.sh --sandboxes-only   # delete sandboxes, leave tmux
#   ./scripts/stop-swarm.sh --prefix dev       # tear down dev-* instead of swarm-*
#   ./scripts/stop-swarm.sh --session FOO      # target a non-default tmux session

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

STOP_SANDBOX="${SCRIPT_DIR}/stop-sandbox.sh"

# ── Parse args ───────────────────────────────────────────────
SESSION="swarm"
PREFIX="swarm"
KILL_TMUX="true"
KILL_SANDBOXES="true"
YES="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)         YES="true"; shift ;;
        --tmux-only)      KILL_SANDBOXES="false"; shift ;;
        --sandboxes-only) KILL_TMUX="false"; shift ;;
        --session)        SESSION="$2"; shift 2 ;;
        --prefix)         PREFIX="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)                osk::die "unknown arg: $1" ;;
    esac
done

osk::require_cmd openshell

# ── Resolve target sandboxes (prefix-*) ─────────────────────
declare -a TARGETS=()
if [[ "$KILL_SANDBOXES" == "true" ]]; then
    mapfile -t TARGETS < <(openshell sandbox list 2>/dev/null \
        | awk 'NR>1 {print $1}' | grep -E "^${PREFIX}-[0-9]+$" || true)
fi

# ── Confirm ──────────────────────────────────────────────────
osk::info "about to:"
[[ "$KILL_TMUX" == "true" ]] && echo "    - kill tmux session '${SESSION}'"
if [[ "$KILL_SANDBOXES" == "true" ]]; then
    if [[ ${#TARGETS[@]} -gt 0 ]]; then
        echo "    - delete sandboxes: ${TARGETS[*]}"
    else
        echo "    - delete sandboxes: (none matched ${PREFIX}-*)"
    fi
fi

if [[ "$YES" != "true" ]]; then
    read -r -p "proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { osk::warn "aborted"; exit 1; }
fi

# ── Execute ──────────────────────────────────────────────────
if [[ "$KILL_TMUX" == "true" ]]; then
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux kill-session -t "$SESSION"
        osk::ok "tmux session '$SESSION' killed"
    else
        osk::info "no tmux session '$SESSION' to kill"
    fi
fi

if [[ "$KILL_SANDBOXES" == "true" && ${#TARGETS[@]} -gt 0 ]]; then
    bash "$STOP_SANDBOX" -y "${TARGETS[@]}"
fi
