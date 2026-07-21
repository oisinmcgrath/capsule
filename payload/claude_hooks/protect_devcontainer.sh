#!/bin/bash
# @tagdex: devtool, script
# Hook 8: Protect .devcontainer/ from unconfirmed edits
# Trigger: PreToolUse on Edit|Write (matching done in-script)
# Behavior: Deny edits to .devcontainer/. Agent surfaces block to owner.
# Note: Uses "deny" instead of "ask" due to VS Code extension bug
#       (GitHub #13339) — "ask" silently ignored in extension mode.
INPUT=$(cat)
FPATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FPATH" ] && exit 0

if echo "$FPATH" | grep -q '\.devcontainer/'; then
  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Modification of .devcontainer/ requires explicit owner approval. Surface this block to the owner with the file path and the intended change. Wait for explicit authorization before retrying."}}
EOF
fi
exit 0