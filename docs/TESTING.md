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

A test that calls `process.exit()` never unwinds back to the native caller —
libc `exit()` runs first — so the native write never happens. The app therefore
also drops a small `exit-verdict-hook.js` into its sandbox at launch and
preloads it, registering a `process.on('exit')` handler that writes the real
code. The handler is confined to the main thread, so a worker calling
`process.exit()` cannot overwrite the parent's verdict, and it `require()`s
nothing until the process is already exiting, so it adds no entries to
`process.moduleLoadList` (which `test-bootstrap-modules` asserts on exactly).
The `atexit` `FAIL` fallback remains for the cases that reach neither path — a
crash or an abort — and checks for an existing verdict file rather than only its
own flag, so it cannot clobber what the hook just wrote.

**This matters far more than "some test calls `process.exit()`".** `common.skip()`
ends in `process.exit(0)`, so *every* test that self-skips at runtime — no QUIC,
no crypto, Windows-only, debug-build-only — was scored FAIL. The curated list
never noticed because it was harvested by keeping what passed, which silently
discarded every self-skipping test. A full-suite sweep found 40 of them.

Both platforms preload it the same way, via `NODE_OPTIONS=--require`, which
stays out of `process.execArgv` entirely. It is installed unconditionally: the
hook `require()`s nothing until exit, so the only observable trace is one extra
listener on `process('exit')`, and there is no way to predict which tests need
it anyway — `common.skip()` reaches `process.exit(0)` from any test, at runtime.

`NODE_OPTIONS` only became usable on Android once patch 0007 relaxed
`SafeGetenv()` (see [that patch](./PATCHES.md)); before it, node discarded the
variable and the harness had to inject `--require` on the command line, which
did land in `process.execArgv`. That workaround is gone.

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
| `tier2b-full-suite.yml` | ubuntu+KVM / macos | nightly 03:00 UTC · dispatch | *advisory* — the **whole** non-`.status`-skipped `test/parallel` suite on both platforms, 4 shards each via `test.py --run=i,4`. Tier 2a covers what someone curated; this covers everything else, so a test upstream adds tomorrow is picked up without anyone noticing it exists |
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

### Tier 2a and Tier 2b

Tier 2 is split, because one job cannot be both fast enough for a PR and broad
enough to be trusted:

- **Tier 2a** — `emulator-tests` / `simulator-tests`, driven from `build.yml`
  on every PR and push. The curated 208-test allow-list, deterministic and a
  few minutes per platform. It answers "did this change break something we
  already care about".
- **Tier 2b** — `tier2b-full-suite.yml`, nightly. Everything `parallel.status`
  and `sequential.status` do not skip: ~3,260 + ~54 tests on Android and ~3,200
  + ~53 on iOS, split four ways per platform. It answers "what is true on a
  device that we have not looked at", which is the larger question — Tier 2a
  covers about 6% of the runnable suite.

  `test/sequential` is included because it had never run anywhere. It has had
  mobile `.status` sections since the harness landed, so it *looked* covered,
  but no job invoked the suite — the skips had never been tested and neither had
  the ~57 tests they leave. Both are now measured: the skip list turns out to be
  sound (every non-structural skip that passes spawns a child process), and the
  tests it leaves pass on both platforms.

The important property of Tier 2b is that it is **not an allow-list**. A test
upstream adds in the next bump runs the night after the bump lands, with no
curation step; excluding something requires a `.status` entry, which is a
decision with a name and a reason attached. That is the drift this fork already
had once — whole families like `test-compile-cache-*` were excluded by
enumerating individual test names, so every test upstream added to them
afterwards failed silently until a full sweep went looking.

Tier 2b is **advisory** and deliberately not on the release chain. Its pass-set
has been measured by hand, once; promoting it to a gate means dropping
`continue-on-error` and adding it to `publish`'s `needs:`, and should wait for a
few nightlies to agree on what green looks like. Each shard writes a summary
(counts, plus the failing names, and hangs and crashes counted separately —
they mean different things) and uploads its log.

### The curated subset

`tools/mobile-test/tier2-parallel-tests.txt` is the allow-list (208 single-
process `test/parallel` cases) shared by both Tier-2 workflows, so a regression
fails the same named test on both platforms. It is **generated** by
`tools/mobile-test/select-tier2a.py` — change the risk weights there and
regenerate rather than adding lines by hand. The runner invocation is:

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

### What the subset does not cover

The allow-list is weighted towards the patch series' blast radius — `net`,
`tls`, `timers`, `process`, `fs`, `dns`, `dgram`, `crypto`, `worker` and `http`
are its ten largest modules — so what it misses is not a module the fork can
break, but sheer breadth: 208 of ~3,200 runnable tests.

Run `tools/mobile-test/coverage-manifest.py` for the current numbers. It
separates the two reasons a test is absent from a device run, which a green run
cannot:

```
android   4103 total   839 skipped by .status   3264 runnable   208 run in Tier 2 (6.4%)   3056 never run on a device
ios       4103 total   906 skipped by .status   3197 runnable   208 run in Tier 2 (6.5%)   2989 never run on a device
```

A `.status` skip is a recorded decision. The other 3,000-odd are not decisions
at all — they are tests nobody has tried on a device. That gap, not the skip
list, is where the missing coverage lives, and Tier 2b is what closes it.
`smoke-host` prints this table on every run.

### Expanding the curated list

The list grows by measurement, not by guessing: run candidates on both
platforms, keep what passes on both, and record a *reason* for anything that
does not. Everything below runs from a materialized tree with the app already
prepared (see "Running tests locally").

**1. Pick candidates.** Anything not already in the list and not
`.status`-skipped is fair game; prefer whole modules over scattered files, and
prefer modules the patch series can plausibly break (`fs`, `net`, `stream`,
`crypto`, `worker`, `dgram`, `timers`, `vm`, `dns`) over more `buffer` tests.

```sh
ls test/parallel/test-fs-*.js | sed 's|test/|| ; s|\.js$||' > /tmp/candidates.txt
```

**2. Run them on both platforms**, one at a time, keeping the per-test verdict:

```sh
xargs ./tools/test.py -j 1 --flaky-tests=dontcare --timeout=300 \
  --arch android < /tmp/candidates.txt
xargs ./tools/test.py -j 1 --flaky-tests=dontcare --timeout=300 \
  --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh < /tmp/candidates.txt
```

`--flaky-tests=dontcare` (rather than `skip`) is deliberate here: during a
harvest you want to see the flaky ones, not hide them.

**3. Run the failures three times before believing them.** Emulator and
simulator timing is the dominant source of noise, and a test that fails once in
three is a `PASS, FLAKY` entry, not a skip.

**4. Triage every failure into exactly one bucket**, and act on it:

| Bucket | What it looks like | What to do |
|---|---|---|
| platform limitation | needs a child process, a unix socket on iOS, `HOME`, a signal, a TTY | add to the `[$system==…]` section of the `.status` file **with a comment saying why** |
| flake | passes in isolation, fails in a batch; timing-sensitive | `PASS, FLAKY` in the `.status` file |
| harness limitation | no verdict; passes when run by hand | fix the harness — don't skip the test |
| real bug | fails the same way every time, for a reason in the diff | fix the patch |

Only the first two produce a `.status` edit, and both carry a reason. An
uncommented skip is indistinguishable from an oversight a year later.

**5. Regenerate the list** with `tools/mobile-test/select-tier2a.py` — it picks
from whatever `.status` now leaves runnable, so recovering a test in step 4 is
what makes it eligible. Then re-run the whole list once on both platforms: a
test can pass alone and fail in company (the proxy relaunches the app per test,
so device load is a real variable).

Because these are all edits to files the fork owns (`.status` files are patched
by `0016`, the list lives in `mobile-src/`), they go back through
`scripts/regenerate-patches.py` like any other change, and `expected-tree.txt`
moves with them.

### The fetch / WebAssembly gate

`test/parallel/test-mobile-fetch` runs a `fetch()` against an in-process HTTP
server. That exercises undici's WebAssembly build of llhttp,
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
| `test-mobile-node-path` | 0007 (`SafeGetenv()` on embedded builds) | `NODE_PATH`, as the embedder set it, stops reaching module resolution |
| `test-mobile-fetch` | 0019 (WebAssembly polyfill) | see [the fetch / WebAssembly gate](#the-fetch--webassembly-gate) |
| `test-mobile-unix-socket` | none — a platform property | a unix socket bound from its own directory with a short relative path stops accepting connections. See [unix domain sockets](#unix-domain-sockets) |

Three limits are structural, and worth stating rather than papering over:

- **Patch 0008 has no deterministic trigger from JS.** `KVStore::Clone()`
  only fails when a name enumerates and then doesn't resolve, which is a
  property of the real process environment (bionic strips `LD_PRELOAD` and
  friends out of a starting app) and can't be staged from a test. The test
  asserts the post-condition instead — the worker starts, and its environment
  is the parent's — which is what a lost patch breaks on Android.
- **Patch 0007's `SafeGetenv()` change is invisible on a host build.**
  `SafeGetenv()` and `process.env` agree unless the process looks privileged,
  so the host run passes either way. The Android leg is the gate — an app
  process is `fork()`ed from the zygote without `exec()`, so it inherits an
  auxiliary vector saying `AT_SECURE=1` and `AT_{,E}{U,G}ID=0` while actually
  running unprivileged with `uid == euid`. `linux_at_secure()` therefore reports
  1 for every app, forever, and upstream's check declines *every* variable the
  embedder sets that is read this way: `TMPDIR` (so `os.tmpdir()` falls back to a
  `/tmp` that does not exist on Android), `NODE_EXTRA_CA_CERTS`,
  `NODE_USE_SYSTEM_CA`, `NODE_ICU_DATA`, `NODE_OPTIONS`, `OPENSSL_CONF`,
  `NODE_PATH`, `NODE_COMPILE_CACHE`. Not `TZ` — its only `SafeGetenv()` read is
  Windows-only (`#ifndef __POSIX__` in `node.cc`); on mobile `TZ` reaches libc
  and ICU through plain `getenv`, so it was never affected. The fix is gated on
  `NODE_MOBILE` — the embedded-library build — rather than on the OS, because a
  standalone `node` `exec()`ed on Android would have a truthful auxv and should
  keep upstream's behaviour. The `uid`/`gid` comparisons stay live.
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

### The working directory

A desktop `tools/test.py` run starts node with the working directory at the tree
root, and a good part of the suite quietly depends on it: `test-dotenv` passes
`--env-file test/fixtures/dotenv/valid.env`, `test-fs-cp-async-file-url` opens
`./test/fixtures/copy/kitchen-sink`, and `common.PIPE` builds a socket path
relative to `process.cwd()` on purpose, to keep it short.

An embedded node inherits the host app's cwd, which is `/`. Every one of those
resolved against the filesystem root instead, so the app now `chdir()`s to the
on-device tree root before starting node — the same starting point a desktop run
has. That is a harness change only; it says nothing about what cwd a real
embedder should use, and libnode is untouched.

Worth knowing for embedders regardless: **cwd is `/` in an app process** unless
you set it. Anything resolving a relative path — including a unix socket path —
should not assume otherwise.

### Unix domain sockets

UDS works in both sandboxes. What differs is how long the socket path may be:
Darwin caps `sockaddr_un.sun_path` at **104 bytes** (Linux allows 108), and the
kernel stores the path exactly as passed.

An iOS app's data container is long before you add a filename — about 81 bytes
on a device, about 171 on the simulator — so an absolute path inside it does not
fit, and `bind()` fails with **`EINVAL`**. That is a path-length limit, not a
missing feature: the same socket completes a round-trip when bound from inside
its own directory with a short relative name.

Upstream's `common.PIPE` builds a relative path for exactly this reason — but
relative to `process.cwd()`, and the app used to inherit `cwd=/`, so it expanded
right back to the full container path. Every upstream UDS test failed on the
simulator and all 18 were skipped for iOS, which left UDS ungated there
entirely. The app now `chdir()`s to the on-device tree root at launch (see
[the working directory](#the-working-directory)), `common.PIPE` is short again,
and **all 18 run and pass**. `test-mobile-unix-socket` gates the behaviour
directly, independent of upstream's helper.

On Android the container path is short (~50 bytes) and the limit never bites:
the upstream UDS tests pass there. Abstract-namespace sockets (`@`-prefixed) are
Linux-only and have no iOS equivalent.

**For embedders:** `chdir()` to the socket's directory and bind a relative path.
That is portable across both platforms, device and simulator alike. An absolute
path works on Android and on an iOS *device* if the whole string stays under 104
bytes, and cannot work on the iOS simulator. Note `os.tmpdir()` on iOS returns a
path inside the container, so it carries the full prefix.

### fs.watch

`fs.watch()` works on both platforms, but on **iOS it cannot tell you which file
changed** for a non-recursive watch. libuv compiles FSEvents out on iOS —
*"iOS (currently) doesn't provide the FSEvents-API (nor CoreServices)"*,
`deps/uv/src/unix/fsevents.c` — and falls back to kqueue, which watches a
directory file descriptor and reports only that the directory changed. The
`filename` argument comes back as the watched directory's own name.

The visible consequence is that the **`ignore` option filters out everything**,
even a predicate that never matches, because node applies it to that filename.
Recursive watching is unaffected: node implements that in JS and does report
proper relative paths.

This is upstream libuv behaviour on the platform, not something this fork can
fix. Isolated by testing three builds — it works on Android (also a
`NODE_MOBILE` build), on stock node 24.18.0 for macOS, and on **this fork's own
macOS host build** — so neither the patch series nor the node version is
involved. The ten affected tests are skipped for iOS with that reason recorded.

**For embedders:** don't rely on `filename` from a non-recursive `fs.watch` on
iOS, and don't use the `ignore` option there.

### Tests under `--permission`

A test that runs with `--permission` but without `--allow-fs-write` cannot be
scored when it calls `process.exit()`: the harness writes its verdict to a file
from a `process.on('exit')` hook, and the permission model — correctly — denies
that write, so no verdict lands and the run reports FAIL whatever the test did.
This is not fixable from inside the sandbox doing the denying. The 22 affected
cases are skipped, with that reason recorded next to them in `parallel.status`.

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
