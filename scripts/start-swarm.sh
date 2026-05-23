#!/usr/bin/env bash
# start-swarm.sh — Spin up a 5-sandbox swarm (one isolated sandbox per role)
# and (if tmux is installed) attach to a tmux session with one window per
# sandbox. If tmux isn't installed, provisions the sandboxes anyway and
# prints the connection commands instead of building a session.
#
# Default sandboxes: swarm-1 … swarm-5 (one per tmux window).
# Override the count with --count N (1-9). Override the prefix with --prefix.
#
# Usage:
#   ./scripts/start-swarm.sh                    # 5 sandboxes, attach if tmux present
#   ./scripts/start-swarm.sh --count 3          # only 3
#   ./scripts/start-swarm.sh --prefix dev       # dev-1 … dev-5
#   ./scripts/start-swarm.sh --no-attach        # build everything, don't enter tmux
#   ./scripts/start-swarm.sh --force            # kill+rebuild existing tmux session
#
# Provisioning is serial by design. Concurrent sandbox creates saturate
# the OpenShell gateway and time out — once the image is cached, serial is
# fast enough that it doesn't matter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

START_SANDBOX="${SCRIPT_DIR}/start-sandbox.sh"

# ── Parse args ───────────────────────────────────────────────
COUNT=5
PREFIX="swarm"
SESSION="swarm"
NO_ATTACH="false"
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)      COUNT="$2"; shift 2 ;;
        --prefix)     PREFIX="$2"; shift 2 ;;
        --session)    SESSION="$2"; shift 2 ;;
        --no-attach)  NO_ATTACH="true"; shift ;;
        --force)      FORCE="true"; shift ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)            osk::die "unknown arg: $1" ;;
    esac
done

[[ "$COUNT" =~ ^[1-9]$ ]] || osk::die "--count must be 1-9 (got: $COUNT)"

osk::require_cmd openshell
osk::ensure_gateway

# ── Detect tmux (optional) ───────────────────────────────────
HAVE_TMUX="false"
if command -v tmux >/dev/null 2>&1; then
    HAVE_TMUX="true"
else
    osk::warn "tmux not installed — will provision sandboxes but skip session build"
fi

# ── Provision each sandbox (serial; idempotent reattach) ────
declare -a SANDBOXES=()
for i in $(seq 1 "$COUNT"); do
    SANDBOXES+=("${PREFIX}-${i}")
done

osk::info "provisioning ${COUNT} sandboxes: ${SANDBOXES[*]}"
for sbx in "${SANDBOXES[@]}"; do
    if openshell sandbox get "$sbx" >/dev/null 2>&1; then
        osk::ok "${sbx} already exists — reusing"
        continue
    fi
    osk::info "  creating ${sbx}..."
    bash "$START_SANDBOX" "$sbx" --no-connect \
        || osk::die "failed to create ${sbx}"
done

# ── No tmux: print connection commands and exit ─────────────
if [[ "$HAVE_TMUX" != "true" ]]; then
    echo
    osk::ok "all sandboxes provisioned. Connect individually:"
    for sbx in "${SANDBOXES[@]}"; do
        echo "  ssh openshell-${sbx}"
    done
    exit 0
fi

# ── Build tmux session ───────────────────────────────────────
if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ "$FORCE" == "true" ]]; then
        osk::info "killing existing tmux session '$SESSION'"
        tmux kill-session -t "$SESSION"
    else
        osk::ok "tmux session '$SESSION' exists — attaching. Use --force to rebuild."
        [[ "$NO_ATTACH" == "true" ]] || exec tmux attach -t "$SESSION"
        exit 0
    fi
fi

osk::info "building tmux session: $SESSION"
# First window: the first sandbox. Subsequent windows: one per remaining sandbox.
FIRST="${SANDBOXES[0]}"
tmux new-session -d -s "$SESSION" -n "$FIRST" \
    "ssh openshell-${FIRST}; echo '[ssh exited — sandbox may be dead]'; exec bash"
for sbx in "${SANDBOXES[@]:1}"; do
    tmux new-window -t "$SESSION" -n "$sbx" \
        "ssh openshell-${sbx}; echo '[ssh exited — sandbox may be dead]'; exec bash"
done

osk::ok "built tmux session '$SESSION' with ${COUNT} windows"
[[ "$NO_ATTACH" == "true" ]] || exec tmux attach -t "$SESSION"
echo "  › attach with: tmux attach -t $SESSION"
