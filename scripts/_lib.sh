#!/usr/bin/env bash
# _lib.sh — shared helpers for openshell-kit scripts.
# Source, do not execute: `source "$(dirname "$0")/_lib.sh"`.

# ── Logging ──────────────────────────────────────────────────
# All to stderr so stdout stays clean for piping.
osk::info()  { printf '\033[36m›\033[0m %s\n' "$*" >&2; }
osk::ok()    { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
osk::warn()  { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
osk::err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
osk::die()   { osk::err "$@"; exit 1; }

# ── Preflight helpers ────────────────────────────────────────
osk::require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || osk::die "required command not found on PATH: $1"
}

osk::require_env() {
    [[ -n "${!1:-}" ]] || osk::die "required env var unset: $1"
}

# ── Credential resolution ────────────────────────────────────
# Resolve a GitHub token from common sources: $GITHUB_TOKEN, $GH_TOKEN,
# or a logged-in `gh` CLI session. Exports GITHUB_TOKEN_RESOLVED on
# success; returns non-zero if none worked.
osk::resolve_github_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        export GITHUB_TOKEN_RESOLVED="$GITHUB_TOKEN"
        return 0
    fi
    if [[ -n "${GH_TOKEN:-}" ]]; then
        export GITHUB_TOKEN_RESOLVED="$GH_TOKEN"
        return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        local t
        t=$(gh auth token 2>/dev/null) || return 1
        [[ -n "$t" ]] || return 1
        export GITHUB_TOKEN_RESOLVED="$t"
        return 0
    fi
    return 1
}

# Resolve a GitLab token from $GITLAB_TOKEN_SANDBOX (preferred —
# decoupled from the `glab` CLI's $GITLAB_TOKEN) or $GITLAB_TOKEN.
# Exports GITLAB_TOKEN_RESOLVED on success.
osk::resolve_gitlab_token() {
    if [[ -n "${GITLAB_TOKEN_SANDBOX:-}" ]]; then
        export GITLAB_TOKEN_RESOLVED="$GITLAB_TOKEN_SANDBOX"
        return 0
    fi
    if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        export GITLAB_TOKEN_RESOLVED="$GITLAB_TOKEN"
        return 0
    fi
    return 1
}

# ── Gateway lifecycle ────────────────────────────────────────
# Ensure the OpenShell gateway is reachable. Doesn't start it; just
# verifies. Starting the gateway is a one-time operator step
# (`openshell gateway start`).
osk::ensure_gateway() {
    if ! openshell gateway status >/dev/null 2>&1; then
        osk::die "openshell gateway is not reachable. Start it once with 'openshell gateway start' and re-run."
    fi
}

# ── Provider provisioning (idempotent) ───────────────────────
# Create a provider if it doesn't already exist. Args: <name> <type>.
# Reads $GITHUB_TOKEN_RESOLVED / $GITLAB_TOKEN_RESOLVED depending on
# the type; resolve those first via osk::resolve_*_token.
osk::ensure_provider() {
    local name="$1" type="$2"
    if openshell provider get "$name" >/dev/null 2>&1; then
        return 0
    fi
    osk::info "creating openshell provider: $name (type=$type, one-time)"
    case "$type" in
        github)
            [[ -n "${GITHUB_TOKEN_RESOLVED:-}" ]] || osk::die "GITHUB_TOKEN_RESOLVED not set"
            GITHUB_TOKEN="$GITHUB_TOKEN_RESOLVED" \
                openshell provider create --name "$name" --type github --from-existing \
                || osk::die "failed to create github provider"
            ;;
        gitlab)
            [[ -n "${GITLAB_TOKEN_RESOLVED:-}" ]] || osk::die "GITLAB_TOKEN_RESOLVED not set"
            GITLAB_TOKEN="$GITLAB_TOKEN_RESOLVED" \
                openshell provider create --name "$name" --type gitlab --from-existing \
                || osk::die "failed to create gitlab provider"
            ;;
        *)
            osk::die "unknown provider type: $type (expected github|gitlab)"
            ;;
    esac
}

# ── Sandbox naming ───────────────────────────────────────────
# Auto-name: returns the next sandbox name in the s<N> series (s1, s2, …).
# Skips names already taken (in any phase). Stops searching at s99.
osk::next_name() {
    local prefix="${1:-s}"
    local existing
    existing=$(openshell sandbox list 2>/dev/null \
        | awk 'NR>1 {print $1}' || true)
    local n
    for n in $(seq 1 99); do
        if ! grep -qE "^${prefix}${n}$" <<<"$existing"; then
            echo "${prefix}${n}"
            return 0
        fi
    done
    osk::die "no available ${prefix}<N> name in range 1-99"
}
