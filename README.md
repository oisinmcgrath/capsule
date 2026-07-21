<!-- @tagdex: docs, orient, primary -->
# capsule

Stand up a new sandboxed **DevPod + Podman + VSCodium** repo, ready for autonomous agent work, with one command. The wizard scaffolds the devcontainer, installs the generic hooks, deploys tagdexer + a fresh taskboard, wires everything so your **first agent chat auto-onboards**, picks a non-clashing port, handles GPU/CDI, and verifies the container actually attaches before declaring success.

This replaces the previous placeholder-substitution runbook (manual `<TOKEN>` edits, hand-picked ports). Everything is derived deterministically now.

---

## Quick start

```bash
# On the HOST (not inside a container):
cd /home/user/projects/capsule
mkdir -p /home/user/projects/<new-repo>      # create the empty target repo first
bash wizard.sh
```

Answer the prompts (repo name, GPU?, extra apt). The wizard does the rest and offers to build + open the container at the end.

**GUI mode (default on the desktop):** when a display and `kdialog` or `zenity` are present, the questions appear as dialogs — you browse and click the repo folder instead of typing its name, and confirm the derived values in a yes/no box. kdialog (KDE-native picker) is preferred if installed; zenity is the fallback. Cancel on any dialog aborts. Pass `--no-gui` for the classic terminal prompts. Progress output always prints to the terminal either way.

---

## Why host-side

The wizard drives `devpod`, `podman`, `nvidia-ctk`, `ssh`, and `sqlite3` — none of which exist inside a devcontainer. **Run it from the host.** It refuses to run if those tools are missing.

Requires: `bash`, `jq`, `devpod`, `podman`, `ssh`, `sqlite3` (and `nvidia-ctk` only if you choose GPU).

---

## What it produces in the new repo

```
<repo>/
├── .devcontainer/
│   ├── devcontainer.json          # mounts, port, runArgs (GPU device only — never --pid=host)
│   ├── Dockerfile                 # lean baseline + your extra apt
│   ├── container-claude-settings.json   # bypassPermissions + effortLevel:max
│   └── post-create.sh             # vsix install, venv, claude settings, memory-bridge symlink
├── .claude/
│   ├── settings.json              # wires the 9 generic hooks (+ taskboard adds 2)
│   └── hooks/                     # the 9 generic hooks
├── tagdexer/                      # CLI deployed; .tagdexerrc -> /workspaces/tagdexer-source
├── taskboard/                     # fresh, empty board + its 2 hooks wired
├── CLAUDE.md                      # project stub (no fbad content)
└── .tagdexerrc                    # genericPath = in-container mount
```

Decision log (`tagdexer/decisions.jsonl`) starts **absent** (JSONL: absent == empty). Taskboard starts **empty**. No content from any other repo leaks in.

---

## What it derives for you (no clashes)

| Value | Rule | Example (`llama-worker-agent`) |
|---|---|---|
| Sanitized workspace name | strip `_`, keep `-`, lowercase | `llama-worker-agent` |
| Container path | `/workspaces/<sanitized>` | `/workspaces/llama-worker-agent` |
| Host project key | `/home/user/projects/<repo>`, `/`+`_`→`-`, leading `-` | `-home-user-projects-llama-worker-agent` |
| Container project key | `-workspaces-<sanitized>` | `-workspaces-llama-worker-agent` |
| Forward port | next free ≥8080 not used by another workspace or bound | `8082` (pickles=8080, fbad=8081) |

---

## Existing repos

The wizard is safe to run on a repo that already has code and history:

| | What happens |
|---|---|
| **Preserved** | `CLAUDE.md`, `tagdexer/decisions.jsonl`, `tagdexer/aliases.json`, taskboard `lists/` + `domains.json` (carried across the refresh), `.git` (init skipped) |
| **Backed up** | `.claude/settings.json` → `settings.json.pre-wizard` (re-merge custom hooks yourself); `.venv` → `.venv_host_backup` (host-built venvs don't run in-container; wizard asks first, post-create rebuilds a broken one regardless) |
| **Replaced** | `.devcontainer/`, `.claude/hooks/`, taskboard code + hooks, `.tagdexerrc` |

The `/workspaces` symlink step now skips sudo entirely when the links are already correct, and prints manual commands instead of dying if sudo is unavailable (e.g. agent-driven runs).

---

## The two hard-won fixes (baked in)

### 1. Never `--pid=host`
A container with `--pid=host` sees the **host's** process table. `open-remote-ssh` decides whether a server is "already running" by scanning processes — with `--pid=host` it finds *another* container's `codium-server` (same VSCodium build hash), concludes a server is up, takes the reuse path, finds no connection-token file, and aborts (`exitCode 1`, "Could not establish connection"). Plain `ssh` works because it doesn't inspect processes — only the VSCodium client does, which is why "ssh works but the window doesn't."

The wizard emits GPU repos with `runArgs: ["--device=nvidia.com/gpu=all", "--security-opt=label=disable"]` and non-GPU repos with `runArgs: []`. **Never `--pid=host`.**

### 2. GPU CDI version is probed + auto-pinned
*(Applies only when you answer GPU = yes, i.e. an NVIDIA host. The current host has no NVIDIA GPU; this logic is retained for the GPU machine and stays dormant on a CPU-only box — you'll simply answer "no" at the prompt and `nvidia-ctk` isn't required.)*

Podman 4.9.3 parses CDI spec **≤0.6.0**. A driver update can leave `/etc/cdi/nvidia.yaml` at 0.7.0, and `nvidia-ctk` ≥1.17 dropped `--cdi-version` and auto-emits the minimum-required (often 0.7.0+) — so `podman run --device nvidia.com/gpu=all` fails with `unresolvable CDI devices` and the container won't start. The wizard:
1. probes `podman run … nvidia-smi -L`;
2. if it fails, regenerates — pinned to `0.6.0` if the flag exists, else plain regen;
3. **re-verifies end-to-end**, so a silent CPU fallback can't pass;
4. if still broken, tells you to downgrade the toolkit (1.16.2 emits 0.5.0) and re-run.

---

## tagdexer in the sandbox (the silent-degrade trap)

The deployed tagdexer CLI reads the **central** source at runtime for shared aliases + `trackdexer.config.json`. If `.tagdexerrc`'s `genericPath` points at a host path (`/home/user/projects/tagdexer`) that doesn't exist inside the container, the CLI **still runs but silently loses the shared layer** (tags show `[project]` not `[shared+project]`). The container bind-mounts central tagdexer at `/workspaces/tagdexer-source`, so the wizard writes `genericPath=/workspaces/tagdexer-source`. The wizard verifies the shared layer is active after build.

---

## Troubleshooting (earned the hard way)

| Symptom | Cause / fix |
|---|---|
| `unresolvable CDI devices nvidia.com/gpu=all` | CDI spec version > Podman's ceiling. Regen at ≤0.6.0; if toolkit can't pin, downgrade to `nvidia-container-toolkit=1.16.2-1` and re-run wizard GPU step. |
| Window: "Could not establish connection" / "install vscode server non-zero" while **plain ssh works** | Almost always `--pid=host` in runArgs → open-remote-ssh false-positives on another container's server. Remove it. The wizard never adds it; if an old repo has it, delete the line and **recreate via Command-Palette → DevPod: Recreate** (CLI `--recreate` caches the old config). |
| Title bar shows the **wrong** `.devpod` host | Cosmetic stale label cache. `sqlite3 ~/.config/VSCodium/User/globalStorage/state.vscdb "DELETE FROM ItemTable WHERE key='memento/cachedResourceLabelFormatters2';"` Trust `hostname` in the container terminal, not the title. |
| `Error port forwarding NNNN: address already in use` | Another process holds the port. The wizard picks a free one; if a clash appears later, find it with `ss -ltnp 'sport = :NNNN'`. |
| tagdexer tags show `[project]` only | `genericPath` not resolving in-container. Check `.tagdexerrc` = `/workspaces/tagdexer-source` and that the mount exists. |
| Editing `.devcontainer/` blocked by the protect hook | `mv .claude/hooks/protect_devcontainer.sh{,.disabled}` → edit → move back. Bash dodges the `Edit\|Write` matcher. |
| `devpod up --recreate` keeps old runArgs | DevPod cached the parsed config. Use Command-Palette **DevPod: Recreate**, or `devpod delete <name> --force && devpod up <name> --ide codium`. |
| Grok/tools: "Couldn't read clipboard contents" on image paste | Host Wayland clipboard not reaching the container. See **Host clipboard passthrough** below. |

---

## Host clipboard passthrough (image paste into in-container tools)

So an agent/tool running **inside** the container (e.g. Grok) can `Ctrl+V` a host screenshot — `image/png`, which OSC 52 can't carry — the wizard bind-mounts the host **runtime directory** (`$XDG_RUNTIME_DIR`) to `/run/host-xdg/` — the whole dir, NOT the single `wayland-0` file, so a logout/login or compositor restart (which makes a fresh socket) doesn't leave the container bound to a dead one — and sets `WAYLAND_DISPLAY` + `DBUS_SESSION_BUS_ADDRESS` (pointing into that dir) in `containerEnv`. `wl-clipboard` is baked into the image. `--security-opt=label=disable` lets the container open the sockets under SELinux (same relaxation used for accel devices). No `--userns` needed — DevPod's podman provider already maps host uid 1000 → container `vscode`, so the socket is owned by `vscode` inside.

**Requirement:** launch the IDE / run the wizard **from the graphical KDE session**, so `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR` exist at container-create time. If they're absent, the wizard **skips** the mounts and warns (no broken bind) — clipboard passthrough is simply disabled until you re-run from a graphical session.

**Verify inside the container** (with an image on the host clipboard):
```bash
wl-paste --list-types        # should include image/png
```
If it prints "failed to connect": check the `wayland-0` mount and that `label=disable` is in runArgs.

---

## Maintaining the payload

When you improve a generic hook in a live repo, copy it into `payload/claude_hooks/` to canonicalize it. The two `block_*` hooks (`block_pip_install`, `block_git_writes`) are deliberately **excluded** from the generic set.

tagdexer is **not** vendored here — it is mounted at build time from the central `tagdexer/` sibling of this wizard (here `/home/user/projects/tagdexer`; overridable via `$CENTRAL_TAGDEXER`), so new repos always get the current central version. Taskboard **is** vendored (`payload/taskboard/`) because it is self-contained; refresh it when taskboard improves.
