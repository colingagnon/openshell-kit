#!/usr/bin/env bash
# _ssh-config.sh — Internal helper sourced by start-sandbox.sh / stop-sandbox.sh.
# Manages an openshell-kit-owned section of ~/.ssh/config so VS Code's
# Remote-SSH extension (and plain `ssh openshell-<name>`) can reach any
# sandbox by name.
#
# Layout (Linux/macOS host):
#   ~/.ssh/config           — main file, gets a one-time `Include openshell.conf`
#   ~/.ssh/openshell.conf   — managed by these helpers; one block per sandbox
#                             wrapped in `# >>> openshell:<name> >>>` markers.
#
# Layout (WSL2 host) — additionally:
#   /mnt/c/Users/<winuser>/.ssh/openshell.conf
#                           — Windows-side mirror with ProxyCommand rewritten to
#                             `wsl.exe -d <distro> -e <openshell-bin> ...` so
#                             VS Code on Windows can read it directly. Point
#                             remote.SSH.configFile at this path.
#
# Re-running register_sandbox_ssh for the same name is idempotent: the old
# block is stripped before the fresh one is appended.

SSH_CONF_DIR="${HOME}/.ssh"
SSH_CONF_FILE="${SSH_CONF_DIR}/config"
SSH_OPENSHELL_FILE="${SSH_CONF_DIR}/openshell.conf"

_is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    grep -qi microsoft /proc/version 2>/dev/null
}

# Resolve and cache the Windows-side .ssh dir (e.g. /mnt/c/Users/foo/.ssh).
# Sets _WIN_SSH_DIR on success, returns non-zero if it can't be resolved.
_resolve_win_ssh_dir() {
    [[ -n "${_WIN_SSH_DIR:-}" ]] && return 0
    local userprofile
    userprofile=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n') || return 1
    [[ -n "${userprofile}" ]] || return 1
    _WIN_SSH_DIR=$(wslpath -u "${userprofile}" 2>/dev/null)/.ssh
    [[ -n "${_WIN_SSH_DIR}" ]] || return 1
    mkdir -p "${_WIN_SSH_DIR}"
    return 0
}

# Ensure the main ssh config has `Include openshell.conf` exactly once.
# Creates the openshell.conf file if missing.
_ensure_ssh_include() {
    mkdir -p "${SSH_CONF_DIR}"
    chmod 700 "${SSH_CONF_DIR}"
    [[ -f "${SSH_CONF_FILE}" ]] || { touch "${SSH_CONF_FILE}"; chmod 600 "${SSH_CONF_FILE}"; }
    [[ -f "${SSH_OPENSHELL_FILE}" ]] || { touch "${SSH_OPENSHELL_FILE}"; chmod 600 "${SSH_OPENSHELL_FILE}"; }

    if ! grep -qE "^Include[[:space:]]+openshell\.conf$" "${SSH_CONF_FILE}" 2>/dev/null; then
        # Prepend so it's parsed before any wildcard host matches in the user's config.
        local tmp
        tmp=$(mktemp)
        printf 'Include openshell.conf\n\n' > "${tmp}"
        cat "${SSH_CONF_FILE}" >> "${tmp}"
        mv "${tmp}" "${SSH_CONF_FILE}"
        chmod 600 "${SSH_CONF_FILE}"
    fi
}

# Strip block, then append fresh marker-wrapped block to the given file.
# Args: <file> <name> <block-content>
_write_block() {
    local file="$1" name="$2" block="$3"
    local tmp
    tmp=$(mktemp)
    if [[ -f "${file}" ]]; then
        awk -v n="${name}" '
            $0 == "# >>> openshell:" n " >>>" { skip=1; next }
            $0 == "# <<< openshell:" n " <<<" { skip=0; next }
            !skip { print }
        ' "${file}" > "${tmp}"
    fi
    {
        printf '# >>> openshell:%s >>>\n' "${name}"
        printf '%s\n' "${block}"
        printf '# <<< openshell:%s <<<\n\n' "${name}"
    } >> "${tmp}"
    mv "${tmp}" "${file}"
    chmod 600 "${file}" 2>/dev/null || true
}

# Rewrite the ProxyCommand line so Windows-side ssh can launch it via wsl.exe.
# The Linux config has: ProxyCommand /home/<user>/.local/bin/openshell ssh-proxy ...
# Windows needs:        ProxyCommand wsl.exe -d <distro> -e /home/<user>/.local/bin/openshell ssh-proxy ...
_rewrite_proxycommand_for_windows() {
    local distro="${WSL_DISTRO_NAME:-Ubuntu}"
    sed -E "s|^([[:space:]]*ProxyCommand )(.+)$|\\1wsl.exe -d ${distro} -e \\2|"
}

# Strip block from a file (no-op if file or block absent).
# Args: <file> <name>
_strip_block() {
    local file="$1" name="$2"
    [[ -f "${file}" ]] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v n="${name}" '
        $0 == "# >>> openshell:" n " >>>" { skip=1; next }
        $0 == "# <<< openshell:" n " <<<" { skip=0; next }
        !skip { print }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
    chmod 600 "${file}" 2>/dev/null || true
}

# Append (or refresh) the SSH host block for a sandbox.
# Usage: register_sandbox_ssh my-sandbox
register_sandbox_ssh() {
    local name="$1"
    [[ -z "${name}" ]] && { echo "register_sandbox_ssh: name required" >&2; return 1; }

    _ensure_ssh_include

    local block
    if ! block=$(openshell sandbox ssh-config "${name}" 2>/dev/null); then
        echo "  WARN: openshell sandbox ssh-config ${name} failed; SSH host not registered." >&2
        return 0
    fi

    _write_block "${SSH_OPENSHELL_FILE}" "${name}" "${block}"

    # WSL: also write a Windows-flavor file with wsl.exe-wrapped ProxyCommand.
    if _is_wsl && _resolve_win_ssh_dir; then
        local win_file="${_WIN_SSH_DIR}/openshell.conf"
        local win_block
        win_block=$(printf '%s\n' "${block}" | _rewrite_proxycommand_for_windows)
        _write_block "${win_file}" "${name}" "${win_block}"
    fi
}

# Strip the SSH host block for a sandbox (no-op if absent).
# Usage: unregister_sandbox_ssh my-sandbox
unregister_sandbox_ssh() {
    local name="$1"
    [[ -z "${name}" ]] && { echo "unregister_sandbox_ssh: name required" >&2; return 1; }

    _strip_block "${SSH_OPENSHELL_FILE}" "${name}"

    if _is_wsl && _resolve_win_ssh_dir; then
        _strip_block "${_WIN_SSH_DIR}/openshell.conf" "${name}"
    fi
}
