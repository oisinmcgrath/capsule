#!/bin/bash
# @tagdex: devtool, script
# Hook 4: Mandatory onboarding — tagdexer and decision log orientation
# Trigger: SessionStart (matcher: startup|clear|compact, skip resume)
# Behavior: Always inject when fired on main agent. Skip silently for sub-agents
#           (stdin payload contains agent_id) — sub-agents inherit context from
#           their parent and do not need their own onboarding mandate.
INPUT=$(cat)
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi
cat <<'MANDATE'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"MANDATORY SESSION ONBOARDING — execute these commands immediately, in order, before responding to the user:\n1. node tagdexer/indexer.js --list-tags — prime your tag vocabulary. Do not truncate output.\n2. node tagdexer/indexer.js --help — learn the full indexer reference.\n3. node tagdexer/tracker.js --help — learn the decision log schema, heuristics, and syntax.\n4. node tagdexer/tracker.js --search --fields id,date,decision,intent — read the slim decision log (decision + intent only). Do not truncate output. If the output is persisted to a file, read the full persisted file with the Read tool, in sections if necessary. Do not proceed until every line has been read. For deeper context on any entry (context, alternatives_rejected, files, commits, consequence), run node tagdexer/tracker.js --search --text <keyword> or filter by --tag / --date on demand.\n\nTrackdexer is an active process — you log as you work, not after. When you discover a cause, try an approach, hit a dead end, or make a choice, propose a trackdexer entry to the owner at that point. Do not accumulate findings and log them later."}}
MANDATE
exit 0
