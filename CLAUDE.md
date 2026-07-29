# CLAUDE.md — agent guide

This repo is the **recipe** for nodejs-mobile, not a copy of Node.js: a
pinned upstream tag, a series of patches, and the fork-only files. Read
[README.md](./README.md) for the layout and [docs/PATCHES.md](./docs/PATCHES.md)
for the model. Follow the linked docs rather than duplicating them here.

## Ground rules

- **Never edit a materialized tree and call it done.** Changes must go back
  through `scripts/regenerate-patches.py`, or they exist only in `out/`.
- **`expected-tree.txt` travels with every content change.** Commit the hash
  the tooling prints. CI fails loudly if you forget, and prints the right one.
- **Don't hand-edit `patches/*.patch`.** Edit in `out/`, regenerate. Hand
  edits break the `files.map` partition and byte-stability.
- **Don't push tags or create releases by hand.** Releases are produced by
  the pipeline (Cut release → reviewed PR → merge). See
  [docs/RELEASING.md](./docs/RELEASING.md).
- **Stage explicitly** (`git add <paths>`), never `git add -A` in `out/` —
  build outputs and scratch files must not reach a commit.

## The loop

```sh
scripts/prepare.sh                 # → ./out (verified full source tree)
cd out && $EDITOR … && make -j node
cd .. && scripts/regenerate-patches.py out
```

`regenerate-patches.py` enforces the partition: upstream-file edits update
their owning patch (`patches/files.map`), new files go to `mobile-src/`, and
an unowned upstream edit is an error until you assign it. → [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md)

## Build

- **Android:** `./tools/android_build.sh <ndk> <sdk> [arch]` — **Linux only**.
  A macOS host cannot complete it: node's gyp links the *host* build-tools
  with GNU `ar`/`ld` options Apple's toolchain rejects. Not a mobile bug.
- **iOS:** `./tools/ios_framework_prepare.sh [arm64|arm64-simulator]` —
  macOS/Xcode; produces `NodeMobile.xcframework`.
- **Python 3.12/3.13** with `setuptools` in the venv (gyp-next needs it).
- Flavors: default `full`; `NODEJS_MOBILE_FLAVOR=lite` for the small build.
- → [BUILDING.md](./mobile-src/doc_mobile/BUILDING.md)

## Test

The gate is a curated `test/parallel` subset
(`mobile-src/tools/mobile-test/tier2-parallel-tests.txt`) run through the
proxy harness on an Android emulator and an iOS simulator, plus boot smokes,
a NAPI symbol smoke, and a real-device smoke on BrowserStack. A test passes
when the app writes `PASS` to its per-launch sandbox verdict file — never
scraped from logs.

Curation caveats: tests that **spawn a child node process** can't pass on
Android and are excluded; a test calling **`process.exit()`** is mis-scored
by the per-process harness (libc `exit()` beats the verdict write), so none
are in the list. → [TESTING.md](./mobile-src/doc_mobile/TESTING.md)

## Upgrading upstream

Bump `upstream-base.txt`, run `prepare.sh`, resolve conflicts in `out/`,
regenerate. Expect a handful of small conflicts. **A clean `git am` is not
proof of correctness** — an upstream restructure can leave a platform guard
(`#if TARGET_OS_OSX`) enclosing the wrong span, which only the compile
catches. → [docs/UPGRADING.md](./docs/UPGRADING.md)

## Gotchas

- **WASI symlink fixtures:** the mobile test-asset copy scripts delete
  `test/fixtures/wasi/subdir/{input_link,outside}.txt` from the working tree.
  Restore them (`git checkout -- test/fixtures/wasi/subdir/`) before
  committing in `out/`, or they regenerate as spurious patch deletions.
- **One base, two readers:** `upstream-base.txt` at the repo root is the
  only place the pinned tag is written. Code running *inside* a materialized
  tree (where that file doesn't exist) derives it from upstream's own
  `src/node_version.h`, which this project never patches — don't reintroduce
  a shipped copy of the tag.
- **CI runs from this branch**, materializing per job. A workflow change is
  a `mobile-src`-free root-level edit and does not move the tree hash.
