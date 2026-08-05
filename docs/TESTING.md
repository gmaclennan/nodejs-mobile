# Testing nodejs-mobile

How the mobile test harness works, what CI runs, and how to run the tests
locally on an Android emulator, an iOS simulator, or a physical device.

## How a test PASSes

The harness runs the **real upstream `tools/test.py`** on the host, but points
its `node` executable at a per-platform **proxy script**. For each test case the
proxy relaunches the testnode app on the device (`am start` on Android, `xcrun
simctl launch` on an iOS simulator, `ios-deploy` on an iOS device), passing the
test-file path and a unique per-launch token. The app runs the file in-process
via the embedded `node_start()`; when node returns, native code writes a `PASS`
/ `FAIL` verdict (the real exit code) to a per-launch file in the app's private
sandbox (`result-<token>.txt`). The proxy reads that file back and reports to
`test.py`.

The verdict rides a **durable sandbox file, never the log stream** — `logcat`
and `simctl --console` are shared, lossy streams that truncate and ring-buffer-
evict, which silently turned dropped lines into false failures under the old
log-scraping design. The token prevents a stale file or a spawned grandchild
from being mis-attributed.

**Caveat:** the post-run verdict is written only when the event loop drains
normally. A test that calls `process.exit()` routes through libc `exit()` before
node unwinds, so only an `atexit` `FAIL` fallback fires — such a test would be
mis-scored. None of the curated tests call `process.exit()`.

**Caveat:** `test-process-getactiveresources` asserts the exact set of active
handles, which depends on what stdout *is*: no handle when it's a file (how
`tools/test.py` runs every test), a `PipeWrap`/`TTYWrap` on a pipe or terminal.
Running that one file by hand fails on stock upstream node the same way — run
it through `tools/test.py`.

## What CI runs

| Workflow (on the `patches` branch) | Runner | Trigger | Proves |
|---|---|---|---|
| `verify-patches.yml` → `verify` | ubuntu | PR · push `patches` | the patch series + `mobile-src/` reconstruct the recorded tree byte-for-byte from a fresh upstream clone |
| `verify-patches.yml` → `patch-stack-configure` | ubuntu | PR · push `patches` | every patch passes `./android-configure` individually (~1 min/patch) |
| `verify-patches.yml` → `tree-diff` | ubuntu | PR | *not a gate* — publishes the diff between the base and head **materialized trees** as a job summary + artifact, so review isn't a diff-of-a-diff |
| `host-smoke.yml` | ubuntu | PR · push `patches` | C++ patches compile; `node -e` runs; `test-mobile-fetch` passes on that build run `--jitless` (see below); the curated list passes on the host build (plus the full `parallel` suite, advisory) |
| `build.yml` → `build-*` / `combine-*` | ubuntu / macos | PR · push `patches` | the cross-compile actually succeeds — the only check that compiles target code |
| `build.yml` → `smoke-{android,ios}` + `napi-smoke-android` | ubuntu+KVM / macos | PR · push `patches` | the exact shipping artifact boots and runs JS (Tier 1); NAPI symbols in `.dynsym` |
| `build.yml` → `emulator-tests` / `simulator-tests` | ubuntu+KVM / macos | PR · push `patches` · releases | curated `test/parallel` subset + crc-native addon load on an x86_64 emulator and arm64 simulator (Tier 2) |
| `build.yml` → `device-smoke` | ubuntu / macos-15 + BrowserStack | releases (untagged version of record; required to publish) · dispatch | boot smoke + crc-native addon load on **physical devices** — Android arm64 (Pixel 9, 16 KB pages) via Espresso and iPhone via XCUITest (Tier 3). Needs `BROWSERSTACK_USER`/`BROWSERSTACK_PW` secrets. |

Every job first **materializes** the source tree from the patches branch
(`.github/actions/materialize` runs `scripts/prepare.sh` and verifies the
tree hash), then proceeds exactly as it would on a full checkout. On a release
(or a `release-dryrun:` rehearsal commit), one `build.yml` run carries the
whole gate chain — Tier 1/2/3 and publish — connected by `needs:`; there is
no cross-run lookup, label contract, or manual step.

### Flavors, and what's required to merge

Every job that consumes a binary tests **both flavors** (`full` and `lite`),
with one deliberate exception: on `pull_request` the **iOS** legs build and
test `full` only. Hosted macOS concurrency is capped far below Linux, the full
chain wants eight concurrent macOS jobs, and what the lite iOS leg uniquely
catches — lite-specific configure/link breakage — is caught at compile time on
the merge run anyway. Android runs both flavors everywhere (ubuntu+KVM is
1×-billed and plentiful). Pushes and releases run both on both platforms.

`build.yml` exposes a single aggregate check, **`ci-required`**, which is what
branch protection should require — the matrix produces check names that change
whenever the matrix does, so a hand-maintained required list silently stops
enforcing. It covers the builds, the combines and Tier 1.

**Tier 2 runs on PRs but is deliberately not required.** Emulator and simulator
lifecycles (AVD boot, `simctl` races, adb disconnects) are the flakiest part of
this system, and a required check that flakes teaches everyone to re-run or
bypass — which costs more than the check is worth. Read it; don't merge through
a red one without knowing why it's red. It is blocking on the release chain,
where `publish` `needs:` it.

Tier 3 stays release-only: GitHub Actions minutes are free for this project,
BrowserStack device minutes are not.

### The curated subset

`tools/mobile-test/tier2-parallel-tests.txt` is the allow-list (~150 single-
process `test/parallel` cases) shared by both Tier-2 workflows, so a regression
fails the same named test on both platforms. The runner invocation is:

```sh
# Android emulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/tier2-parallel-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 --arch android

# iOS simulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/tier2-parallel-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 \
      --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

`-j 1` is required (the proxy relaunches the app once per test; parallel
relaunches on one device cause spurious timeouts). `--timeout=300` is larger
than the proxy's own ~120 s verdict poll so the proxy is the authoritative
deadline. Tests that can't run on mobile (`child_process`, `cluster`, `fork`,
signals, OpenSSL-CLI, …) are skipped via the upstream
`[$system==android]` / `[$system==ios]` sections of `test/*/*.status` — kept out
of the test bodies.

### The fetch / WebAssembly gate

`test/parallel/test-mobile-fetch` is the one fork-only test in the curated
list, and the one that isn't pure JS: it runs a `fetch()` against an
in-process HTTP server. That exercises undici's WebAssembly build of llhttp,
which on iOS runs on the bundled polywasm polyfill because a jitless V8 has no
WebAssembly of its own ([FAQ](./FAQ.md#does-fetch-work-what-about-webassembly)).

It also runs on **every PR and push**, without a device: `host-smoke.yml` runs
it on the host build with `--jitless`, which makes V8 drop its WebAssembly
exactly as the iOS build does — so a regression in the polyfill or in its
install path fails in ~10 minutes, at the PR boundary.

```sh
NODEJS_MOBILE_EXPECT_WASM_IMPL=polyfill ./out/Release/node --jitless \
  test/parallel/test-mobile-fetch.js                              # host, polyfill path
NODEJS_MOBILE_EXPECT_WASM_IMPL=engine ./out/Release/node \
  test/parallel/test-mobile-fetch.js                              # host, V8's own wasm
```

The test reports which implementation it ran on, and asserts it when
`NODEJS_MOBILE_EXPECT_WASM_IMPL` is set (`polyfill` | `engine`) -- so the
jitless step can't silently degrade into testing native wasm if a future V8
keeps WebAssembly under `--jitless`. The device runs leave it unset.

A third step runs upstream's `test-freeze-intrinsics` under the same jitless
engine:

```sh
./out/Release/node --jitless --frozen-intrinsics \
  test/parallel/test-freeze-intrinsics.js
```

`--frozen-intrinsics` is the one code path that reaches into the polyfill's
shape rather than just calling it: `internal/freeze_intrinsics.js` reads seven
`WebAssembly.*.prototype`s the moment the global exists, so a member the
polyfill doesn't implement doesn't fail a `fetch()` — it stops the runtime from
booting at all. That is how `LinkError` and `RuntimeError` missing from
polywasm were found; keeping the step means the next such gap fails here
instead of in an embedder's app.

### The NAPI addon gate

After the curated subset, each Tier-2 workflow builds the **crc-native** N-API
addon (`tools/mobile-test/addon/`) against that build's library and loads it in
the testnode app — proving a real `.node` addon `dlopen`s and runs (the
"blocker B-1" check the symbol-grep smoke only approximates).

## Running tests locally

Every command in this section runs from a materialized source tree — the
`out/` that `scripts/prepare.sh` produces (see [BUILDING.md](./BUILDING.md)),
not from this branch.

`tools/test.py` and the prepare scripts run on the host; the device/emulator
runs the app. A specific device/emulator can be targeted with `DEVICE_ID=<id>`
(`adb devices` / `ios-deploy --detect` / `xcrun simctl list` to find it).

> **WASI symlink side-effect.** The prepare scripts delete the dangling symlinks
> under `test/fixtures/wasi/subdir/` (Android asset packaging and iOS app
> install reject them). Restore them before committing:
> `git checkout -- test/fixtures/wasi/subdir/`.

### Android emulator (or device)

Requires a **Linux** host (Android can't cross-build on macOS — see
[BUILDING.md](./BUILDING.md)), NDK r27d, JDK 17, and `adb`.

```sh
./tools/android_build.sh "$ANDROID_NDK_HOME" 24 x86_64   # build libnode (x86_64 for an emulator)
./tools/mobile-test/android/prepare-android-test.sh      # build+install the app, copy test assets, drop the proxy
# then run the curated subset (command above), or a single test:
echo test/parallel/test-buffer-alloc.js | xargs ./tools/test.py -j 1 --arch android
```

### iOS simulator

Requires macOS + Xcode.

```sh
./tools/ios_framework_prepare.sh arm64-simulator              # build the simulator framework
./tools/mobile-test/ios/prepare-ios-sim-tests.sh              # build+install the app on a booted simulator, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

### iOS physical device

Requires macOS + Xcode, an arm64 device with a valid development certificate,
and [`ios-deploy`](https://github.com/ios-control/ios-deploy) (`npm i -g ios-deploy`).
Sign `tools/mobile-test/ios/testnode/testnode.xcodeproj` in Xcode first (set a
Team; change the bundle id if it's taken).

```sh
./tools/ios_framework_prepare.sh arm64                        # build the device framework
./tools/mobile-test/ios/prepare-ios-tests.sh                  # build+install on the connected device, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-proxy.sh
```

### Running the addon gate locally

```sh
# Android (after prepare-android-test.sh):
./tools/mobile-test/addon/build-android-addon.sh "$ANDROID_NDK_HOME" x86_64 out_android/x86_64 out_android/libnode/include/node ./crcnative.node
./tools/mobile-test/addon/run-android-addon.sh ./crcnative.node
# iOS simulator (after prepare-ios-sim-tests.sh): see tools/mobile-test/addon/build-ios-addon.sh + run-ios-addon.sh
```
