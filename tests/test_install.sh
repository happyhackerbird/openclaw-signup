#!/usr/bin/env bash
# Tests for install.sh. Each test runs a copy of the repo in a temp dir, so the
# real build/ and profile.md are never touched. OpenClaw is replaced by a stub
# on PATH that logs its arguments. Needs node (as OpenClaw does).
# Run: bash tests/test_install.sh (exit 0 = green).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node)" || { echo "FAIL: node not found (OpenClaw needs it too)"; exit 1; }
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# Fresh sandbox: repo copy, two agent workspaces, and a PATH holding only the
# openclaw stub, node and system tools. STUB_VISIBLE / STUB_INSTALL_RC steer the
# stub; it logs each call to $OC_LOG.
new_sandbox() {
  T="$(mktemp -d)"
  mkdir -p "$T/repo" "$T/bin" "$T/ws-main" "$T/ws-work"
  cp -R "$ROOT/install.sh" "$ROOT/skill" "$ROOT/queue" "$ROOT/profile.example.md" "$T/repo/"
  grep -v '<!-- TEMPLATE:' "$ROOT/profile.example.md" > "$T/repo/profile.md"
  printf '%s\n' "# AGENTS.md" "" "Be helpful." > "$T/ws-main/AGENTS.md"
  printf '%s\n' "# AGENTS.md (work)" > "$T/ws-work/AGENTS.md"
  ln -s "$NODE" "$T/bin/node"
  cat > "$T/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$OC_LOG"
case "$1 $2" in
  "skills install") exit "${STUB_INSTALL_RC:-0}" ;;
  "skills info") echo "📝 event-signup ✓ Ready"
                 echo "  Path: ~/.openclaw/skills/event-signup/SKILL.md"
                 echo "  Visible to model: ${STUB_VISIBLE:-yes}" ;;
  "agents list") echo "Config warnings: [plugins] something"   # noise before the JSON
                 printf '[\n {"id": "main", "workspace": "%s", "isDefault": true},\n' "$WS_MAIN"
                 printf ' {"id": "work", "workspace": "%s", "isDefault": false}\n]\n' "$WS_WORK" ;;
esac
STUB
  chmod +x "$T/bin/openclaw"
  export OC_LOG="$T/oc.log" WS_MAIN="$T/ws-main" WS_WORK="$T/ws-work"
  : > "$OC_LOG"
}
run() { PATH="$T/bin:/usr/bin:/bin" bash "$T/repo/install.sh" "$@" 2>&1; }
skill() { cat "$T/repo/build/event-signup/SKILL.md"; }
profile_part() { sed -n '/^## Profile$/,$p' "$T/repo/build/event-signup/SKILL.md"; }
blocks() { grep -c '^<!-- event-signup:start' "$1"; }

# 1. the example profile renders into a complete skill
new_sandbox
out="$(run --render-only)" || fail "render-only exited non-zero: $out"
[ "$(skill | head -1)" = "---" ] || fail "SKILL.md does not start with frontmatter"
skill | grep -q '^name: event-signup$' || fail "frontmatter name missing"
skill | grep -q 'alex@example.com' || fail "profile email not inlined"
skill | grep -q '{{PROFILE}}' && fail "{{PROFILE}} marker left in output"
skill | grep -q '<!--\|-->' && fail "HTML comment left in output"
[ "$(profile_part | sed -n '2p')" = "" ] && [ "$(profile_part | sed -n '3p')" = "### Contact details" ] \
  || fail "profile does not start right after '## Profile' + one blank line"
[ -s "$OC_LOG" ] && fail "render-only called openclaw: $(cat "$OC_LOG")"
ok "example profile renders"

# 2. comments: inline ones are cut, multi-line ones vanish, blank runs collapse
new_sandbox
printf '%s\n' "### Contact details" "" "name: A <!-- inline --> B" "email: a@b.c" "" "<!-- one" \
  "two" "three -->" "" "" "after" "<!-- whole line -->" "end" > "$T/repo/profile.md"
run --render-only >/dev/null || fail "render with comments failed"
profile_part | grep -q '^name: A  B$' || fail "inline comment not cut correctly"
profile_part | grep -q 'two\|three\|whole line' && fail "comment text leaked"
profile_part | awk 'prev=="" && $0=="" && NR>1 {bad=1} {prev=$0} END {exit bad}' \
  || fail "consecutive blank lines in profile section"
profile_part | grep -A1 '^after$' | grep -q '^end$' || fail "comment-only line left a gap"
ok "comments stripped, blank lines collapsed"

# 3. refuses an unedited template
new_sandbox
cp "$ROOT/profile.example.md" "$T/repo/profile.md"
out="$(run --render-only)" && fail "unedited template accepted"
echo "$out" | grep -q 'TEMPLATE line' || fail "no TEMPLATE message: $out"
ok "refuses unedited template"

# 4. refuses a missing profile, and a profile without an email value
new_sandbox
rm "$T/repo/profile.md"
out="$(run --render-only)" && fail "missing profile accepted"
echo "$out" | grep -q 'cp profile.example.md profile.md' || fail "no copy hint: $out"
new_sandbox
printf '%s\n' "name: A" "email:     # fill me" > "$T/repo/profile.md"
out="$(run --render-only)" && fail "empty email accepted"
echo "$out" | grep -q "no value for 'email:'" || fail "no email message: $out"
ok "refuses missing profile and empty email"

# 5. em-dashes warn but do not block
new_sandbox
printf '%s\n' "name: A" "email: a@b.c" "Builds things — fast" > "$T/repo/profile.md"
out="$(run --render-only)" || fail "em-dash blocked the build: $out"
echo "$out" | grep -q 'em-dashes' || fail "no em-dash warning: $out"
ok "em-dash warns"

# 6. default install: global, forced, as event-signup, from build/
new_sandbox
out="$(run)" || fail "install failed: $out"
grep -q "^skills install $T/repo/build/event-signup --as event-signup --force --global$" "$OC_LOG" \
  || fail "unexpected install call: $(cat "$OC_LOG")"
grep -q '^skills info event-signup$' "$OC_LOG" || fail "no visibility check: $(cat "$OC_LOG")"
echo "$out" | grep -q 'Visible to model: yes' || fail "result not shown: $out"
ok "global install + visibility check"

# 7. --agent installs for that agent only (and is not combined with --global)
new_sandbox
out="$(run --agent work)" || fail "agent install failed: $out"
grep -q "^skills install $T/repo/build/event-signup --as event-signup --force --agent work$" "$OC_LOG" \
  || fail "unexpected agent install call: $(cat "$OC_LOG")"
grep -q -- '--global' "$OC_LOG" && fail "--agent run also passed --global"
grep -q '^skills info event-signup --agent work$' "$OC_LOG" || fail "agent visibility check missing"
ok "per-agent install"

# 8. a failed install or an invisible skill fails loudly
new_sandbox
out="$(STUB_INSTALL_RC=1 run)" && fail "failed install reported success"
echo "$out" | grep -q 'install failed' || fail "no install-failed message: $out"
new_sandbox
out="$(STUB_VISIBLE=no run)" && fail "invisible skill reported success"
echo "$out" | grep -q 'not show the skill as visible' || fail "no visibility message: $out"
ok "failures are loud"

# 9. no openclaw on PATH: install explains
new_sandbox
rm "$T/bin/openclaw"
out="$(run)" && fail "install without openclaw reported success"
echo "$out" | grep -q 'openclaw is not on PATH' || fail "no PATH message: $out"
ok "missing openclaw explained"

# 10. routing: block goes into the DEFAULT agent's AGENTS.md, with the expanded path,
#     below the user's own text; a re-run leaves the file byte-identical
new_sandbox
run >/dev/null || fail "install failed"
A="$WS_MAIN/AGENTS.md"
[ "$(blocks "$A")" = "1" ] || fail "expected 1 routing block, got $(blocks "$A")"
grep -qF "\`$HOME/.openclaw/skills/event-signup/SKILL.md\`" "$A" || fail "skill path not expanded in block: $(cat "$A")"
[ "$(head -3 "$A")" = "$(printf '%s\n' "# AGENTS.md" "" "Be helpful.")" ] || fail "user text changed: $(cat "$A")"
[ "$(tail -1 "$A")" = "<!-- event-signup:end -->" ] || fail "block not at the end"
grep -q 'Be helpful' "$WS_WORK/AGENTS.md" && fail "non-default agent touched"
cp "$A" "$T/first"
run >/dev/null || fail "second install failed"
cmp -s "$A" "$T/first" || fail "re-run changed AGENTS.md: $(diff "$T/first" "$A")"
ok "routing block added once, idempotent"

# 11. routing follows --agent, and an old block is replaced while text after it is kept
new_sandbox
printf '%s\n' "# work" "" "<!-- event-signup:start old -->" "stale" "<!-- event-signup:end -->" "" "My own rule." \
  > "$WS_WORK/AGENTS.md"
cp "$WS_MAIN/AGENTS.md" "$T/main-before"
run --agent work >/dev/null || fail "agent install failed"
W="$WS_WORK/AGENTS.md"
[ "$(blocks "$W")" = "1" ] || fail "expected 1 block in work AGENTS.md"
grep -q 'stale' "$W" && fail "old block not replaced"
grep -q '^My own rule\.$' "$W" || fail "user text after the old block lost"
cmp -s "$WS_MAIN/AGENTS.md" "$T/main-before" || fail "--agent work touched the main workspace"
ok "routing per agent, old block replaced, user text kept"

# 12. --no-routing leaves AGENTS.md alone and never looks up agents
new_sandbox
cp "$WS_MAIN/AGENTS.md" "$T/before"
run --no-routing >/dev/null || fail "--no-routing install failed"
cmp -s "$WS_MAIN/AGENTS.md" "$T/before" || fail "--no-routing changed AGENTS.md"
grep -q '^agents list' "$OC_LOG" && fail "--no-routing still listed agents"
ok "--no-routing"

# 13. no AGENTS.md: installs anyway, prints the block, creates nothing
new_sandbox
rm "$WS_MAIN/AGENTS.md"
out="$(run)" || fail "missing AGENTS.md made the install fail: $out"
echo "$out" | grep -q 'add this block' || fail "no hand-add hint: $out"
echo "$out" | grep -q 'event-signup:end' || fail "block not printed: $out"
[ -e "$WS_MAIN/AGENTS.md" ] && fail "AGENTS.md was created"
ok "missing AGENTS.md handled"

# 14. a start marker without an end marker is never 'repaired' (would eat user text)
new_sandbox
printf '%s\n' "# x" "<!-- event-signup:start" "my notes" "more notes" > "$WS_MAIN/AGENTS.md"
cp "$WS_MAIN/AGENTS.md" "$T/before"
out="$(run)" || fail "broken marker made the install fail: $out"
cmp -s "$WS_MAIN/AGENTS.md" "$T/before" || fail "AGENTS.md with a broken marker was rewritten"
echo "$out" | grep -q 'no end marker' || fail "no broken-marker warning: $out"
ok "broken marker left alone"

# 15. the build carries the handoff scripts; queue-dir defaults to ~/.openclaw-signup,
#     --queue-dir is kept as given (~ or absolute) and relative paths become absolute
new_sandbox
run --render-only >/dev/null || fail "render failed"
B="$T/repo/build/event-signup/scripts"
for f in handoff.sh signupq queue.py; do [ -f "$B/$f" ] || fail "build lacks scripts/$f"; done
[ "$(cat "$B/queue-dir")" = "~/.openclaw-signup" ] || fail "default queue-dir: $(cat "$B/queue-dir")"
skill | grep -q 'bash {baseDir}/scripts/handoff.sh' || fail "skill does not call handoff.sh via bash"
run --render-only --queue-dir /srv/q >/dev/null; [ "$(cat "$B/queue-dir")" = "/srv/q" ] || fail "absolute queue-dir"
run --render-only --queue-dir "~/q" >/dev/null; [ "$(cat "$B/queue-dir")" = "~/q" ] || fail "~ queue-dir"
( cd "$T" && PATH="$T/bin:/usr/bin:/bin" bash "$T/repo/install.sh" --render-only --queue-dir rel/q >/dev/null 2>&1 )
[ "$(cat "$B/queue-dir")" = "$(cd "$T" && pwd)/rel/q" ] || fail "relative queue-dir not made absolute: $(cat "$B/queue-dir")"
ok "build carries handoff scripts + queue-dir"

if [ $FAILS -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$FAILS FAILURE(S)"; exit 1; fi
