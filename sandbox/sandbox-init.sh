#!/usr/bin/env bash
# sandbox-init.sh — In-sandbox bootstrap (runs once at sandbox boot).
# Staged at /sandbox/sandbox-init.sh by start-sandbox.sh and invoked as
# the sandbox entrypoint.
#
# Responsibilities (deliberately minimal):
#   1. Configure git identity + GitHub/GitLab credential helpers
#   2. Install the native Claude build (for the current OAuth flow)
#   3. Install the Claude HUD plugin (statusline)
#   4. Apply pre-baked Claude configs (onboarding bypass + model + plugins)
#   5. Wire .bashrc to auto-launch claude on interactive shells
#
# What this script DOES NOT do (because openshell-kit is a starter — you
# customize from here):
#   - Clone any repos (no $REPO_LIST, no /sandbox/<repo> trees)
#   - Install language toolchains (Go, Node beyond the base image, etc.)
#   - Bake in any project-specific tooling
#
# To customize: edit this file, add what you need (clones, toolchains,
# extra services), rebuild your sandbox. See README.md → Customization.

set -euo pipefail

# ── Git identity ─────────────────────────────────────────────
git config --global user.name  "sandbox-agent"
git config --global user.email "sandbox-agent@noreply"

# ── GitHub credential helper (only fires if the github provider is wired) ──
# OpenShell's github provider injects a placeholder GITHUB_TOKEN that the
# proxy substitutes in Authorization headers at egress. The helper sends
# it as the password over HTTPS so clones to github.com transparently
# authenticate. No-op if $GITHUB_TOKEN is unset.
git config --global "credential.https://github.com.helper" \
    '!f() { echo "username=oauth2"; echo "password=${GITHUB_TOKEN}"; }; f'

# ── GitLab credential helper (only fires if the gitlab provider is wired) ──
git config --global "credential.https://gitlab.com.helper" \
    '!f() { echo "username=oauth2"; echo "password=${GITLAB_TOKEN}"; }; f'

# ── TLS trust store ──────────────────────────────────────────
# The proxy uses an ephemeral CA for TLS interception; the combined bundle
# lives at /etc/openshell-tls/. Point git at it so HTTPS clones work even
# when SSL_CERT_FILE isn't set.
if [[ -f /etc/openshell-tls/ca-bundle.pem ]]; then
    git config --global http.sslCAInfo /etc/openshell-tls/ca-bundle.pem
fi

# ── Verify python3 (informational) ───────────────────────────
# OpenShell base ships python 3.x. Surface a loud warning if it's missing
# rather than silently breaking downstream tools.
if command -v python3 >/dev/null 2>&1; then
    echo "python3: $(python3 --version 2>&1)"
else
    echo "WARN: python3 not on PATH — base image should ship one"
fi

# ── Install Claude HUD plugin (FIRST, before applying configs) ──
# claude's first-run init clobbers ~/.claude/settings.json and
# ~/.claude.json with defaults. By installing the HUD plugin first we
# trigger that init now (when there's nothing to lose), then overwrite
# the configs below.
mkdir -p "${HOME}/.claude" /tmp/logs
HUD_INSTALLED="${HOME}/.claude/plugins/cache/claude-hud"
if [[ ! -d "${HUD_INSTALLED}" ]] || [[ -z "$(ls -A "${HUD_INSTALLED}" 2>/dev/null)" ]]; then
    {
        claude plugin marketplace add anthropics/claude-plugins-official || true
        claude plugin marketplace add jarrodwatts/claude-hud             || true
        claude plugin install claude-hud                                  || true
    } &>/tmp/logs/claude-hud-install.log
    echo "Claude HUD installed (log: /tmp/logs/claude-hud-install.log)."
fi

# ── Install Claude native build ──────────────────────────────
# Preferred path: start-sandbox.sh staged the host's native claude binary
# at /sandbox/claude-bin/<version>. Install from there — no download,
# no `claude install` step. Falls back to running `claude install` from
# inside the sandbox if no host binary was staged.
#
# IMPORTANT: the egress proxy gates on the *resolved* binary path, so
# the native build path must be in claude_code.binaries in policy.yaml.
# That entry is already there in the shipped baseline.
mkdir -p /tmp/logs
shopt -s nullglob
STAGED_CLAUDE=(/sandbox/claude-bin/*)
shopt -u nullglob
if (( ${#STAGED_CLAUDE[@]} > 0 )) && [[ -x "${STAGED_CLAUDE[0]}" ]]; then
    version=$(basename "${STAGED_CLAUDE[0]}")
    install -m 0755 -D "${STAGED_CLAUDE[0]}" "${HOME}/.local/share/claude/versions/${version}"
    mkdir -p "${HOME}/.local/bin"
    ln -sfn "${HOME}/.local/share/claude/versions/${version}" "${HOME}/.local/bin/claude"
    echo "Claude native build installed from host bundle: ${version}"
else
    # Fallback: `claude install` fetches the native build from
    # storage.googleapis.com. timeout+kill-after handles the rare case
    # where its `npm uninstall` step wedges in a stopped (T) state and
    # ignores SIGTERM.
    {
        timeout --kill-after=10s 60 claude install < /dev/null || true
    } &>/tmp/logs/claude-install-native.log
    if [[ -x "${HOME}/.local/bin/claude" ]]; then
        echo "Claude native build installed (via claude install)."
    else
        echo "WARN: Claude native install didn't land at ~/.local/bin/claude (log: /tmp/logs/claude-install-native.log)."
    fi
fi

# Ensure ~/.local/bin is on PATH for future shells.
if ! grep -q 'HOME/.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
fi

# ── Apply Claude configs (after first-run init has run) ─────
# settings.json carries model, plugin marketplaces, enabled plugins,
# permissions bypass, and the HUD statusLine. claude.json carries
# onboarding bypass + per-project trust.
if [[ -f /sandbox/claude-settings.json ]]; then
    cp /sandbox/claude-settings.json "${HOME}/.claude/settings.json"
    echo "Claude settings.json applied."
fi
if [[ -f /sandbox/claude.json ]]; then
    cp /sandbox/claude.json "${HOME}/.claude.json"
    echo "Claude onboarding bypassed."
fi
if [[ -f /sandbox/claude-hud-config.json ]]; then
    mkdir -p "${HOME}/.claude/plugins/claude-hud"
    cp /sandbox/claude-hud-config.json "${HOME}/.claude/plugins/claude-hud/config.json"
    echo "Claude HUD config applied."
fi

# ── Auto-launch Claude on interactive connect ───────────────
# Only fires on interactive shells; the CLAUDE_LAUNCHED guard prevents
# re-entry if claude spawns a subshell that re-sources .bashrc. cd to
# /sandbox so the trust block in ~/.claude.json (keyed on /sandbox)
# matches the cwd at launch.
if ! grep -q 'CLAUDE_LAUNCHED' "${HOME}/.bashrc" 2>/dev/null; then
    cat >> "${HOME}/.bashrc" <<'BASHRC'

# Disable claude's TUI mouse capture so tmux's click+drag → copy-mode
# trigger still fires inside a sandbox claude session. Without this,
# claude 2.1.132+ captures all mouse events for its own UI, breaking
# tmux's drag-to-select. Documented via claude-code issues #58364,
# #56881. Exported (not just per-invocation) so manual relaunches
# inherit it too.
export CLAUDE_CODE_DISABLE_MOUSE=1

# Auto-launch Claude on interactive connect (added by sandbox-init).
# Uses PATH-resolved `claude` so the native build (~/.local/bin/claude)
# wins over the npm install (/usr/local/bin/claude) when present.
if [ -t 0 ] && [ -z "${CLAUDE_LAUNCHED:-}" ]; then
    export CLAUDE_LAUNCHED=1
    cd /sandbox
    claude --dangerously-skip-permissions
fi
BASHRC
    echo "Claude auto-launch wired into .bashrc."
fi

echo "sandbox initialized."
