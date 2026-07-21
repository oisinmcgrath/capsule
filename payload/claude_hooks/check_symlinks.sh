#!/bin/bash
# @tagdex: devtool, script
# Hook 2: Verify critical symlinks resolve
# Trigger: SessionStart
# Behavior: Silent on success, inject warning on failure
WARNINGS=""
for LINK in /workspaces/fbad-scraper /workspaces/tagdexer-source /workspaces/setsquare-source; do
  if [ ! -d "$LINK" ]; then
    WARNINGS="${WARNINGS}Broken or missing: ${LINK}. "
  fi
done
if [ -n "$WARNINGS" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"WARNING — symlink check failed: %s Some tools may not work. Report to user."}}\n' "$WARNINGS"
fi
exit 0