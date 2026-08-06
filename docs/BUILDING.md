# Build Instructions

nodejs-mobile builds one native library per target, and **each target builds on
one host OS only:**

| Target  | Output                       | Build host           |
|---------|------------------------------|----------------------|
| Android | `libnode.so` (per ABI)       | **Linux only**       |
| iOS     | `NodeMobile.xcframework`     | **macOS only** (Xcode) |

> **Why Android can't be built on macOS.** node's bundled gyp archives static
> libs as GNU thin archives (`ar crsT … @file-list` response files) and links
> the cross-build's *host* build-tools (e.g. `node_js2c`) with the ELF-linker
> option `-Wl,--start-group`. Apple's `/usr/bin/ar` and `ld64` support neither,
> so a macOS host fails — first at the archiver (`ar: @…ar-file-list: No such
> file or directory`), and even with `AR_host` pointed at the NDK's `llvm-ar`,
> then at the host link (`ld: unknown options: --start-group`). `--start-group`
> is ELF-only and no Mach-O linker implements it, so there is no drop-in macOS
> fix. This is a property of node's build system, not the mobile patches, and it
> affects `full` and `lite` identically. Build Android on Linux (CI uses
> `ubuntu-24.04`).

## Python (both targets)

Both build paths run gyp / V8 code generation under Python. Use a **Python 3.13**
(3.12 also works) venv with `setuptools` installed — gyp-next declares
`setuptools` as a build-time dependency and a bare venv does not bundle it. CI
does the same:

```sh
python3.13 -m venv .venv
. .venv/bin/activate
pip install setuptools
```

---

## Android — build on Linux

### Prerequisites

```sh
sudo apt-get install -y build-essential git gcc-multilib g++-multilib
```

Install Android NDK **r27d** (`27.3.13750724`) via the SDK Manager (the
`ubuntu-24.04` GitHub runner already ships an NDK 27 at `$ANDROID_NDK_LATEST_HOME`):

```sh
sdkmanager "ndk;27.3.13750724"
```

### 1) Get a source tree

This repository holds the recipe, not the source. Generate a tree from it:

```sh
git clone -b patches https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile && scripts/prepare.sh && cd out
```

All the build commands below run from that `out/` directory. A release tag
(`vX.Y.Z-R`) already *is* a materialized tree, so checking one out works too.

### 2) Build with the helper script

```sh
./tools/android_build.sh <ndk-path> <sdk-version> [arch]
```

- `<ndk-path>` — the installed NDK, e.g. `~/Android/Sdk/ndk/27.3.13750724`
- `<sdk-version>` — minimum Android SDK version as a number, e.g. `24`
- `[arch]` — `arm`, `arm64`, or `x86_64`; omit to build all three.

```sh
./tools/android_build.sh ~/Android/Sdk/ndk/27.3.13750724 24
```

Output: `out_android/<abi>/libnode.so` for each ABI (`armeabi-v7a`, `arm64-v8a`,
`x86_64`).

To configure and build a single architecture manually instead:

```sh
./android-configure <ndk-path> <sdk-version> <arch>
make
# -> out/Release/lib.target/libnode.so
```

---

## iOS — build on macOS

### Prerequisites

Xcode with the Command Line Tools (`xcode-select --install`, which also installs
`git`).

### 1) Get a source tree

As above — `scripts/prepare.sh`, or a release tag. Commands run from `out/`.

### 2) Build with the helper script

```sh
./tools/ios_framework_prepare.sh [arm64|arm64-simulator]
```

With no argument it builds **both** arm64 slices — device (`iphoneos`) and
simulator (`iphonesimulator`) — and combines them. The script configures gyp to
build Node.js and its dependencies as static libraries with V8 set to run
jitless (Apple's no-JIT rule), staging the libs through
`tools/ios-framework/bin/` into the `tools/ios-framework/NodeMobile.xcodeproj`
project. Pass `arm64` or `arm64-simulator` to build only one slice during
development. (x86_64 / Intel-simulator support was dropped for v24: Intel Macs
are EOL and Apple Silicon runs the arm64 simulator natively.)

Output: **`out_ios/NodeMobile.xcframework`** (device + simulator arm64 slices).

---

## The lite variant

To build it instead of the default, set `NODEJS_MOBILE_FLAVOR=lite` on either
target's build command.

The build ships in two flavors (selected by `NODEJS_MOBILE_FLAVOR`, default
`full`). **`full`** is the general-purpose binary all consumers get. **`lite`**
is a smaller binary for consumers that don't need the full feature set, built by
layering feature-drops on top of the full configure — so the full binary and its
test gate are unchanged.

What `lite` drops (all already-available upstream `configure` flags, so no extra
patch-stack surface):

| Cut | Why it can be dropped |
|---|---|
| `--without-amaro` (TS type-stripping) | for consumers shipping plain `.js` |
| `--without-inspector` | not used in production |
| `--without-sqlite` | for consumers using the `better-sqlite3` addon, not `node:sqlite` |
| `--with-intl=none` (no ICU) | for consumers that use no `Intl.*` — verify per consumer (e.g. valibot's only `Intl` user, `Intl.Segmenter`, sits behind grapheme validators that may be unused); also shipped on Node 18 with `intl=none` |
| `-ffunction-sections`/`--gc-sections` | dead-code strip; no behavior change |
| **iOS only:** `--v8-lite-mode` | drops the compiled JIT + V8 WASM engine, both **dead on iOS** (it runs jitless; WebAssembly is served by the bundled polywasm polyfill — see [FAQ](./FAQ.md#does-fetch-work-what-about-webassembly)). This is the big lever. |

Measured shipping sizes (arm64, after symbol strip):

- **iOS:** ~63 MB (full) → **~44.5 MB (lite)**, a ~29% cut (mostly `--v8-lite-mode`).
- **Android:** smaller via the feature drops + gc-sections, but no
  `--v8-lite-mode` (Android keeps the JIT and V8's native WASM for undici).

`build-id` (`-Wl,--build-id=sha1`) is emitted on the Android `libnode.so` in
**both** flavors so Sentry can symbolicate native crashes. The standing
safeguard for `intl=none` is the consumer's own backend test suite run against the
lite binary — it catches any `Intl` breakage from future dependency changes.

