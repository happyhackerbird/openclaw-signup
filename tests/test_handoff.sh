#!/usr/bin/env bash
# Tests for skill/scripts/handoff.sh and queue/signupq, in local mode and in git
# mode (a bare repo with a "server" and a "laptop" clone). Everything runs in
# temp dirs with the user's git config switched off.
# Run: bash tests/test_handoff.sh (exit 0 = green).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# The skill's scripts dir as it is installed: handoff.sh + signupq + queue.py together.
S="$(mktemp -d)"
cp "$ROOT/skill/scripts/handoff.sh" "$ROOT/queue/signupq" "$ROOT/queue/queue.py" "$S/"
export HOME="$(mktemp -d)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
handoff() { bash "$S/handoff.sh" "$@"; }
q() { bash "$S/signupq" "$@"; }
pending_ids() { q list 2>/dev/null | python3 -c 'import json,sys; print(" ".join(r["id"] for r in json.load(sys.stdin)))'; }

# ---- local mode ---------------------------------------------------------------
export SIGNUP_QUEUE_DIR="$(mktemp -d)/queue"   # does not exist yet

# 1. happy path: receipt with id + sync: local, record pending with its prefill
out="$(handoff --url "https://lu.ma/test-xyz" --title "Test Event" \
  --prefill '{"name":"Alex"}' --needs-user "final submit + captcha")" || fail "happy path non-zero: $out"
echo "$out" | grep -q "^QUEUED" || fail "no QUEUED line: $out"
echo "$out" | grep -q "^id: test-xyz$" || fail "no id line: $out"
echo "$out" | grep -q "^sync: local$" || fail "expected sync: local: $out"
[ "$(pending_ids)" = "test-xyz" ] || fail "queue does not hold test-xyz as pending: $(pending_ids)"
[ -f "$SIGNUP_QUEUE_DIR/signups.jsonl" ] || fail "queue file not in SIGNUP_QUEUE_DIR"
ok "handoff queues a record (local mode)"

# 2. same link again while pending: same id, no duplicate
out="$(handoff --url "https://lu.ma/test-xyz")" || fail "repeat handoff non-zero: $out"
echo "$out" | grep -q "^id: test-xyz$" || fail "repeat lost the id: $out"
[ "$(pending_ids)" = "test-xyz" ] || fail "duplicate created: $(pending_ids)"
ok "repeat handoff is idempotent"

# 3. closed by /signup, then handed off again: back to pending
q done --id test-xyz --notes "prefilled" >/dev/null || fail "done failed"
[ -z "$(pending_ids)" ] || fail "record still pending after done"
out="$(handoff --url "https://lu.ma/test-xyz" --needs-user "captcha")" || fail "requeue non-zero: $out"
echo "$out" | grep -q "^id: test-xyz$" || fail "requeue lost the id: $out"
[ "$(pending_ids)" = "test-xyz" ] || fail "record not pending again: $(pending_ids)"
ok "closed record is re-queued"

# 4. bad input fails loudly and does not hang
out="$(handoff --title "no url" 2>&1)" && fail "missing --url accepted"
echo "$out" | grep -q "HANDOFF FAILED" || fail "no HANDOFF FAILED for missing url: $out"
out="$(handoff --url "https://x.example/bad" --prefill 'not-json' 2>&1)" && fail "bad prefill accepted"
echo "$out" | grep -q "HANDOFF FAILED" || fail "no HANDOFF FAILED for bad prefill: $out"
out="$(perl -e 'alarm(10); exec @ARGV' bash "$S/handoff.sh" --url 2>&1)"; rc=$?
[ $rc -ne 142 ] || fail "valueless --url hung"
[ $rc -ne 0 ] || fail "valueless --url accepted"
ok "bad input fails loudly"

# 5. queue-dir file next to the scripts is used when SIGNUP_QUEUE_DIR is unset
D="$(mktemp -d)/from-file"
echo "$D" > "$S/queue-dir"
( unset SIGNUP_QUEUE_DIR; q where ) | grep -qx "$D/signups.jsonl" || fail "queue-dir file ignored"
rm "$S/queue-dir"
( unset SIGNUP_QUEUE_DIR; q where ) | grep -qx "$HOME/.openclaw-signup/signups.jsonl" || fail "default dir wrong"
ok "queue dir: env, then queue-dir file, then ~/.openclaw-signup"

# ---- git mode -----------------------------------------------------------------
G="$(mktemp -d)"
git init -q --bare "$G/remote.git"
git clone -q "$G/remote.git" "$G/seed" 2>/dev/null
echo "# signup queue" > "$G/seed/README.md"
git -C "$G/seed" -c user.name=t -c user.email=t@t add -A
git -C "$G/seed" -c user.name=t -c user.email=t@t commit -q -m seed
git -C "$G/seed" push -q origin HEAD 2>/dev/null
git clone -q "$G/remote.git" "$G/server"; git clone -q "$G/remote.git" "$G/laptop"

# 6. server hands off -> pushed; laptop sees it; laptop closes it -> server sees that
out="$(SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/git-event" --prefill '{"a":"b"}')" \
  || fail "git handoff non-zero: $out"
echo "$out" | grep -q "^sync: pushed$" || fail "expected sync: pushed: $out"
[ "$(SIGNUP_QUEUE_DIR="$G/laptop" pending_ids)" = "git-event" ] || fail "laptop did not get the record"
out="$(SIGNUP_QUEUE_DIR="$G/laptop" q done --id git-event)" || fail "laptop done failed: $out"
echo "$out" | grep -q "^SYNC: pushed$" || fail "laptop close not pushed: $out"
[ "$(SIGNUP_QUEUE_DIR="$G/server" q check 2>/dev/null)" = "0" ] || fail "server still sees it pending"
[ -z "$(git -C "$G/server" status --porcelain)" ] || fail "server clone left dirty"
ok "git mode: server -> laptop -> server round trip"

# 7. race: the laptop holds an unpushed commit closing the LAST record while the
#    server appends a new one right after it (adjacent lines). The rebase must
#    merge both; nothing may be lost or left half-rebased.
SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/one" >/dev/null
SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/two" >/dev/null
SIGNUP_QUEUE_DIR="$G/laptop" q list >/dev/null
SIGNUP_QUEUE="$G/laptop/signups.jsonl" python3 "$S/queue.py" mark-done --id two --notes "prefilled" >/dev/null
git -C "$G/laptop" -c user.name=t -c user.email=t@t commit -q -am "close two (unpushed)"
SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/three" >/dev/null   # lands after "two"
out="$(SIGNUP_QUEUE_DIR="$G/laptop" q done --id one 2>&1)" || fail "racing done failed: $out"
echo "$out" | grep -q "^SYNC: pushed$" || fail "racing close not pushed: $out"
ids="$(SIGNUP_QUEUE_DIR="$G/server" pending_ids)"
[ "$ids" = "three" ] || fail "after the race the server sees pending [$ids], want [three]"
[ ! -d "$G/laptop/.git/rebase-merge" ] && [ ! -d "$G/laptop/.git/rebase-apply" ] || fail "laptop left mid-rebase"
python3 -c "import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]" "$G/laptop/signups.jsonl" || fail "laptop log has a broken line"
ok "git mode: racing edits on both sides merge"

# 8. remote unreachable -> handoff still succeeds, saved locally, says so
mv "$G/remote.git" "$G/remote.gone"
out="$(SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/offline")" || fail "offline handoff failed: $out"
echo "$out" | grep -q "^sync: push failed" || fail "push failure not reported: $out"
grep -q '"offline"' "$G/server/signups.jsonl" || fail "offline record not saved locally"
mv "$G/remote.gone" "$G/remote.git"
SIGNUP_QUEUE_DIR="$G/server" handoff --url "https://lu.ma/back" >/dev/null
[ "$(SIGNUP_QUEUE_DIR="$G/laptop" pending_ids)" = "three offline back" ] \
  || fail "offline record did not go out with the next change: $(SIGNUP_QUEUE_DIR="$G/laptop" pending_ids)"
ok "git mode: offline handoff is kept and sent later"

# 9. a queue dir inside some other repo stays local - no commits there
O="$(mktemp -d)/outer"
git init -q "$O" && git -C "$O" remote add origin "$G/remote.git"
out="$(SIGNUP_QUEUE_DIR="$O/q" handoff --url "https://lu.ma/inner")" || fail "inner handoff failed: $out"
echo "$out" | grep -q "^sync: local$" || fail "queue inside another repo was treated as git mode: $out"
[ -z "$(git -C "$O" log --oneline 2>/dev/null)" ] || fail "committed into the outer repo"
ok "queue inside another repo stays local"

if [ $FAILS -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$FAILS FAILURE(S)"; exit 1; fi
