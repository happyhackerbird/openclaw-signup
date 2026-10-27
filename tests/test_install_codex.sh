#!/usr/bin/env bash
# Tests for install-codex.sh, plus one test that runs both installs against one
# queue: an OpenClaw handoff must show up in $signup's list.
# Every run uses a temp CODEX_HOME; the real ~/.codex is never touched.
# Run: bash tests/test_install_codex.sh (exit 0 = green).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

new_home() { C="$(mktemp -d)/codex"; export CODEX_HOME="$C"; }
inst() { bash "$ROOT/install-codex.sh" "$@" 2>&1; }
sk() { cat "$C/skills/${1:-signup}/SKILL.md"; }

# 1. fresh install: skill + queue scripts + marker; paths absolute and quoted
new_home
out="$(inst)" || fail "install failed: $out"
for f in SKILL.md signupq queue.py queue-dir .installed-by-openclaw-signup; do
  [ -f "$C/skills/signup/$f" ] || fail "missing $f"
done
[ "$(sk | sed -n 2p)" = "name: signup" ] || fail "frontmatter name: $(sk | sed -n 2p)"
sk | grep -q '^# \$signup ' || fail "heading is not \$signup"
sk | grep -qF "bash \"$C/skills/signup/signupq\" list" || fail "signupq list path not rendered"
sk | grep -qF "bash \"$C/skills/signup/signupq\" done" || fail "signupq done path not rendered"
sk | grep -q '{{' && fail "template marker left"
sk | grep -q 'claude-in-chrome' && fail "Codex skill mentions Claude in Chrome"
[ "$(cat "$C/skills/signup/queue-dir")" = "~/.openclaw-signup" ] || fail "default queue-dir"
echo "$out" | grep -q 'installed \$signup' || fail "no success line: $out"
ok "fresh install"

# 2. re-running over its own install just updates it
echo "stale" >> "$C/skills/signup/SKILL.md"
inst >/dev/null || fail "reinstall failed"
sk | grep -q stale && fail "reinstall did not replace SKILL.md"
ls -a "$C/skills" | grep -q '\.tmp\.' && fail "temp dir left behind"
ok "reinstall updates in place"

# 3. a skill of the same name it did not create is left alone (unless --force)
new_home
mkdir -p "$C/skills/signup" && echo "mine" > "$C/skills/signup/SKILL.md"
out="$(inst)" && fail "foreign skill overwritten without --force"
echo "$out" | grep -q "not installed by this repo" || fail "no foreign-skill message: $out"
[ "$(cat "$C/skills/signup/SKILL.md")" = "mine" ] || fail "foreign skill was changed"
inst --force >/dev/null || fail "--force install failed"
sk | grep -q '^name: signup$' || fail "--force did not replace it"
ok "foreign skill protected, --force replaces"

# 4. --name renames everywhere; bad names are refused
new_home
out="$(inst --name finish-events)" || fail "--name install failed: $out"
[ "$(sk finish-events | sed -n 2p)" = "name: finish-events" ] || fail "--name not in frontmatter"
sk finish-events | grep -q '^# \$finish-events ' || fail "--name not in heading"
sk finish-events | grep -qF "$C/skills/finish-events/signupq" || fail "--name path not rendered"
out="$(inst --name 'Bad Name')" && fail "invalid name accepted"
ok "--name works, invalid name refused"

# 5. --queue-dir is stored; the installed signupq uses it
new_home
inst --queue-dir /srv/signup-q >/dev/null || fail "--queue-dir install failed"
[ "$(cat "$C/skills/signup/queue-dir")" = "/srv/signup-q" ] || fail "queue-dir not stored"
[ "$(bash "$C/skills/signup/signupq" where)" = "/srv/signup-q/signups.jsonl" ] || fail "signupq ignores queue-dir"
ok "--queue-dir"

# 6. both sides against one queue folder: an OpenClaw handoff appears in $signup's list,
#    and closing it from $signup empties the queue for the OpenClaw side too
new_home
Q="$(mktemp -d)/shared-queue"
T="$(mktemp -d)"; cp -R "$ROOT/install.sh" "$ROOT/skill" "$ROOT/queue" "$T/"
printf '%s\n' "name: A" "email: a@b.c" > "$T/profile.md"
bash "$T/install.sh" --render-only --queue-dir "$Q" >/dev/null 2>&1 || fail "openclaw build failed"
inst --queue-dir "$Q" >/dev/null || fail "codex install failed"
bash "$T/build/event-signup/scripts/handoff.sh" --url "https://lu.ma/both-sides" \
  --prefill '{"Name":"A"}' --needs-user "captcha" >/dev/null || fail "handoff failed"
ids="$(bash "$C/skills/signup/signupq" list | python3 -c 'import json,sys; print(" ".join(r["id"] for r in json.load(sys.stdin)))')"
[ "$ids" = "both-sides" ] || fail "\$signup does not see the handoff: [$ids]"
bash "$C/skills/signup/signupq" done --id both-sides --notes "prefilled" >/dev/null || fail "close failed"
[ "$(bash "$T/build/event-signup/scripts/signupq" check)" = "0" ] || fail "OpenClaw side still sees it pending"
ok "OpenClaw handoff -> \$signup list -> closed on both sides"

if [ $FAILS -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$FAILS FAILURE(S)"; exit 1; fi
