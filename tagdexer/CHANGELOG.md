<!-- @tagdex: docs, tool, orient -->
# Changelog

## v0.05

### New features

- **Trackdexer CLI** (`tracker.js`): Append-only architectural decision log for the tagdexer ecosystem.
  - `--help`: Prints full JSON schema and usage reference with examples — designed for agent consumption.
  - `--search`: Stackable filters (`--tag`, `--date`, `--file`, `--text`) with AND logic. `--fields` controls output columns.
  - `--add`: Structured entry creation with auto-incremented IDs, alias resolution via merged shared/project aliases, and schema validation before write.
  - `--validate`: Full JSONL validation against `decisions.schema.json` with per-entry error reporting.
- **Schema** (`decisions.schema.json`): Defines the decision entry format. `intent` is required — every decision must state why it matters.
- Atomic writes (`.tmp.PID` then rename) for all decision log mutations, matching `indexer.js` pattern.
- Tag resolution uses merged shared/project aliases via the same `findGenericPath()` / `.tagdexerrc` pattern as the indexer.
- `tracker.js` and `decisions.schema.json` added to the deploy allowlist.

---

## v0.04

### New features

- **Shared/project classification**: Tags now belong to either the shared aliases file (generic, cross-repo) or the project aliases file (repo-specific). `--add-tag` with an unknown tag auto-registers it in the project file by default; pass `--generic` to write to shared.
- **`--list-tags` overlap flagging**: After listing tags, scans both files and flags any string appearing in both with a conflict summary.
- **`--define-tag` merged reads**: Show mode displays tags from both shared and project files, indicating source.
- **`--merge` command**: Two-phase conflict resolution. Phase 1 generates a JSON file listing all string collisions. Phase 2 applies edits after the user sets resolution for each conflict. `--merge-cleanup` removes the merge file.
- **Extension chip UI classification**: New tags default to project. Right-click a chip to open the define/edit view with a Project/Shared radio button.
- **Orange conflict chips**: Tags with collisions between shared and project files appear orange. Clicking opens a conflict resolution interface.
- **Deploy generates `.tagdexerrc`**: On fresh deploy, generates a `.tagdexerrc` at the project repo root with `genericPath=` pointing to the configured source path.
- **Deploy copies `CHANGELOG.md`**: Added to the deploy allowlist.

### Terminology changes

- `--canonical` CLI flag renamed to `--generic` (backward compatible).
- `.tagdexerrc` key `canonicalPath` renamed to `genericPath` (backward compatible).
- User-facing text uses "shared" and "project" instead of "canonical" and "local".
- Internal code retains "canonical" for the tag-name-vs-alias distinction.

### Fixes

- `--add-tag` now detects collisions with existing names/aliases across both files before writing.

---

## v0.03

### New features

- **CLI search** (`--search`): AND queries with comma-separated tags, exclude with `-` prefix.
- **CLI tag management**: `--define-tag` for viewing and modifying tag definitions, including `--create`, `--description`, `--add-alias`, `--remove-alias`, `--promote`.
- **Exclude filter**: Extension sidebar and CLI support excluding tags from results.
- **Canonical alias merge**: Extension loads aliases from both `tagdexer.sourcePath` and local `tagdexer/aliases.json`.
- **Chip input UI**: Tag editing with autocomplete, right-click to define description and variants, conflict detection for aliases.
- **Bug/fix submission**: Extension command to submit bugs to the tagdexer source repo.
- **Deploy preserves aliases**: Update deploys no longer overwrite `aliases.json`.
- **Alias resolution feedback**: `--add-tag` and `--remove-tag` inform when resolving aliases.

### Architecture

- `shared/core.js` — parsing and alias resolution shared between indexer and extension.
- Extension TypeScript source with full sidebar: search view, tree view, chip input, tag editor.
- Atomic writes for all file mutations.
- ripgrep-based file listing with `.tagdexerignore` support.
- `.tags` companion files for tagging non-commentable file types.
