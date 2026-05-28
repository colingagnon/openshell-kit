#!/usr/bin/env bash
# start-sandbox.sh — Create a single OpenShell sandbox preconfigured from
# the openshell-kit baseline (policy + claude config + sandbox-init bootstrap).
#
# Usage:
#   ./scripts/start-sandbox.sh                            # auto-named, interactive
#   ./scripts/start-sandbox.sh my-sandbox                 # custom name
#   ./scripts/start-sandbox.sh --no-connect               # create only, don't SSH in
#   ./scripts/start-sandbox.sh -- -p "do the thing"       # headless agent run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"
# shellcheck source=_ssh-config.sh
source "${SCRIPT_DIR}/_ssh-config.sh"

# ── Parse args ───────────────────────────────────────────────
NAME=""
NO_CONNECT="false"
AGENT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-connect)  NO_CONNECT="true"; shift ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --)
            shift
            AGENT_ARGS=("$@")
            break
            ;;
        --*)
            osk::die "unknown flag: $1"
            ;;
        *)
            [[ -n "$NAME" ]] && osk::die "name already set to '$NAME', got '$1'"
            NAME="$1"
            shift
            ;;
    esac
done

# ── Preflight ────────────────────────────────────────────────
osk::require_cmd openshell
osk::require_cmd docker
osk::ensure_gateway

# Auto-name if none given (s1, s2, …).
[[ -z "$NAME" ]] && NAME=$(osk::next_name s)

# ── Provider setup (idempotent; only what's available) ──────
# Provision the github provider if we can resolve a token. Optional —
# skip if no token is available, and let the in-sandbox agent do
# interactive `gh auth login` etc. Same flow for gitlab.
if osk::resolve_github_token; then
    osk::ensure_provider github github
fi
if osk::resolve_gitlab_token; then
    osk::ensure_provider gitlab gitlab
fi

# ── Stage upload bundle ──────────────────────────────────────
# Bundle = the contents of sandbox/. After upload they should land at
# /sandbox/ inside the new sandbox so sandbox-init.sh's hardcoded
# /sandbox/* paths still resolve.
#
# v0.0.50: `--upload <SRC>:<DEST>` places SRC as a child of DEST
# (preserves its basename). We use a stable name ("bootstrap") so the
# in-sandbox entrypoint can find it predictably, then `cp -rT` the
# contents up into /sandbox/.
STAGE_PARENT=$(mktemp -d)
trap 'rm -rf "$STAGE_PARENT"' EXIT
BUNDLE="$STAGE_PARENT/bootstrap"
mkdir -p "$BUNDLE"
cp -a "${OSK_ROOT}/sandbox/." "${BUNDLE}/"

POLICY="${OSK_ROOT}/sandbox/policy.yaml"
[[ -f "$POLICY" ]] || osk::die "policy file missing: $POLICY"

# ── Create sandbox ───────────────────────────────────────────
osk::info "creating sandbox: ${NAME}"

CREATE_ARGS=(
    --name "$NAME"
    --policy "$POLICY"
    --upload "${BUNDLE}:/sandbox/"
)

# Wire in the github + gitlab providers if they exist (silent skip otherwise).
openshell provider get github >/dev/null 2>&1 && CREATE_ARGS+=(--provider github)
openshell provider get gitlab >/dev/null 2>&1 && CREATE_ARGS+=(--provider gitlab)

openshell sandbox create "${CREATE_ARGS[@]}" -- bash -c \
    'set -e; cp -rT /sandbox/bootstrap/. /sandbox/ && rm -rf /sandbox/bootstrap && chmod +x /sandbox/sandbox-init.sh && /sandbox/sandbox-init.sh' \
    || osk::die "openshell sandbox create failed for '$NAME'"

# ── Register SSH alias ──────────────────────────────────────
register_sandbox_ssh "$NAME"
osk::ok "sandbox ${NAME} registered as SSH host openshell-${NAME}"

# ── Connect (interactive default; headless if --) ───────────
if [[ ${#AGENT_ARGS[@]} -gt 0 ]]; then
    osk::info "running headless agent: claude ${AGENT_ARGS[*]}"
    ssh "openshell-${NAME}" -- bash -lc "claude --dangerously-skip-permissions ${AGENT_ARGS[*]@Q}"
elif [[ "$NO_CONNECT" != "true" ]]; then
    osk::info "connecting to ${NAME} (claude will auto-launch on the interactive shell)"
    exec ssh "openshell-${NAME}"
else
    osk::ok "sandbox ${NAME} ready"
    echo "  › reconnect later with:  openshell sandbox connect ${NAME}"
    echo "  › or SSH alias:          ssh openshell-${NAME}"
    echo "  › or VS Code (Remote-SSH): code --remote ssh-remote+openshell-${NAME} /sandbox"
fi
