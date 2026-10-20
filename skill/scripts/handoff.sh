#!/usr/bin/env bash
# event-signup skill - deterministic handoff. Queues an event the agent could
# not finish (via signupq) and prints a receipt with the record id. The agent
# MUST paste this id; it may not claim "queued" without it. Any failure exits
# non-zero with HANDOFF FAILED.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

URL=""; TITLE=""; TICKET=""; PREFILL=""; NEEDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url|--title|--ticket|--prefill|--needs-user)
      [ $# -ge 2 ] || { echo "HANDOFF FAILED: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --url) URL="$2";;
        --title) TITLE="$2";;
        --ticket) TICKET="$2";;
        --prefill) PREFILL="$2";;
        --needs-user) NEEDS="$2";;
      esac
      shift 2;;
    *) echo "HANDOFF FAILED: unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$URL" ] || { echo "HANDOFF FAILED: --url is required" >&2; exit 2; }

args=(--url "$URL")
[ -n "$TITLE" ]   && args+=(--event-title "$TITLE")
[ -n "$TICKET" ]  && args+=(--ticket "$TICKET")
[ -n "$PREFILL" ] && args+=(--prefill "$PREFILL")
[ -n "$NEEDS" ]   && args+=(--needs-user "$NEEDS")

out="$(bash "$HERE/signupq" enqueue "${args[@]}" 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then
  echo "HANDOFF FAILED: $out" >&2
  exit 1
fi

id="$(printf '%s\n' "$out" | sed -nE 's/^(ENQUEUED|REQUEUED): (.+)$/\2/p; s/^SKIP: ([^ ]+) already .*/\1/p' | head -1)"
if [ -z "$id" ]; then
  echo "HANDOFF FAILED: could not parse record id from: $out" >&2
  exit 1
fi
sync="$(printf '%s\n' "$out" | sed -n 's/^SYNC: //p' | head -1)"

echo "QUEUED ✓"
echo "id: $id"
echo "sync: ${sync:-unknown}"
[ -n "$NEEDS" ] && echo "needs_user: $NEEDS"
echo "-> finish it with /signup in Claude Code (Chrome connected)."
exit 0
