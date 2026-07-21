<!-- @tagdex: docs, tool, orient, canon -->
**Agents: read `AGENT_README.md` instead. This document is for human users. It may be outdated — read the code to understand tagdexer's function.**

## tagdexer v0.05

Tag-based file and folder discovery, plus append-only architectural decision logging. Portable across repos. Works from CLI (for agents) and VSCodium (for humans).

---

### How it works

Every file can carry tags — short labels like `recorder`, `online`, `active`, `calibration`. Tags are declared in two ways:

1. **Header lines** in source files (Python, JS, Markdown, etc.)
2. **Companion `.tags` files** for things that can't embed comments (JSON, images, folders)

The **indexer** scans the repo, reads all tag declarations, resolves aliases, and writes a single `.tagindex.json` at the repo root. The **extension** reads that index and presents a searchable sidebar in VSCodium.

---

### For agents (CLI usage)

Agents interact with tagdexer via native CLI commands from the repo root. No VSCodium required.

**Search by tags (include and exclude):**
```bash
node tagdexer/indexer.js --search "online,active"
node tagdexer/indexer.js --search "active,-deprecated"
node tagdexer/indexer.js --search "tool,core,-ui"
```

**List all tags with source labels and conflict detection:**
```bash
node tagdexer/indexer.js --list-tags
```

**View or modify tag definitions (reads from both shared and project):**
```bash
node tagdexer/indexer.js --define-tag active
node tagdexer/indexer.js --define-tag newtag --create --description "desc" --add-alias a1 --yes
node tagdexer/indexer.js --define-tag active --description "new desc" --yes
node tagdexer/indexer.js --define-tag active --add-alias newalias --yes
node tagdexer/indexer.js --define-tag active --remove-alias oldalias --yes
node tagdexer/indexer.js --define-tag active --promote deployed --yes
```

**Add tags to a file (unknown tags auto-register in project aliases):**
```bash
node tagdexer/indexer.js --add-tag lib/some_script.py "recorder,active,online"
node tagdexer/indexer.js --add-tag lib/some_script.py "newtag" --generic /path/to/source
```

**Resolve conflicts between shared and project aliases:**
```bash
node tagdexer/indexer.js --merge              # generate or apply merge JSON
node tagdexer/indexer.js --merge-cleanup      # remove merge JSON after resolution
```

**Remove tags from a file:**
```bash
node tagdexer/indexer.js --remove-tag lib/some_script.py "deprecated"
```

**Full reindex:**
```bash
node tagdexer/indexer.js
```

**Incremental reindex (single file):**
```bash
node tagdexer/indexer.js --file lib/some_script.py
```

**Detect orphaned `.tags` entries:**
```bash
node tagdexer/indexer.js --reconcile
```

---

### For humans (VSCodium extension)

**Install:**
```bash
cd tagdexer/extension && npm install && npx tsc -p ./ && npx vsce package --no-dependencies --allow-missing-repository
codium --install-extension tagdexer/extension/tagdexer-0.0.5.vsix
```

**First-time setup — configure source path:**

Open VSCodium Settings and set `tagdexer.sourcePath` to the absolute path of your tagdexer source folder (e.g. `/home/user/repos/my-repo/tagdexer`). This lets the Deploy button copy tagdexer into any repo, and enables canonical alias merging and bug submissions.

**Deploy to a new repo:**

Click the **Deploy** button (cloud icon) in the tagdexer sidebar panel header. This copies the tagdexer folder from your configured source path into the current workspace, and copies the agent onboarding prompt to your clipboard.

**Usage:**
- Click the tag icon in the Activity Bar to open the sidebar
- **Search panel** (top):
  - **Include tags bar**: type tags separated by commas for AND queries. Results must match ALL listed tags.
  - **Exclude tags bar**: type tags to exclude. Results must match NONE of the listed tags.
  - **Filename filter**: substring or glob matching (e.g. `*.py` or `parser`).
  - Press Enter in either tag bar to apply both filters together.
- **Tagged Files panel** (below): tree of files grouped by tag. Click to open, right-click for tag operations.
- **Right-click a file**: Add Tag, Remove Tag, Edit Tags (chip input with autocomplete)
- **Right-click a tag group**: Rename Tag, Add Alias, Edit Description, Delete Tag
- **Right-click in Explorer**: Add Tag, Remove Tag, Edit Tags also available on any file
- **Chip input**: right-click a new tag (dashed border) to define its description and variants before saving. If a variant conflicts with an existing tag, choose to absorb or reverse the merge — no variants are lost either way.
- **Bug/Fix button** (bug icon): submit bugs or fixes to the tagdexer source repo. Requires `tagdexer.sourcePath` to be set.
- **Refresh button** in panel header reindexes and refreshes the view
- **Reset button** clears all filters
- **Deploy button** copies tagdexer to the current repo and copies the onboarding prompt
- **Decisions panel** (bottom): view, filter, and add architectural decision log entries. Filters by tag, date, text, and file. Collapsible entries — click to expand full fields. "Add Decision" form shells out to `tracker.js` for validation and writing.

**Shared/project alias merging:**

When `tagdexer.sourcePath` is configured (or `.tagdexerrc` exists at the repo root with `genericPath=`), the extension loads both the shared `aliases.json` from the source repo and the project `aliases.json` from the workspace. The merged set appears in autocomplete, search, and chip input. New tags default to the project file. In the define/edit modal, a radio button lets you choose "Project" or "Shared" as the write target. Tags with collisions between both files appear orange — click them to open a conflict resolution interface.

**`.tagdexerrc` configuration:**

Generated automatically by Deploy. Lives at the project repo root. Contains `genericPath=` pointing to the shared aliases source. The indexer CLI uses this to find the shared file.

**Conflict resolution (`--merge`):**

Run `node tagdexer/indexer.js --merge` from the repo root. This generates a JSON file listing all string collisions between shared and project. Edit the file to set resolutions, then re-run `--merge` to apply. Run `--merge-cleanup` to remove the file afterwards.

---

### Tagging formats

**Header marker** (for `.py`, `.js`, `.ts`, `.md`, `.sh`, `.html`, `.css`, `.yaml`):

```python
# @tagdex: recorder, online, active
```
```html
<!-- @tagdex: docs, primary, flagged -->
```
```javascript
// @tagdex: tool, core, active
```

Must appear within the first 20 lines. Uses the file's native comment syntax.

**Companion `.tags` file** (for JSON, images, folders, anything without comment syntax):

```
# .tags — one entry per line
# name: tag1, tag2 (file)
# name/: tag1, tag2 (folder — greylisted, contents not scanned)

criteria.json: json, absolute, backup
raw/: data, backup
```

Place `.tags` in any folder to tag items in that folder.

---

### Aliases

`aliases.json` maps canonical tags to search aliases and descriptions. When a file is tagged with `db`, it resolves to the canonical `database`. When an agent searches for `db`, it matches `database`.

Format:
```json
{
  "database": {
    "aliases": ["db", ".db", "sqlite"],
    "description": "Database interaction."
  }
}
```

Tags not in aliases.json are accepted as-is (lowercased). New tags can be added at runtime via the extension's chip input (right-click to define) or by editing aliases.json directly.

---

### Tag design principles

- Tags describe **what the file does**, not what it is. Use lowercase, comma-separated.
- A file can have many tags. The unique combination is the fingerprint.
- Tags fall into categories: **role** (recorder, parser), **status** (active, flagged, deprecated), **risk** (online, core), **content** (data, docs, json), **chain** (chain-feed, chain-record).
- `flagged` = not trusted, owner review required. `deprecated` = confirmed outdated.
- `active` = currently deployed and running. `development` = prototype, not deployed.
- `calibration` = carefully optimised, product of iterative refinement, extremely valuable.
- `axiomatic` = core foundational assumptions the project builds upon.

---

### File tree

```
tagdexer/
  indexer.js              — CLI indexer (reindex, search, add/remove tags, merge)
  tracker.js              — CLI decision log (search, add, validate)
  decisions.schema.json   — Decision entry schema
  decisions.jsonl          — Decision log (per-repo, preserved on update deploy)
  shared/core.js          — Parsing and alias resolution shared by indexer and extension
  aliases.json            — Project-specific tags, aliases, and descriptions
  CHANGELOG.md            — Version history
  LICENSE                 — MIT
  tests/                  — Indexer and feature tests
  extension/
    src/index.ts            — Extension entry point, deploy logic
    src/indexManager.ts     — Loads index, runs indexer, provides query API
    src/treeProvider.ts     — Tag-grouped tree view
    src/searchView.ts       — Persistent search inputs webview
    src/decisionsView.ts    — Decisions panel (view, filter, add entries)
    src/tagEditor.ts        — Atomic tag editing (headers, .tags, aliases.json)
    src/chipInput.ts        — Chip-input UI with classification radio and conflict resolution
    package.json            — Extension manifest
```

### Repo-root files

- `.tagindex.json` — generated index, committed to git
- `.tagdexerignore` — gitignore-syntax file controlling what the indexer skips
- `.tagdexerrc` — configuration file pointing to the shared aliases source (used by both CLI and extension)
- `.tags` — companion files in any folder for tagging

### Requirements

- Node.js >= 22
- ripgrep (`rg`) on PATH
- VSCodium >= 1.85 (for the extension only — CLI works without it)

### Portability

Copy `tagdexer/` into any repo. Run the indexer from that repo's root. Or use the Deploy button in the extension to copy tagdexer and the onboarding prompt in one click.
