#!/bin/bash
# @tagdex: devtool, script, tool
# taskboard non-use nudge — soft reminder modelled on TodoWrite's pattern.
# Trigger: PostToolUse (any tool). Fires per tool invocation.
# Suppresses when the just-fired tool was a taskboard CLI call; accepts
# duplicate injections within multi-tool turns — TodoWrite does the same.
# Skips sub-agents; no-ops in any repo without taskboard/taskboard.js;
# no-ops if jq is unavailable (degraded-silent, not degraded-noisy).

INPUT=$(cat)
echo "$INPUT" | grep -q '"agent_id"' && exit 0
cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null || exit 0
[ -f taskboard/taskboard.js ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
if [ "$TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
  case "$CMD" in
    *taskboard.js*|*taskboard/taskboard.js*) exit 0 ;;
  esac
fi

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"The taskboard tool hasn't been used recently. If you're working on tasks that would benefit from persistent pending-work tracking that survives chat death, consider using it (node taskboard/taskboard.js). Also consider removing items that no longer reflect pending work. Only use it if it's relevant to the current work. This is just a gentle reminder — ignore if not applicable."}}
JSON
exit 0
