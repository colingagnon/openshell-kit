# openshell-kit

A starter operator layer for [OpenShell](https://github.com/NVIDIA/OpenShell) sandboxes — bash scripts + a baseline policy + Claude config + a tmux-aware cluster runner — that gets you from a fresh OpenShell install to "I have isolated sandboxes my agent can work in" in a few commands.

Opinionated about the things that almost always burn first-time operators (Claude OAuth domain migration, native-binary path matching, SSH alias management, WSL2 + Docker Desktop quirks). Hands-off about the things that vary per setup (which repos to clone, which language toolchains to install, what credentials your agent needs beyond GitHub/GitLab).

---

## Table of contents

1. [What this is and isn't](#what-this-is-and-isnt)
2. [Prerequisites](#prerequisites)
3. [Install](#install)
4. [One-time setup](#one-time-setup)
5. [Daily workflow](#daily-workflow)
6. [Swarm: multi-sandbox cluster](#swarm-multi-sandbox-cluster)
7. [Conversation context: snapshot / restore](#conversation-context-snapshot--restore)
8. [VS Code Remote-SSH](#vs-code-remote-ssh)
9. [Security model](#security-model)
10. [⚠ Restricting git (the trust-boundary gap)](#-restricting-git-the-trust-boundary-gap)
11. [Customization](#customization)
12. [Troubleshooting](#troubleshooting)
13. [Layout](#layout)
14. [License](#license)

---

## What this is and isn't

**Is:**

- A baseline OpenShell sandbox setup with **a working network policy** for the things you almost always need (Claude API + plugin marketplace, GitHub + GitLab git/API), and **the non-obvious gotchas already handled** (Claude OAuth domain migration, native-build resolved-path matching, SSH alias automation for VS Code).
- A simple **`start-sandbox` / `stop-sandbox` / `start-swarm` / `stop-swarm`** lifecycle. Swarm is a 5-sandbox tmux cluster; degrades gracefully if you don't have tmux.
- A **starting point** — customize the bootstrap, the policy, the cluster shape, the Claude config to fit your workflow.

**Isn't:**

- Not a turnkey production setup. The shipped policy is liberal enough to work out of the box, which means **git pushes from in-sandbox agents are unrestricted** — see [Restricting git](#-restricting-git-the-trust-boundary-gap) before pointing an autonomous agent at a repo you care about.
- Not a credential broker. Per-sandbox `claude /login` is the model. If you need one OAuth chain shared across many sandboxes, you'll build that yourself.
- Not opinionated about which repos you clone, which language toolchains you install, or what other tools the in-sandbox agent uses. `sandbox/sandbox-init.sh` is intentionally minimal — customize from there.

---

## Prerequisites

- A supported host — Linux, macOS, or Windows with WSL2.
- **[OpenShell CLI](https://github.com/NVIDIA/OpenShell)** on PATH (`openshell version` must work).
- **Docker** running (for the gateway and default sandbox driver).
- **Claude Code** installed on the host (`claude --version`). Used for the OAuth chain when sandboxes do `claude /login`.
- **GitHub credentials** if you want agents to push to GitHub — one of `$GITHUB_TOKEN`, `$GH_TOKEN`, or a logged-in `gh` CLI session. Optional.
- **GitLab credentials** if you want agents to push to GitLab — `$GITLAB_TOKEN_SANDBOX` (preferred — doesn't clash with `glab`'s own `$GITLAB_TOKEN`) or `$GITLAB_TOKEN`. Optional.
- **`tmux`** if you want the swarm cluster to spin up a multi-window session. Optional; the swarm script provisions sandboxes either way and just skips the tmux session if `tmux` isn't installed.

---

## Install

```bash
git clone git@github.com:colingagnon/openshell-kit.git ~/.openshell-kit
```

(Or fork it first — this is a starter you'll customize.)

Add aliases (adjust the path if you cloned elsewhere):

```bash
alias os-up="bash ~/.openshell-kit/scripts/start-sandbox.sh"
alias os-down="bash ~/.openshell-kit/scripts/stop-sandbox.sh"
alias os-swarm-up="bash ~/.openshell-kit/scripts/start-swarm.sh"
alias os-swarm-down="bash ~/.openshell-kit/scripts/stop-swarm.sh"
```

---

## One-time setup

### 1. Start the OpenShell gateway

```bash
openshell gateway start
```

(If port 8080 conflicts with something else on your machine: `openshell gateway start --port 9090`.)

### 2. (Optional) Provision GitHub credentials

If you want sandboxes to clone or push to GitHub:

```bash
# One of:
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx       # personal access token
export GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx           # alternate name
gh auth login                                      # or use the gh CLI
```

`start-sandbox.sh` will automatically create an OpenShell `github` provider on first run that owns the real token; sandboxes only ever see a placeholder that the proxy substitutes at egress.

### 3. (Optional) Provision GitLab credentials

```bash
export GITLAB_TOKEN_SANDBOX=glpat-xxxxxxxxxxxxxxxxxxxx
```

Same model — `start-sandbox.sh` creates the `gitlab` provider on first run. The env var is named `GITLAB_TOKEN_SANDBOX` deliberately so it doesn't clash with `glab`'s `GITLAB_TOKEN` on the host.

### 4. Have Claude Code logged in on the host

```bash
claude --version    # sanity check
claude /login       # if not already authed
```

The in-sandbox `claude` will do its own `/login` the first time you spin up a sandbox (interactive flow — opens a browser locally, you paste the code back).

---

## Daily workflow

```bash
os-up                              # auto-named (s1, s2, …), interactive (drops you into claude)
os-up my-sandbox                   # custom name
os-up my-sandbox --no-connect      # create only, don't SSH in
os-up -- -p "do the thing"         # headless agent run: claude -p '...' then exit

os-down s1                         # tear down one
os-down s1 s2 s3                   # several
os-down --all                      # everything (prompts)
os-down -y --s-only                # all auto-named s<N> sandboxes, no prompt
```

On a fresh sandbox you'll need to do `claude /login` once inside (the in-sandbox OAuth flow). The session token persists for the life of the sandbox. Subsequent reconnects via `ssh openshell-<name>` (or VS Code) auto-launch claude with the cached session.

---

## Swarm: multi-sandbox cluster

When you want N isolated sandboxes running in parallel — different roles, different work streams, different builders — use the swarm runner:

```bash
os-swarm-up                            # 5 sandboxes (swarm-1 .. swarm-5), tmux session with one window each
os-swarm-up --count 3                  # only 3
os-swarm-up --prefix dev               # dev-1 .. dev-5 instead
os-swarm-up --no-attach                # provision everything, don't enter tmux
os-swarm-up --force                    # kill + rebuild the tmux session (sandboxes survive)
os-swarm-down                          # prompt, kill tmux, delete swarm-* sandboxes
os-swarm-down -y                       # skip the prompt
os-swarm-down --tmux-only              # close tmux, keep the sandboxes
os-swarm-down --sandboxes-only         # delete sandboxes, leave tmux
```

**Without tmux installed:** `start-swarm.sh` still provisions the sandboxes serially and prints the `ssh openshell-<name>` commands you'd use to connect to each one individually. No fatal error.

**Sequential by design.** Concurrent sandbox creates saturate the OpenShell gateway and time out (the symptom is sandboxes that show `Phase: Ready` but `sandbox-init.sh` never ran — bare pods). Once the sandbox image is cached, serial is fast.

---

## Conversation context: snapshot / restore

The Claude conversation state inside a sandbox (transcripts + per-project auto-memory at `/sandbox/.claude/projects/`) is **disposable by default** — wiped when you delete the sandbox. Two standalone scripts let you preserve it across rebuilds:

```bash
bash scripts/snapshot-context.sh --name s1         # download → state/s1/
bash scripts/snapshot-context.sh --name s1 --dest /tmp/x

bash scripts/restore-context.sh --name s1          # upload state/s1/projects → /sandbox/.claude/projects
bash scripts/restore-context.sh --name s1 --source /tmp/x
```

The snapshots live in `state/<sandbox-name>/` (gitignored). What's captured: transcripts (`*.jsonl`) + per-project auto-memory + transient PID→session mappings. What's **not** captured: credentials, settings, plugins, host-bound config — all of which `sandbox-init.sh` re-applies on the next bootstrap.

**These scripts are intentionally standalone — not auto-wired into `start-sandbox.sh` / `stop-sandbox.sh`.** If you want them auto-wired (e.g., snapshot before every teardown, restore after every fresh provision), call them yourself from a wrapper or modify the lifecycle scripts.

---

## VS Code Remote-SSH

`start-sandbox.sh` automatically registers each new sandbox as an SSH host. The alias is `openshell-<sandbox-name>`. The lifecycle is independent of VS Code — closing the editor doesn't stop the sandbox, and `stop-sandbox.sh` removes the SSH entry automatically.

**Open a sandbox in VS Code from the terminal:**

```bash
code --remote ssh-remote+openshell-s1 /sandbox
```

(The script prints this command at the end of every successful run.)

### One-time setup: WSL2 users

VS Code on Windows reads `C:\Users\<you>\.ssh\config`, not WSL's `~/.ssh/config`. The helper detects WSL and writes a Windows mirror at `C:\Users\<you>\.ssh\openshell.conf` with a `wsl.exe`-wrapped `ProxyCommand` so Windows OpenSSH can reach the sandbox without a Linux binary on PATH.

Point VS Code at the mirror once, in `settings.json`:

```json
{
  "remote.SSH.configFile": "C:\\Users\\<your-windows-user>\\.ssh\\openshell.conf",
  "remote.SSH.localServerDownload": "always"
}
```

**`remote.SSH.localServerDownload: "always"` is mandatory** — the sandbox egress policy blocks Microsoft CDNs, so VS Code's default "download the server inside the sandbox" approach hangs forever at "Installing VS Code Server". `always` makes the Windows client download the ~100MB server and push it through the SSH tunnel — zero sandbox egress, no policy change needed.

### One-time setup: native Linux / macOS

Nothing extra — VS Code reads `~/.ssh/config` directly, and the helper adds an `Include openshell.conf` line to it on first run.

---

## Security model

| Layer | What it does |
|---|---|
| Network policy | Allow-list of endpoints declared in `sandbox/policy.yaml`. Everything else denied at the in-pod proxy. |
| Provider system | Real credentials (GitHub PAT, GitLab PAT, Anthropic OAuth) live in the OpenShell gateway. Sandboxes see opaque placeholders that the proxy substitutes at egress. A compromised in-sandbox process can't exfiltrate tokens that aren't there. |
| Filesystem policy | OpenShell defaults — writes restricted to `/sandbox` + `/tmp`, no host FS access, no host network. |
| Process policy | Runs as the `sandbox` user, no sudo, no Docker. |
| Disposable sandboxes | Default lifecycle is create → work → destroy. No state survives teardown unless you snapshot it. |

---

## ⚠ Restricting git (the trust-boundary gap)

**The shipped baseline allows in-sandbox agents to `git push` directly to any allowlisted remote without going through any wrapper.** The `github_git` and `gitlab_git` policies both include the `POST /**/git-receive-pack` rule, and `/usr/bin/git` is in the binaries list. So an agent doing `git push origin master` will succeed — no protected-branch check, no force-push refusal, no hook-bypass refusal, no operator-in-the-loop.

This is **the right default** for a starter kit (you can iterate freely while getting set up). It's **the wrong default for an autonomous agent** making changes on its own — the agent has no enforcement preventing `git push --force` to your default branch.

### The pattern to fix it

OpenShell's proxy walks the full process ancestor chain when matching binaries, and the OR-across-policies semantics let you split read access from write access onto two policies that target the same endpoint. The fix:

1. Pick a wrapper binary the agent will route through for mutations — a Go (or any language) binary (call it `<your-wrapper>`) that knows the rules you want (no force, no `--no-verify`, no master pushes, etc.) and shells out to git internally.
2. Stage the wrapper into your sandbox via `sandbox-init.sh` so it lands at a known path (e.g. `~/.local/bin/<wrapper>` → resolved real path `/sandbox/.local/bin/<wrapper>`).
3. **Split `github_git` (and `gitlab_git`) into two policies on the same endpoint:**

```yaml
# Read-only git: clone, fetch, info/refs. Any /usr/bin/git invocation can do these.
github_git_ro:
  name: github-git-ro
  endpoints:
    - host: github.com
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: GET,  path: "/**/info/refs*" }
        - allow: { method: POST, path: "/**/git-upload-pack" }
  binaries:
    - { path: /usr/bin/git }

# Mutating git: receive-pack (push). Requires <your-wrapper> as an ancestor
# of the connecting git process — closes the raw-`git push` backdoor.
github_git_rw:
  name: github-git-rw
  endpoints:
    - host: github.com
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: GET,  path: "/**/info/refs*" }
        - allow: { method: POST, path: "/**/git-upload-pack" }
        - allow: { method: POST, path: "/**/git-receive-pack" }
  binaries:
    - { path: "/sandbox/.local/bin/<your-wrapper>" }
```

How it works:

- An agent's raw `git push`: matches `_ro`'s binary list but `_ro`'s rules don't include receive-pack → no allow from that policy. Matches `_rw`'s endpoint but the connecting git's ancestors don't include `<your-wrapper>` → binary check fails → no allow from that policy either. → **denied**.
- `<your-wrapper> git push`: `_ro` matches binary+endpoint but rules don't allow receive-pack → no contribution. `_rw` matches binary (wrapper is in the ancestor chain when it spawned git), endpoint, AND rules (receive-pack allowed) → **allowed**.

Clones, fetches, and refs lookups still work for any caller (including any bootstrap clones you add to `sandbox-init.sh`). Only pushes are gated.

Symmetric change applies to `gitlab_git` if you push to GitLab.

The proxy mechanism (resolved-binary-path matching over the full ancestor chain) that makes this work is documented in detail in [`AGENTS.md`](AGENTS.md) — written for agents but operator-readable.

---

## Customization

The shipped kit is deliberately minimal so you can grow it. Common adds:

### Clone repos at sandbox boot

Edit `sandbox/sandbox-init.sh`, add after the Claude HUD install:

```bash
# Clone the repos you want pre-populated in every sandbox.
REPOS=(your-org/repo-a your-org/repo-b)
for repo in "${REPOS[@]}"; do
    target="/sandbox/${repo##*/}"
    [[ -d "$target/.git" ]] && continue
    git clone "https://github.com/${repo}.git" "$target"
done
```

### Install a language toolchain

In `sandbox/sandbox-init.sh`, add the install step + add the resolved binary path to `sandbox/policy.yaml`. Watch the resolved-path gotcha — `readlink -f` the binary inside a real sandbox before allowlisting.

### Enable npm / pypi / ollama

Uncomment the corresponding block in `sandbox/policy.yaml`. The ollama block has an inline note about the SSRF override and `host.openshell.internal` resolution that you'll want to read before enabling.

### Snapshot/restore on every teardown / startup

Wrap `stop-sandbox.sh` and `start-sandbox.sh` (or modify them) to call `snapshot-context.sh` / `restore-context.sh` as appropriate.

### Bake services into the sandbox image

For things like MongoDB / Elasticsearch / MinIO that you don't want to install every sandbox-init, drop a `Dockerfile` in `sandbox/` extending `ghcr.io/nvidia/openshell-community/sandboxes/base:latest`, and pass `--from sandbox/` to `openshell sandbox create` in `start-sandbox.sh` (in addition to the policy + upload).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `claude /login` 403s in the browser | The 2026-05 OAuth domain migration; needs `claude.com` in policy | Already in the shipped baseline. If you stripped it, re-add it. |
| `Failed to connect to api.anthropic.com: ERR_BAD_REQUEST` from claude | Native Claude binary's resolved path isn't allowlisted | Verify `/sandbox/.local/share/claude/versions/*` is in `claude_code.binaries` |
| In-sandbox network call denied with no obvious reason | Default-deny for everything not allowlisted | `openshell logs <sandbox> \| grep -iE 'deny\|action=\|policy='` — the deny line carries the exact reason |
| Sandbox shows `Phase: Ready` but `claude` isn't there / nothing initialized | Gateway saturation killed `sandbox-init.sh` before it ran (bare pod) | `os-down -y <name>` and retry — transient |
| Custom-binary push (e.g. via a wrapper) 403s | Wrapper path not in the relevant `_git` policy's binaries (full ancestor chain check) | Add the wrapper's *resolved* real path to the binaries list; live-apply with `openshell policy set <sandbox> --policy sandbox/policy.yaml` (no rebuild) |
| VS Code Remote-SSH hangs on "Installing VS Code Server" | Default behavior tries to fetch the server from inside the sandbox (egress blocked) | Set `"remote.SSH.localServerDownload": "always"` in Windows VSCode settings.json |
| `ancestor integrity check failed for X: Binary integrity violation` | You modified binary X in-place inside a running sandbox (TOFU SHA256 mismatch) | No reset available — rebuild the sandbox. The iteration loop for binary updates is host-side build → sandbox rebuild. |
| `start-swarm.sh` hangs creating a sandbox | Gateway temporarily saturated | Ctrl+C, `os-down -y <swarm-prefix>-N` for the half-created one, retry. Don't introduce parallelism — it makes the problem worse. |

For deeper coverage of the proxy's behavior (binary classification, SSRF guard, TOFU, OAuth migration) see [`AGENTS.md`](AGENTS.md) — it's written for agents but is operator-readable.

---

## Layout

```
openshell-kit/
  README.md                          # this file
  LICENSE                            # MIT
  .gitignore                         # state/, .env, editor noise
  AGENTS.md                          # context primer for agents (auto-region + operator-curated section)
  .agents/notes.md                   # human-owned free-form notes
  scripts/
    start-sandbox.sh                 # create + configure + connect to a single sandbox
    stop-sandbox.sh                  # tear down sandbox(es)
    start-swarm.sh                   # 5-sandbox cluster + tmux session (tmux-optional)
    stop-swarm.sh                    # tear down the swarm
    snapshot-context.sh              # download Claude transcripts from a sandbox to host
    restore-context.sh               # upload snapshotted transcripts back
    _lib.sh                          # shared helpers (sourced, not executed)
    _ssh-config.sh                   # SSH-alias management (sourced; WSL2-aware)
  sandbox/                           # uploaded into every sandbox at create time
    sandbox-init.sh                  # in-sandbox bootstrap (runs at boot)
    policy.yaml                      # network/filesystem/process policy
    claude.json                      # onboarding bypass + per-project trust
    claude-settings.json             # model, marketplaces, HUD plugin, statusLine
    claude-hud-config.json           # HUD display preferences
  state/                             # gitignored; created by snapshot-context.sh
```

---

## License

MIT. See [LICENSE](LICENSE).
