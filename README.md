<!-- @tagdex: docs, orient, primary -->
# Capsule

**Sandboxed, agent-ready dev containers in one command — DevPod + rootless Podman + VSCodium — for running autonomous AI coding agents (Claude Code, Grok, and friends) safely isolated from your host machine.**

**Capsule** is an interactive, host-side installer (`wizard.sh`) that turns any empty folder into a reproducible [devcontainer](https://containers.dev): it generates the `.devcontainer/` (Dockerfile + `devcontainer.json`), wires the agent hooks, deploys a decision log and a persistent task board, picks a non-clashing forwarded port, handles GPU / NPU / iGPU passthrough, sets up host Wayland clipboard passthrough, and **verifies the container actually attaches** before it declares success. No hand-edited placeholders — every value is derived deterministically, and host-specific settings are asked **once** and reused for every future repo.

> **Use it when** you want to let an AI agent write code, install packages, and run shell commands with broad permissions **without** handing it your real machine — a disposable, rebuildable, network-isolated container that still opens straight into a VSCodium window.

---

## What this is good for (features & keywords)

- **Sandbox for autonomous AI coding agents** — isolate Claude Code / Grok / any LLM agent in a rootless Podman container so it can run under bypass permissions while the host stays untouched.
- **Devcontainer generator / scaffolder** — produces a spec-compliant `devcontainer.json` + `Dockerfile` for **DevPod + Podman + VSCodium**; no Docker daemon, no root daemon required.
- **Deterministic, no-clash setup** — auto-derives the sanitized workspace name, container path, project keys, and the next free forwarded port (≥ 8080) so multiple sandboxed repos never collide.
- **GPU passthrough for containers** — NVIDIA via CDI (`--device=nvidia.com/gpu=all`), with **automatic CDI-spec version pinning** so it works on Podman 4.x (the classic `unresolvable CDI devices` failure, solved).
- **NPU & iGPU passthrough** — AMD XDNA / Ryzen AI NPU (`/dev/accel`) and AMD ROCm iGPU (`/dev/dri` + `/dev/kfd`), with the right render/video groups.
- **Host Wayland clipboard passthrough** — paste a host screenshot (`image/png`, which OSC 52 can't carry) straight into an in-container tool.
- **Agent-ready on first launch** — installs generic Claude Code hooks, a lightweight decision log (tagdexer), and a persistent task board, all firing on the first chat; Grok agent hooks are mirrored automatically with no duplicate scripts.
- **First-run machine profile** — host-specific values (container timezone, git author identity, where tagdexer/setsquare live, and whether to deploy the tagdexer decision-log — always / never / ask) are captured once in `~/.config/capsule/machine.conf` and reused for every repo you scaffold afterwards.
- **Optional, self-contained tagdexer** — the decision-log CLI is vendored in this repo (works with no external dependency); choose to deploy it into every repo, never, or per-repo, and the wizard can `git clone` it for you on first run.
- **Auto-installs the DevPod CLI** — if `devpod` isn't found, the first-run profile installs the official release binary for you (or points at your existing build).
- **Safe on existing repos** — preserves your code, git history, decision log, and task lists; backs up anything it replaces.
- **Isolation verified, never `--pid=host`** — sidesteps the `open-remote-ssh` "Could not establish connection" attach failure by construction (details below).

**Topics:** `devcontainer` · `podman` · `devpod` · `vscodium` · `sandbox` · `ai-agents` · `claude-code` · `llm-agent` · `rootless-containers` · `gpu-passthrough` · `nvidia-cdi` · `rocm` · `ryzen-ai` · `developer-tools` · `reproducible-environments`

---

## Quick start

```bash
# Run on the HOST (Linux), not inside a container:
cd capsule
mkdir -p ~/projects/<new-repo>      # create the empty target repo first
bash wizard.sh
```

Answer the prompts (which repo, GPU/NPU/iGPU?, extra apt packages, display name). On its **first ever run** Capsule also sets up your machine profile — container timezone, the git identity to stamp on scaffolded repos, your tagdexer deploy policy (always/never/ask), and where tagdexer/setsquare live (it can `git clone` tagdexer or install the DevPod CLI for you) — then saves it and never asks again. It derives everything else and offers to build + open the container at the end.

**GUI mode (default on the desktop):** when a display and `kdialog` or `zenity` are present, the questions appear as dialogs — you browse and click the repo folder instead of typing its name, and confirm the derived values in a yes/no box. `kdialog` (KDE-native picker) is preferred if installed; `zenity` is the fallback. Cancel on any dialog aborts. Pass `--no-gui` for the classic terminal prompts. Progress always prints to the terminal.

---

## Requirements

Run it **from the host** — the wizard drives `devpod`, `podman`, `nvidia-ctk`, `ssh`, and `sqlite3`, none of which exist inside a devcontainer. It refuses to run if a required tool is missing — except the `devpod` CLI, which the first-run profile offers to install for you (the official binary from [github.com/loft-sh/devpod](https://github.com/loft-sh/devpod)) or lets you point at an existing build.

Host tools: `bash`, `jq`, `podman`, `ssh`, `sqlite3` (plus `nvidia-ctk` only if you choose GPU). The `devpod` CLI is auto-installable on first run. Portable across Linux hosts — nothing host-specific is baked into the script; per-machine values live in the machine profile.

---

## What it produces in the new repo

```
<repo>/
├── .devcontainer/
│   ├── devcontainer.json          # mounts, port, runArgs (device passthrough only — never --pid=host)
│   ├── Dockerfile                 # lean baseline + your extra apt
│   ├── container-claude-settings.json   # bypassPermissions + effortLevel:max
│   └── post-create.sh             # vsix install, venv, agent settings, memory-bridge symlink
├── .claude/
│   ├── settings.json              # wires the 9 generic hooks (+ task board adds 2)
│   └── hooks/                     # the 9 generic hooks
├── .grok/hooks/                   # Grok agent hooks, mirrored from the Claude set
├── tagdexer/                      # decision-log CLI; .tagdexerrc -> /workspaces/tagdexer-source
├── taskboard/                     # fresh, empty task board + its 2 hooks wired
├── CLAUDE.md                      # project stub (no cross-repo content)
└── .tagdexerrc                    # genericPath = in-container mount
```

Decision log (`tagdexer/decisions.jsonl`) starts **absent** (JSONL: absent == empty). Task board starts **empty**. No content from any other repo leaks in.

---

## What it derives for you (no clashes)

| Value | Rule | Example (`llama-worker-agent`) |
|---|---|---|
| Sanitized workspace name | strip `_`, keep `-`, lowercase | `llama-worker-agent` |
| Container path | `/workspaces/<sanitized>` | `/workspaces/llama-worker-agent` |
| Host project key | absolute repo path, `/` + `_` → `-`, leading `-` | `-home-user-projects-llama-worker-agent` |
| Container project key | `-workspaces-<sanitized>` | `-workspaces-llama-worker-agent` |
| Forward port | next free ≥ 8080 not used by another workspace or bound | `8082` (e.g. two existing repos hold 8080, 8081) |

---

## Existing repos

Capsule is safe to run on a repo that already has code and history:

| | What happens |
|---|---|
| **Preserved** | `CLAUDE.md`, `tagdexer/decisions.jsonl`, `tagdexer/aliases.json`, task board `lists/` + `domains.json` (carried across the refresh), `.git` (init skipped) |
| **Backed up** | `.claude/settings.json` → `settings.json.pre-wizard` (re-merge custom hooks yourself); `.venv` → `.venv_host_backup` (host-built venvs don't run in-container; the wizard asks first, post-create rebuilds a broken one regardless) |
| **Replaced** | `.devcontainer/`, `.claude/hooks/`, task board code + hooks, `.tagdexerrc` |

The `/workspaces` symlink step skips sudo entirely when the links are already correct, and prints manual commands instead of dying if sudo is unavailable (e.g. agent-driven runs).

---

## The two hard-won fixes (baked in)

### 1. Never `--pid=host`
A container with `--pid=host` sees the **host's** process table. `open-remote-ssh` decides whether a server is "already running" by scanning processes — with `--pid=host` it finds *another* container's `codium-server` (same VSCodium build hash), concludes a server is up, takes the reuse path, finds no connection-token file, and aborts (`exitCode 1`, "Could not establish connection"). Plain `ssh` works because it doesn't inspect processes — only the VSCodium client does, which is why "ssh works but the window doesn't."

Capsule emits GPU repos with `runArgs: ["--device=nvidia.com/gpu=all", "--security-opt=label=disable"]` and non-GPU repos with `runArgs: []`. **Never `--pid=host`.**

### 2. GPU CDI version is probed + auto-pinned
*(Applies only when you answer GPU = yes, i.e. an NVIDIA host. On a CPU-only box you answer "no" and `nvidia-ctk` isn't required — the logic stays dormant.)*

Podman 4.9.3 parses CDI spec **≤ 0.6.0**. A driver update can leave `/etc/cdi/nvidia.yaml` at 0.7.0, and `nvidia-ctk` ≥ 1.17 dropped `--cdi-version` and auto-emits the minimum-required (often 0.7.0+) — so `podman run --device nvidia.com/gpu=all` fails with `unresolvable CDI devices` and the container won't start. Capsule:
1. probes `podman run … nvidia-smi -L`;
2. if it fails, regenerates — pinned to `0.6.0` if the flag exists, else plain regen;
3. **re-verifies end-to-end**, so a silent CPU fallback can't pass;
4. if still broken, tells you to downgrade the toolkit (1.16.2 emits 0.5.0) and re-run.

---

## Decision log in the sandbox (the silent-degrade trap)

The deployed [tagdexer](tagdexer/AGENT_README.md) decision-log CLI reads a **central** source at runtime for its shared aliases + config. If `.tagdexerrc`'s `genericPath` points at a **host** path that doesn't exist inside the container, the CLI **still runs but silently loses the shared layer** (tags show `[project]` not `[shared+project]`). The container bind-mounts the central source at `/workspaces/tagdexer-source`, so the wizard writes `genericPath=/workspaces/tagdexer-source` and verifies the shared layer is active after build.

---

## Troubleshooting (earned the hard way)

| Symptom | Cause / fix |
|---|---|
| `unresolvable CDI devices nvidia.com/gpu=all` | CDI spec version > Podman's ceiling. Regen at ≤ 0.6.0; if the toolkit can't pin, downgrade to `nvidia-container-toolkit=1.16.2-1` and re-run the wizard GPU step. |
| Window: "Could not establish connection" / "install vscode server non-zero" while **plain ssh works** | Almost always `--pid=host` in runArgs → open-remote-ssh false-positives on another container's server. Remove it. Capsule never adds it; if an old repo has it, delete the line and **recreate via Command-Palette → DevPod: Recreate** (CLI `--recreate` caches the old config). |
| Title bar shows the **wrong** `.devpod` host | Cosmetic stale label cache. `sqlite3 ~/.config/VSCodium/User/globalStorage/state.vscdb "DELETE FROM ItemTable WHERE key='memento/cachedResourceLabelFormatters2';"` Trust `hostname` in the container terminal, not the title. |
| `Error port forwarding NNNN: address already in use` | Another process holds the port. Capsule picks a free one; if a clash appears later, find it with `ss -ltnp 'sport = :NNNN'`. |
| Decision-log tags show `[project]` only | `genericPath` not resolving in-container. Check `.tagdexerrc` = `/workspaces/tagdexer-source` and that the mount exists. |
| Editing `.devcontainer/` blocked by the protect hook | `mv .claude/hooks/protect_devcontainer.sh{,.disabled}` → edit → move back. Bash dodges the `Edit\|Write` matcher. |
| `devpod up --recreate` keeps old runArgs | DevPod cached the parsed config. Use Command-Palette **DevPod: Recreate**, or `devpod delete <name> --force && devpod up <name> --ide codium`. |
| Agent/tool: "Couldn't read clipboard contents" on image paste | Host Wayland clipboard not reaching the container. See **Host clipboard passthrough** below. |

---

## Host clipboard passthrough (image paste into in-container tools)

So an agent/tool running **inside** the container can `Ctrl+V` a host screenshot — `image/png`, which OSC 52 can't carry — the wizard bind-mounts the host **runtime directory** (`$XDG_RUNTIME_DIR`) to `/run/host-xdg/` — the whole dir, NOT the single `wayland-0` file, so a logout/login or compositor restart (which makes a fresh socket) doesn't leave the container bound to a dead one — and sets `WAYLAND_DISPLAY` + `DBUS_SESSION_BUS_ADDRESS` (pointing into that dir) in `containerEnv`. `wl-clipboard` is baked into the image. `--security-opt=label=disable` lets the container open the sockets under SELinux (same relaxation used for accel devices). No `--userns` needed — DevPod's podman provider already maps host uid 1000 → container `vscode`, so the socket is owned by `vscode` inside.

**Requirement:** launch the IDE / run the wizard **from the graphical session**, so `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR` exist at container-create time. If they're absent, the wizard **skips** the mounts and warns (no broken bind) — clipboard passthrough is simply disabled until you re-run from a graphical session.

**Verify inside the container** (with an image on the host clipboard):
```bash
wl-paste --list-types        # should include image/png
```
If it prints "failed to connect": check the `wayland-0` mount and that `label=disable` is in runArgs.

---

## How it fits together (architecture)

- **`wizard.sh`** — the host-side installer. Interactive: asks the per-repo questions, derives the rest, scaffolds, builds, verifies.
- **`payload/`** — the canonical source it installs *from*: the generic `.claude` hooks and a pristine task board.
- **`tagdexer/`** — the decision-log + tag-index CLI (mounted into the container, not vendored into generated repos, so new repos always get the current version).

When you improve a generic hook in a live repo, copy it into `payload/claude_hooks/` to canonicalize it. The two `block_*` hooks (`block_pip_install`, `block_git_writes`) are deliberately **excluded** from the generic set. The task board **is** vendored (`payload/taskboard/`) because it is self-contained; refresh it when the task board improves. tagdexer is mounted at build time from the central `tagdexer/` source (overridable via `$CENTRAL_TAGDEXER`).

---

## License

[MIT](LICENSE) © 2026 Oisin McGrath. The bundled tagdexer decision-log CLI is also MIT ([tagdexer/LICENSE](tagdexer/LICENSE)).
