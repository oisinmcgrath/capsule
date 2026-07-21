#!/bin/bash
# @tagdex: devtool, script, tool
# taskboard SessionStart awareness — inject the CLI location + pull-model contract.
# Trigger: SessionStart (matcher: startup|clear|compact). Skips sub-agents
#          (stdin payload carries "agent_id" — they inherit the parent's context).
# No-ops in any repo without taskboard/taskboard.js, so it is safe to wire at the
# user level (~/.claude/settings.json) and have it fire across every repo.
# Injects awareness ONLY — never list inventory or contents (pull model, intent 10).
INPUT=$(cat)
echo "$INPUT" | grep -q '"agent_id"' && exit 0
cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0
[ -f taskboard/taskboard.js ] || exit 0
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"taskboard is active in this repo — persistent pending-work lists that survive chat death (the third artefact alongside git and the decision log). CLI: node taskboard/taskboard.js (run --help for the full verb surface). PULL MODEL — do not auto-load any list; read one on demand with 'list <name>' only when a user query implicates that line of work. Add an item the moment pending work surfaces and remove it when the work is done, in real time — never batch at session end (that is the failure mode this tool exists to prevent). You are fully autonomous for add/remove, no approval needed. Destructive verbs (rename, merge, split, delete, unlock) are owner-only via --owner — run them only on explicit owner instruction. One list per distinct line of work; the bare name <domain>[_<freename>] maps to lists/<name>_whiteboard.json; pick a domain via 'domains' or invent one (it auto-registers). Only one agent writes a given list at a time (ppid lock); if a write is refused, drain your non-conflicting work first, then escalate to the owner. After any add or remove, relay the rendered checklist block to the user. Sub-agents never write — they return summaries to you, the parent, and you do the writing."}}
JSON
exit 0
