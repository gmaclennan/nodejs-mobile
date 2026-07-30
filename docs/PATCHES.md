# The patches model

nodejs-mobile is maintained as a **recipe for a source tree**, not as a fork
of one. This document explains the pieces, the rules that keep them
consistent, and why it is built this way. For the day-to-day loop see
[CONTRIBUTING.md](./CONTRIBUTING.md); for upstream bumps,
[UPGRADING.md](./UPGRADING.md).

## The pieces

| File / directory | Role |
|---|---|
| `upstream-base.txt` | the pinned `nodejs/node` release tag the patches apply to |
| `patches/*.patch` | one patch per **concern**, covering every upstream file the project modifies or deletes |
| `patches/series` | apply order |
| `patches/files.map` | `patch<TAB>path` for every file a patch owns — the partition that makes regeneration deterministic |
| `mobile-src/` | files with **no upstream counterpart**, tracked as plain files (build scripts, iOS framework project, test apps and harness) |
| `expected-tree.txt` | the git tree hash the reconstruction must produce |
| `scripts/prepare.sh` | recipe → source tree, with the hash check |
| `scripts/regenerate-patches.py` | source tree → recipe |

The split matters: a fork-only file never becomes a patch (a patch that
re-adds the same 400-line file on every upgrade is noise), and an upstream
file is never edited outside a patch (that is what makes the diff to upstream
readable and reviewable).

## The integrity check

`prepare.sh` = clone upstream at the base → `git am` the series → overlay
`mobile-src/` → compare the resulting git tree hash against
`expected-tree.txt`, and fail on mismatch.

A git tree hash is a Merkle checksum of an entire directory: paths, contents,
and executable bits. Two trees share a hash only if they are byte-for-byte
identical. Committing that hash next to the recipe closes a class of quiet
failures — a hunk applying with drifted context in the wrong place, whitespace
mangling from someone's git config, a lost `+x` bit, a fork-only file that
didn't survive the overlay, or an upstream tag being re-pointed at different
content. It does not assert that the tree is *good*, only that it is exactly
the tree whose recipe was reviewed.

It is enforced in three places: on every push (`verify-patches.yml`, against
a fresh upstream clone), inside every CI job before it compiles (the
`materialize` action), and at release time (the tag points at a materialized
commit with that tree).

**So: any intentional change to the recipe changes the product — run
`prepare.sh` or `regenerate-patches.py`, and commit the new hash with the
change.** Forgetting is safe; CI fails and prints the hash it computed.

## Patch rules

- **One concern per patch**, minimal diff, subsystem-prefixed subject
  (`build:`, `src:`, `deps,v8:`, `test:`). `files.map` records ownership.
- **The commit body explains *why*** — which platform limitation forces the
  change. On the next upgrade that is what tells you whether upstream has
  made the patch obsolete.
- **New upstream-file edits need an owner**: assign the file to an existing
  patch in `files.map`, or add a new `NNNN-name.patch` to `series` +
  `files.map`. `regenerate-patches.py` refuses to guess.
- **New files default to `mobile-src/`**, unless they are upstream-coupled
  (e.g. a new file inside `deps/`), in which case give them to a patch.

Patch messages and `Co-authored-by:` trailers carry the attribution of the
original nodejs-mobile contributors whose work the series descends from.

## Branches

| Branch | Role |
|---|---|
| `patches` | the project: the recipe, the tooling, the docs, and all CI |
| `mobile/v24` | frozen — the materialized branch CI used through 24.18.0-0 |
| `main` | frozen — the legacy Node 18 line |

Release tags (`vX.Y.Z-R`) point at **materialized full-source commits**, so
every release stays browsable as a complete tree even though no branch
carries one.

## Why this shape

The project has used three models. Through v18 it was a squash-merge import
of each upstream release — one commit of ~5M changed lines, effectively
unreviewable and impossible to bisect. The first Node 24 work replaced that
with a rebased in-tree patch stack, which made the changes legible but put
every edit through history rewriting: fix-ups accumulated on top, restoring
atomicity meant an interactive rebase of a 50-commit stack, force-pushes
invalidated review state, and CI had to re-validate every commit.

The patches model keeps the legibility and drops the history management.
Patches are ordinary files: editing one is a normal commit with a reviewable
diff, no rebase, no force-push. What it deliberately does *not* claim to fix
is upstream conflicts — a conflicting upstream change is the same work
either way. What it changes is that the work is isolated to one small patch,
and that resolving it is an edit rather than a rebase.

The cost is real and worth stating: the source tree is not directly
browsable here (run `prepare.sh`, or read a release tag), and GitHub renders
patch files as text rather than as diffs.
