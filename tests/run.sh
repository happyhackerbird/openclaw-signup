#!/usr/bin/env bash
# Run every test suite. Needs bash, awk, python3, git, node, perl. Exit 0 = green.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
# The README runs these directly (./install.sh), so they must stay executable.
for f in ../install.sh ../install-claude-code.sh ../queue/signupq ../skill/scripts/handoff.sh; do
  [ -x "$f" ] || { echo "FAIL: $f is not executable (chmod +x it)"; rc=1; }
done
for t in "python3 test_queue.py" "bash test_handoff.sh" "bash test_install.sh" "bash test_install_claude_code.sh"; do
  echo "### $t"
  $t || rc=1
done
[ $rc -eq 0 ] && echo "### ALL SUITES PASSED" || echo "### SOME SUITES FAILED"
exit $rc
