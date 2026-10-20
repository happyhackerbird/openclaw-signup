#!/usr/bin/env python3
"""Queue helper for the event-signup handoff (OpenClaw skill -> Claude Code /signup).

Pure data operations on signups.jsonl. NO git here - signupq handles sync.

The queue is an append-only log: one JSON event per line, "enqueue" or "close".
The current state is the log replayed in timestamp order. Nothing ever rewrites
an existing line, so when both computers add events before syncing, git's
built-in union merge keeps both sides and never conflicts (a single JSON array
conflicts as soon as the two sides touch neighbouring lines, and then every
later sync fails until someone repairs it by hand).

Subcommands:
  enqueue       add a pending record (dedup by id; strips em-dashes)
  mark-done     close a record (default status done)
  list-pending  print pending records (text, or --json)
  check         print the count of pending records (always exit 0)

The log path is the SIGNUP_QUEUE env var, else ~/.openclaw-signup/signups.jsonl.
Never next to this file: installs replace the skill directory this file lives in.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

QUEUE = os.environ.get("SIGNUP_QUEUE") or os.path.join(
    os.path.expanduser("~"), ".openclaw-signup", "signups.jsonl")
STATUSES = ("pending", "done", "skipped", "failed")

# No em-dashes in any generated free text. An em dash (or horizontal bar) becomes
# a spaced hyphen " - " with surrounding spaces normalized (so "X — Y" -> "X - Y",
# not "X  -  Y", and "X—Y" -> "X - Y"); newlines are preserved. En / figure /
# minus signs collapse to a plain hyphen.
_EMDASH_RE = re.compile(r"[ \t]*[—―][ \t]*")
_OTHER_DASHES = {"–": "-", "‒": "-", "−": "-"}  # en, figure, minus


def strip_dashes(s):
    if not isinstance(s, str):
        return s
    s = _EMDASH_RE.sub(" - ", s)
    for ch, repl in _OTHER_DASHES.items():
        s = s.replace(ch, repl)
    return s


def clean(obj):
    """Recursively strip non-hyphen dashes from every string in a record."""
    if isinstance(obj, str):
        return strip_dashes(obj)
    if isinstance(obj, list):
        return [clean(x) for x in obj]
    if isinstance(obj, dict):
        return {k: clean(v) for k, v in obj.items()}
    return obj


def now_iso():
    # Microseconds: events from two computers are ordered by this timestamp.
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def read_events():
    """Return the events in the log. Missing file = [] (first run). A malformed
    line = FAIL LOUD: never guess, never rewrite the log."""
    if not os.path.exists(QUEUE):
        return []
    events = []
    with open(QUEUE, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                ev = json.loads(line)
            except ValueError as e:
                sys.exit(f"FATAL: {QUEUE} line {n} is not valid JSON ({e}). "
                         f"Fix or delete that line by hand.")
            if not isinstance(ev, dict) or ev.get("op") not in ("enqueue", "close"):
                sys.exit(f"FATAL: {QUEUE} line {n} is not a queue event.")
            events.append(ev)
    return events


def load():
    """Replay the log into {id: record}, oldest event first. sorted() is stable,
    so events with equal timestamps keep their order in the file."""
    records = {}
    for ev in sorted(read_events(), key=lambda e: e.get("at", "")):
        if ev["op"] == "enqueue":
            rec = dict(ev["record"])
            rec.update(status="pending", created_at=ev["at"], completed_at=None)
            records[rec["id"]] = rec
        else:
            rec = records.get(ev.get("id"))
            if rec is None:
                continue
            rec["status"] = ev["status"]
            rec["completed_at"] = ev["at"] if ev["status"] != "pending" else None
            if ev.get("notes"):
                rec["notes"] = ev["notes"]
    return records


def append(event):
    """Append one event as one line. A short single write either lands whole or
    not at all, so a crash cannot leave a half-written record behind."""
    os.makedirs(os.path.dirname(os.path.abspath(QUEUE)), exist_ok=True)
    line = json.dumps(event, ensure_ascii=False) + "\n"
    with open(QUEUE, "a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())


def slug_from_url(url):
    s = url.rstrip("/").split("/")[-1].split("?")[0]
    return s or url


def cmd_enqueue(a):
    records = load()
    rid = a.id or slug_from_url(a.url)
    # Already waiting -> no duplicate. A closed record (done/skipped/failed) is
    # re-opened instead: the agent only hands off an event it just found
    # unregistered, so the earlier close was premature (e.g. the user never
    # submitted the form /signup left for them).
    old = records.get(rid)
    if old is not None and old.get("status") == "pending":
        print(f"SKIP: {rid} already pending")
        return
    prefill = {}
    if a.prefill:
        try:
            prefill = json.loads(a.prefill)
        except ValueError as e:
            sys.exit(f"FATAL: --prefill is not valid JSON: {e}")
        if not isinstance(prefill, dict):
            sys.exit("FATAL: --prefill must be a JSON object")
    needs = [x.strip() for x in (a.needs_user or "").split(",") if x.strip()]
    append({"op": "enqueue", "at": now_iso(), "record": clean({
        "id": rid,
        "url": a.url,
        "event_title": a.event_title or "",
        "ticket": a.ticket or "",
        "prefill": prefill,
        "needs_user": needs,
        "notes": a.notes or "",
    })})
    print(f"{'REQUEUED' if old is not None else 'ENQUEUED'}: {rid}")


def cmd_mark_done(a):
    if a.status not in STATUSES:
        sys.exit(f"FATAL: --status must be one of {STATUSES}")
    if a.id not in load():
        sys.exit(f"FATAL: no record with id {a.id}")
    ev = {"op": "close", "at": now_iso(), "id": a.id, "status": a.status}
    if a.notes:
        ev["notes"] = strip_dashes(a.notes)
    append(ev)
    print(f"{a.status.upper()}: {a.id}")


def pending():
    recs = [r for r in load().values() if r.get("status") == "pending"]
    return sorted(recs, key=lambda r: r["created_at"])


def cmd_list(a):
    recs = pending()
    if a.json:
        print(json.dumps(recs, indent=2, ensure_ascii=False))
        return
    for r in recs:
        nu = ", ".join(r.get("needs_user") or []) or "-"
        print(f"{r.get('id')}\t{r.get('url')}\t{r.get('event_title', '')}\tneeds_user: {nu}")


def cmd_check(a):
    print(len(pending()))


def build_parser():
    p = argparse.ArgumentParser(description="event-signup handoff queue helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("enqueue", help="add a pending handoff record")
    e.add_argument("--url", required=True)
    e.add_argument("--id", default=None, help="default: slug from url")
    e.add_argument("--event-title", dest="event_title", default=None)
    e.add_argument("--ticket", default=None)
    e.add_argument("--prefill", default=None, help="JSON object of field->value")
    e.add_argument("--needs-user", dest="needs_user", default=None,
                   help="comma-separated human-readable field descriptors")
    e.add_argument("--notes", default=None)
    e.set_defaults(func=cmd_enqueue)

    m = sub.add_parser("mark-done", help="close a record (status + completed_at)")
    m.add_argument("--id", required=True)
    m.add_argument("--status", default="done", help="done|skipped|failed|pending")
    m.add_argument("--notes", default=None)
    m.set_defaults(func=cmd_mark_done)

    ls = sub.add_parser("list-pending", help="print pending records")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    c = sub.add_parser("check", help="print count of pending records")
    c.set_defaults(func=cmd_check)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
