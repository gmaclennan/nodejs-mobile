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

## Materialize + release

```sh
scripts/prepare.sh out-release            # fresh, verified materialization
cd out-release
git push <fork> HEAD:refs/heads/release/vX.Y.Z-0
```

- `Build` runs on `release/**`; once green, add the `mobile-test` label to
  the release PR for the Tier-2 emulator/simulator gates, and run the
  Tier-3 BrowserStack device smoke (see [TESTING.md](./TESTING.md)).
- The release PR needs a final commit with subject
  `release: nodejs-mobile X.Y.Z-0` (dates the CHANGELOG entry) — that
  subject is what `publish-release.yml`'s guard keys on.
- Merging is a **force-push of `mobile/v24`** to the release tip — an
  upstream bump is a new history rooted at the new tag; the previous
  history stays reachable via the release tags. `publish-release.yml` then
  tags and publishes (prerelease until a device smoke is recorded, see
  [RELEASING.md](./RELEASING.md)).

## Cross-major upgrades (e.g. v24 → v26)

Same procedure, larger blast radius: bump the base to the new major's LTS
tag and expect several patches to need rework or deletion (upstream may
have absorbed or obsoleted them — each patch body records *why* it exists
for exactly this decision). Materialize to a new `mobile/v26` branch;
`mobile/v24` stays for the old line.
