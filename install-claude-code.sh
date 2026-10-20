#!/usr/bin/env bash
# Install /signup into Claude Code. It finishes the events your OpenClaw agent
# queued, in your own Chrome (Claude in Chrome). Run it on the computer where you
# use Claude Code and Chrome.
#
#   ./install-claude-code.sh                     install as /signup
#   ./install-claude-code.sh --queue-dir <dir>   where the queue is (default ~/.openclaw-signup)
#   ./install-claude-code.sh --name <name>       install as /<name> instead
#   ./install-claude-code.sh --force             replace a skill or command of that name
#                                                that this installer did not create
#
# Installs into $CLAUDE_CONFIG_DIR/skills/<name>, else ~/.claude/skills/<name>.
# Works on macOS and Linux (bash + awk).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/claude/signup/SKILL.md.tmpl"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
NAME="signup"
QUEUE_DIR="~/.openclaw-signup"
FORCE=0
MARK=".installed-by-openclaw-signup"

die() { echo "install-claude-code: $*" >&2; exit 1; }
warn() { echo "install-claude-code: warning - $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --queue-dir)
      [ $# -ge 2 ] || die "--queue-dir needs a directory"
      case "$2" in "~"|"~/"*|/*) QUEUE_DIR="$2" ;; *) QUEUE_DIR="$PWD/$2" ;; esac
      shift 2 ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a name"
      NAME="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || die "--name must be lowercase letters, digits and hyphens: $NAME"
TARGET="$CLAUDE_DIR/skills/$NAME"

# ---- never clobber something this installer did not create -------------------
if [ $FORCE -eq 0 ]; then
  if [ -e "$TARGET" ] && [ ! -f "$TARGET/$MARK" ]; then
    die "$TARGET already exists and was not installed by this repo.
  Install under another name with --name <name>, or replace it with --force."
  fi
  if [ -e "$CLAUDE_DIR/commands/$NAME.md" ]; then
    die "you already have a /$NAME command ($CLAUDE_DIR/commands/$NAME.md); two /$NAME would clash.
  Install under another name with --name <name>, or use --force to install anyway."
  fi
fi

# ---- build into a temp dir next to the target, then swap it in ---------------
mkdir -p "$CLAUDE_DIR/skills" || die "cannot create $CLAUDE_DIR/skills"
STAGE="$(mktemp -d "$CLAUDE_DIR/skills/.$NAME.tmp.XXXXXX")" || die "cannot create a temp dir"
trap 'rm -rf "$STAGE"' EXIT

# Literal (not regex) replacement; values come through ENVIRON so awk does not
# interpret backslashes in paths.
SK_NAME="$NAME" SK_SIGNUPQ="$TARGET/signupq" awk '
  function rep(s, a, b,   i, out) {
    out = ""
    while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
    return out s
  }
  { $0 = rep($0, "{{NAME}}", ENVIRON["SK_NAME"]); print rep($0, "{{SIGNUPQ}}", ENVIRON["SK_SIGNUPQ"]) }
' "$TEMPLATE" > "$STAGE/SKILL.md" || die "rendering failed"
grep -q '{{' "$STAGE/SKILL.md" && die "render left a {{...}} marker"

cp "$HERE/queue/signupq" "$HERE/queue/queue.py" "$STAGE/" || die "could not copy the queue scripts"
printf '%s\n' "$QUEUE_DIR" > "$STAGE/queue-dir"
echo "This skill is managed by openclaw-signup/install-claude-code.sh; re-run it to update." > "$STAGE/$MARK"

rm -rf "$TARGET" && mv "$STAGE" "$TARGET" || die "could not install into $TARGET"
trap - EXIT

# ---- report -------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || warn "python3 not found - /$NAME needs it to read the queue."
q="$(bash "$TARGET/signupq" where 2>/dev/null)"; qdir="$(dirname "$q")"
top="$(git -C "$qdir" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$qdir" && pwd -P)" ] \
   && git -C "$qdir" remote | grep -q .; then   # same rule as signupq's git mode
  mode="git ($(git -C "$qdir" remote get-url "$(git -C "$qdir" remote | head -1)" 2>/dev/null))"
elif [ -d "$qdir" ]; then
  mode="local folder"
else
  mode="local folder, created by the first handoff"
fi
cat <<EOF
installed /$NAME -> $TARGET
  queue: $qdir ($mode)

Next: start Claude Code with Chrome connected (claude --chrome, or /chrome in a
session) and type /$NAME whenever your agent says an event was queued.
EOF
