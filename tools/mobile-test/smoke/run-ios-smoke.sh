#!/bin/bash
# Install the testnode app on a booted iOS simulator, run a one-line console.log
# via `node -e`, and assert it booted and exited cleanly. Tier 1 smoke
# (doc_mobile/TEST_PLAN.md).
#
# Usage: run-ios-smoke.sh <testnode.app> <simulator-udid>
set -uo pipefail

APP="$1"; UDID="$2"
BUNDLE_ID=nodejsmobile.test
MARKER=NODEJS_MOBILE_SMOKE_OK
# Single shell-quoted -e expression so simctl passes it as one argv (main.m
# forwards argv after the executable straight to node). Deliberately NO
# process.exit(0): nodejs-mobile's process.exit() routes through node::Exit ->
# libc exit(), which never returns from node_start, so NodeRunner's post-run
# PASS write is skipped and only the atexit FAIL fallback fires. Letting the
# event loop drain returns 0 from node_start -> a clean PASS verdict.
EXPR="console.log('${MARKER} ' + process.version + ' ' + process.platform + ' ' + process.arch);"
LOG="$(mktemp)"

xcrun simctl install "$UDID" "$APP"

# Decide pass/fail from the durable verdict file NodeRunner writes
# (Documents/result-<token>.txt), not from scraping `simctl --console`: that
# stream races a fast-exiting process and intermittently drops the marker on
# loaded CI runners. The console output is still echoed below for visibility.
RUN_TOKEN="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
DOCS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents"
RESULT_FILE="$DOCS/result-${RUN_TOKEN}.txt"
rm -f "$RESULT_FILE"

xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE_ID" \
  --run-token "$RUN_TOKEN" -e "$EXPR" >| "$LOG" 2>&1 &
LP=$!
verdict=""
for _ in $(seq 1 60); do
  if [ -f "$RESULT_FILE" ]; then
    verdict=$(tr -d '\r\n' < "$RESULT_FILE")
    [ -n "$verdict" ] && break
  fi
  kill -0 "$LP" 2>/dev/null || { [ -f "$RESULT_FILE" ] && verdict=$(tr -d '\r\n' < "$RESULT_FILE"); break; }
  sleep 1
done
kill "$LP" 2>/dev/null || true
wait "$LP" 2>/dev/null || true

echo "----- app output -----"
cat "$LOG"
echo "----------------------"
rm -f "$RESULT_FILE"
[ "$verdict" = "PASS" ] || { echo "::error::iOS smoke verdict was '${verdict:-<none>}' (expected PASS)"; exit 1; }
echo "iOS smoke: PASS"
