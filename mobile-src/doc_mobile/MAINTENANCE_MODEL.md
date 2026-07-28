# Maintenance model: patches branch + materialized source branch

nodejs-mobile is maintained as a small set of **patches and fork-only files
on the orphan [`patches` branch](../../../tree/patches)** — the canonical
representation of the entire mobile contribution (~1.5 MB) — plus this
**materialized full-source branch** (`mobile/v24`), which is what CI builds,
tests, and releases.

| Branch | Role |
| --- | --- |
| `patches` | canonical: `patches/` (per-concern diffs to upstream files) + `mobile-src/` (fork-only files) + `scripts/prepare.sh` / `regenerate-patches.py` + `expected-tree.txt` integrity anchor |
| `mobile/v24` | generated materialization of `patches` on upstream `v24.x`: the branch CI compiles and releases are tagged from |
| `main` | legacy v18.20.4 line (frozen) |

The invariant tying them together: `prepare.sh` on the patches branch must
reconstruct **byte-for-byte** the tree of this branch's tip
(`expected-tree.txt`), and CI on the patches branch re-proves that against a
real upstream clone on every push.

## Changing mobile code

Day-to-day changes happen via the patches branch dev loop (see its README):
`prepare.sh` → edit/commit in `out/` → `regenerate-patches.py` → commit the
regenerated `patches/` + `mobile-src/` → materialize and push here. Small
doc-only changes may land here first and be synced back; the tree-hash gate
keeps the two from drifting silently.

Guidelines for the patch series itself:

- One patch per concern, minimal diff, subsystem-prefixed subject
  (`build:`, `src:`, `deps,v8:`, …). `patches/files.map` records which patch
  owns which upstream file.
- The commit body says *why* the change is needed, so a future upgrade can
  decide whether upstream has made the patch obsolete.
- Fork-only files (no upstream counterpart) never become patches — they live
  in `mobile-src/` as plain files.

## Upgrading upstream Node.js

See [UPGRADING.md](./UPGRADING.md). Summary: bump `upstream-base.txt` on the
patches branch, run `prepare.sh`, resolve any conflicting patch in `out/`,
regenerate, then materialize this branch from the new base (a force-push —
release tags preserve the old history) and run the release pipeline.

## History

The project previously used a squash-merge import per upstream release
(through v18.20.4, on `main`), then a rebased in-tree patch stack (the first
v24 releases). The patches-branch model replaced the rebased stack in July
2026 because history rewriting made stack maintenance painful; the stack's
commits, messages, and attribution live on as the generated patch series.
