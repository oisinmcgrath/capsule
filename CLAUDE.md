<!-- @tagdex: canon, docs, orient -->
**First action: read [tagdexer/AGENT_README.md](tagdexer/AGENT_README.md) in full.** Use tagdex as your primary navigation. (Onboarding + trackdexer protocol are injected by the SessionStart hook.)

# Capsule

A host-side install wizard that scaffolds a new sandboxed **DevPod + Podman + VSCodium** repo, pre-wired for autonomous agent work — tagdexer, decision log, taskboard, and the generic hooks all installed and firing on the first chat. Replaces the old hand-substituted runbook.

## Invariant — read first

**CLAUDE.md is orientation only.** Decisions never go in markdown — `node tagdexer/tracker.js --add` for every architectural choice, finding, dead-end, or handoff. Pending work lives in the taskboard (`node taskboard/taskboard.js --help`). The seeded [tagdexer/decisions.jsonl](tagdexer/decisions.jsonl) already records why this wizard exists and the two failures it hard-guards against — read it before changing wizard behaviour.

## What it is

- **[wizard.sh](wizard.sh)** — the installer. Runs **on the host** (it drives `devpod`/`podman`/`nvidia-ctk`/`ssh`/`sqlite`; it cannot run inside a container). Interactive: asks the per-repo questions, derives the rest, scaffolds, builds, verifies.
- **[payload/](payload/)** — the canonical source it installs *from*: the 9 generic `.claude` hooks and a pristine taskboard. tagdexer is **mounted**, not vendored (see below).
- **[README.md](README.md)** — architecture + runbook + troubleshooting.

## Two things that must never regress

1. **No `--pid=host`.** It makes the container see the host process table; open-remote-ssh then mistakes another container's codium-server for this one's and the VSCodium window fails to attach. The wizard never emits it. (decision #2)
2. **GPU CDI version is auto-pinned, never hardcoded.** Podman 4.9.3 parses CDI spec ≤0.6.0; toolkit ≥1.17 emits newer. The wizard probes, regenerates, and verifies end-to-end. (decision #3)

## tagdexer in a sandbox

The deployed tagdexer CLI reads the central source at runtime for its shared vocabulary/config. Inside the container that source is the bind-mount `/workspaces/tagdexer-source`, so `.tagdexerrc` must use **that in-container path**, not a host path — otherwise the CLI silently degrades. (decision #4)

## Repo principle

Whatever you build here must be intuitive to the owner returning in six months. Keep it legible.
