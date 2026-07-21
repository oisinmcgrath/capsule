<!-- @tagdex: docs, orient, tool -->
# Mid-session onboarding

Use when an existing agent — mid-chat, low context, with pending in-chat work
— needs to start using taskboard before their session dies and the work is lost.

Paste the block below into that agent's chat. The verbatim-quote gate forces
them to actually read the contract rather than skim and bluff.

---

```
taskboard is installed in this repo. Run: node taskboard/taskboard.js --help
Then read: cat taskboard/README.md (focus on the "Agent contract" section).

Before doing anything else, answer this gate: per the agent contract, what
is the rule about sub-agents writing to whiteboards? Quote the rule verbatim.

Once you've answered, add every pending task from this chat to a whiteboard
via: node taskboard/taskboard.js add <name> "<item>"

Pick a domain via: node taskboard/taskboard.js domains
Invent a new one if nothing fits — `add` auto-registers.

Context budget is low — do this first, before any further work.
```

---

Expected gate answer (verbatim from `README.md`):

> Sub-agents do not write. They return summaries to the parent; the parent
> writes.
