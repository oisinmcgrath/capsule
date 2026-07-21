#!/bin/bash
# @tagdex: devtool, script
# Sub-agent usage reminder injector
# Trigger: UserPromptSubmit
# Behavior: Increments a project-scoped counter on every user prompt. Emits
#           a REMINDER every INTERVAL-th prompt, offset by OFFSET so this hook
#           interleaves with periodic_reminder.sh (fires at 5,10,15...).
#           This hook fires at 3,8,13,18... Reminder is randomly drawn from a
#           pool of variants on each fire to resist banner-blindness.
#           ~40% are leading (explicit owner preference), ~60% are neutral
#           rhetorical nudges.

# ── tune these ────────────────────────────────────────────────────────
INTERVAL=5
OFFSET=3

# Leading variants — explicit owner preference (6 of 14, ~43%)
LEADING=(
  "the owner wants you to use sub-agents wherever you can"
  "owner preference: reach for sub-agents wherever they apply"
  "the owner's standing instruction: delegate to sub-agents wherever fitting"
  "owner expects sub-agents used wherever they fit"
  "the owner wants context preserved — delegate to sub-agents wherever you can"
  "standing rule from the owner: lean on sub-agents wherever they belong"
)
# Neutral variants — rhetorical / probing (8 of 14, ~57%)
NEUTRAL=(
  "could a sub-agent be doing any of this?"
  "spotting any work a sub-agent could own?"
  "where could sub-agents be carrying weight?"
  "sub-agents available — using them where they fit?"
  "anything here ripe for delegation?"
  "any branch of this a sub-agent could run?"
  "which steps could a sub-agent be running now?"
  "parallel work going unparallelised?"
)
REMINDERS=("${LEADING[@]}" "${NEUTRAL[@]}")
# ──────────────────────────────────────────────────────────────────────

INPUT=$(cat)
# Skip sub-agents — counter and reminder belong to the main agent only
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0

STATE_FILE="/tmp/claude-subagent-reminder-counter-$(echo "${CLAUDE_PROJECT_DIR}" | tr '/' '_')"

COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

if [ $((COUNT % INTERVAL)) -eq $OFFSET ]; then
  REMINDER="${REMINDERS[RANDOM % ${#REMINDERS[@]}]}"
  ESCAPED=$(echo "$REMINDER" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$ESCAPED"
fi
exit 0
