# Maintenance model: patches branch + materialized source branch

nodejs-mobile is maintained as a small set of **patches and fork-only files
on the orphan [`patches` branch](../../../tree/patches)** — the canonical
representation of the entire mobile contribution (~1.5 MB) — plus this
**materialized full-source branch** (`mobile/v24`), which is what CI builds,
tests, and releases.

| Branch | Role |
| --- | --- |
| `patches` | canonical AND the CI branch: `patches/` (per-concern diffs to upstream files) + `mobile-src/` (fork-only files) + `scripts/prepare.sh` / `regenerate-patches.py` + `expected-tree.txt` + all workflows. Every CI job materializes the full tree via `.github/actions/materialize` before building. |
| `mobile/v24` | frozen (was the materialized CI branch through 24.18.0-0). Full-source trees now live on release tags (`nodejs-mobile-X.Y.Z-R`), each pointing at a materialized commit. |
| `main` | legacy v18.20.4 line (frozen) |

The invariant: `prepare.sh` must reconstruct **byte-for-byte** the tree
recorded in `expected-tree.txt`, and CI re-proves that against a real
upstream clone on every push — and again inside every build job, since each
one materializes before compiling.

## Changing mobile code

Day-to-day changes happen via the patches branch dev loop (see its README):
`prepare.sh` → edit/commit in `out/` → `regenerate-patches.py` → commit the
regenerated `patches/` + `mobile-src/` + updated `expected-tree.txt` to the
patches branch. CI builds from exactly that.

Guidelines for the patch series itself:

- One patch per concern, minimal diff, subsystem-prefixed subject
  (`build:`, `src:`, `deps,v8:`, …). `patches/files.map` records which patch
  owns which upstream file.
- The commit body says *why* the change is needed, so a future upgrade can
  decide whether upstream has made the patch obsolete.
- Fork-only files (no upstream counterpart) never become patches — they live
  in `mobile-src/` as plain files.

## Upgrading upstream Node.js

See [UPGRADING.md](./UPGRADING.md). Summary: bump `upstream-base.txt`, run
`prepare.sh`, resolve any conflicting patch in `out/`, regenerate, land a
`release:` commit — the pipeline does the rest.

## History

The project previously used a squash-merge import per upstream release
(through v18.20.4, on `main`), then a rebased in-tree patch stack (the first
v24 releases). The patches-branch model replaced the rebased stack in July
2026 because history rewriting made stack maintenance painful; the stack's
commits, messages, and attribution live on as the generated patch series.
