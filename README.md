# nodejs-mobile — patches branch

This branch is the **canonical, patches-only representation of nodejs-mobile**
(the model sketched in `doc_mobile/PATCHES_ONLY_PROPOSAL.md` on `mobile/v24`,
now adopted). It contains the *entire* mobile contribution — about 1.5 MB —
instead of a ~1 GB fork of upstream Node.js:

| Path | What it is |
| --- | --- |
| `upstream-base.txt` | the pinned upstream `nodejs/node` release tag (`v24.15.0`) |
| `patches/` | one patch per mobile concern for **modified/deleted upstream files** (109 files across 19 patches), plus `series` (apply order) and `files.map` (which patch owns which file) |
| `mobile-src/` | **fork-only files** with no upstream counterpart (build scripts, xcframework project, test apps and harness, CI workflows, mobile docs) — plain files, not patches |
| `expected-tree.txt` | the git tree hash the reconstruction must produce, byte-for-byte |
| `scripts/prepare.sh` | clone upstream @ base → `git am` the series → overlay `mobile-src/` → verify against `expected-tree.txt` |
| `scripts/regenerate-patches.py` | the dev loop: re-emit `patches/` + sync `mobile-src/` from an edited `out/` tree |

Attribution from the original patch stack is preserved in each patch's
`Co-authored-by:` trailers.

## Get a buildable tree

```sh
scripts/prepare.sh          # produces ./out — a full source tree, verified
cd out
./android-configure ...     # build as usual (see doc_mobile/BUILDING.md in out/)
```

`prepare.sh` fails loudly if any patch does not apply or the reconstructed
tree does not hash to `expected-tree.txt`.

## Make a change

```sh
scripts/prepare.sh
cd out
# ... edit, build, test ...
git commit -am "what I changed"          # any commit shape is fine
cd ..
scripts/regenerate-patches.py out
git add patches mobile-src expected-tree.txt   # update expected-tree.txt to the printed hash
git commit -m "src: ..."
```

Rules of the partition (enforced by `regenerate-patches.py`):

- an edit to a file **owned by a patch** (see `patches/files.map`) re-emits
  that patch — unchanged patches regenerate byte-identically;
- a **new file** goes to `mobile-src/` by default;
- an edit to an upstream file owned by **no** patch is an error — assign the
  file to an existing patch or add a new `NNNN-name.patch` entry to `series`
  + `files.map` first. Keep patches per-concern and minimal.

## Upgrade to a newer upstream release

```sh
$EDITOR upstream-base.txt                # bump the tag, e.g. v24.16.0
scripts/prepare.sh                       # conflicts (if any) stop at the failing patch
# resolve in out/ (git am --continue), build, test
scripts/regenerate-patches.py out        # re-emit the series against the new base
# update expected-tree.txt, commit
```

Because each patch is a small per-concern diff, a conflicting upstream change
is isolated to one patch; a patch made obsolete by upstream is deleted from
`series` + `files.map`.

## Relationship to the other branches

- **`mobile/v24`** is the full-source materialization this branch was
  generated from (its tip tree at generation time is `expected-tree.txt`).
  The build/test/release CI (`build-mobile.yml`, Tier-1/2 gates,
  `publish-release.yml`, BrowserStack Tier-3 smoke) currently runs there.
  After changing this branch, materialize and push:

  ```sh
  scripts/prepare.sh out && cd out
  git remote add fork git@github.com:gmaclennan/nodejs-mobile.git
  git push fork HEAD:refs/heads/mobile/v24   # fast-forward-only by policy
  ```

  (Longer term the build CI can run `prepare.sh` itself and `mobile/v24`
  becomes a generated artifact; that migration is deliberate follow-up work,
  not part of this branch.)
- **`main`** is the legacy v18.20.4 line.
- Releases are tagged from the materialized branch (`nodejs-mobile-X.Y.Z-R`),
  unchanged.

## CI on this branch

`verify-patches.yml` runs `prepare.sh` against a real shallow clone of
`nodejs/node` on every push and fails unless the tree matches
`expected-tree.txt` — the branch can never silently drift from what it
claims to reconstruct.
