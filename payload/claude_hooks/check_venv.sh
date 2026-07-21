#!/bin/bash
# @tagdex: devtool, script
# Hook 3: Verify .venv health
# Trigger: SessionStart
# Behavior: Silent on success, inject warning with context-appropriate rebuild instructions
VENV="${CLAUDE_PROJECT_DIR}/.venv"
if [ ! -f "${VENV}/bin/python3" ]; then
  if test -f /run/.containerenv; then
    FIX="Rebuild the container, or run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
  else
    FIX="Run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"WARNING — .venv/bin/python3 not found. Python scripts will fail. %s"}}\n' "$FIX"
fi
exit 0