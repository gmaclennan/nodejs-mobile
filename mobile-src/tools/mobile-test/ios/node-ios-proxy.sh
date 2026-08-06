#!/bin/bash
# Per-test proxy for a *physical* iOS device, used via `test.py --shell`. Launches
# the installed testnode app with ios-deploy, reads the test's real exit code from
# the per-launch verdict file the app writes to its Documents dir — pulled back off
# the device with ios-deploy's own sandbox download — echoes node's stdout/stderr
# for test.py to compare, and maps PASS->0 / FAIL or no-verdict->1.
#
# The verdict is neither scraped from the console stream nor taken from
# ios-deploy's exit code: same contract as the simulator proxy
# (node-ios-sim-proxy.sh) and the Android one. See TESTING.md on the recipe branch.
#
# Local-only — no CI job runs this; Tier-3 device coverage goes through
# BrowserStack. Retrieval flags verified against ios-deploy 1.12.x: `--bundle_id`
# opens house arrest on the app, `--download=<sandbox path> --to <dir>` writes the
# file to <dir>/<sandbox path>. ios-deploy exits 0 when the requested path does
# not exist, so the downloaded file's presence is the only reliable signal.
set -uo pipefail

DEVICE_ID="${DEVICE_ID:-}"
# Bundle id of the installed app. Overridable because TESTING.md tells you to
# change it in Xcode when `nodejsmobile.test` is already taken on your account.
BUNDLE_ID="${NODE_IOS_BUNDLE_ID:-nodejsmobile.test}"

# ios-deploy with the optional device selector applied — a function rather than a
# `$TARGET_DEVICE` string so the empty case needs no unquoted expansion.
iosdeploy() {
  if [ -n "$DEVICE_ID" ]; then
    ios-deploy -i "$DEVICE_ID" "$@"
  else
    ios-deploy "$@"
  fi
}

PROXY_BASE_DIR="$( cd "$( dirname "$0" )" && pwd )"
MYID=$(uuidgen)
SHORTDEVICE=$(echo "$DEVICE_ID" | head -c 4)
LOG_FILE_PATH="$PROXY_BASE_DIR/testsrun_$SHORTDEVICE.$MYID.log"
STDOUT_FILE_PATH="$PROXY_BASE_DIR/stdout_$SHORTDEVICE.$MYID.log"
STDERR_FILE_PATH="$PROXY_BASE_DIR/stderr_$SHORTDEVICE.$MYID.log"
IOS_APP_PATH="$PROXY_BASE_DIR/Release-iphoneos/testnode.app"
touch "$STDOUT_FILE_PATH"
touch "$STDERR_FILE_PATH"

TEST_BASE_DIR="$( cd "$( dirname "$0" )" && cd .. && cd .. && cd test && pwd )"

# Per-launch token: names the verdict file (Documents/result-<token>.txt) so a
# stale file, or a child the test spawned (it never gets --run-token), can't be
# read back as this launch's verdict. Lowercased uuid -> [0-9a-f], uniform with
# the simulator and Android tokens.
RUN_TOKEN="$(/usr/bin/uuidgen | tr 'A-F' 'a-f' | tr -d '-')"
# Bail rather than launch tokenless: main.m parses --run-token positionally, so
# an empty token shifts --substitute-dir into its slot and the run goes wrong in
# a way no verdict would explain.
[ -n "$RUN_TOKEN" ] || { echo "::error::node-ios-proxy: uuidgen produced no run token" >&2; exit 1; }

echo "Time: $(date '+%FT%T') -> Proxying testcase: $0 $* (token $RUN_TOKEN)" >> "$LOG_FILE_PATH"

# main.m consumes --run-token into the environment (NodeRunner builds the verdict
# path from it, then unsets it so a spawned child can't inherit it) and applies
# --substitute-dir to rewrite host test paths to the Documents copy. --run-token
# has to come first: main.m parses the two in that order.
# -t 240 doubles as the hang cap — ios-deploy's timer aborts a run that outlives
# it, which lands here as a no-verdict FAIL instead of a stuck proxy.
iosdeploy -t 240 --noinstall -b "$IOS_APP_PATH" --output "$STDOUT_FILE_PATH" \
    --error_output "$STDERR_FILE_PATH" --noninteractive \
    --args "--run-token $RUN_TOKEN --substitute-dir $TEST_BASE_DIR $*" \
  | sed $'s/\r$//' | tee -a "$LOG_FILE_PATH" | sed '1,/(lldb)     autoexit/d' \
  | sed -E '/Process [0-9]+ exited with status.*|PROCESS_EXITED/,$d'

LAUNCH_STATUS=${PIPESTATUS[0]}

# Pull the verdict file off the device. Under --noninteractive ios-deploy has
# already waited for the app process to exit, so the file — written before node
# returns — is complete by now.
#
# ios-deploy's AFC root is the app container when the device grants VendContainer
# (verdict at /Documents/result-<token>.txt) and the Documents dir itself on the
# VendDocuments fallback (verdict at /result-<token>.txt); it tries them in that
# order, so try both paths here and locate the file by name rather than trust an
# assumed layout.
DL_DIR="$(mktemp -d)"
VERDICT_FILE=""
for remote_path in "/Documents/result-${RUN_TOKEN}.txt" "/result-${RUN_TOKEN}.txt"; do
  iosdeploy -t 60 --bundle_id "$BUNDLE_ID" --download="$remote_path" --to "$DL_DIR" \
    >> "$LOG_FILE_PATH" 2>&1 || true
  VERDICT_FILE="$(find "$DL_DIR" -type f -name "result-${RUN_TOKEN}.txt" | head -n 1)"
  [ -n "$VERDICT_FILE" ] && break
done

verdict=""
[ -n "$VERDICT_FILE" ] && verdict="$(tr -d '\r\n' < "$VERDICT_FILE")"
rm -rf "$DL_DIR"

case "$verdict" in
  PASS) RESULT=0 ;;
  FAIL) RESULT=1 ;;
  *) RESULT=1
     echo "::warning::node-ios-proxy: no verdict file for token ${RUN_TOKEN} (crash/timeout/launch failure; ios-deploy exited ${LAUNCH_STATUS}, see ${LOG_FILE_PATH}) for: $*" >&2 ;;
esac

# Echo node's stdout/stderr for test.py's .out comparison; ios-deploy captured
# them into files via --output/--error_output. The verdict no longer rides them.
sed $'s/\r$//' < "$STDOUT_FILE_PATH"
sed $'s/\r$//' < "$STDERR_FILE_PATH" >&2

# On-device verdict files are left in place on purpose: deleting each one costs
# another device round-trip per test, the token makes a stale file unreadable,
# and prepare-ios-tests.sh reinstalls the app — wiping its container — anyway.
exit "$RESULT"
