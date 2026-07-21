#!/bin/bash
# @tagdex: ancillary, script
# taskboard installer — wires per-repo hooks that orient agents to the CLI on
# session start (awareness) and prod gently on tool turns without a taskboard
# call (nudge). Idempotent. Run once per repo. Safe on host or in container —
# writes only to <repo>/.claude/settings.json and never to $HOME.
#
# Hook scripts stay in taskboard/hooks/; .claude/settings.json references them
# via relative path, the same way this repo's existing hooks wire .claude/hooks.
#
# Required: bash, jq. No sudo. No npm install.

set -euo pipefail

RESET_DOMAINS=false
RESET_LISTS=false

usage() {
  cat <<'USAGE'
Usage: bash taskboard/install.sh [flags]

Flags:
  --reset-domains   Overwrite taskboard/domains.json with a generic seed
                    (["docs","tooling"]). Use when copying taskboard/ from
                    another repo whose domain choices don't fit this one.
  --reset-lists     Delete every taskboard/lists/*_whiteboard.json and *.lock.
                    Use when copying taskboard/ from another repo to drop the
                    source's pending work.
  --reset           Both of the above. Generic drop-in deploy.
  -h, --help        Show this.

What it does:
  1. Optional: reset domains/lists per flags.
  2. Ensure exec bit on taskboard/hooks/*.sh.
  3. Create <repo>/.claude/ if missing.
  4. Backup <repo>/.claude/settings.json to .bak.<epoch> if present.
  5. jq-merge SessionStart awareness + PostToolUse nudge entries idempotently.
  6. Atomic write, restore on validation failure.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-domains) RESET_DOMAINS=true; shift ;;
    --reset-lists)   RESET_LISTS=true; shift ;;
    --reset)         RESET_DOMAINS=true; RESET_LISTS=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'install: unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_ROOT=$(dirname "$SCRIPT_DIR")
AWARENESS_REL="taskboard/hooks/taskboard_awareness.sh"
NUDGE_REL="taskboard/hooks/taskboard_nudge.sh"
AWARENESS_ABS="${REPO_ROOT}/${AWARENESS_REL}"
NUDGE_ABS="${REPO_ROOT}/${NUDGE_REL}"
DOMAINS_FILE="${SCRIPT_DIR}/domains.json"
LISTS_DIR="${SCRIPT_DIR}/lists"
CLAUDE_DIR="${REPO_ROOT}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
say() { printf 'install: %s\n' "$*"; }

[ -f "$AWARENESS_ABS" ] || die "missing $AWARENESS_REL — run from a real taskboard/ checkout"
[ -f "$NUDGE_ABS" ]     || die "missing $NUDGE_REL"
command -v jq >/dev/null 2>&1 || die "jq is required. Install: 'sudo apt-get install -y jq' (Debian/Ubuntu) or your package manager equivalent."

if [ "$RESET_DOMAINS" = true ]; then
  printf '["docs","tooling"]\n' > "$DOMAINS_FILE"
  say "reset ${DOMAINS_FILE} → generic seed"
fi

if [ "$RESET_LISTS" = true ] && [ -d "$LISTS_DIR" ]; then
  find "$LISTS_DIR" -mindepth 1 -maxdepth 1 \( -name '*_whiteboard.json' -o -name '*.lock' \) -delete 2>/dev/null || true
  say "reset ${LISTS_DIR}/ → empty"
fi

WB_COUNT=$(find "$LISTS_DIR" -maxdepth 1 -name '*_whiteboard.json' 2>/dev/null | wc -l | tr -d ' ')
DOM_COUNT=$(jq 'length' "$DOMAINS_FILE" 2>/dev/null || echo 0)
if [ "$WB_COUNT" -gt 0 ] && [ "$RESET_LISTS" != true ]; then
  say "note: ${WB_COUNT} whiteboard(s) present — pass --reset-lists if these are foreign to this repo"
fi
if [ "$DOM_COUNT" -gt 6 ] && [ "$RESET_DOMAINS" != true ]; then
  say "note: domains.json has ${DOM_COUNT} entries — pass --reset-domains for a generic seed"
fi

chmod +x "$AWARENESS_ABS" "$NUDGE_ABS"
say "ensured exec bit on hook scripts"

mkdir -p "$CLAUDE_DIR"
say "ensured ${CLAUDE_DIR}/"

BACKUP=""
if [ -f "$SETTINGS" ]; then
  BACKUP="${SETTINGS}.bak.$(date +%s)"
  cp -p "$SETTINGS" "$BACKUP"
  say "backed up settings.json → ${BACKUP}"
  CURRENT=$(cat "$SETTINGS")
else
  CURRENT='{}'
  say "no existing settings.json — will create"
fi

MERGED=$(printf '%s' "$CURRENT" | jq \
  --arg aw "$AWARENESS_REL" \
  --arg nu "$NUDGE_REL" \
'
  def has_cmd($cmd):
    [.[]? | (.hooks // []) | .[]? | .command] | any(. == $cmd);
  def add_session_start($cmd):
    if (.hooks.SessionStart // [] | has_cmd($cmd)) then .
    else .hooks.SessionStart = ((.hooks.SessionStart // []) +
      [{matcher: "startup|clear|compact",
        hooks: [{type: "command", command: $cmd}]}])
    end;
  def add_post_tool_use($cmd):
    if (.hooks.PostToolUse // [] | has_cmd($cmd)) then .
    else .hooks.PostToolUse = ((.hooks.PostToolUse // []) +
      [{hooks: [{type: "command", command: $cmd}]}])
    end;
  add_session_start($aw) | add_post_tool_use($nu)
') || { [ -n "$BACKUP" ] && cp -p "$BACKUP" "$SETTINGS"; die "jq merge failed; settings.json restored from backup"; }

printf '%s' "$MERGED" | jq -e . >/dev/null 2>&1 || {
  [ -n "$BACKUP" ] && cp -p "$BACKUP" "$SETTINGS"
  die "merged settings.json failed validation; restored from backup"
}

TMP=$(mktemp "${SETTINGS}.tmp.XXXXXX")
printf '%s\n' "$MERGED" > "$TMP"
mv "$TMP" "$SETTINGS"
say "wrote ${SETTINGS}"

say "done."
say ""
say "VERIFY: open a new chat in this repo."
say "        SessionStart context should contain: \"taskboard is active in this repo\"."
say "        Tool turns without a taskboard.js invocation should append:"
say "        \"The taskboard tool hasn't been used recently…\""
