# Updating nodejs-mobile to a newer upstream Node.js

Upgrades happen on the [`patches` branch](../../../tree/patches) — the
canonical patches-only representation — and are then materialized to this
full-source branch for CI and release. There is no rebasing of long-lived
branches and no force-push of anything except the final materialization.

The procedure below is what the 24.15.0 → 24.18.0 upgrade actually took
(five small conflicts, all resolved in minutes).

## On the patches branch

```sh
git switch patches
$EDITOR upstream-base.txt                 # bump the tag, e.g. v24.18.0
scripts/prepare.sh                        # clone new base + apply series
```

`prepare.sh` stops at the first patch that no longer applies. For each
conflict, resolve **in `out/`** with the usual `git am` loop
(`git status` → edit → `git add` → `git am --continue`), guided by one
question: *what does this patch intend, and what did upstream change?*
Patterns seen in practice:

- **Adjacent churn** — upstream changed a line next to a mobile hunk (e.g. a
  version string in `common.gypi`): keep upstream's new value, keep the
  mobile hunk.
- **Both append at the same spot** (e.g. the tail of a gyp `conditions`
  list): keep both blocks, upstream's first.
- **Upstream restructured context the patch relied on** (e.g. a macro block
  the mobile diff sat inside was removed): re-apply only the mobile intent
  against the new structure.
- **Delete/modify** — a file we delete was modified upstream: the intent is
  still deletion → `git rm` the unmerged paths, continue.
- **Wholesale-replacement docs** (the fork `README.md` replaces the upstream
  remainder): resolve to ours.

A clean `git am` is **not** proof of semantic correctness: in the 24.18.0
bump, an upstream restructure of `crypto_context.cc` merged cleanly but left
our `#endif // TARGET_OS_OSX` above a new function tail that used
guard-scoped identifiers — caught only by the iOS compile. Treat the full
Build matrix as part of the upgrade loop, and re-check that every
platform-guard (`TARGET_OS_OSX` / `__ANDROID__`) still encloses everything
it needs to.

Also update, in `mobile-src/`:

- `src/node_mobile_version.h` — mirror the new upstream version (revision
  resets to 0);
- `doc_mobile/upstream-base.txt` — same tag (read by
  `validate-patch-stack.yml` on the materialized branch);
- `doc_mobile/CHANGELOG.md` — new `X.Y.Z-0` section;
- check `.github/workflows/` in `out/` for **new upstream workflows** the
  removal patch doesn't cover yet — delete-and-own them in patch 0019 if
  they would actually run on this fork (most are gated on
  `github.repository == 'nodejs/node'` and are harmless).

Then regenerate and commit:

```sh
git -C out add -A && git -C out commit -m "resolve v24.18.0 conflicts"  # any shape
scripts/regenerate-patches.py out         # re-emits patches/ + syncs mobile-src/
# update expected-tree.txt to the hash the script prints
git add -A && git commit -m "upgrade: rebase patch series onto v24.18.0"
git push
```

The `verify-patches.yml` CI on the patches branch re-runs the reconstruction
against a fresh upstream clone and fails on any drift from
`expected-tree.txt`.

## Release

Land the upgrade with a final commit whose subject is
`release: nodejs-mobile X.Y.Z-0` (see [RELEASING.md](./RELEASING.md)). That
single push runs the whole gate chain — build, Tier-1/2/3 including real
devices — and publishes the prerelease when everything is green. Use a
`release-dryrun:` subject first if you want a rehearsal without tagging.

## Cross-major upgrades (e.g. v24 → v26)

Same procedure, larger blast radius: bump the base to the new major's LTS
tag and expect several patches to need rework or deletion (upstream may
have absorbed or obsoleted them — each patch body records *why* it exists
for exactly this decision). If both lines must stay releasable, branch the
patches branch itself (e.g. `patches-v24`) before bumping the base.
