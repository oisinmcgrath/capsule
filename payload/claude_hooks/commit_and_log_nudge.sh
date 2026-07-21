#!/bin/bash
# @tagdex: devtool, script
# commit_and_log_nudge — soft reminders to commit work and log decisions.
# Trigger: PostToolUse (any tool). Fires per tool invocation.
# Pattern matches taskboard_nudge.sh: PostToolUse, suppressed when the action
# happened. Detection runs against repo state (git HEAD, decision-log line
# count) rather than only the tool command — so external commits by the owner
# also reset the counter and silence the prompt.
#
# Two independent reminders:
#   - git nudge: silent if HEAD moved since last tool turn; else counter++,
#     fires at COMMIT_INTERVAL non-action tool turns, then resets.
#   - decision-log nudge: silent if tagdexer/decisions.jsonl gained a line;
#     same counter pattern with LOG_INTERVAL.
#
# Skips sub-agents; no-ops outside a git repo (git nudge) or without
# tagdexer/decisions.jsonl (decision-log nudge).

# ── tune these ────────────────────────────────────────────────────────
COMMIT_INTERVAL=1
LOG_INTERVAL=1
# ──────────────────────────────────────────────────────────────────────

INPUT=$(cat)
echo "$INPUT" | grep -q '"agent_id"' && exit 0
cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0

PROJECT_HASH=$(echo "${CLAUDE_PROJECT_DIR}" | tr '/' '_')
GIT_STATE="/tmp/claude-commit-nudge-${PROJECT_HASH}"
LOG_STATE="/tmp/claude-decision-nudge-${PROJECT_HASH}"

REMINDERS=()

CUR_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$CUR_HEAD" ]; then
  if [ -f "$GIT_STATE" ]; then
    PREV_HEAD=$(sed -n '1p' "$GIT_STATE")
    COMMIT_COUNT=$(sed -n '2p' "$GIT_STATE")
    if [ "$CUR_HEAD" != "$PREV_HEAD" ]; then
      COMMIT_COUNT=0
    else
      COMMIT_COUNT=$((COMMIT_COUNT + 1))
    fi
    if [ "$COMMIT_COUNT" -ge "$COMMIT_INTERVAL" ]; then
      REMINDERS+=("Work hasn't been committed recently. Consider a focused git commit so the work survives — the owner encourages active use of committing to git (of your own work) regularly during the work process for traceability and isolation purposes.")
      COMMIT_COUNT=0
    fi
    printf '%s\n%s\n' "$CUR_HEAD" "$COMMIT_COUNT" > "$GIT_STATE"
  else
    printf '%s\n0\n' "$CUR_HEAD" > "$GIT_STATE"
  fi
fi

if [ -f tagdexer/decisions.jsonl ]; then
  CUR_LOG=$(wc -l < tagdexer/decisions.jsonl 2>/dev/null | tr -d ' ')
  if [ -f "$LOG_STATE" ]; then
    PREV_LOG=$(sed -n '1p' "$LOG_STATE")
    LOG_COUNT=$(sed -n '2p' "$LOG_STATE")
    if [ "$CUR_LOG" != "$PREV_LOG" ]; then
      LOG_COUNT=0
    else
      LOG_COUNT=$((LOG_COUNT + 1))
    fi
    if [ "$LOG_COUNT" -ge "$LOG_INTERVAL" ]; then
      REMINDERS+=("A decision hasn't been logged recently. If decisions have been made, use node tagdexer/tracker.js --add regularly to enter an entry.")
      LOG_COUNT=0
    fi
    printf '%s\n%s\n' "$CUR_LOG" "$LOG_COUNT" > "$LOG_STATE"
  else
    printf '%s\n0\n' "$CUR_LOG" > "$LOG_STATE"
  fi
fi

if [ ${#REMINDERS[@]} -eq 0 ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(printf '%s\n\n' "${REMINDERS[@]}")
ESCAPED=$(printf '%s' "$PAYLOAD" | jq -Rs .)
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$ESCAPED"
exit 0
