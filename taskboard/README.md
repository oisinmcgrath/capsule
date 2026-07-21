<!-- @tagdex: canon, docs, orient, tool -->
# taskboard

Persistent pending-work lists that survive a chat session. Alongside git (what
changed) and a decision log (what was decided and why — this repo uses
`tagdexer/tracker.js`), taskboard holds what is still to do.

CLI surface: `node taskboard/taskboard.js --help`.

## Quickstart — drop into a new repo

If your source `taskboard/` is **pre-cleaned** (empty `lists/`, generic
`domains.json` — the recommended NAS-backup shape):

```
cp -r /path/to/clean/taskboard <new-repo>/
bash <new-repo>/taskboard/install.sh
```

If your source carries another repo's lists or domains, add `--reset`:

```
cp -r /path/to/source/taskboard <new-repo>/
bash <new-repo>/taskboard/install.sh --reset
```

`--reset` wipes `lists/*_whiteboard.json`, `lists/*.lock`, and seeds
`domains.json` to `["docs","tooling"]`. Re-run is idempotent either way.

Requires `bash`, `node`, `jq`. Writes only to `<new-repo>/.claude/settings.json`.

### Preparing a clean source (one-time, e.g. on a NAS backup)

```
rm -f taskboard/lists/*_whiteboard.json taskboard/lists/*.lock
printf '["docs","tooling"]\n' > taskboard/domains.json
```

After this, every future drop-in deploy needs only `cp` + `install.sh` with
no flags.

## File shape and naming

A whiteboard is a JSON array of strings at
`taskboard/lists/<domain>_<freename>_whiteboard.json`. Each string is one item,
written self-sufficiently — an agent reading the line knows what's next without
other context.

```json
[
  "Verify the FocusLock patch live on host",
  "Add @reboot dedup guard"
]
```

- Pass the **bare name** `<domain>[_<freename>]` (e.g. `recorder`,
  `recorder_focuslock`). The CLI owns the `_whiteboard.json` suffix.
- Names containing `/`, ending `.json`, or ending `_whiteboard` are rejected.
- `<domain>` groups related lines of work; directory-sort places `<domain>_*`
  adjacent. `<freename>` is optional and specialises within the domain.
- One whiteboard = one line of work. New work that doesn't fit creates a new one.
- Present = pending, absent = done. Last item removed ⇒ file auto-deletes.

## Domains

`domains.json` is a suggested-domains list. Pick from it or invent one — `add`
auto-registers new domains and the owner prunes later. `domains` prints the list.

## Size

`config.json` holds `soft_max_items` (default 12). Crossing it prints a warning
but still adds.

## Locks

First mutating call writes `lists/<name>_whiteboard.json.lock` carrying the
calling agent's parent PID. Same-PID proceeds; foreign PID is refused.

A refused agent drains its non-conflicting work, then flags the conflict to the
owner (whiteboard name + what it was attempting). Do not bypass the lock or
edit JSON directly.

The lock guards only the read-modify-write critical section of a single
mutating command: it is acquired at the start of `add`/`remove` and released at
the end, so a one-shot CLI invocation never leaves a lock behind. As a
crash safety-net, a lock left by a process that is no longer alive is reclaimed
automatically (the common case in a container harness, where every command runs
under a fresh, short-lived shell ppid). A lock held by a *live* foreign ppid
still refuses — that is a genuine concurrent writer — and `unlock --owner`
remains the manual escape hatch. Lock files are gitignored.

## Owner-only verbs

`rename`, `merge`, `split`, `delete`, `unlock` require `--owner`. Convention, not
authentication — runs them only on explicit owner instruction. These bypass the
per-list lock (owner authority).

## Agent contract

- **Add** when pending work surfaces; **remove** when it's done. Real-time, never
  batched at session end.
- Fully autonomous for add/remove. Destructive verbs are owner-only.
- **Pull model:** do not auto-load lists. Read on demand (`list <name>`) when a
  query implicates that line of work.
- After a change, relay the rendered checklist block to the user.
- **Sub-agents do not write.** They return summaries to the parent; the parent
  writes.

## Mid-session onboarding

If an existing agent in this repo isn't aware of taskboard and has pending
in-chat work, see [`MID_SESSION_ONBOARDING.md`](MID_SESSION_ONBOARDING.md)
for a pastable block to drop into their chat. Migrates their pending tasks
to whiteboards before context death.

## Hooks

- `hooks/taskboard_awareness.sh` — SessionStart. Injects CLI location +
  contract once per session (`startup|clear|compact`).
- `hooks/taskboard_nudge.sh` — PostToolUse. TodoWrite-style gentle reminder on
  tool turns; suppressed when the just-fired tool was a `taskboard.js`
  invocation. Accepts duplicate injections within multi-tool turns (TodoWrite
  parity).

Both no-op in any repo without `taskboard/taskboard.js` and skip sub-agents.
Designed to wire at user level (`~/.claude/settings.json`) so they fire across
every repo in the container.

## Deploy reference

```
bash taskboard/install.sh [--reset-domains] [--reset-lists] [--reset] [--help]
```

Idempotent jq-merge into `<repo>/.claude/settings.json`. Safe to re-run. Backs
settings up to `.bak.<epoch>` before any write and restores on
JSON-validation failure. Wires the hooks via relative paths
(`taskboard/hooks/<script>.sh`); no script duplication. Safe to run from host
or container — the repo is bind-mounted so both see the same file.

Flags:

- `--reset-domains` — overwrite `taskboard/domains.json` with the generic seed.
- `--reset-lists` — delete every `taskboard/lists/*_whiteboard.json` and `.lock`.
- `--reset` — both. Use when copying from another repo.
- `--help` — usage.

Without flags, the installer prints soft notes pointing at the resets when it
detects source-tinted state (non-empty `lists/`, `domains.json` over 6 entries).

## Portability

The `taskboard/` folder is self-contained — pure Node stdlib, no npm deps,
paths anchor to the script's own location. Data lives inside the repo
(`lists/`). No cross-repo state. The tool never calls git — list files are
version-controlled by committing them alongside the work.
