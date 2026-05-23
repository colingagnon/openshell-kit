# AGENTS.md — context primer for agents

<!-- auto:start generated-by=author-agent-context last-run=2026-05-23T00:00:00Z section=all -->

openshell-kit is a **starter operator layer** for OpenShell sandboxes — host-side bash + YAML + JSON glue that an operator uses to spin up / configure / tear down sandboxes for autonomous agent work. It is **not an application**. Scripts in `scripts/` create and manage sandboxes; files in `sandbox/` are uploaded *into* each sandbox as its bootstrap. For the human-facing setup walkthrough see [`README.md`](README.md).

## Stack

- **Bash** — 8 shell scripts (`scripts/` + `sandbox/sandbox-init.sh`), all with `set -euo pipefail` except the sourced libs (`_lib.sh`, `_ssh-config.sh`) by design.
- **YAML** — single file `sandbox/policy.yaml` (OpenShell network/filesystem/process policy).
- **JSON** — `sandbox/claude*.json` (Claude config baked into sandbox bootstrap).
- No language manifest by design. The kit orchestrates external tools (`openshell`, `docker`, `git`, `claude`, optionally `gh` / `glab` / `tmux`); it doesn't compile or ship code itself.
- Host-side runtime deps: `openshell` CLI, `docker`, a way to get GitHub and/or GitLab credentials (env var or `gh auth login`), `claude` (Claude Code) on the host for the OAuth chain. `tmux` is **optional** (the swarm script degrades gracefully without it).

## Build / test / dev commands

There are no tests. The operator workflow is the scripts in `scripts/`:

```bash
bash scripts/start-sandbox.sh                    # create + connect to one sandbox
bash scripts/stop-sandbox.sh <name>              # tear down by name
bash scripts/start-swarm.sh                      # 5 sandboxes + tmux session (default)
bash scripts/stop-swarm.sh                      # tear down the swarm
bash scripts/snapshot-context.sh --name <sbx>    # ad-hoc: save Claude transcripts
bash scripts/restore-context.sh --name <sbx>     # ad-hoc: restore transcripts
```

Every script accepts `-h` / `--help` and prints its usage from the leading comment block.

## Repository structure

- `scripts/` — operator entry points (host-side). `_lib.sh` and `_ssh-config.sh` are sourced libs (underscore-prefix convention), not invokable.
- `sandbox/` — assets uploaded *into* every sandbox at create time: `sandbox-init.sh` (entrypoint), `policy.yaml` (network/FS/process policy), `claude*.json` (pre-baked Claude config).
- `state/` — gitignored. Created by `snapshot-context.sh` to hold per-sandbox Claude transcript snapshots that survive sandbox rebuilds.

## Entry points

Host-side (in `scripts/`):

- `start-sandbox.sh` — primary entry. Preflight (openshell + docker + gateway), optional provider provisioning (github / gitlab if a token is resolvable), stage bundle from `sandbox/`, `openshell sandbox create --policy sandbox/policy.yaml`, register SSH alias, optionally SSH in.
- `stop-sandbox.sh` — delete sandbox(es), strip SSH aliases.
- `start-swarm.sh` — provision N sandboxes (default 5, `swarm-1`..`swarm-5`) serially, then if `tmux` is present build a multi-window session and attach. Without `tmux`, prints connect commands instead.
- `stop-swarm.sh` — kill tmux session (if any) + delete all `<prefix>-N` sandboxes.
- `snapshot-context.sh` / `restore-context.sh` — Claude transcript persistence for any sandbox by name.
- `_lib.sh` (sourced) — namespacing: `osk::info/ok/warn/err/die`, `osk::require_cmd/require_env`, `osk::resolve_github_token / resolve_gitlab_token`, `osk::ensure_gateway`, `osk::ensure_provider`, `osk::next_name`.
- `_ssh-config.sh` (sourced) — registers/unregisters per-sandbox SSH host blocks in `~/.ssh/openshell.conf` + on WSL2 also writes a Windows mirror with `wsl.exe`-wrapped ProxyCommand.

In-sandbox (uploaded; runs inside the sandbox):

- `sandbox/sandbox-init.sh` — runs once at boot. Configures git identity + credential helpers, installs the native Claude build via `claude install`, installs the Claude HUD plugin, applies pre-baked Claude configs, wires `.bashrc` to auto-launch claude on interactive shells. **Intentionally does NOT clone repos or install language toolchains** — customize as needed.

## Environment variables

Host-side (optional — the scripts gracefully no-op if the corresponding provider isn't needed):

- `GITHUB_TOKEN` / `GH_TOKEN` — used (in that order, with `gh auth token` as final fallback) to provision the `github` OpenShell provider on first run. Real token captured by the gateway, never enters a sandbox.
- `GITLAB_TOKEN_SANDBOX` / `GITLAB_TOKEN` — same model for the `gitlab` provider. Prefer `GITLAB_TOKEN_SANDBOX` to avoid clashing with `glab`'s own `GITLAB_TOKEN`.

There's no `.env.example` because there are no required env vars. Add whatever your customizations need.

## Network policy (sandbox/policy.yaml)

Active by default: `github_git`, `github_api`, `gitlab_git`, `gitlab_api`, `claude_code`. Commented-out optional blocks: `npm`, `pypi`, `ollama` (raw host-Ollama passthrough). Filesystem policy (read-only `/usr`, `/lib`, `/etc`; read-write `/sandbox`, `/tmp`) and process policy (`run_as_user: sandbox`) are standard. See the file's inline comments + README for the operator-meaningful details — especially the security note about git push.

## Conventions

- **Bash discipline:** `set -euo pipefail` everywhere except sourced libs (where propagating `-e` to callers would be wrong).
- **Underscore-prefix for sourced libs:** `_lib.sh`, `_ssh-config.sh`.
- **`osk::` function prefix** for helpers in `_lib.sh`.
- **Header comment shape:** every script opens with `#!/usr/bin/env bash` + `# <name> — <one-line purpose>` + a `# Usage:` block. `--help` extracts and prints this.
- **Color-coded operator logging** (`›` info, `✓` ok, `!` warn, `✗` err), all to stderr so stdout stays clean.

## External integrations

- **OpenShell CLI** (`openshell`) — sandbox lifecycle, provider provisioning, policy management. Required.
- **Docker** — runs the OpenShell gateway. Required.
- **GitHub** (optional) — `github.com` clones + `api.github.com` REST/GraphQL.
- **GitLab** (optional) — `gitlab.com` clones + REST/GraphQL.
- **Anthropic Claude** — both via the in-sandbox `claude` CLI (interactive `/login`) and the native build downloaded from `downloads.claude.ai`.

<!-- auto:end -->

## Operator notes

See [`.agents/notes.md`](.agents/notes.md) for context the skill didn't capture. The substantive operator-curated context for this kit lives below the sentinel in this file — it's the first hand-written section an agent reading the file linearly encounters, and it survives `author-agent-context` re-runs.

## Known unknowns (OPEN QUESTIONs)

<!-- auto:start section=open-questions -->
- (none — this is a starter kit; gaps are documented as customization points in README.md, not as OPEN QUESTIONs)
<!-- auto:end -->

<!-- Content below this line is preserved verbatim on re-run. -->

---

## Operator-curated context (hand-written; survives skill re-runs)

The auto-generated section above describes **what** is in this kit. This section is load-bearing tribal knowledge about OpenShell itself that bit us repeatedly while developing the patterns the kit ships with. It's not derivable from local files — it came from reading OpenShell's source, hitting failure modes, and reverse-engineering the proxy's behavior. If you're an agent working inside an openshell-kit sandbox (or modifying this kit), **trust this section over re-deriving from OpenShell source or from your own assumptions.**

### How OpenShell's egress proxy actually classifies traffic

There is a single in-pod proxy that intercepts every outbound connection (default `http://10.200.0.1:3128`). It decides allow/deny by combining three things:

1. **Endpoint match** — does the destination `host:port` appear in some `network_policies.*.endpoints[]`?
2. **Binary match** — does the connecting process's binary (or *any* ancestor's binary) appear in that same policy's `binaries[].path`?
3. **L7 rule match** — if the endpoint has `protocol: rest` and `rules:`, does the method+path match?

A request passes iff **at least one policy** has *all three* match. Default is deny. The OR-across-policies semantic is the basis for splitting one logical access surface across multiple policies (e.g. a read-policy for one binary + a write-policy for a different binary on the same endpoint).

**Critical: binary identity is the *resolved* exe path, not `comm`.** The proxy reads `/proc/<pid>/exe` via `read_link` and walks every ancestor process the same way. This means:

- **Symlinks are followed.** When you allowlist a binary, list its real path (or a glob covering it), not the symlink. The Claude native build is the canonical example: `~/.local/bin/claude` → `~/.local/share/claude/versions/<ver>/...` — the version path is what the proxy sees.
- **Renaming a binary file changes its identity** (different real path).
- `/proc/<ppid>/comm` is **NOT** the discriminator. Don't propose `Setpgid`/`Setsid`/`PR_SET_NAME` workarounds — those don't change `/proc/<pid>/exe`.

When the proxy denies, the deny log line carries the exact reason. **Check the logs before speculating about the cause** — `openshell logs <sandbox> | grep -iE 'deny|action=|policy='`. Every wild-goose chase comes from guessing about HTTP/auth/DNS instead of looking at the log; the log is always definitive.

### `HOME=/sandbox` — path-resolution gotchas

The in-sandbox user's `HOME` is `/sandbox` (not `/home/sandbox`). Anything installed into `$HOME` ends up under `/sandbox/...`. Combined with resolved-binary-path matching, this means:

- The Claude native build → `/sandbox/.local/bin/claude` → `/sandbox/.local/share/claude/versions/<ver>/...` (resolved). The shipped `claude_code.binaries` allowlists `/sandbox/.local/share/claude/versions/*` (version-agnostic glob) — this is the load-bearing entry; the symlink path is defense-in-depth.
- If you uncomment the `pypi` block, the venv python at `/sandbox/.venv/bin/python` is typically a uv-managed symlink. The real path is something like `/sandbox/.uv/python/cpython-<ver>-linux-x86_64-gnu/bin/python3.<minor>`. The shipped commented entries include both the symlink path and the uv-managed real path for completeness.

**Rule:** when adding a binary to `policy.yaml`, `readlink -f` it inside a real sandbox first. The on-disk symlink path is almost never the right thing to allowlist.

### SSRF guard and `allowed_ips` override

The proxy has an anti-SSRF check: even if a hostname is in `endpoints[]`, the proxy resolves it via DNS and **blocks any IP in private/RFC1918/loopback ranges**. This is why a bare `{host: host.openshell.internal, port: 11434}` 403s on CONNECT — `host.openshell.internal` resolves to `192.168.65.254` (Docker Desktop host gateway, a private IP). The documented escape hatch is `allowed_ips` on the endpoint:

```yaml
- host: host.openshell.internal
  port: 11434
  allowed_ips: ["192.168.65.254"]
```

`allowed_ips` is a list of plain IP strings (no CIDR, no port). Must include every IP the hostname resolves to. Re-check via `getent hosts host.openshell.internal` inside a sandbox if Docker / the gateway topology changes.

### TOFU binary integrity (and why in-place binary updates kill the sandbox)

The in-pod proxy keeps a **SHA256 hash cache** of every binary it has ever seen for a connection (TOFU — trust on first use). On subsequent CONNECTs, it verifies the cached hash against the current on-disk file. If they differ, the deny log reads `ancestor integrity check failed for <ancestor>: Binary integrity violation: <ancestor> hash changed`.

**This applies to every binary in the ancestor chain**, not just the immediate caller.

**There is no user-facing reset.** The cache lives in pid-1's process memory; **only a sandbox rebuild resets it.** Practical implication: if you write any custom script that replaces a binary in-place inside a running sandbox (recompile, swap, in-place upgrade), every CONNECT involving that binary will 403 until rebuild. The official iteration loop is: edit on the host → commit → rebuild the sandbox.

**Recovery path when this hits and you have unpushed work inside a broken sandbox:**

1. Use raw `git push` (the `/usr/bin/git` binary is unchanged, so its integrity is fine — only the just-modified binary's chain is affected).
2. Or use **host-mediated push**: `git bundle create rescue.bundle origin/master..HEAD` inside the sandbox, `openshell sandbox download <name> /tmp/rescue.bundle .` on the host, `git fetch ./rescue.bundle main:rescue && git push origin rescue`. Works through the gateway control plane, unaffected by TOFU or policy state.
3. Then rebuild the sandbox.

### Network policy is DYNAMIC — never rebuild for a policy change

`network_policies` is a Dynamic field. Live updates:

```bash
openshell policy set <sandbox> --policy sandbox/policy.yaml
```

Per-sandbox; takes effect in ~5–10 seconds (propagation is async — `Status: Pending` → `Status: Loaded`). Verify with `openshell policy get <sandbox>`. **Never rebuild a sandbox just to push a policy change.** Rebuild is only needed for things baked at create (`sandbox-init.sh`, filesystem layout, the binary that pid-1 SHA256-cached) or to escape TOFU.

### Anthropic OAuth domain migration (2026-05)

`claude /login` uses `https://claude.com/cai/oauth/authorize` as the authorize host (callback on `platform.claude.com`). Both must be in `claude_code.endpoints` — the shipped baseline already has them. Without `claude.com`, login 403s/hangs with a misleading "Failed to connect to api.anthropic.com: ERR_BAD_REQUEST". Don't chase the api.anthropic.com host when you see that error — verify `claude.com` is allowlisted first.

### Gateway saturation + bare-pod recovery

`openshell sandbox create` can hang at the **file-upload step** when the gateway is under load (e.g. running multi-sandbox swarms, repeated create/delete churn). The sandbox shows `Status: Ready` (the pod is up) but `sandbox-init.sh` never runs because the bundle was never uploaded. The script's `timeout` kills it; you're left with a bare, uninitialized pod (only `sleep infinity` running as pid 1).

**Recovery:** `stop-sandbox.sh -y <name>` to delete the bare pod, then re-run `start-sandbox.sh`. Second attempt usually succeeds — the issue is transient saturation. **Related: `start-swarm.sh` is serial by design.** Don't add a `--parallel` mode; concurrent sandbox creates saturate the gateway and time out at 300s.

### VSCode Remote-SSH into sandboxes

`_ssh-config.sh` auto-maintains `~/.ssh/openshell.conf` and (on WSL2) a Windows mirror with `wsl.exe`-wrapped ProxyCommand. Open a sandbox in VSCode via `code --remote ssh-remote+openshell-<name> /sandbox`.

**Required Windows VSCode setting:** `"remote.SSH.localServerDownload": "always"`. Otherwise first connect hangs forever at "Installing VS Code Server" — the sandbox can't reach Microsoft CDNs and the default behavior tries to fetch the server *inside* the sandbox. `always` makes the Windows client fetch the server and push it through the SSH tunnel — zero sandbox egress.

### Where to read OpenShell source if you need to verify behavior

`crates/openshell-sandbox/data/sandbox-policy.rego` (OPA policy logic), `crates/openshell-sandbox/src/procfs.rs` (exe-path resolution + ancestor chain walk), `crates/openshell-sandbox/src/identity.rs` (TOFU SHA256 cache), `docs/sandboxes/policies.md`, `docs/reference/policy-schema.md` (schema). Clone OpenShell locally and grep when in-system behavior contradicts your mental model. The version on disk may not match the deployed gateway exactly; check carefully for behavioral drift.

### Where this kit deliberately stops

This kit ships a **baseline that works** but is opinionated in places you'll probably want to customize:

- **No repo clones in `sandbox-init.sh`** — you decide what gets cloned.
- **No language toolchains baked in** — add Go / Node / Python / Rust install steps as you need them, and remember to allowlist the resolved binaries in policy.yaml.
- **No credential broker** — uses interactive `claude /login` per sandbox. If you operate at scale and want one-OAuth-chain-to-many-sandboxes, you'd need to build a broker.
- **Git mutations are NOT yet gated through a wrapper** — see the README's "Restricting git" section for the L7-split recipe if you want protected-branch / no-force-push / etc. refusals.

### What to do when this section grows stale

Edit it directly. The auto-region above is regenerated by `author-agent-context`; this section below the sentinel is preserved verbatim across re-runs. If a topic gets too big, lift it into `.agents/<topic>.md` and leave a pointer here. Date claims that are time-sensitive.
