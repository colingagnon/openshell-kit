#!/usr/bin/env bash
# stop-sandbox.sh — Tear down one or more OpenShell sandboxes.
# Usage:
#   ./scripts/stop-sandbox.sh s1                 # delete one by name
#   ./scripts/stop-sandbox.sh s1 s2 s3           # delete several
#   ./scripts/stop-sandbox.sh --all              # delete every sandbox (prompts)
#   ./scripts/stop-sandbox.sh --s-only           # delete only s<N>-named sandboxes
#   ./scripts/stop-sandbox.sh -y --all           # skip confirmation
#
# Custom-named sandboxes (not matching s<N>) must be passed explicitly,
# unless --all is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"
# shellcheck source=_ssh-config.sh
source "${SCRIPT_DIR}/_ssh-config.sh"

# ── Parse args ───────────────────────────────────────────────
MODE="explicit"   # explicit | all | s-only
YES="false"
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)      MODE="all"; shift ;;
        --s-only)   MODE="s-only"; shift ;;
        -y|--yes)   YES="true"; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --*)
            osk::die "unknown flag: $1"
            ;;
        *)
            TARGETS+=("$1"); shift ;;
    esac
done

osk::require_cmd openshell

# ── Resolve target list ──────────────────────────────────────
case "$MODE" in
    all)
        mapfile -t TARGETS < <(openshell sandbox list 2>/dev/null | awk 'NR>1 {print $1}')
        ;;
    s-only)
        mapfile -t TARGETS < <(openshell sandbox list 2>/dev/null \
            | awk 'NR>1 {print $1}' | grep -E '^s[0-9]+$' || true)
        ;;
    explicit)
        [[ ${#TARGETS[@]} -gt 0 ]] || osk::die "no sandbox names given; pass names, --all, or --s-only"
        ;;
esac

[[ ${#TARGETS[@]} -gt 0 ]] || { osk::warn "no matching sandboxes"; exit 0; }

# ── Confirm ──────────────────────────────────────────────────
osk::info "about to delete: ${TARGETS[*]}"
if [[ "$YES" != "true" ]]; then
    read -r -p "proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { osk::warn "aborted"; exit 1; }
fi

# ── Delete + strip SSH alias for each ───────────────────────
for name in "${TARGETS[@]}"; do
    if openshell sandbox delete "$name" >/dev/null 2>&1; then
        osk::ok "deleted $name"
    else
        osk::warn "delete failed for $name (already gone?)"
    fi
    unregister_sandbox_ssh "$name"
done
