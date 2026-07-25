#!/bin/bash
# @tagdex: anchor, core, devtool, script
# ============================================================================
# capsule — interactive installer for a new sandboxed
# DevPod + Podman + VSCodium repo, pre-wired for autonomous agent work
# (tagdexer + decision log + taskboard + the generic hooks).
#
# RUN ON THE HOST (Linux). It drives devpod / podman / nvidia-ctk / ssh
# / sqlite, none of which exist inside a container. It cannot run from inside
# a devcontainer.
#
# Usage: bash wizard.sh [--no-gui]
#   With a display + kdialog/zenity present, questions appear as GUI dialogs
#   (folder picker instead of typing the repo name). --no-gui forces the
#   classic terminal prompts. Progress always prints to the terminal.
#
# What it does, end to end:
#   1. Asks the per-repo questions (target repo, GPU?, extra apt, display name).
#   2. Derives everything else deterministically (sanitized name, project keys,
#      a non-clashing forward port).
#   3. Scaffolds <repo>/.devcontainer + <repo>/.claude (the 9 generic hooks)
#      + tagdexer (mounted, .tagdexerrc -> in-container path) + a FRESH taskboard.
#   4. If GPU: ensures the CDI spec is at a version this Podman can parse
#      (auto-pins; never hardcodes 0.5.0).
#   5. Creates the host /workspaces symlinks.
#   6. Builds the container (CLI, never the extension UI) and verifies isolation.
#
# Safe on EXISTING repos: preserves CLAUDE.md, decisions.jsonl, aliases.json,
# taskboard lists/domains, and .git; backs up a prior .claude/settings.json to
# settings.json.pre-wizard; offers to move a host-built .venv aside. Replaces
# .devcontainer/, the generic hooks, taskboard code, and .tagdexerrc.
#
# Requires (host): bash, jq, devpod, podman, ssh, sqlite3; nvidia-ctk only if GPU.
# ============================================================================
set -euo pipefail

WIZ_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PAYLOAD="$WIZ_DIR/payload"
# Portable: default to this wizard's parent dir (the sibling-repos root), so a
# clone under any path works with zero edits. Override any of these via env if
# your layout differs. tagdexer/ and setsquare/ must be siblings of the wizard.
REPOS_ROOT="${REPOS_ROOT:-$(dirname "$WIZ_DIR")}"
# tagdexer/setsquare source resolution. Priority: an explicit $CENTRAL_* env var
# wins; else the machine profile's saved path (asked on first run, below); else a
# sibling checkout; else — for tagdexer — the copy vendored inside this repo, so a
# standalone clone is self-contained. Capture the env override now; the profile
# refines these after preflight.
CENTRAL_TAGDEXER_ENV="${CENTRAL_TAGDEXER:-}"
CENTRAL_SETSQUARE_ENV="${CENTRAL_SETSQUARE:-}"
if   [ -n "$CENTRAL_TAGDEXER_ENV" ]; then :
elif [ -d "$REPOS_ROOT/tagdexer" ]; then CENTRAL_TAGDEXER="$REPOS_ROOT/tagdexer"
else CENTRAL_TAGDEXER="$WIZ_DIR/tagdexer"; fi
# setsquare is an OPTIONAL external sibling; its mount/symlink are skipped when absent.
CENTRAL_SETSQUARE="${CENTRAL_SETSQUARE:-$REPOS_ROOT/setsquare}"
HOST_CLAUDE_PROJECTS="${HOST_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

c_bold=$'\e[1m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_off"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_ylw" "$c_off" "$*"; }

# ---------------------------------------------------------------------------
# GUI mode — questions become dialogs (folder picker, input boxes, yes/no);
# progress output still prints to the terminal. Auto-enabled when a display
# and a dialog tool are present; pass --no-gui for the classic terminal
# prompts. kdialog (KDE-native, Dolphin-style picker) is preferred; zenity is
# the fallback. Cancel on any dialog aborts the wizard.
# ---------------------------------------------------------------------------
WIZ_TITLE="capsule"
GUI_TOOL=""
if [ "${1:-}" != "--no-gui" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if   command -v kdialog >/dev/null 2>&1; then GUI_TOOL=kdialog
  elif command -v zenity  >/dev/null 2>&1; then GUI_TOOL=zenity; fi
fi

gui_error() {
  case "$GUI_TOOL" in
    kdialog) kdialog --title "$WIZ_TITLE" --error "$1" >/dev/null 2>&1 ;;
    zenity)  zenity --title "$WIZ_TITLE" --error --text="$1" >/dev/null 2>&1 ;;
  esac
}
gui_input() {  # $1 prompt, $2 default -> stdout; nonzero on cancel
  case "$GUI_TOOL" in
    kdialog) kdialog --title "$WIZ_TITLE" --inputbox "$1" "$2" 2>/dev/null ;;
    zenity)  zenity --title "$WIZ_TITLE" --entry --text="$1" --entry-text="$2" 2>/dev/null ;;
  esac
}
gui_yesno() {  # $1 prompt -> exit status
  case "$GUI_TOOL" in
    kdialog) kdialog --title "$WIZ_TITLE" --yesno "$1" 2>/dev/null ;;
    zenity)  zenity --title "$WIZ_TITLE" --question --text="$1" 2>/dev/null ;;
  esac
}
gui_pickdir() {  # $1 start dir -> stdout; nonzero on cancel
  case "$GUI_TOOL" in
    kdialog) kdialog --title "Select the repo folder to set up" --getexistingdirectory "$1" 2>/dev/null ;;
    zenity)  zenity --title "Select the repo folder to set up" --file-selection --directory --filename="$1/" 2>/dev/null ;;
  esac
}

die()  { printf '%swizard: %s%s\n' "$c_red" "$*" "$c_off" >&2; [ -n "$GUI_TOOL" ] && gui_error "$*"; exit 1; }
ask()  { local p="$1" d="${2:-}" r
  if [ -n "$GUI_TOOL" ]; then
    r="$(gui_input "$p" "$d")" || die "aborted (dialog cancelled)."
    echo "${r:-$d}"
  elif [ -n "$d" ]; then read -rp "  $p [$d]: " r; echo "${r:-$d}"
  else read -rp "  $p: " r; echo "$r"; fi; }
ask_yn(){ local p="$1" d="${2:-n}" r
  if [ -n "$GUI_TOOL" ]; then gui_yesno "$p"; return $?; fi
  read -rp "  $p ($([ "$d" = y ] && echo 'Y/n' || echo 'y/N')): " r; r="${r:-$d}"; [[ "$r" =~ ^[Yy] ]]; }

# GUI sudo: in dialog mode the user is looking at dialogs, so a terminal
# "[sudo] password:" prompt is invisible and the wizard looks hung. Route sudo
# through an askpass dialog (kdialog/zenity --password) so the password box pops
# up in the same GUI flow, focused like every other question. Terminal mode
# keeps ordinary sudo. Use "${SUDO[@]}" everywhere instead of a bare `sudo`.
SUDO=(sudo)
if [ -n "$GUI_TOOL" ]; then
  ASKPASS="$(mktemp --suffix=-csw-askpass)"
  cat > "$ASKPASS" <<ASK
#!/bin/bash
exec $GUI_TOOL $([ "$GUI_TOOL" = kdialog ] && echo '--title "'"$WIZ_TITLE"'" --password "sudo password (to create the host /workspaces symlinks)"' || echo '--title "'"$WIZ_TITLE"'" --password')
ASK
  chmod +x "$ASKPASS"
  export SUDO_ASKPASS="$ASKPASS"
  SUDO=(sudo -A)
  trap 'rm -f "$ASKPASS"' EXIT
fi

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
step "Preflight"
[ -d "$PAYLOAD" ] || die "payload/ not found next to wizard.sh — run from the wizard repo."
# devpod is intentionally NOT here — the machine profile can install it (below).
for t in jq podman ssh sqlite3; do command -v "$t" >/dev/null 2>&1 || die "missing required host tool: $t"; done
[ -d "$CENTRAL_TAGDEXER" ] || warn "tagdexer source not found at $CENTRAL_TAGDEXER — deploy will be unavailable (fine if you choose not to deploy it)."
[ -d "$CENTRAL_TAGDEXER" ] && [ ! -f "$CENTRAL_TAGDEXER/trackdexer.config.json" ] && warn "tagdexer missing trackdexer.config.json — shared config layer will be unavailable."
ok "host tools present"

# ---------------------------------------------------------------------------
# 0b. Machine profile — settings that belong to THIS host + owner, not to any
# one repo (container timezone; the git identity stamped on scaffolded repos).
# Asked once on the first run, saved under $XDG_CONFIG_HOME, then reused
# silently for every future repo. Edit or delete the file to change them; a
# newly added key re-prompts for only that key. This is what keeps the wizard
# portable — no host-specific value is baked into the script.
# ---------------------------------------------------------------------------
step "Machine profile"
MACHINE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/capsule/machine.conf"
MACHINE_TZ=""; MACHINE_GIT_NAME=""; MACHINE_GIT_EMAIL=""; TAGDEXER_MODE=""
MACHINE_TAGDEXER_PATH=""; MACHINE_SETSQUARE_PATH=""; MACHINE_DEVPOD_BIN=""
# shellcheck source=/dev/null
[ -f "$MACHINE_CONF" ] && . "$MACHINE_CONF"

_conf_new=0
if [ -z "${MACHINE_TZ:-}" ]; then
  _d="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
  MACHINE_TZ="$(ask "Container timezone (IANA name, e.g. Europe/Dublin)" "${_d:-UTC}")"
  _conf_new=1
fi
if [ -z "${MACHINE_GIT_NAME:-}" ]; then
  _d="$(git config --global user.name 2>/dev/null || true)"
  MACHINE_GIT_NAME="$(ask "Git author name to stamp on scaffolded repos" "${_d:-owner}")"
  _conf_new=1
fi
if [ -z "${MACHINE_GIT_EMAIL:-}" ]; then
  _d="$(git config --global user.email 2>/dev/null || true)"
  MACHINE_GIT_EMAIL="$(ask "Git author email to stamp on scaffolded repos" "${_d:-owner@local}")"
  _conf_new=1
fi
if [ -z "${TAGDEXER_MODE:-}" ]; then
  # Default policy for deploying the tagdexer decision-log into each repo:
  #   always = deploy every run · never = never deploy · ask = prompt per run.
  _d="$(ask "Deploy the tagdexer decision-log into repos? (always/never/ask)" "always")"
  case "$(printf '%s' "$_d" | tr '[:upper:]' '[:lower:]')" in
    never|no|n) TAGDEXER_MODE=never ;;
    ask)        TAGDEXER_MODE=ask ;;
    *)          TAGDEXER_MODE=always ;;
  esac
  _conf_new=1
fi
if [ -z "${MACHINE_TAGDEXER_PATH:-}" ]; then
  if [ "$TAGDEXER_MODE" = never ]; then
    MACHINE_TAGDEXER_PATH="$WIZ_DIR/tagdexer"       # unused while 'never', but records a value
  else
    _guess=""
    [ -d "$REPOS_ROOT/tagdexer" ] && _guess="$REPOS_ROOT/tagdexer"
    [ -z "$_guess" ] && [ -d "$WIZ_DIR/tagdexer" ] && _guess="$WIZ_DIR/tagdexer"
    if ask_yn "Do you already have tagdexer installed on this host?" "$([ -n "$_guess" ] && echo y || echo n)"; then
      MACHINE_TAGDEXER_PATH="$(ask "Path to your tagdexer checkout" "$_guess")"
    elif ask_yn "Clone tagdexer now from github.com/oisinmcgrath/tagdexer?" y; then
      _dst="$(ask "Clone tagdexer to" "$HOME/projects/tagdexer")"
      mkdir -p "$(dirname "$_dst")"
      if [ -d "$_dst/.git" ]; then
        warn "already a git checkout at $_dst — using it"; MACHINE_TAGDEXER_PATH="$_dst"
      elif git clone --depth 1 https://github.com/oisinmcgrath/tagdexer "$_dst"; then
        ok "cloned tagdexer -> $_dst"; MACHINE_TAGDEXER_PATH="$_dst"
      else
        warn "clone failed — using the copy vendored in this wizard"; MACHINE_TAGDEXER_PATH="$WIZ_DIR/tagdexer"
      fi
    else
      say "  Get it later at https://github.com/oisinmcgrath/tagdexer"
      MACHINE_TAGDEXER_PATH="$WIZ_DIR/tagdexer"     # vendored fallback keeps the wizard working
    fi
  fi
  _conf_new=1
fi
if [ -z "${MACHINE_SETSQUARE_PATH:-}" ]; then
  _guess=""; [ -d "$REPOS_ROOT/setsquare" ] && _guess="$REPOS_ROOT/setsquare"
  if ask_yn "Do you have setsquare installed (optional)?" "$([ -n "$_guess" ] && echo y || echo n)"; then
    MACHINE_SETSQUARE_PATH="$(ask "Path to your setsquare checkout" "$_guess")"
  else
    MACHINE_SETSQUARE_PATH="-"                       # sentinel: none — skip its mount/symlink
  fi
  _conf_new=1
fi
if [ -z "${MACHINE_DEVPOD_BIN:-}" ]; then
  # The wizard drives the devpod CLI (github.com/loft-sh/devpod). Use it from
  # PATH, install the official release binary, or point at an existing build.
  if command -v devpod >/dev/null 2>&1; then
    MACHINE_DEVPOD_BIN="$(command -v devpod)"
    ok "found devpod on PATH: $MACHINE_DEVPOD_BIN"
  elif ask_yn "devpod CLI not found — install it from github.com/loft-sh/devpod releases now?" y; then
    case "$(uname -m)" in x86_64|amd64) _a=amd64 ;; aarch64|arm64) _a=arm64 ;; *) _a="" ;; esac
    _dst="$(ask "Install the devpod binary to" "$HOME/.local/bin/devpod")"
    if [ -n "$_a" ] && mkdir -p "$(dirname "$_dst")" \
       && curl -fL "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-$_a" -o "$_dst" \
       && chmod +x "$_dst"; then
      MACHINE_DEVPOD_BIN="$_dst"; ok "installed devpod -> $_dst"
      case ":$PATH:" in *":$(dirname "$_dst"):"*) : ;; *) warn "$(dirname "$_dst") is not on PATH — the wizard calls devpod by full path, but add it to PATH for everyday use." ;; esac
    else
      warn "devpod install failed (arch '$(uname -m)' or download error) — install it from github.com/loft-sh/devpod, then re-run."
      MACHINE_DEVPOD_BIN="devpod"
    fi
  else
    MACHINE_DEVPOD_BIN="$(ask "Path to your existing devpod binary" "devpod")"
  fi
  _conf_new=1
fi
if [ "$_conf_new" = 1 ]; then
  mkdir -p "$(dirname "$MACHINE_CONF")"
  {
    printf '# capsule machine profile — per-host settings, asked once and\n'
    printf '# reused for every repo scaffolded on this machine. Edit or delete to change.\n'
    printf 'MACHINE_TZ=%q\n'        "$MACHINE_TZ"
    printf 'MACHINE_GIT_NAME=%q\n'  "$MACHINE_GIT_NAME"
    printf 'MACHINE_GIT_EMAIL=%q\n' "$MACHINE_GIT_EMAIL"
    printf 'TAGDEXER_MODE=%q\n'          "$TAGDEXER_MODE"
    printf 'MACHINE_TAGDEXER_PATH=%q\n'  "$MACHINE_TAGDEXER_PATH"
    printf 'MACHINE_SETSQUARE_PATH=%q\n' "$MACHINE_SETSQUARE_PATH"
    printf 'MACHINE_DEVPOD_BIN=%q\n'     "$MACHINE_DEVPOD_BIN"
  } > "$MACHINE_CONF"
  ok "machine profile saved -> $MACHINE_CONF (reused for every future repo; edit/delete to change)"
else
  ok "machine profile loaded (tz=$MACHINE_TZ, git=$MACHINE_GIT_NAME <$MACHINE_GIT_EMAIL>, tagdexer=$TAGDEXER_MODE @ $MACHINE_TAGDEXER_PATH)"
fi

# Apply the machine-profile paths (an explicit $CENTRAL_* env var still wins),
# then guarantee tagdexer resolves to a real dir (vendored fallback if the saved
# path is gone), and honour the setsquare 'none' sentinel ("-" or empty).
if [ -z "$CENTRAL_TAGDEXER_ENV" ] && [ -n "${MACHINE_TAGDEXER_PATH:-}" ]; then CENTRAL_TAGDEXER="$MACHINE_TAGDEXER_PATH"; fi
# A missing NON-env path (saved profile path deleted/moved) → vendored fallback;
# an explicit env path is left as-is so a typo surfaces at deploy time, not silently.
if [ ! -d "$CENTRAL_TAGDEXER" ] && [ -z "$CENTRAL_TAGDEXER_ENV" ]; then CENTRAL_TAGDEXER="$WIZ_DIR/tagdexer"; fi
if [ -z "$CENTRAL_SETSQUARE_ENV" ]; then
  case "${MACHINE_SETSQUARE_PATH:-}" in
    ""|-) CENTRAL_SETSQUARE="" ;;
    *)    CENTRAL_SETSQUARE="$MACHINE_SETSQUARE_PATH" ;;
  esac
fi
ok "tagdexer source: $CENTRAL_TAGDEXER${CENTRAL_SETSQUARE:+ · setsquare source: $CENTRAL_SETSQUARE}"
# The devpod binary the build step will invoke (full path or bare 'devpod').
DEVPOD="${MACHINE_DEVPOD_BIN:-devpod}"
command -v "$DEVPOD" >/dev/null 2>&1 || warn "devpod not runnable ($DEVPOD) — build/open will be skipped or fail until it's installed."

# ---------------------------------------------------------------------------
# 1. interactive inputs
# ---------------------------------------------------------------------------
step "Project questions"
# Target repo location is fully configurable and INDEPENDENT of REPOS_ROOT (the
# wizard/sources install dir). It may live anywhere on the host: pass an
# absolute path via $REPO_PATH, browse to it in the GUI, or type an absolute
# path / a bare name (resolved under REPOS_ROOT for convenience) at the prompt.
if [ -n "${REPO_PATH:-}" ]; then
  HOST_REPO_PATH="${REPO_PATH%/}"
  say "  repo (from \$REPO_PATH): $HOST_REPO_PATH"
elif [ -n "$GUI_TOOL" ]; then
  # GUI: browse and click the folder — anywhere on the host, not just REPOS_ROOT.
  HOST_REPO_PATH="$(gui_pickdir "$REPOS_ROOT")" || die "aborted (no folder chosen)."
  HOST_REPO_PATH="${HOST_REPO_PATH%/}"
  say "  selected: $HOST_REPO_PATH"
else
  ANS="$(ask "Path to the repo to containerise (absolute path, or a bare name under $REPOS_ROOT/)")"
  [ -n "$ANS" ] || die "repo path required."
  case "$ANS" in /*) HOST_REPO_PATH="${ANS%/}" ;; *) HOST_REPO_PATH="$REPOS_ROOT/${ANS%/}" ;; esac
fi
REPO_NAME="$(basename "$HOST_REPO_PATH")"
[ -d "$HOST_REPO_PATH" ] || die "host repo folder does not exist: $HOST_REPO_PATH (create it first)."

DISPLAY_NAME="$(ask "Short display name" "${REPO_NAME%%-*}-dev")"
WANT_GPU=n;  ask_yn "GPU passthrough (NVIDIA)?" n && WANT_GPU=y
WANT_NPU=n;  ask_yn "NPU passthrough (AMD XDNA / Ryzen AI, /dev/accel)?" n && WANT_NPU=y
WANT_IGPU=n; ask_yn "iGPU passthrough (AMD ROCm — /dev/dri + /dev/kfd)?" n && WANT_IGPU=y
EXTRA_APT="$(ask "Extra apt packages (space-separated, blank for none)" "")"

# Optional: paste the repo-analysis JSON (from the "paste-to-agent" prompt) to
# auto-configure image needs — apt (system libs), pip (packages/extras),
# build_steps (offline model prewarm), env, verify. Strict schema; invalid JSON
# aborts rather than silently misconfiguring. Everything maps to the right file:
# apt->Dockerfile, pip/build_steps/verify->post-create.sh, env->containerEnv.
REPO_NEEDS_JSON=""; NEEDS_APT=""; NEEDS_ENV_LINES=""; NEEDS_VERIFY=""; NEEDS_VOL_LINES=""
NEEDS_PIP=(); NEEDS_BUILD=(); NEEDS_VOLS=(); NEEDS_SUMMARY="(none)"
if ask_yn "Auto-configure apt/pip/models/env from a repo-analysis JSON block?" n; then
  # Step 1: hand the analysis prompt to the user (auto-copied to the clipboard via
  # wl-copy) so they can paste it to the agent running IN the target repo, then
  # bring back its JSON. Step 2 captures that JSON.
  _tmpP="$(mktemp)"
  cat > "$_tmpP" <<'PROMPT'
You are analysing THIS repository to determine what its Podman dev container
needs at the IMAGE level so the app runs end-to-end with no runtime root and no
runtime network. Investigate — do not guess:

- Read requirements.txt / pyproject.toml / setup.* and any existing Dockerfile,
  README, or setup scripts.
- Grep the code for imports and for libraries known to dlopen system .so files
  (e.g. cv2->libGL, sound/gl/glib/ffi libs).
- Where possible, actually try importing the key packages and capture the real
  failing .so / DependencyError names. Prefer verified facts over assumptions.
- Ensure requirements.txt is correct and up to date: it must capture every
  runtime import, with nothing installed only manually or editable and no wrong/
  conflicting pins. Correct it IN THE REPO if needed. This is an action, not part
  of your reply — record any change made or gap remaining ONLY inside "notes".

Classification rules:
- "apt"  = SYSTEM libraries only: OS packages that a Python wheel loads at
  runtime (.so files). NOT anything pip can install.
- "pip"  = packages / extras / exact-name or version pins the app needs beyond a
  plain `pip install -r requirements.txt` (e.g. an extra like paddlex[ocr], or a
  specific distribution name like opencv-contrib-python vs headless). Say WHY in
  notes if a specific name matters.
- "build_steps" = shell commands that must run at IMAGE BUILD time (e.g. fetching
  models), so nothing hits the network at runtime. Each must be offline-safe.
- Hard constraint: fully offline at runtime. If any need would require a runtime
  network call, DO NOT hide it — list it in "notes" as a blocker.

OUTPUT CONTRACT — obey exactly:
- Output ONE fenced ```json code block and NOTHING else. No prose before or after.
- Use exactly these keys, all present even if empty:
  {
    "apt": [],            // system packages, e.g. "libgl1"
    "pip": [],            // pip packages/extras, e.g. "paddlex[ocr]"
    "build_steps": [],    // build-time shell commands (offline)
    "volumes": [],        // container paths to persist on a named volume across
                          // rebuilds — heavy, non-pip-reproducible dirs only
                          // (multi-GB venvs, model caches), e.g. "/home/vscode/.cache/pip"
    "env": {},            // container env vars needed, KEY:VALUE
    "verify": "",         // one shell cmd, exit 0 = success
    "notes": []           // contradictions, blockers, name-pin reasons
  }
- Arrays are flat lists of strings. No comments inside the JSON. No trailing text.
- Every apt/pip entry must be justified by something you actually found in the
  repo; if unsure, put it in notes, not in apt/pip.
PROMPT
  _copied="(copy it from this window)"
  if command -v wl-copy >/dev/null 2>&1 && wl-copy < "$_tmpP" 2>/dev/null; then _copied="— already on your clipboard, just paste it"; fi
  if [ -n "$GUI_TOOL" ]; then
    case "$GUI_TOOL" in
      kdialog)
        kdialog --title "Step 1/2: give THIS prompt to your repo agent $_copied" --textbox "$_tmpP" 820 620 2>/dev/null || true
        REPO_NEEDS_JSON="$(kdialog --title "Step 2/2: paste the agent's JSON reply (blank = skip)" --textinputbox "Paste the JSON block the agent returned:" "" 720 520 2>/dev/null)" || REPO_NEEDS_JSON="" ;;
      zenity)
        zenity --title "Step 1/2: prompt for your repo agent" --text-info --filename="$_tmpP" 2>/dev/null || true
        REPO_NEEDS_JSON="$(zenity --title "Step 2/2: paste the JSON reply" --text-info --editable 2>/dev/null)" || REPO_NEEDS_JSON="" ;;
    esac
  else
    say ""; say "  ===== paste THIS prompt to the agent in the target repo $_copied ====="
    cat "$_tmpP"
    say "  ===== then paste its JSON reply below; Ctrl-D on a new line to finish ====="
    REPO_NEEDS_JSON="$(cat)"
  fi
  rm -f "$_tmpP"
fi
if [ -n "${REPO_NEEDS_JSON//[[:space:]]/}" ]; then
  printf '%s' "$REPO_NEEDS_JSON" | jq -e . >/dev/null 2>&1 || die "pasted repo-analysis is not valid JSON. Fix it (one { } block) and re-run, or decline the paste."
  NEEDS_APT="$(printf '%s' "$REPO_NEEDS_JSON" | jq -r '.apt[]?' | tr '\n' ' ')"
  mapfile -t NEEDS_PIP   < <(printf '%s' "$REPO_NEEDS_JSON" | jq -r '.pip[]?')
  mapfile -t NEEDS_BUILD < <(printf '%s' "$REPO_NEEDS_JSON" | jq -r '.build_steps[]?')
  mapfile -t NEEDS_VOLS  < <(printf '%s' "$REPO_NEEDS_JSON" | jq -r '.volumes[]?')
  NEEDS_VERIFY="$(printf '%s' "$REPO_NEEDS_JSON" | jq -r '.verify // empty')"
  NEEDS_ENV_LINES="$(printf '%s' "$REPO_NEEDS_JSON" | jq -r '(.env // {}) | to_entries[] | ", " + (.key|@json) + ": " + (.value|tostring|@json)' | tr -d '\n')"
  EXTRA_APT="$(printf '%s %s' "$EXTRA_APT" "$NEEDS_APT" | xargs || true)"
  NEEDS_SUMMARY="apt:$(printf '%s' "$NEEDS_APT" | wc -w) pip:${#NEEDS_PIP[@]} build:${#NEEDS_BUILD[@]} vol:${#NEEDS_VOLS[@]} env:$(printf '%s' "$REPO_NEEDS_JSON" | jq -r '(.env//{})|length') verify:$([ -n "$NEEDS_VERIFY" ] && echo y || echo n)"
  ok "repo-needs parsed ($NEEDS_SUMMARY) — merged into apt/pip/env/post-create"
  # Surface the agent's notes: these often flag repo edits the wizard can't make
  # safely (e.g. replacing a conflicting pin in requirements.txt).
  printf '%s' "$REPO_NEEDS_JSON" | jq -r '.notes[]?' | while IFS= read -r _n; do [ -n "$_n" ] && warn "note: $_n"; done
fi
WANT_GIT=y;  ask_yn "git init the repo if not already a git repo?" y || WANT_GIT=n

# tagdexer deploy for THIS run, per the machine-profile policy (always/never/ask).
DEPLOY_TAGDEXER=y
case "$TAGDEXER_MODE" in
  never) DEPLOY_TAGDEXER=n ;;
  ask)   DEPLOY_TAGDEXER=n; ask_yn "Deploy the tagdexer decision-log into this repo?" y && DEPLOY_TAGDEXER=y ;;
esac
# tagdexer requested but no source to deploy from → fail fast rather than half-scaffold.
[ "$DEPLOY_TAGDEXER" = y ] && [ ! -d "$CENTRAL_TAGDEXER" ] && die "tagdexer deploy requested but its source is missing at $CENTRAL_TAGDEXER (set \$CENTRAL_TAGDEXER, or choose 'never')."

# ---------------------------------------------------------------------------
# 2. derive everything (sanitization + project keys + non-clashing port)
# ---------------------------------------------------------------------------
step "Derived values"
# DevPod sanitization: strip underscores, preserve hyphens, lowercase.
SANITIZED="$(printf '%s' "$REPO_NAME" | tr -d '_' | tr '[:upper:]' '[:lower:]')"
# Host project key: Claude's per-repo key is the absolute repo path with every
# / and _ turned into - (leading / -> leading -). Derive it from the REAL path
# so it's correct wherever the repo lives, not just under one fixed root.
HOST_PROJECT_KEY="$(printf '%s' "$HOST_REPO_PATH" | tr '_/' '--')"
CONTAINER_PROJECT_KEY="-workspaces-$SANITIZED"

# Non-clashing forward port: scan existing devpod workspaces' devcontainer.json
# forwardPorts, then pick the next free >= 8080 not already bound.
# NOTE: forwardPorts is usually multiline ("forwardPorts": [\n  8081\n]), and
# grep -P's \s* does NOT span newlines, so a single-file grep misses it. jq
# parses the JSON structure regardless of formatting; fall back to a
# whole-file (-z) grep for any non-JSON-clean file.
used_ports=""
for dcf in "$REPOS_ROOT"/*/.devcontainer/devcontainer.json; do
  [ -f "$dcf" ] || continue
  p="$(jq -r '.forwardPorts[]? // empty' "$dcf" 2>/dev/null)"
  [ -z "$p" ] && p="$(grep -zoP '"forwardPorts"\s*:\s*\[\s*\K[0-9]+' "$dcf" 2>/dev/null | tr '\0' '\n')"
  used_ports="$used_ports$p"$'\n'
done
used_ports="$(printf '%s' "$used_ports" | grep -E '^[0-9]+$' | sort -un || true)"
FORWARD_PORT=8080
while :; do
  clash=0
  for p in $used_ports; do [ "$p" = "$FORWARD_PORT" ] && clash=1 && break; done
  if [ "$clash" = 0 ] && ! ss -ltn "( sport = :$FORWARD_PORT )" 2>/dev/null | grep -q ":$FORWARD_PORT"; then break; fi
  FORWARD_PORT=$((FORWARD_PORT+1))
done

say "  repo name ............. $REPO_NAME"
say "  host path ............. $HOST_REPO_PATH"
say "  sanitized (container) . $SANITIZED   (DevPod-sanitized workspace name)"
say "  container path ........ /workspaces/$SANITIZED"
say "  host project key ...... $HOST_PROJECT_KEY"
say "  container project key . $CONTAINER_PROJECT_KEY"
say "  forward port .......... $FORWARD_PORT   (next free; existing: ${used_ports//$'\n'/ })"
say "  GPU ................... $WANT_GPU"
say "  NPU ................... $WANT_NPU   (AMD XDNA / Ryzen AI, /dev/accel/accel0)"
say "  iGPU (ROCm) .......... $WANT_IGPU   (/dev/dri + /dev/kfd, video+render groups)"
say "  extra apt ............. ${EXTRA_APT:-(none)}"
say "  repo needs (pasted) .. $NEEDS_SUMMARY"
say "  tagdexer ............. $DEPLOY_TAGDEXER   (policy: $TAGDEXER_MODE)"
if [ -n "$GUI_TOOL" ]; then
  ask_yn "Proceed with these derived values?

repo:            $REPO_NAME
container path:  /workspaces/$SANITIZED
forward port:    $FORWARD_PORT
GPU:             $WANT_GPU
NPU:             $WANT_NPU
iGPU (ROCm):     $WANT_IGPU
extra apt:       ${EXTRA_APT:-(none)}
repo needs:      $NEEDS_SUMMARY" || die "aborted by user."
else
  ask_yn "Proceed with these?" y || die "aborted by user."
fi

# ---------------------------------------------------------------------------
# 3. scaffold .devcontainer
# ---------------------------------------------------------------------------
step "Scaffold .devcontainer"
DC="$HOST_REPO_PATH/.devcontainer"
mkdir -p "$DC"

# Existing repo: a host-built .venv is broken inside the container (interpreter
# paths point at host python) and would kill post-create mid-install.
if [ -d "$HOST_REPO_PATH/.venv" ]; then
  if ask_yn "Existing .venv found (host-built; unusable inside the container). Move aside to .venv_host_backup?" y; then
    mv "$HOST_REPO_PATH/.venv" "$HOST_REPO_PATH/.venv_host_backup"
    ok ".venv -> .venv_host_backup (container builds its own; delete the backup once happy)"
  else
    warn "keeping .venv — post-create will rebuild it in place if its python doesn't run in-container"
  fi
fi

# repo-needs "volumes": persist heavy, non-pip-reproducible container dirs (e.g.
# multi-GB ROCm/quark venvs, model caches) on named volumes so a recreate does
# NOT wipe them. Named volumes dodge rootless-uid + SELinux caveats (podman owns
# them) and survive `devpod delete`. Volume name = <workspace>-<path-slug>.
for _v in "${NEEDS_VOLS[@]}"; do
  [ -n "$_v" ] || continue
  _slug="$(printf '%s' "$_v" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{1,\}/-/g;s/^-//;s/-$//')"
  NEEDS_VOL_LINES="$NEEDS_VOL_LINES,
    \"source=$SANITIZED-$_slug,target=$_v,type=volume\""
done

# Host Wayland clipboard passthrough: mount the host runtime DIRECTORY (not the
# single socket file) so tools + agents INSIDE the container can read the HOST
# clipboard — including image/png, which OSC 52 cannot carry. Mounting the DIR
# (not the wayland-0 file) is deliberate: a file bind pins one socket inode, so a
# logout/login or compositor restart makes a fresh host socket and the container
# is left bound to a dead one ("connection refused"). A directory bind always
# resolves the CURRENT wayland-0/bus, surviving re-logins with no recreate.
# Requires the IDE to be launched from a graphical session so WAYLAND_DISPLAY /
# XDG_RUNTIME_DIR exist here at create time; if absent we SKIP and warn rather
# than ship a broken mount. Mounted at a dedicated /run/host-xdg target so the
# container's own XDG_RUNTIME_DIR is never overwritten. (Container vscode is
# uid 1000 = host uid, so the sockets are openable.)
CLIP_OK=n; WL_SOCK=""; WL_MOUNT_LINES=""; WL_ENV_LINES=""
HOST_XDG="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
HOST_WL="${WAYLAND_DISPLAY:-}"
case "$HOST_WL" in "") WL_SOCK="" ;; /*) WL_SOCK="$HOST_WL" ;; *) WL_SOCK="$HOST_XDG/$HOST_WL" ;; esac
if [ -n "$WL_SOCK" ] && [ -S "$WL_SOCK" ] && [ -d "$HOST_XDG" ]; then
  CLIP_OK=y
  _wlname="${HOST_WL##*/}"   # bare socket name, e.g. wayland-0 (resolved under the mounted dir)
  # Leading comma: follows the last existing mounts[] entry. Mount the whole
  # runtime dir so wayland-0 + bus are always the live ones.
  WL_MOUNT_LINES=",
    \"source=$HOST_XDG,target=/run/host-xdg,type=bind\""
  WL_ENV_LINES=", \"WAYLAND_DISPLAY\": \"/run/host-xdg/$_wlname\""
  [ -S "$HOST_XDG/bus" ] && WL_ENV_LINES="$WL_ENV_LINES, \"DBUS_SESSION_BUS_ADDRESS\": \"unix:path=/run/host-xdg/bus\""
fi

# runArgs: device passthrough (GPU and/or NPU) + SELinux label-disable. Never
# --pid=host (it makes open-remote-ssh see the host's process table and falsely
# conclude a server is 'already running' -> reuse path -> no token -> attach
# fails. This is THE bug that broke pickles; the wizard never emits it.)
RUN_ARGS_PARTS=()
if [ "$WANT_GPU" = y ]; then
  RUN_ARGS_PARTS+=('"--device=nvidia.com/gpu=all"')
fi
if [ "$WANT_NPU" = y ]; then
  # AMD XDNA / Ryzen AI NPU is a DRM 'accel' device, NOT a CDI device. Pass the
  # node itself and add the host 'render' gid so the container user can open it
  # even if udev tightens perms from 0666 to 0660. (No CDI/nvidia-ctk involved.)
  RENDER_GID="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
  RUN_ARGS_PARTS+=('"--device=/dev/accel/accel0"')
  [ -n "$RENDER_GID" ] && RUN_ARGS_PARTS+=("\"--group-add=$RENDER_GID\"")
fi
if [ "$WANT_IGPU" = y ]; then
  # AMD iGPU / ROCm: pass the DRI render node (/dev/dri) + the KFD compute node
  # (/dev/kfd), and add the host video+render gids so the container user can open
  # them. ROCm userspace in the image must match the host amdgpu/amdkfd.
  IGPU_RENDER_GID="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
  IGPU_VIDEO_GID="$(getent group video 2>/dev/null | cut -d: -f3 || true)"
  RUN_ARGS_PARTS+=('"--device=/dev/dri"' '"--device=/dev/kfd"')
  [ -n "$IGPU_VIDEO_GID" ]  && RUN_ARGS_PARTS+=("\"--group-add=$IGPU_VIDEO_GID\"")
  [ -n "$IGPU_RENDER_GID" ] && RUN_ARGS_PARTS+=("\"--group-add=$IGPU_RENDER_GID\"")
fi
# label=disable lets the container open a passed host device OR the mounted host
# Wayland/D-Bus sockets under SELinux (Fedora enforcing). Added once if any.
if [ "$WANT_GPU" = y ] || [ "$WANT_NPU" = y ] || [ "$WANT_IGPU" = y ] || [ "$CLIP_OK" = y ]; then
  RUN_ARGS_PARTS+=('"--security-opt=label=disable"')
fi
# Join the parts into a JSON array body: `a, b, c` (empty when no devices).
RUN_ARGS=""
if [ "${#RUN_ARGS_PARTS[@]}" -gt 0 ]; then
  RUN_ARGS="$(printf '%s, ' "${RUN_ARGS_PARTS[@]}")"; RUN_ARGS="${RUN_ARGS%, }"
fi

# Sister-repo mounts + editor settings — tagdexer only when we're deploying it,
# setsquare only when that sibling exists on this host. Both optional, so a
# standalone clone with neither still yields a valid container. Leading-comma
# style (like WL_MOUNT_LINES) so an empty set collapses cleanly.
SISTER_MOUNT_LINES=""; SISTER_SETTINGS=""
if [ "$DEPLOY_TAGDEXER" = y ]; then
  SISTER_MOUNT_LINES="$SISTER_MOUNT_LINES,
    \"source=$CENTRAL_TAGDEXER,target=/workspaces/tagdexer-source,type=bind,consistency=cached\""
  SISTER_SETTINGS="\"tagdexer.sourcePath\": \"/workspaces/tagdexer-source\""
fi
if [ -d "$CENTRAL_SETSQUARE" ]; then
  SISTER_MOUNT_LINES="$SISTER_MOUNT_LINES,
    \"source=$CENTRAL_SETSQUARE,target=/workspaces/setsquare-source,type=bind,consistency=cached\""
  SISTER_SETTINGS="${SISTER_SETTINGS:+$SISTER_SETTINGS, }\"setsquare.hostRepoPath\": \"/workspaces/setsquare-source\""
fi

cat > "$DC/devcontainer.json" <<JSON
{
  "name": "$DISPLAY_NAME (containerized)",
  "build": { "dockerfile": "Dockerfile" },
  "runArgs": [ $RUN_ARGS ],
  "mounts": [
    "source=claude-code-config-\${devcontainerId},target=/home/vscode/.claude,type=volume",
    "source=$HOST_CLAUDE_PROJECTS,target=/home/vscode/.claude-host-projects,type=bind,consistency=cached",
    "source=$(dirname "$HOST_CLAUDE_PROJECTS")/.credentials.json,target=/home/vscode/.claude/.credentials.json,type=bind,consistency=cached"$SISTER_MOUNT_LINES$WL_MOUNT_LINES$NEEDS_VOL_LINES
  ],
  "containerEnv": { "CLAUDE_CONFIG_DIR": "/home/vscode/.claude", "TZ": "$MACHINE_TZ"$WL_ENV_LINES$NEEDS_ENV_LINES },
  "containerUser": "vscode",
  "remoteUser": "vscode",
  "customizations": {
    "vscode": {
      "settings": { $SISTER_SETTINGS },
      "extensions": []
    }
  },
  "postCreateCommand": "/bin/bash .devcontainer/post-create.sh",
  "forwardPorts": [ $FORWARD_PORT ]
}
JSON
ok "devcontainer.json (runArgs: ${RUN_ARGS:-[] — no --pid=host})"
if [ "$CLIP_OK" = y ]; then
  ok "host Wayland clipboard passthrough ENABLED (host runtime dir -> /run/host-xdg; survives re-login; image/png paste into Grok works after rebuild)"
else
  warn "no host WAYLAND_DISPLAY at create time — clipboard passthrough DISABLED. Launch the IDE from the graphical KDE session, then re-run the wizard to enable host image paste."
fi

# Dockerfile: lean baseline + optional extra apt. EXTRA_APT expands inline on
# its own continuation line — do NOT build it via $(...) command substitution:
# that strips the trailing newline, gluing "pkg \    && rm" onto one line where
# the backslash escapes a space and apt sees an empty package name.
cat > "$DC/Dockerfile" <<DOCKER
# Pinned to 24.04 LTS: the floating ':ubuntu' tag now resolves to 25.10
# ("resolute"), which ships python3.13 and has no python3.12 packages, breaking
# the pinned apt install below. 24.04 ships python3.12 as default.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
USER root
# Lean baseline. Add repo-specific system libs via the wizard's "extra apt" prompt.
RUN apt-get update && apt-get install -y --no-install-recommends \\
    ripgrep procps build-essential curl jq wl-clipboard \\
    python3.12 python3.12-venv python3.12-dev python3-pip \\
    libpython3.12-dev libffi-dev libssl-dev pkg-config \\
    $EXTRA_APT \\
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \\
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1
USER vscode
# grok CLI (x.ai) — installed for the container user so it is on PATH by default.
RUN curl -fsSL https://x.ai/cli/install.sh | bash
DOCKER
ok "Dockerfile (extra apt: ${EXTRA_APT:-none})"

# container-claude-settings.json: bypass + max (generic, copied verbatim).
cat > "$DC/container-claude-settings.json" <<'JSON'
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "effortLevel": "max"
}
JSON
ok "container-claude-settings.json"

# Repo-needs post-create section: extra pip + offline model prewarm + verify,
# built only if a JSON block was pasted. Pip specs are single-quoted so shell
# metacharacters in pins/extras ([ocr], >=, <) stay literal. Runs AFTER the
# requirements.txt install (venv exists), so extras layer on top; the prewarm
# and verify need that venv, which is why this is post-create, not the Dockerfile.
PCS_EXTRA_BLOCK=""
if [ "${#NEEDS_PIP[@]}" -gt 0 ] || [ "${#NEEDS_BUILD[@]}" -gt 0 ] || [ -n "$NEEDS_VERIFY" ] || [ "${#NEEDS_VOLS[@]}" -gt 0 ]; then
  PCS_EXTRA_BLOCK="echo '=== repo needs: venv + extra pip ==='
[ -x .venv/bin/python3 ] || { rm -rf .venv; python3 -m venv .venv; }
. .venv/bin/activate"
  # Named volumes mount ROOT-owned in rootless podman, so the vscode user cannot
  # write them (the model prewarm silently fails). chown each declared mountpoint
  # to vscode BEFORE the prewarm/build steps. Needs vscode passwordless sudo
  # (granted by the devcontainers base image); non-fatal if unavailable.
  if [ "${#NEEDS_VOLS[@]}" -gt 0 ]; then
    PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
echo '=== repo needs: chown named-volume mountpoints to vscode ==='"
    for _v in "${NEEDS_VOLS[@]}"; do
      [ -n "$_v" ] && PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
sudo chown vscode:vscode '$_v' 2>/dev/null || true"
    done
  fi
  if [ "${#NEEDS_PIP[@]}" -gt 0 ]; then
    _pipq=""; for _p in "${NEEDS_PIP[@]}"; do _pipq="$_pipq '$_p'"; done
    PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
pip install --upgrade pip && pip install$_pipq"
  fi
  if [ "${#NEEDS_BUILD[@]}" -gt 0 ]; then
    # NON-FATAL: a failing model prewarm (e.g. an app-level model/lib version
    # crash) must NOT abort container creation and leave the user with nothing.
    # Wrap in set +e so the container is still built; the failure is visible in
    # the log and the user debugs the app stack INSIDE a working container.
    PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
echo '=== repo needs: build-time model prewarm (non-fatal; keeps runtime offline) ==='
set +e"
    for _s in "${NEEDS_BUILD[@]}"; do PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
$_s"; done
    PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
set -e"
  fi
  if [ -n "$NEEDS_VERIFY" ]; then
    PCS_EXTRA_BLOCK="$PCS_EXTRA_BLOCK
echo '=== repo needs: verify ==='
if $NEEDS_VERIFY; then echo 'REPO VERIFY: OK'; else echo 'REPO VERIFY: FAILED (inspect above)'; fi"
  fi
fi

# post-create.sh: vsix install + venv + claude settings + memory-bridge symlink.
cat > "$DC/post-create.sh" <<PCS
#!/bin/bash
set -e
echo "=== sister-repo extensions ==="
for VSIX in /workspaces/tagdexer-source/extension/*.vsix /workspaces/setsquare-source/*.vsix; do
  [ -f "\$VSIX" ] && (codium --install-extension "\$VSIX" 2>/dev/null || \\
    code-server --install-extension "\$VSIX" 2>/dev/null || echo "manual install: \$VSIX")
done
echo "=== python venv ==="
if [ -f requirements.txt ] && [ "\$(wc -l < requirements.txt)" -le 100 ]; then
  # A venv inherited from the host won't execute in-container — rebuild it.
  .venv/bin/python3 -c '' 2>/dev/null || { rm -rf .venv; python3 -m venv .venv; }
  . .venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt
fi
$PCS_EXTRA_BLOCK
echo "=== container Claude settings ==="
cp .devcontainer/container-claude-settings.json /home/vscode/.claude/settings.json 2>/dev/null || \\
  echo "WARN: container-claude-settings.json not installed"
echo "=== host<->container memory bridge ==="
mkdir -p /home/vscode/.claude/projects
if [ -d "/home/vscode/.claude-host-projects/$HOST_PROJECT_KEY" ]; then
  ln -sfn "/home/vscode/.claude-host-projects/$HOST_PROJECT_KEY" \\
    "/home/vscode/.claude/projects/$CONTAINER_PROJECT_KEY"
fi
echo "=== post-create complete ==="
PCS
chmod +x "$DC/post-create.sh"
ok "post-create.sh (memory bridge: $HOST_PROJECT_KEY -> $CONTAINER_PROJECT_KEY)"

# ---------------------------------------------------------------------------
# 4. scaffold .claude hooks (the 9 generic, block_* excluded)
# ---------------------------------------------------------------------------
step "Install generic hooks"
mkdir -p "$HOST_REPO_PATH/.claude/hooks"
cp "$PAYLOAD"/claude_hooks/*.sh "$HOST_REPO_PATH/.claude/hooks/"
chmod +x "$HOST_REPO_PATH/.claude/hooks/"*.sh
# check_symlinks.sh references <CONTAINER_WORKSPACE_NAME> — substitute it.
sed -i "s|<CONTAINER_WORKSPACE_NAME>|$SANITIZED|g" "$HOST_REPO_PATH/.claude/hooks/check_symlinks.sh" 2>/dev/null || true
ok "9 hooks installed (detect_context, check_symlinks, check_venv, onboarding_mandate, staleness_check, periodic_reminder, subagent_reminder, protect_devcontainer, commit_and_log_nudge)"

# Write .claude/settings.json wiring all 9 + (taskboard wires its own 2 below).
# Existing repo: back up any prior settings.json — its hook wiring is replaced
# wholesale, so the owner can re-merge custom hooks from the backup.
if [ -f "$HOST_REPO_PATH/.claude/settings.json" ]; then
  cp "$HOST_REPO_PATH/.claude/settings.json" "$HOST_REPO_PATH/.claude/settings.json.pre-wizard"
  warn "existing .claude/settings.json backed up to settings.json.pre-wizard — re-merge any custom hooks from it"
fi
cat > "$HOST_REPO_PATH/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": ".claude/hooks/detect_context.sh" },
        { "type": "command", "command": ".claude/hooks/check_symlinks.sh" },
        { "type": "command", "command": ".claude/hooks/check_venv.sh" }
      ]},
      { "matcher": "startup|clear|compact", "hooks": [
        { "type": "command", "command": ".claude/hooks/onboarding_mandate.sh" }
      ]}
    ],
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command", "command": ".claude/hooks/staleness_check.sh", "timeout": 5 },
        { "type": "command", "command": ".claude/hooks/periodic_reminder.sh", "timeout": 5 },
        { "type": "command", "command": ".claude/hooks/subagent_reminder.sh", "timeout": 5 }
      ]}
    ],
    "PreToolUse": [
      { "matcher": "Edit|Write", "hooks": [
        { "type": "command", "command": ".claude/hooks/protect_devcontainer.sh" }
      ]}
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": ".claude/hooks/commit_and_log_nudge.sh" } ] }
    ]
  }
}
JSON
ok ".claude/settings.json wired (taskboard adds its 2 hooks next)"

# ---------------------------------------------------------------------------
# 5. deploy tagdexer (CLI files in-repo; .tagdexerrc -> in-CONTAINER path)
# ---------------------------------------------------------------------------
step "Deploy tagdexer"
if [ "$DEPLOY_TAGDEXER" != y ]; then
  ok "tagdexer deploy skipped (policy: $TAGDEXER_MODE) — no tagdexer/ or .tagdexerrc written"
else
TD="$HOST_REPO_PATH/tagdexer"
mkdir -p "$TD/shared"
for f in indexer.js tracker.js decisions.schema.json package.json LICENSE AGENT_README.md README.md CHANGELOG.md; do
  cp "$CENTRAL_TAGDEXER/$f" "$TD/$f" 2>/dev/null || warn "central tagdexer missing $f"
done
cp -r "$CENTRAL_TAGDEXER/shared/." "$TD/shared/" 2>/dev/null || true
# aliases.json seeded once; never overwrite an existing per-repo copy.
[ -f "$TD/aliases.json" ] || cp "$CENTRAL_TAGDEXER/aliases.json" "$TD/aliases.json" 2>/dev/null || true
# .tagdexerrc MUST point at the IN-CONTAINER mount, not the host path, or the
# CLI silently degrades (loses shared aliases + trackdexer config).
cat > "$HOST_REPO_PATH/.tagdexerrc" <<'RC'
# tagdexer configuration — points the CLI at the shared (central) source.
# Inside the container, /workspaces/tagdexer-source is the bind-mount of the
# central tagdexer. Do NOT use a host path here: it won't exist in the
# container and the CLI will silently drop the shared alias/config layer.
genericPath=/workspaces/tagdexer-source
RC
# decisions.jsonl: do NOT create. Absent == empty (it's JSONL, not a JSON array).
ok "tagdexer CLI deployed; .tagdexerrc -> /workspaces/tagdexer-source; empty decision log (absent)"
fi

# ---------------------------------------------------------------------------
# 6. deploy a FRESH taskboard (self-contained; its installer wires 2 hooks)
# ---------------------------------------------------------------------------
step "Deploy taskboard"
# Existing repo: pending work survives the refresh — lists/ + domains.json are
# carried across; only the taskboard code + hooks are replaced.
TB="$HOST_REPO_PATH/taskboard"
TB_KEEP=""
if ls "$TB"/lists/*_whiteboard.json >/dev/null 2>&1; then
  TB_KEEP="$(mktemp -d)"
  cp "$TB"/lists/*_whiteboard.json "$TB_KEEP/"
  cp "$TB/domains.json" "$TB_KEEP/" 2>/dev/null || true
fi
cp -r "$PAYLOAD/taskboard" "$HOST_REPO_PATH/taskboard.__new"
rm -rf "$TB" 2>/dev/null || true
mv "$HOST_REPO_PATH/taskboard.__new" "$TB"
( cd "$HOST_REPO_PATH" && bash taskboard/install.sh --reset >/dev/null ) \
  && ok "taskboard installed (code + 2 hooks merged into settings.json)" \
  || die "taskboard install.sh failed"
if [ -n "$TB_KEEP" ]; then
  cp "$TB_KEEP"/*_whiteboard.json "$TB/lists/"
  [ -f "$TB_KEEP/domains.json" ] && cp "$TB_KEEP/domains.json" "$TB/domains.json"
  rm -rf "$TB_KEEP"
  ok "existing taskboard lists + domains preserved across refresh"
else
  ok "fresh empty board"
fi

# ---------------------------------------------------------------------------
# 6b. wire Grok agent hooks — mirror the FINALIZED Claude hook set (9 generic +
# taskboard's 2) into .grok/hooks/agent-hooks.json so a Grok agent fires the SAME
# hooks with zero duplicate scripts. Grok resolves hook commands relative to its
# config dir (.grok/hooks/), so each repo-root path gets a ../../ prefix. The
# devcontainer-protect matcher is widened to Grok's edit-tool names.
# ---------------------------------------------------------------------------
step "Wire Grok agent hooks"
mkdir -p "$HOST_REPO_PATH/.grok/hooks"
[ -f "$HOST_REPO_PATH/.grok/hooks/agent-hooks.json" ] && \
  cp "$HOST_REPO_PATH/.grok/hooks/agent-hooks.json" "$HOST_REPO_PATH/.grok/hooks/agent-hooks.json.pre-wizard"
if jq '{
  hooks: (
    .hooks
    | walk(if type == "object" and has("command") then .command = "../../" + .command else . end)
    | .PreToolUse |= map(if has("matcher") then .matcher = "Edit|Write|MultiEdit|search_replace" else . end)
  )
}' "$HOST_REPO_PATH/.claude/settings.json" > "$HOST_REPO_PATH/.grok/hooks/agent-hooks.json" 2>/dev/null; then
  _gh="$(jq '[.. | objects | select(has("command"))] | length' "$HOST_REPO_PATH/.grok/hooks/agent-hooks.json")"
  ok ".grok/hooks/agent-hooks.json wired ($_gh hooks, shared with Claude — no duplicate scripts; Grok works out of the box)"
else
  warn "could not generate .grok/hooks/agent-hooks.json — Grok hooks not wired (Claude unaffected)"
fi

# ---------------------------------------------------------------------------
# 6c. seed generic agent memory (host-side; bridged into the container)
# ---------------------------------------------------------------------------
# Memory lives outside the repo, host-side, keyed by project path. The container
# Claude reads it via the post-create memory-bridge symlink
# (/home/vscode/.claude/projects/<CONTAINER_KEY> -> host <HOST_KEY>). So we write
# the generic memory files into the HOST project memory dir; the bridge surfaces
# them in-container. Currently just the no-co-author rule (a harness default that
# only memory/CLAUDE.md can override — no hook can).
if [ -d "$PAYLOAD/memory" ]; then
  step "Seed generic memory"
  HOST_MEM="$HOST_CLAUDE_PROJECTS/$HOST_PROJECT_KEY/memory"
  mkdir -p "$HOST_MEM"
  for mf in "$PAYLOAD"/memory/*.md; do
    base="$(basename "$mf")"
    [ "$base" = "MEMORY.md" ] && continue
    [ -f "$HOST_MEM/$base" ] || cp "$mf" "$HOST_MEM/$base"   # never clobber owner edits
  done
  # Merge the index line(s) into MEMORY.md without duplicating.
  touch "$HOST_MEM/MEMORY.md"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    grep -qF -- "$line" "$HOST_MEM/MEMORY.md" || printf '%s\n' "$line" >> "$HOST_MEM/MEMORY.md"
  done < "$PAYLOAD/memory/MEMORY.md"
  ok "generic memory seeded -> $HOST_MEM (no-co-author rule)"
fi

# ---------------------------------------------------------------------------
# 7. CLAUDE.md (minimal, project-specific — NO fbad content)
# ---------------------------------------------------------------------------
step "Write CLAUDE.md"
# Container/host boundary appendix — every repo gets this, with its real paths.
# Fresh repo: included in the stub. Existing CLAUDE.md: appended once (keyed on
# the heading), never duplicated, rest of the file untouched.
APPENDIX_HEADING="## Appendix: Container/Host Execution Boundary"
APPENDIX="$(cat <<MD
$APPENDIX_HEADING

The host folder \`$HOST_REPO_PATH/\` is bind-mounted live into the Podman container as \`/workspaces/$SANITIZED\`. Same folder, same files, edits propagate instantly both directions — not copies.

The container exists for agents to develop freely; the owner operates the host (desktop, browser, interactive work). Each session declares container or host at startup.

Container-side operations: agents run autonomously.

Host-side operations (browser apps, owner-interactive tools): agents cannot act autonomously. Supply the command as a pasteable code block; the owner runs it host-side and returns the output. Container paths (\`/workspaces/$SANITIZED/...\`) resolve on the host as-is via symlink; if a path fails to resolve there, substitute the \`$HOST_REPO_PATH/\` prefix. Agents assist, not act.
MD
)"
# CLAUDE.md wording adapts to whether tagdexer was deployed into this repo.
if [ "$DEPLOY_TAGDEXER" = y ]; then
  CM_FIRST='**First action: read [tagdexer/AGENT_README.md](tagdexer/AGENT_README.md) in full.** Use tagdex as your primary navigation. (Onboarding + trackdexer protocol are injected by the SessionStart hook.)'
  CM_DECISIONS='**CLAUDE.md is orientation only.** Decisions never go in markdown — `node tagdexer/tracker.js --add` for every architectural choice, finding, dead-end, or handoff. Pending work lives in the taskboard (`node taskboard/taskboard.js --help`).'
else
  CM_FIRST='**First action: read this file, then run `node taskboard/taskboard.js --help` for pending work.**'
  CM_DECISIONS='**CLAUDE.md is orientation only.** Pending work lives in the taskboard (`node taskboard/taskboard.js --help`).'
fi
if [ ! -f "$HOST_REPO_PATH/CLAUDE.md" ]; then
cat > "$HOST_REPO_PATH/CLAUDE.md" <<MD
$CM_FIRST

# $REPO_NAME

> New project. Replace this description with what it does.

## Invariant — read first

$CM_DECISIONS

## Workflow

Sandboxed DevPod + Podman + VSCodium container, mounted from the host repo. Agent runs under bypass permissions; the generic hooks drive tagdexer/taskboard/decision-log usage automatically.

$APPENDIX
MD
ok "CLAUDE.md written (project stub + container/host appendix)"
elif ! grep -qF "$APPENDIX_HEADING" "$HOST_REPO_PATH/CLAUDE.md"; then
printf '\n%s\n' "$APPENDIX" >> "$HOST_REPO_PATH/CLAUDE.md"
ok "CLAUDE.md present — container/host appendix appended (rest untouched)"
else
ok "CLAUDE.md already present with appendix — left untouched"
fi

# ---------------------------------------------------------------------------
# 8. host /workspaces symlinks (sanitized name + sister sources)
# ---------------------------------------------------------------------------
step "Host /workspaces symlinks"
# Only reach for sudo when a link is missing/wrong; if sudo is unavailable
# (non-interactive run), print the manual commands and carry on — the links
# are host-side convenience, not required by the container build.
LINKS=( "/workspaces/$SANITIZED|$HOST_REPO_PATH" )
[ "$DEPLOY_TAGDEXER" = y ] && LINKS+=( "/workspaces/tagdexer-source|$CENTRAL_TAGDEXER" )
[ -d "$CENTRAL_SETSQUARE" ] && LINKS+=( "/workspaces/setsquare-source|$CENTRAL_SETSQUARE" )
missing=()
for l in "${LINKS[@]}"; do
  [ "$(readlink "${l%%|*}" 2>/dev/null)" = "${l##*|}" ] || missing+=("$l")
done
if [ ${#missing[@]} -eq 0 ]; then
  ok "all /workspaces symlinks already correct (no sudo needed)"
elif "${SUDO[@]}" mkdir -p /workspaces 2>/dev/null; then
  for l in "${missing[@]}"; do
    "${SUDO[@]}" ln -sfn "${l##*|}" "${l%%|*}" || warn "failed: sudo ln -sfn ${l##*|} ${l%%|*}"
  done
  ok "/workspaces symlinks created"
else
  warn "sudo unavailable — create these manually, then continue:"
  for l in "${missing[@]}"; do say "    sudo ln -sfn ${l##*|} ${l%%|*}"; done
fi

# ---------------------------------------------------------------------------
# 9. GPU: ensure the CDI spec is at a version THIS podman can parse
# ---------------------------------------------------------------------------
if [ "$WANT_GPU" = y ]; then
  step "GPU / CDI"
  command -v nvidia-ctk >/dev/null 2>&1 || die "GPU requested but nvidia-ctk not installed."
  # Probe: does podman resolve the device right now?
  if podman run --rm --device nvidia.com/gpu=all docker.io/library/ubuntu nvidia-smi -L >/dev/null 2>&1; then
    ok "GPU passthrough already resolves"
  else
    warn "GPU device unresolvable — regenerating CDI spec"
    # Podman <5 parses CDI spec <=0.6.0. nvidia-ctk >=1.17 dropped --cdi-version
    # and auto-emits the minimum required (often 0.7.0+), which Podman 4.x can't
    # parse. So: if the toolkit can pin, pin to 0.6.0; otherwise rely on a
    # toolkit old enough to emit <=0.6.0 (1.16.x emits 0.5.0). Never hardcode.
    if nvidia-ctk cdi generate --help 2>&1 | grep -q -- '--cdi-version'; then
      "${SUDO[@]}" nvidia-ctk cdi generate --cdi-version=0.6.0 --output=/etc/cdi/nvidia.yaml
    else
      "${SUDO[@]}" nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    fi
    spec_ver="$(grep -i cdiversion /etc/cdi/nvidia.yaml | head -1 | grep -oP '[0-9.]+')"
    say "  emitted CDI spec version: ${spec_ver:-unknown}"
    if podman run --rm --device nvidia.com/gpu=all docker.io/library/ubuntu nvidia-smi -L >/dev/null 2>&1; then
      ok "GPU passthrough now resolves (spec $spec_ver)"
    else
      die "GPU still unresolvable after regen (spec $spec_ver). Toolkit likely emits a version > Podman's ceiling; downgrade nvidia-container-toolkit (e.g. 1.16.2) and re-run."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 9b. NPU: confirm the amdxdna device node is present on the host, and be
# explicit that passthrough != a working NPU model stack.
# ---------------------------------------------------------------------------
if [ "$WANT_NPU" = y ]; then
  step "NPU / amdxdna"
  [ -e /dev/accel/accel0 ] || die "NPU requested but /dev/accel/accel0 is absent. Load the amdxdna driver, then re-run (check: lsmod | grep amdxdna; ls /dev/accel)."
  lsmod 2>/dev/null | grep -q amdxdna || warn "amdxdna not seen in lsmod, but /dev/accel/accel0 exists — proceeding."
  ok "NPU device present; passed via runArgs --device=/dev/accel/accel0 (render gid ${RENDER_GID:-unknown})"
  warn "Passthrough exposes the NPU device ONLY. Running PaddleOCR/LiLT *on* the NPU also needs the AMD Ryzen AI runtime (XRT + amdxdna userspace + ONNXRuntime Vitis-AI EP) and XDNA2-compiled models installed INSIDE the container (its Dockerfile / post-create). The wizard does not install those."
fi

# ---------------------------------------------------------------------------
# 9c. iGPU: confirm the DRI/KFD nodes exist; passthrough is the prerequisite,
# not the ROCm stack (that's an in-container wheel matched to the host driver).
# ---------------------------------------------------------------------------
if [ "$WANT_IGPU" = y ]; then
  step "iGPU / ROCm"
  [ -e /dev/kfd ]      || die "iGPU requested but /dev/kfd is absent — amdgpu/amdkfd not loaded. Check: ls /dev/kfd /dev/dri; lsmod | grep amdgpu."
  [ -d /dev/dri ]      || die "iGPU requested but /dev/dri is absent. Check: ls /dev/dri."
  ok "iGPU nodes present; passed via runArgs --device=/dev/dri --device=/dev/kfd (video gid ${IGPU_VIDEO_GID:-?}, render gid ${IGPU_RENDER_GID:-?})"
  if [ ! -r /dev/kfd ] || [ ! -w /dev/kfd ]; then
    warn "/dev/kfd may need a host udev rule for group access — as root: echo 'SUBSYSTEM==\"kfd\", GROUP=\"render\", MODE=\"0666\"' > /etc/udev/rules.d/70-kfd.rules && udevadm control --reload && udevadm trigger"
  fi
  warn "Passthrough is the PREREQUISITE only. Using the iGPU needs a ROCm-matched torch/ONNXRuntime wheel INSIDE the container (gfx1152 needs ROCm 7.13+, torch from repo.amd.com/rocm/whl/gfx1152/) and its userspace must match the host amdgpu/amdkfd. The wizard does not install those."
fi

# ---------------------------------------------------------------------------
# 10. git init (optional)
# ---------------------------------------------------------------------------
if [ "$WANT_GIT" = y ] && [ ! -d "$HOST_REPO_PATH/.git" ]; then
  step "git init"
  ( cd "$HOST_REPO_PATH" && git init -q && git add -A && git -c user.name="$MACHINE_GIT_NAME" -c user.email="$MACHINE_GIT_EMAIL" commit -qm "Containerised scaffold (capsule)" )
  ok "git initialised + first commit"
fi

# ---------------------------------------------------------------------------
# 11. build the container (CLI, never the extension UI) + verify isolation
# ---------------------------------------------------------------------------
step "Build container"
if ask_yn "Build + open the container now (devpod up --ide codium)?" y; then
  # Existing workspace? DevPod caches the parsed config, so a plain re-up would
  # reuse the OLD Dockerfile/devcontainer.json and silently ignore everything we
  # just re-scaffolded. Force-delete any existing workspace first so the rebuild
  # always applies the fresh config + image. Repo files are bind-mounted, so
  # nothing in the project is lost. No-op (silent) on a first-time creation.
  if "$DEVPOD" delete "$SANITIZED" --force >/dev/null 2>&1; then
    say "  existing workspace '$SANITIZED' removed — recreating with the new config"
  fi
  # First creation MUST point DevPod at the local folder PATH, not the bare
  # workspace name — a bare name is read as a git source (https://<name>) and the
  # clone fails. DevPod derives the workspace id from the folder name.
  # Stream build output LIVE so long installs/model fetches visibly progress —
  # do NOT pipe through tail (it buffers everything until EOF, so the terminal
  # looks frozen for minutes, and pipefail would read tail's exit code, masking a
  # devpod failure). Direct output preserves both live progress and exit status.
  "$DEVPOD" up "$HOST_REPO_PATH" --ide codium 2>&1 || warn "devpod up returned non-zero — see output above"
  step "Verify isolation"
  # pgrep -x, NOT -f: the ssh remote shell's own cmdline contains "synochat",
  # so -f self-matches and reports HOST-VISIBLE even in an isolated container.
  if ssh "$SANITIZED.devpod" 'pgrep -x synochat >/dev/null 2>&1 && echo HOST-VISIBLE || echo ISOLATED' 2>/dev/null | grep -q ISOLATED; then
    ok "process namespace ISOLATED (no --pid=host) — open-remote-ssh will attach cleanly"
  else
    warn "could not confirm isolation over ssh (container may still be starting)"
  fi
  if [ "$DEPLOY_TAGDEXER" = y ]; then
  if ssh "$SANITIZED.devpod" 'node /workspaces/'"$SANITIZED"'/tagdexer/indexer.js --list-tags 2>/dev/null | grep -qi shared && echo SHARED || echo LOCAL-ONLY' 2>/dev/null | grep -q SHARED; then
    ok "tagdexer shared-vocabulary layer ACTIVE in container"
  else
    warn "tagdexer shared layer not confirmed — check .tagdexerrc genericPath + tagdexer-source mount"
  fi
  fi
  if [ "$WANT_NPU" = y ]; then
    if ssh "$SANITIZED.devpod" 'test -e /dev/accel/accel0 && echo NPU-OK || echo NPU-MISSING' 2>/dev/null | grep -q NPU-OK; then
      ok "NPU /dev/accel/accel0 visible inside the container"
    else
      warn "NPU device NOT visible in container — check runArgs (--device=/dev/accel/accel0), SELinux (label=disable), and host /dev/accel/accel0"
    fi
  fi
  if [ "$WANT_IGPU" = y ]; then
    if ssh "$SANITIZED.devpod" 'test -e /dev/kfd && test -d /dev/dri && echo IGPU-OK || echo IGPU-MISSING' 2>/dev/null | grep -q IGPU-OK; then
      ok "iGPU /dev/dri + /dev/kfd visible inside the container"
    else
      warn "iGPU nodes NOT visible in container — check runArgs (--device=/dev/dri --device=/dev/kfd), label=disable, and the /dev/kfd udev rule"
    fi
  fi
  if [ "$CLIP_OK" = y ]; then
    if ssh "$SANITIZED.devpod" 'command -v wl-paste >/dev/null 2>&1 || { echo CLIP-NOWL; exit 0; }; o=$(wl-paste --list-types 2>&1); echo "$o" | grep -qi "failed to connect\|connection refused" && echo CLIP-NOCONN || echo CLIP-OK' 2>/dev/null | grep -q CLIP-OK; then
      ok "host clipboard reachable in container (wl-paste connects to the host compositor; image/png will paste into Grok)"
    else
      warn "clipboard not confirmed — wl-paste missing or could not connect. Check the wayland-0 mount + label=disable, and that the IDE was launched from the graphical session"
    fi
  fi
else
  say "  Skipped. Build later with: $DEVPOD up $SANITIZED --ide codium"
fi

step "Done"
say "  $REPO_NAME is scaffolded. First agent chat in the container will auto-onboard"
say "  (decision log + tagdexer + taskboard, driven by the hooks)."
say ""
say "  If the VSCodium window errors on attach, see README 'Troubleshooting'."
