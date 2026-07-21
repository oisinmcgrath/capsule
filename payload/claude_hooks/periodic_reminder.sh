#!/bin/bash
# @tagdex: devtool, script
# Periodic reminder injector
# Trigger: UserPromptSubmit
# Behavior: Increments a project-scoped counter on every user prompt. Emits
#           REMINDER context only every N-th prompt (set INTERVAL below).
#           Tweak INTERVAL to tune the cadence; tweak REMINDER to change the
#           message. Silent in between. Sub-agents skipped.

# ── tune these ────────────────────────────────────────────────────────
INTERVAL=5
REMINDER="Output: numbered, lean — drop any word that does not earn its place, verb-led. Under-respond rather than over-respond. No preamble or commentary. Forbidden: pleasantries, acknowledgments, recap, hedging, restatement."
# ──────────────────────────────────────────────────────────────────────

INPUT=$(cat)
# Skip sub-agents — counter and reminder belong to the main agent only
if echo "$INPUT" | grep -q '"agent_id"'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0

STATE_FILE="/tmp/claude-reminder-counter-$(echo "${CLAUDE_PROJECT_DIR}" | tr '/' '_')"

COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

if [ $((COUNT % INTERVAL)) -eq 0 ]; then
  ESCAPED=$(echo "$REMINDER" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$ESCAPED"
fi
exit 0
