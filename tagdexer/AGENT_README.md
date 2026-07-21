<!-- @tagdex: docs, tool, orient, canon -->
# tagdexer — Agent Quick Start

**Run all three of these now. Do not respond to the user until you have completed them.**

```bash
node tagdexer/indexer.js --list-tags
node tagdexer/indexer.js --help
node tagdexer/tracker.js --help
```

These apply to every repo — fresh or mature. Do not skip them. Do not summarise what you read. Do not respond until all three have run.

---

## Trackdexer — when to record

The tracker exists to preserve context that would otherwise be lost between sessions. Work gets interrupted. People forget. A new engineer picks up where you left off with no idea what was tried, what failed, or what the next step was. The tracker is the bridge.

**Record when any of these are true:**

- You made an architectural choice — technology selection, structural convention, rejected alternative.
- You investigated a problem and found a cause, even if you haven't fixed it yet.
- You tried an approach and it failed — what you tried, why it broke, what you'd try next.
- Work is being interrupted or deferred — capture where you stopped, what's unfinished, what the next step would be.
- You discovered a constraint or dependency that isn't obvious from the code.
- You went down a chain of dependencies trying to fix something and the trail matters.

The common thread: **if you walked away right now, would the next person have to rediscover what you already know?** If yes, log it.

**Do not record:** routine refactors, dependency updates, config tweaks, or anything that is self-evident from the code or git history. If the commit message is sufficient explanation, no entry is needed.

**Logging is an active process — you log as you work, not after.** When you discover a cause, try an approach, hit a dead end, or make a choice, propose an entry at that point. Do not accumulate findings and log them retrospectively. Don't wait for a clean resolution. Interrupted work never resolves — that's exactly when context is lost.

### Adding an entry

Run `node tagdexer/tracker.js --help` for the full schema, required fields, heuristics, and examples. Then try adding an entry — the CLI will guide you.

Always propose the entry to the owner before writing. The owner may adjust fields or decide the entry is not worth recording.

---

## Universal rules

- **Every commit goes through the owner.** Suggest files to stage and propose commit messages only. Never commit directly. Never include "Co-Authored-By: Claude" or any model signature.
- **Tag as you create.** Every new file gets tags proposed to the owner using only canonical tags from `aliases.json`. If no tag fits, propose a new one.
- **Search before guessing paths.** Use the tag system to find files by concept.

---

## Integrating tagdexer into an existing repo

1. Ensure `tagdexer/` folder is in the repo root (copy it if not).
2. Create `.tagdexerignore` at repo root with sensible defaults for the project.
3. Begin the iterative tagging dialogue with the owner:

**Tagging dialogue — one file at a time:**

   a. Pick one significant file. Ask the owner: "What are the 5 most relevant tags for this file in your head?"

   b. Number each tag the owner gives. Present them back numbered and ask for definitions:
   ```
   Definitions?
   1. x
   2. y
   3. z
   ```
   The owner responds with definitions by number.

   c. Clean the definitions — keep them short, general, neutral English. Present them back numbered for approval:
   ```
   1. x — [improved definition]
   2. y — [improved definition]
   ```
   Iterate until the owner approves.

   d. Then ask for variants, numbered:
   ```
   Variants?
   1. x — any other words for this?
   2. y — any other words for this?
   ```
   Once both definitions and variants are established for overlapping tags, flag potential redundancies in brackets. If the owner acknowledges the redundancy, merge. If the owner doesn't comment on it, keep them separate.

   e. **Apply immediately via CLI.** After each file's tags are approved:
   ```bash
   node tagdexer/indexer.js --add-tag <file> "tag1,tag2,tag3"
   ```
   Do not accumulate tags in conversation without applying them. Use the tool.

   f. Move to the next file. Patterns emerge — the same tags recur. As the vocabulary grows, you will start to see inferences. Hold them until the owner invites you to suggest patterns of your own.

   g. When the owner uses a different word for the same concept, ask: "Is this the same as [previous tag], or different?" Merge as variants of one canonical form if same.

   h. When the owner says none of the existing tags fit, try different angles — ask what the file reminds them of, what group it belongs to in their head, what they'd search for to find it.

   i. After 10-15 files, the core vocabulary stabilises. Bulk-tag remaining files using established patterns via the CLI.

   j. Write all canonical tags, aliases, and descriptions to `tagdexer/aliases.json` via the CLI:
   ```bash
   node tagdexer/indexer.js --define-tag <tag> --create --description "desc" --add-alias a1 --yes
   ```

   k. Run `node tagdexer/indexer.js` to produce `.tagindex.json`.
