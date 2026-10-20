#!/usr/bin/env python3
"""Self-tests for queue.py. Run: python3 tests/test_queue.py  (no deps; exit 0 = green).

Drives the real CLI via subprocess with SIGNUP_QUEUE pointed at a temp file, so it
tests exactly what the OpenClaw skill and the /signup skill will invoke.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
QUEUE_PY = os.path.join(HERE, "..", "queue", "queue.py")
_fails = []


def run(args, queue, expect_rc=0, env_extra=None):
    env = dict(os.environ, SIGNUP_QUEUE=queue or "", **(env_extra or {}))
    if queue is None:
        del env["SIGNUP_QUEUE"]
    p = subprocess.run([sys.executable, QUEUE_PY, *args], env=env,
                       capture_output=True, text=True)
    if p.returncode != expect_rc:
        _fails.append(f"{args}: rc={p.returncode} (want {expect_rc}); stderr={p.stderr.strip()}")
    return p


def check(cond, msg):
    if not cond:
        _fails.append(msg)


def read(queue):
    """The replayed state, as queue.py itself computes it: list of records."""
    os.environ["SIGNUP_QUEUE"] = queue
    spec = importlib.util.spec_from_file_location("signup_queue", QUEUE_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return list(mod.load().values())


def main():
    tmp = tempfile.mkdtemp()
    q = os.path.join(tmp, "signups.jsonl")

    # 1. enqueue on missing file -> creates it with one pending record
    run(["enqueue", "--url", "https://lu.ma/ai-berlin", "--event-title", "AI Berlin",
         "--prefill", '{"company": "AI Workshop Berlin"}',
         "--needs-user", "final submit + Turnstile"], q)
    recs = read(q)
    check(len(recs) == 1 and recs[0]["id"] == "ai-berlin", "enqueue: id slug from url")
    check(recs[0]["status"] == "pending" and recs[0]["completed_at"] is None, "enqueue: pending")
    check(recs[0]["needs_user"] == ["final submit + Turnstile"], "enqueue: needs_user parsed")

    # 2. dedup: same id, pending -> SKIP, no duplicate
    p = run(["enqueue", "--url", "https://lu.ma/ai-berlin"], q)
    check("SKIP" in p.stdout, "enqueue dedup: prints SKIP")
    check(len(read(q)) == 1, "enqueue dedup: no duplicate record")

    # 3. em-dash stripping across event_title / prefill / notes / needs_user
    run(["enqueue", "--url", "https://lu.ma/cerebras", "--id", "cerebras",
         "--event-title", "Cerebras — Hackathon",
         "--prefill", '{"bio": "builder — ai engineer"}',
         "--needs-user", "org_ID — needs account",
         "--notes", "heavy form — gated"], q)
    rec = [r for r in read(q) if r["id"] == "cerebras"][0]
    blob = json.dumps(rec, ensure_ascii=False)
    check("—" not in blob, "no em-dash anywhere in the stored record")
    check(rec["event_title"] == "Cerebras - Hackathon", "em-dash -> spaced hyphen")

    # 4. mark-done: sets status+completed_at, keeps the other record
    run(["mark-done", "--id", "ai-berlin", "--notes", "prefilled — left open"], q)
    recs = read(q)
    check(len(recs) == 2, "mark-done: other records preserved")
    done = [r for r in recs if r["id"] == "ai-berlin"][0]
    check(done["status"] == "done" and done["completed_at"], "mark-done: status+completed_at set")
    check(done["notes"] == "prefilled - left open", "mark-done: notes stored without em-dash")
    check([r for r in recs if r["id"] == "cerebras"][0]["status"] == "pending",
          "mark-done: did not touch the other record")

    # 5. mark-done unknown id -> fail loud
    run(["mark-done", "--id", "nope"], q, expect_rc=1)

    # 6. list-pending / check counts (1 pending now: cerebras)
    p = run(["check"], q)
    check(p.stdout.strip() == "1", "check: counts only pending")
    p = run(["list-pending", "--json"], q)
    pend = json.loads(p.stdout)
    check(len(pend) == 1 and pend[0]["id"] == "cerebras", "list-pending: only pending")

    # 6b. re-queue: a closed record is re-opened with the new data (the user never
    # submitted what /signup left them, and the agent handed the event off again)
    p = run(["enqueue", "--url", "https://lu.ma/ai-berlin", "--prefill", '{"company": "New Co"}',
             "--needs-user", "captcha"], q)
    check("REQUEUED: ai-berlin" in p.stdout, "requeue: prints REQUEUED")
    recs = read(q)
    again = [r for r in recs if r["id"] == "ai-berlin"]
    check(len(recs) == 2 and len(again) == 1, "requeue: one record per id")
    check(again[0]["status"] == "pending" and again[0]["completed_at"] is None, "requeue: pending again")
    check(again[0]["prefill"] == {"company": "New Co"}, "requeue: takes the new prefill")
    p = run(["enqueue", "--url", "https://lu.ma/ai-berlin"], q)
    check("SKIP: ai-berlin already pending" in p.stdout, "requeue: a pending record is still skipped")

    # 6c. the log is append-only: every earlier line is still there, unchanged
    with open(q, encoding="utf-8") as f:
        lines = f.read().splitlines()
    check(len(lines) == 4 and all(json.loads(x)["op"] in ("enqueue", "close") for x in lines),
          f"append-only: 4 event lines expected, got {len(lines)}")

    # 6d. order comes from timestamps, not file position (a union merge may put a
    # later event above an earlier one)
    q2 = os.path.join(tmp, "merged.jsonl")
    with open(q2, "w", encoding="utf-8") as f:
        f.write(json.dumps({"op": "close", "at": "2026-01-01T10:00:02.000000Z", "id": "x",
                            "status": "done"}) + "\n")
        f.write(json.dumps({"op": "enqueue", "at": "2026-01-01T10:00:01.000000Z",
                            "record": {"id": "x", "url": "u"}}) + "\n")
        f.write(json.dumps({"op": "enqueue", "at": "2026-01-01T10:00:03.000000Z",
                            "record": {"id": "y", "url": "v"}}) + "\n")
    st = {r["id"]: r["status"] for r in read(q2)}
    check(st == {"x": "done", "y": "pending"}, f"replay follows timestamps: {st}")

    # 6e. default path: no SIGNUP_QUEUE -> ~/.openclaw-signup/, never next to queue.py
    home = tempfile.mkdtemp()
    run(["enqueue", "--url", "https://example.com/e"], None, env_extra={"HOME": home})
    check(os.path.exists(os.path.join(home, ".openclaw-signup", "signups.jsonl")),
          "default path: log created under $HOME/.openclaw-signup")
    check(not os.path.exists(os.path.join(os.path.dirname(QUEUE_PY), "signups.jsonl")),
          "default path: nothing written next to queue.py")

    # 7. a malformed line -> FAIL LOUD on every command, file NOT touched
    with open(q, "a", encoding="utf-8") as f:
        f.write("{ this is not json ]\n")
    with open(q, encoding="utf-8") as f:
        before = f.read()
    p = run(["enqueue", "--url", "https://lu.ma/x"], q, expect_rc=1)
    check("line 5" in p.stderr, f"malformed: names the bad line: {p.stderr.strip()}")
    run(["list-pending"], q, expect_rc=1)
    with open(q, encoding="utf-8") as f:
        check(f.read() == before, "malformed: log left untouched")

    # 8. missing file is OK for read paths (check -> 0)
    os.unlink(q)
    p = run(["check"], q)
    check(p.stdout.strip() == "0", "check: missing file -> 0 pending (no crash)")

    if _fails:
        print("FAIL:")
        for f in _fails:
            print("  -", f)
        sys.exit(1)
    print("OK: all queue.py self-tests passed")


if __name__ == "__main__":
    main()
