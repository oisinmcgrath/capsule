#!/bin/bash
# @tagdex: devtool, script
# Hook 5: Detect git HEAD or decision log changes between user prompts
# Trigger: UserPromptSubmit
# Behavior: Silent if no change. Inject authoritative alert with retrieval
#           commands if git HEAD or decision log entry count changed.
#           First prompt of a session: if state file exists from a prior
#           session, compare against it (catches inter-session commits).
#           If no state file at all, store baseline silently (very first
#           run ever — agent will be oriented by SessionStart hooks).
#           Sub-agents (stdin payload contains agent_id) exit silently with
#           no state update and no alert — staleness tracking belongs to the
#           main agent only.
INPUT=$(cat)
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi
cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0

# Project-scoped state file — persists across sessions
STATE_FILE="/tmp/claude-staleness-$(echo "${CLAUDE_PROJECT_DIR}" | tr '/' '_')"

# Current values (fast — no tracker.js call)
CUR_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
CUR_COUNT=$(wc -l < tagdexer/decisions.jsonl 2>/dev/null || echo 0)

# Load previous values
if [ -f "$STATE_FILE" ]; then
  PREV_HEAD=$(sed -n '1p' "$STATE_FILE")
  PREV_COUNT=$(sed -n '2p' "$STATE_FILE")
else
  # Very first run ever — store baseline, no injection
  printf '%s\n%s\n' "$CUR_HEAD" "$CUR_COUNT" > "$STATE_FILE"
  exit 0
fi

# Update state file
printf '%s\n%s\n' "$CUR_HEAD" "$CUR_COUNT" > "$STATE_FILE"

# Build alert if anything changed
ALERTS=""
if [ "$CUR_HEAD" != "$PREV_HEAD" ]; then
  ALERTS="${ALERTS}Git HEAD changed (${PREV_HEAD:0:8}..${CUR_HEAD:0:8}). Run: git log ${PREV_HEAD:0:8}..${CUR_HEAD:0:8} --oneline — read fully before proceeding. "
fi
if [ "$CUR_COUNT" != "$PREV_COUNT" ]; then
  OLD_N=$((PREV_COUNT + 1))
  ALERTS="${ALERTS}Decision log changed (${PREV_COUNT} -> ${CUR_COUNT} entries). Run: node tagdexer/tracker.js --search — read entries #${OLD_N} through #${CUR_COUNT} before proceeding. "
fi

if [ -n "$ALERTS" ]; then
  ALERTS=$(echo "$ALERTS" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"STALENESS ALERT: %s"}}\n' "$ALERTS"
fi
exit 0
