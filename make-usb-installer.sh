#!/usr/bin/env bash
# ============================================================================
# make-usb-installer.sh — build the single-file, portable bootstrap installer.
#
# WHY THIS EXISTS
#   wizard.sh installs FROM payload/ and MOUNTS two sibling repos (tagdexer,
#   setsquare). On a fresh machine none of those exist. This builder packs all
#   three repos into ONE self-extracting script — capsule-install.sh — that you drop
#   on a USB stick, run from anywhere, and it lays down the core files a new host
#   needs before wizard.sh can do its job.
#
#   Run this on a machine that HAS the three repos. It emits capsule-install.sh.
#   Copy that one file to the target machine and run it. That's the whole loop.
#
# WHAT'S PACKED (and what's not)
#   Included: capsule/, tagdexer/, setsquare/ — the wizard, its
#   payload, and the two mount-sources (incl. their prebuilt *.vsix).
#   Excluded: .git and node_modules. node_modules is ~194M of build-time deps;
#   the shipped *.vsix are already bundled and the copied CLI files are plain
#   node scripts, so the runtime never needs it. Keeps the installer ~18M.
# ============================================================================
set -euo pipefail

BUILDER_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$(dirname "$BUILDER_DIR")}"
OUT="${1:-$BUILDER_DIR/capsule-install.sh}"
REPOS=(capsule tagdexer setsquare)

c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_ylw" "$c_off" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for r in "${REPOS[@]}"; do
  [ -d "$REPOS_ROOT/$r" ] || die "source repo not found: $REPOS_ROOT/$r"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PAYLOAD_TGZ="$TMP/payload.tgz"

echo "Packing ${REPOS[*]} from $REPOS_ROOT ..."
tar czf "$PAYLOAD_TGZ" \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='capsule-install.sh' \
  --exclude='*.tar.gz' \
  -C "$REPOS_ROOT" "${REPOS[@]}"

RAW_SIZE="$(du -h "$PAYLOAD_TGZ" | cut -f1)"

# --- write the bootstrap header, then the base64 payload after a marker -------
cat > "$OUT" <<'BOOTSTRAP'
#!/usr/bin/env bash
# ============================================================================
# capsule-install.sh — self-extracting, portable bootstrap for the DevPod/Podman/
# VSCodium wizard. ONE file. Run it from anywhere (USB included):
#
#     ./capsule-install.sh                 # extract to $HOME/repos (default)
#     ./capsule-install.sh -d /some/root   # extract to a root you choose
#     ./capsule-install.sh -y              # extract, then run wizard.sh immediately
#     ./capsule-install.sh -h              # help
#
# It lays down three sibling repos under <root>/:
#     capsule/  tagdexer/  setsquare/
# then wizard.sh (which derives REPOS_ROOT from its own location) just works.
# ============================================================================
set -euo pipefail

DEST="${CAPSULE_DEST:-$HOME/repos}"
RUN_WIZARD=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dest) DEST="${2:?--dest needs a path}"; shift 2 ;;
    -y|--run)  RUN_WIZARD=1; shift ;;
    -h|--help)
      sed -n '3,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (try -h)" >&2; exit 1 ;;
  esac
done

c_bold=$'\e[1m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_ylw" "$c_off" "$*"; }

command -v tar    >/dev/null || { echo "need: tar" >&2; exit 1; }
command -v base64 >/dev/null || { echo "need: base64" >&2; exit 1; }

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# Guard: don't silently clobber an existing install.
EXISTING=()
for r in capsule tagdexer setsquare; do
  [ -e "$DEST/$r" ] && EXISTING+=("$r")
done
if [ "${#EXISTING[@]}" -gt 0 ]; then
  warn "already present in $DEST: ${EXISTING[*]}"
  printf '  overwrite them? [y/N] '
  read -r reply
  case "$reply" in y|Y) ;; *) echo "aborted."; exit 1 ;; esac
fi

printf '%s== extracting to %s ==%s\n' "$c_bold" "$DEST" "$c_off"
PAYLOAD_LINE=$(awk '/^__CAPSULE_PAYLOAD__$/{print NR+1; exit}' "$0")
tail -n +"$PAYLOAD_LINE" "$0" | base64 -d | tar xzf - -C "$DEST"

for r in capsule tagdexer setsquare; do
  [ -d "$DEST/$r" ] && ok "$r" || { echo "extraction failed: $r missing" >&2; exit 1; }
done
chmod +x "$DEST/capsule/wizard.sh" 2>/dev/null || true

WIZ="$DEST/capsule/wizard.sh"
if [ "$RUN_WIZARD" -eq 1 ]; then
  printf '%s== running wizard ==%s\n' "$c_bold" "$c_off"
  exec "$WIZ"
fi

cat <<EOF

${c_grn}Core files installed.${c_off} Next, on this host:

    cd $DEST/capsule
    ./wizard.sh

The wizard derives REPOS_ROOT from its own location ($DEST), so the
tagdexer/ and setsquare/ mounts resolve with no edits. Keep the three siblings.
EOF
exit 0

__CAPSULE_PAYLOAD__
BOOTSTRAP

base64 "$PAYLOAD_TGZ" >> "$OUT"
chmod +x "$OUT"

OUT_SIZE="$(du -h "$OUT" | cut -f1)"
ok "built $OUT"
ok "payload $RAW_SIZE compressed -> installer $OUT_SIZE"
echo
echo "Copy that one file to the target machine and run it."
