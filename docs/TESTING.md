# Testing nodejs-mobile

How the mobile test harness works, what CI runs, and how to run the tests
locally on an Android emulator, an iOS simulator, or a physical device.

## How a test PASSes

The harness runs the **real upstream `tools/test.py`** on the host, but points
its `node` executable at a per-platform **proxy script**. For each test case the
proxy relaunches the testnode app on the device (`am start` on Android, `xcrun
simctl launch` on an iOS simulator, `devicectl` on an iOS device), passing the
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

A run that produces no verdict file at all is a FAIL, and the proxy says which
kind: the Android one polls the app process alongside the file, so a native
crash (SIGSEGV/SIGKILL never reaches the `atexit` fallback, so no verdict is
ever written) reports `crashed (process gone after Ns, no verdict)` as soon as
the process dies, while `hung (no verdict after full TIMEOUT)` means it was
still alive at the deadline.

**Caveat:** `test-process-getactiveresources` asserts the exact set of active
handles, which depends on what stdout *is*: no handle when it's a file (how
`tools/test.py` runs every test), a `PipeWrap`/`TTYWrap` on a pipe or terminal.
Running that one file by hand fails on stock upstream node the same way — run
it through `tools/test.py`.

## What CI runs

| Workflow (on the `recipe` branch) | Runner | Trigger | Proves |
|---|---|---|---|
| `verify-patches.yml` → `verify` | ubuntu | PR · push `recipe` | the patch series + `mobile-src/` reconstruct the recorded tree byte-for-byte from a fresh upstream clone |
| `verify-patches.yml` → `patch-stack-configure` | ubuntu | PR · push `recipe` | every patch passes `./android-configure` individually (~1 min/patch) |
| `verify-patches.yml` → `tree-diff` | ubuntu | PR | *not a gate* — publishes the diff between the base and head **materialized trees** as a job summary + artifact, so review isn't a diff-of-a-diff |
| `build.yml` → `smoke-host` | ubuntu | PR · push `recipe` | C++ patches compile; `node -e` runs; `test-mobile-fetch` passes on that build run `--jitless` (see below); `test-mobile-system-ca` finds a non-empty system trust store; the curated list passes on the host build (plus the full `parallel` suite, advisory). Gates `ci-required` and `publish` |
| `build.yml` → `build-*` / `combine-*` | ubuntu / macos | PR · push `recipe` | the cross-compile actually succeeds — the only check that compiles target code |
| `build.yml` → `smoke-{android,ios}` (+ the NAPI symbol assert in `combine-android`) | ubuntu+KVM / macos | PR · push `recipe` | the exact shipping artifact boots and runs JS (Tier 1); NAPI symbols in `.dynsym` |
| `build.yml` → `emulator-tests` / `simulator-tests` | ubuntu+KVM / macos | PR · push `recipe` · releases | curated `test/parallel` subset + crc-native addon load on an x86_64 emulator and arm64 simulator (Tier 2) |
| `build.yml` → `device-smoke` | ubuntu / macos-15 + BrowserStack | releases (untagged version of record; required to publish) · dispatch | boot smoke + crc-native addon load on **physical devices** — Android arm64 (Pixel 9, 16 KB pages) via Espresso and iPhone via XCUITest (Tier 3). Needs `BROWSERSTACK_USER`/`BROWSERSTACK_PW` secrets. |

Every job first **materializes** the source tree from the recipe branch
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

`test/parallel/test-mobile-fetch` is the one entry in the curated list that
isn't pure JS: it runs a `fetch()` against an
in-process HTTP server. That exercises undici's WebAssembly build of llhttp,
which on iOS runs on the bundled polywasm polyfill because a jitless V8 has no
WebAssembly of its own ([FAQ](./FAQ.md#does-fetch-work-what-about-webassembly)).

It also runs on **every PR and push**, without a device: `build.yml`'s `smoke-host` job runs
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

### What covers which patch

Most of the curated list is upstream tests that happen to pass on mobile.
Those catch a patch that breaks *node*, which is most of the risk — but not a
patch that stops doing its own job. Several patches only change behaviour on
Android or on iOS, so no upstream test ever observes them, and a revert would
sail through every job. The fork-only tests below close that gap: one per
patch, each running on the host build (where it proves the assertion is
well-formed, and catches an outright break) and on both devices (where the
patched behaviour is the behaviour).

| Test | Patch | What a regression looks like |
|---|---|---|
| `test-mobile-credentials` | 0006 (POSIX credentials on Android), 0007 (credential guards) | on Android, `process.getuid()` disappears (0006 gone) or `process.setuid()` reaches the native setter instead of being inert (0007 gone). Everywhere, `process.initgroups()` stops resolving group names — the only JS path into the bionic `getgrnam()` lookup 0007 adds |
| `test-mobile-worker-env-clone` | 0008 (env clone) | a default-`env` worker comes up with a missing or partial environment; on Android, with one unclonable variable present, it does not come up at all |
| `test-mobile-system-ca` | 0010 (iOS TLS trust) | `tls.getCACertificates('system')` throws, hands back expired or duplicated certificates, or comes back empty where the platform has a readable store |
| `test-mobile-node-path` | 0015 (`NODE_PATH`) | `NODE_PATH`, as the embedder set it, stops reaching module resolution |
| `test-mobile-fetch` | 0020 (WebAssembly polyfill) | see [the fetch / WebAssembly gate](#the-fetch--webassembly-gate) |

Three limits are structural, and worth stating rather than papering over:

- **Patch 0008 has no deterministic trigger from JS.** `KVStore::Clone()`
  only fails when a name enumerates and then doesn't resolve, which is a
  property of the real process environment (bionic strips `LD_PRELOAD` and
  friends out of a starting app) and can't be staged from a test. The test
  asserts the post-condition instead — the worker starts, and its environment
  is the parent's — which is what a lost patch breaks on Android.
- **Patch 0015 is invisible on a host build.** `SafeGetenv()` and
  `process.env` agree unless the process looks setuid, so the host run passes
  either way. The Android and iOS legs are the gate; the host run is there to
  keep the assertion honest as upstream moves `Module._initPaths()` around.
- **Patch 0010's trust store can legitimately be empty on iOS**, where an app
  is sandboxed away from the system keychain — that's a platform fact, not a
  regression. So the test asserts the reader's invariants unconditionally and
  demands a non-empty result only when the caller says the platform has one:

  ```sh
  NODEJS_MOBILE_EXPECT_SYSTEM_CA=nonempty \
    ./out/Release/node test/parallel/test-mobile-system-ca.js
  ```

  `smoke-host` sets it, since a Linux build reading `/etc/ssl` has no excuse
  for an empty store. The device runs leave it unset, the same arrangement
  `NODEJS_MOBILE_EXPECT_WASM_IMPL` uses above.

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
(`adb devices` / `xcrun devicectl list devices` / `xcrun simctl list` to find it).

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

Requires macOS + Xcode 15+, an arm64 device on iOS 17 or newer with Developer
Mode enabled, and an Apple Development certificate whose account is signed
into Xcode. Everything device-facing runs through `xcrun devicectl`
(CoreDevice): `ios-deploy` is no longer used — its lldb launch phase cannot
work on iOS 17+, where the personalized developer disk image replaced the
`DeveloperDiskImage.dmg` it looks for. (For an iOS 16-or-older device, use the
old ios-deploy scripts from git history.)

```sh
./tools/ios_framework_prepare.sh arm64                        # build the device framework
NODE_IOS_DEV_TEAM=<your team id> \
  ./tools/mobile-test/ios/prepare-ios-tests.sh                # build+sign+install, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-proxy.sh
```

`NODE_IOS_DEV_TEAM` makes xcodebuild sign with your team (automatic signing +
`-allowProvisioningUpdates`); without it the project's own — empty — signing
settings apply. `DEVICE_ID` takes a CoreDevice identifier or name (`xcrun
devicectl list devices`, *not* the classic UDID) and is auto-selected when
exactly one device is connected. If the default bundle id is taken on your
account, export `NODE_IOS_BUNDLE_ID` for both scripts.

The device proxy scores from the same verdict file as the other two: it passes
a per-launch token and pulls `Documents/result-<token>.txt` back out of the
app's data container with `devicectl device copy from`, rather than trusting an
exit code. Verified end-to-end on an iPhone 16 Pro running iOS 26. This flow is
local-only; no CI job runs it (Tier-3 device coverage goes through
BrowserStack).

### Running the addon gate locally

```sh
# Android (after prepare-android-test.sh):
./tools/mobile-test/addon/build-android-addon.sh "$ANDROID_NDK_HOME" x86_64 out_android/x86_64 out_android/libnode/include/node ./crcnative.node
./tools/mobile-test/addon/run-android-addon.sh ./crcnative.node
# iOS simulator (after prepare-ios-sim-tests.sh): see tools/mobile-test/addon/build-ios-addon.sh + run-ios-addon.sh
```
