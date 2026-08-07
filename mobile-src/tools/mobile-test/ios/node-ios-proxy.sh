#!/bin/bash
# Per-test proxy for a *physical* iOS device, used via `test.py --shell`. Launches
# the installed testnode app, reads the test's real exit code from the per-launch
# verdict file the app writes to its Documents dir — pulled back out of the app's
# data container — echoes node's stdout/stderr for test.py to compare, and maps
# PASS->0 / FAIL or no-verdict->1.
#
# Everything goes through `xcrun devicectl` (CoreDevice, ships with Xcode 15+).
# On iOS 17+ ios-deploy's lldb launch path is dead — the personalized developer
# disk image replaced the DeveloperDiskImage.dmg it looks for — while devicectl
# launches with arguments, streams the console, reports the app's real exit
# code, and copies files out of the app container. Verified end-to-end on an
# iPhone 16 Pro / iOS 26. A pre-CoreDevice device (iOS 16 or older) needs the
# previous ios-deploy proxy, retrievable from git history.
#
# The verdict is neither scraped from the console stream nor taken from an exit
# code: same contract as the simulator and Android proxies. See TESTING.md on
# the recipe branch.
#
# Local-only — no CI job runs this; Tier-3 device coverage goes through
# BrowserStack.
set -uo pipefail

BUNDLE_ID="${NODE_IOS_BUNDLE_ID:-nodejsmobile.test}"
# Hang cap: devicectl blocks until the app exits, so a wedged test would wedge
# the proxy without this. Landing here with no verdict scores FAIL.
TIMEOUT="${NODE_IOS_PROXY_TIMEOUT:-240}"

# devicectl addresses devices by CoreDevice identifier or name — NOT the
# classic UDID ios-deploy used. With DEVICE_ID unset, auto-select when exactly
# one device is connected; anything else must be picked explicitly.
DEVICE_ID="${DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVJSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true
  DEVICE_ID="$(python3 - "$DEVJSON" <<'PYEOF'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
connected = [d["identifier"] for d in devs
             if d.get("connectionProperties", {}).get("tunnelState") == "connected"]
if len(connected) == 1:
    print(connected[0])
PYEOF
)"
  rm -f "$DEVJSON"
  [ -n "$DEVICE_ID" ] || { echo "::error::node-ios-proxy: no single connected device — set DEVICE_ID to a CoreDevice identifier (xcrun devicectl list devices)" >&2; exit 1; }
fi

# The proxy is invoked from two places — in-place (test.py --shell=tools/…)
# and as the out/ios.release/node copy prepare-ios-tests.sh stages (what a
# bare `test.py --arch ios` runs) — which sit at different depths. Walk up to
# the tree root instead of hard-coding one of them.
BASE="$( cd "$( dirname "$0" )" && pwd )"
while [ "$BASE" != "/" ] && [ ! -d "$BASE/test/common" ]; do
  BASE="$(dirname "$BASE")"
done
[ -d "$BASE/test/common" ] || { echo "::error::node-ios-proxy: cannot locate the source tree above $0" >&2; exit 1; }
TEST_BASE_DIR="$BASE/test"
LOG="$(mktemp)"

# Per-launch token: names the verdict file (Documents/result-<token>.txt) so a
# stale file, or a child the test spawned (it never gets --run-token), can't be
# read back as this launch's verdict. Lowercased uuid -> [0-9a-f], uniform with
# the simulator and Android tokens.
RUN_TOKEN="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
[ -n "$RUN_TOKEN" ] || { echo "::error::node-ios-proxy: uuidgen produced no run token" >&2; exit 1; }


# main.m consumes --run-token into the environment (NodeRunner builds the
# verdict path from it, then unsets it so a spawned child can't inherit it) and
# applies --substitute-dir to rewrite host test paths to the Documents copy.
# main.m parses them in this order: --run-token, --exit-hook, --substitute-dir.
# --console makes devicectl relay the app's output and block until it exits, so
# the verdict file is complete by the time the copy below runs.
# shellcheck disable=SC2086 # is a whitespace-free literal or empty
xcrun devicectl device process launch --device "$DEVICE_ID" --console \
    --terminate-existing "$BUNDLE_ID" \
    --run-token "$RUN_TOKEN" --substitute-dir "$TEST_BASE_DIR" "$@" \
    > "$LOG" 2>&1 &
LP=$!
waited=0
while kill -0 "$LP" 2>/dev/null; do
  if [ "$waited" -ge "$TIMEOUT" ]; then
    kill "$LP" 2>/dev/null || true
    echo "::warning::node-ios-proxy: launch still running after ${TIMEOUT}s, killed (hang) for: $*" >&2
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$LP" 2>/dev/null
LAUNCH_STATUS=$?

# Pull the verdict file out of the app's data container. A wrong bundle id, a
# crash before the write, or the kill above all land here as "no verdict".
DL_DIR="$(mktemp -d)"
xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/result-${RUN_TOKEN}.txt" \
    --destination "$DL_DIR/result.txt" >> "$LOG" 2>&1 || true

verdict=""
[ -f "$DL_DIR/result.txt" ] && verdict="$(tr -d '\r\n' < "$DL_DIR/result.txt")"
rm -rf "$DL_DIR"

case "$verdict" in
  PASS) RESULT=0 ;;
  FAIL) RESULT=1 ;;
  *) RESULT=1
     echo "::warning::node-ios-proxy: no verdict file for token ${RUN_TOKEN} (crash/timeout/launch failure; devicectl exited ${LAUNCH_STATUS}) for: $*" >&2 ;;
esac

# Echo the app's output for test.py's .out comparison, dropping devicectl's own
# chrome: its status lines are HH:MM:SS-prefixed, plus three fixed phrases.
# The verdict does not ride this stream.
sed -E \
  -e '/^[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]/d' \
  -e '/^Launched application with /d' \
  -e '/^Waiting for the application to terminate/d' \
  -e '/^The app terminated with the exit code /d' \
  "$LOG"
rm -f "$LOG"

# On-device verdict files are left in place on purpose: deleting each one costs
# another device round-trip per test, the token makes a stale file unreadable,
# and prepare-ios-tests.sh reinstalls the app — wiping its container — anyway.
exit "$RESULT"
