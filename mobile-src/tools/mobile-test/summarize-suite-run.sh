#!/bin/bash
# Turn a tools/test.py run log into a short, reviewable summary: the counts and
# the names that failed, as a GitHub job summary when there is one and on stdout
# either way.
#
# A Tier-2b shard log is thousands of progress lines with the interesting part
# scattered through it. Reading a failure out of the raw log means finding the
# `=== release <name> ===` banners by eye, which is exactly the friction that
# stops people looking at an advisory job at all.
#
# Never fails: this reports on a run, it does not judge it. The caller decides
# whether a failure count is allowed to fail the build.
set -uo pipefail

LOG="${1:?usage: summarize-suite-run.sh <log> [label]}"
LABEL="${2:-suite run}"

if [ ! -r "$LOG" ]; then
  echo "::warning::summarize-suite-run: no log at $LOG (the run may have died before writing one)"
  exit 0
fi

# test.py writes progress with \r; split those so grep sees whole lines.
NORM="$(mktemp)"
trap 'rm -f "$NORM"' EXIT
tr '\r' '\n' < "$LOG" > "$NORM"

# Last progress line carries the totals: [mm:ss|%NNN|+ pass|- fail]
LAST="$(grep -aE '^\[[0-9]+:[0-9]+\|' "$NORM" | tail -1)"
PASS="$(printf '%s' "$LAST" | sed -nE 's/.*\+[[:space:]]*([0-9]+).*/\1/p')"
FAIL="$(printf '%s' "$LAST" | sed -nE 's/.*-[[:space:]]*([0-9]+)\].*/\1/p')"
PASS="${PASS:-0}"; FAIL="${FAIL:-0}"

FAILED="$(grep -aoE '^=== release [a-z0-9._-]+ ===$' "$NORM" \
          | sed 's/^=== release //; s/ ===$//' | sort -u)"
NFAILED="$(printf '%s' "$FAILED" | grep -c . || true)"

# The proxies distinguish these, and they mean different things: a crash is a
# bug, a hang is usually a test waiting on something the platform never
# delivers. Worth separating in the summary rather than lumping as "failed".
NHANG="$(grep -ac 'hung (no verdict' "$NORM" || true)"
NCRASH="$(grep -ac 'crashed (process gone' "$NORM" || true)"

{
  echo "### Tier 2b — ${LABEL}"
  echo
  echo "| passed | failed | no verdict: hung | no verdict: crashed |"
  echo "|---:|---:|---:|---:|"
  echo "| ${PASS} | ${FAIL} | ${NHANG} | ${NCRASH} |"
  if [ "${NFAILED}" -gt 0 ]; then
    echo
    echo "<details><summary>${NFAILED} failing test(s)</summary>"
    echo
    printf '%s\n' "$FAILED" | sed 's/^/- `/; s/$/`/'
    echo
    echo '</details>'
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}" > /dev/null

echo "${LABEL}: ${PASS} passed, ${FAIL} failed (${NHANG} hung, ${NCRASH} crashed)"
[ "${NFAILED}" -gt 0 ] && printf '%s\n' "$FAILED" | sed 's/^/  FAIL /'
exit 0
