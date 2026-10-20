#!/usr/bin/env bash
# Build the event-signup skill from your profile and install it into OpenClaw.
#
#   ./install.sh                     install for all agents; route links via the default agent
#   ./install.sh --agent <id>        install for one agent only
#   ./install.sh --render-only       only build build/event-signup/SKILL.md (no OpenClaw needed)
#   ./install.sh --profile <file>    use another profile file (default: ./profile.md)
#   ./install.sh --no-routing        do not touch the agent's AGENTS.md (see README)
#
# The profile is inlined into SKILL.md at build time, so the agent never reads a
# profile file at runtime and needs no file tools - only the browser. Re-run this
# after every profile change. Works on macOS and Linux (bash + awk; node for JSON).
set -uo pipefail

SLUG="event-signup"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/skill/SKILL.md.tmpl"
PROFILE="$HERE/profile.md"
# Build inside the repo, not /tmp: a gateway running under systemd with
# PrivateTmp cannot see the CLI's /tmp, and the install then fails with
# "Skill path not found".
BUILD="$HERE/build/$SLUG"
AGENT=""
RENDER_ONLY=0
ROUTING=1

die() { echo "install: $*" >&2; exit 1; }
warn() { echo "install: warning - $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || die "--profile needs a file"
      PROFILE="$2"; shift 2 ;;
    --agent)
      [ $# -ge 2 ] || die "--agent needs an agent id"
      AGENT="$2"; shift 2 ;;
    --render-only) RENDER_ONLY=1; shift ;;
    --no-routing) ROUTING=0; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---- check the profile ------------------------------------------------------
if [ ! -f "$PROFILE" ]; then
  die "no profile at $PROFILE
  Create it with:  cp profile.example.md profile.md   then fill it in."
fi
if grep -q '<!-- TEMPLATE:' "$PROFILE"; then
  die "$PROFILE still has the TEMPLATE line at the top.
  Replace the example values with your own, then delete that line."
fi
for key in name email; do
  grep -Eq "^[[:space:]]*$key:[[:space:]]*[^[:space:]#]" "$PROFILE" \
    || die "$PROFILE has no value for '$key:' (needed on every form)."
done
if grep -n '—' "$PROFILE" >/dev/null; then
  warn "em-dashes in $PROFILE (the skill types hyphens only):"
  grep -n '—' "$PROFILE" | sed 's/^/  line /' >&2
fi

# ---- render SKILL.md ----------------------------------------------------------
# Replace the {{PROFILE}} line with the profile, dropping HTML comments (which
# may span lines), leading blank lines, and runs of blank lines.
rm -rf "$BUILD" && mkdir -p "$BUILD" || die "cannot create $BUILD"
awk -v prof="$PROFILE" '
  function emit(s) {
    if (s ~ /^[ \t]*$/) { if (started) blank = 1; return }
    if (blank) print ""
    print s; started = 1; blank = 0
  }
  $0 == "{{PROFILE}}" {
    incomment = 0
    while ((getline line < prof) > 0) {
      out = ""; rest = line; hadcomment = 0
      while (rest != "") {
        if (incomment) {
          p = index(rest, "-->")
          if (p == 0) { rest = ""; break }
          rest = substr(rest, p + 3); incomment = 0
        } else {
          p = index(rest, "<!--")
          if (p == 0) { out = out rest; break }
          out = out substr(rest, 1, p - 1); rest = substr(rest, p + 4)
          incomment = 1; hadcomment = 1
        }
      }
      # a line that held only (part of) a comment is dropped, not left blank
      if ((hadcomment || incomment) && out ~ /^[ \t]*$/) continue
      emit(out)
    }
    close(prof); found = 1; next
  }
  { print }
  END { if (!found) exit 3 }
' "$TEMPLATE" > "$BUILD/SKILL.md"
rc=$?
[ $rc -eq 3 ] && die "template has no {{PROFILE}} line: $TEMPLATE"
[ $rc -eq 0 ] || die "rendering failed (awk exit $rc)"
grep -q '{{PROFILE}}' "$BUILD/SKILL.md" && die "render left a {{PROFILE}} marker in $BUILD/SKILL.md"

echo "built $BUILD/SKILL.md"
[ $RENDER_ONLY -eq 1 ] && exit 0

# ---- install into OpenClaw --------------------------------------------------
command -v openclaw >/dev/null 2>&1 \
  || die "openclaw is not on PATH. Install OpenClaw first, or use --render-only."

# Run an openclaw command for the chosen agent, or with no agent (the default).
# Not an array: bash 3.2 (macOS) aborts on an empty "${arr[@]}" under set -u.
oc() {
  if [ -n "$AGENT" ]; then openclaw "$@" --agent "$AGENT"; else openclaw "$@"; fi
}

if [ -n "$AGENT" ]; then
  echo "installing into OpenClaw for agent '$AGENT' ..."
  out="$(oc skills install "$BUILD" --as "$SLUG" --force 2>&1)"; rc=$?
else
  echo "installing into OpenClaw for all agents ..."
  out="$(oc skills install "$BUILD" --as "$SLUG" --force --global 2>&1)"; rc=$?
fi
if [ $rc -ne 0 ]; then
  echo "$out" >&2
  die "openclaw skills install failed (exit $rc)"
fi

# Assert the model can actually see it - a successful copy is not enough.
info="$(oc skills info "$SLUG" 2>&1)"
if ! printf '%s\n' "$info" | grep -q 'Visible to model: yes'; then
  printf '%s\n' "$info" >&2
  die "installed, but OpenClaw does not show the skill as visible to the model (see above)."
fi
printf '%s\n' "$info" | grep -E 'Ready|Path:|Visible to model' | sed 's/^ *//; s/^/  /'

# ---- route event links to the skill (AGENTS.md) -------------------------------
# With the claude-cli runtime, OpenClaw skills reach the model by name only, not
# with their description, so a bare event link never triggers the skill on its
# own. A short block in the agent's AGENTS.md (loaded every turn, by every
# runtime) names the skill and its path. Kept between markers so re-runs replace
# it instead of adding another copy.
START_MARK="<!-- $SLUG:start"
END_MARK="<!-- $SLUG:end -->"

route() {
  command -v node >/dev/null 2>&1 || { warn "node not on PATH, cannot find the agent workspace"; return 1; }
  local workspace skill_path agents_md block tmp
  workspace="$(openclaw agents list --json 2>/dev/null | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const i = s.search(/^\[/m); if (i < 0) process.exit(2);
      const list = JSON.parse(s.slice(i)), want = process.argv[1];
      const a = want ? list.find(x => x.id === want) : (list.find(x => x.isDefault) || list[0]);
      if (!a || !a.workspace) process.exit(3);
      console.log(a.workspace);
    });' "$AGENT")" || { warn "could not read the agent workspace from 'openclaw agents list --json'"; return 1; }
  skill_path="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -1)"
  case "$skill_path" in "~/"*) skill_path="$HOME/${skill_path#\~/}" ;; esac
  [ -n "$skill_path" ] || skill_path="the $SLUG skill's SKILL.md"
  agents_md="$workspace/AGENTS.md"
  block="$START_MARK - added by openclaw-signup/install.sh; re-run it to update, delete this block to remove -->
## Event signups

When the user sends an event, registration, waitlist or RSVP link - even a bare
link with no other text - sign them up with the \`$SLUG\` skill: read
\`$skill_path\` and follow it. It holds their details; do not ask for anything
it already covers.
$END_MARK"

  if [ ! -f "$agents_md" ]; then
    warn "no AGENTS.md in $workspace - add this block to your agent's instructions by hand:"
    printf '\n%s\n\n' "$block" >&2
    return 1
  fi
  if grep -qF "$START_MARK" "$agents_md" && ! grep -qF "$END_MARK" "$agents_md"; then
    warn "$agents_md has a '$START_MARK' line but no end marker - fix it by hand; left unchanged"
    return 1
  fi
  # Drop any old block and the blank lines trailing the file, then append the new block.
  tmp="$agents_md.tmp.$$"
  awk -v s="$START_MARK" -v e="$END_MARK" '
    index($0, s) == 1 { skip = 1; next }
    skip { if (index($0, e) == 1) skip = 0; next }
    /^[ \t]*$/ { blanks = blanks "\n"; next }
    { printf "%s", blanks; blanks = ""; print }
  ' "$agents_md" > "$tmp" && printf '\n%s\n' "$block" >> "$tmp" \
    && cat "$tmp" > "$agents_md"  # cat, not mv: keeps the file's owner and mode
  rc=$?; rm -f "$tmp"
  [ $rc -eq 0 ] || { warn "could not update $agents_md"; return 1; }
  echo "  routing: event links -> $SLUG, via $agents_md"
}

if [ $ROUTING -eq 1 ]; then
  route || warn "the skill is installed, but bare event links may not reach it (see README, 'Routing')."
fi

cat <<'EOF'

Done. Next:
  - Start a fresh chat with your agent (send /new) so it loads the skill.
  - Send it an event link to test.
  - First time only: log the OpenClaw browser into Luma (see README, "Log the browser in").
EOF
