#!/bin/bash
# @tagdex: devtool, script
# Hook 1: Detect container vs host context
# Trigger: SessionStart (always inject)
# Behavior: Inject environment name and workspace path
cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null
if test -f /run/.containerenv; then
  CTX="container"
else
  CTX="host"
fi
WS=$(pwd)
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Environment: %s. Workspace: %s."}}\n' "$CTX" "$WS"
exit 0