# Release Instructions

Releases are **fully automated behind a single commit**. The entire gate
chain — build (all arches, both flavors), Tier-1 boot smokes, NAPI symbol
smoke, Tier-2 emulator/simulator curated suites, and the Tier-3 BrowserStack
real-device smoke — runs as one `build.yml` run on the
[`patches` branch](../../../tree/patches), and the publish job (tag +
GitHub prerelease) sits behind `needs:` on all of it. No PAT, GitHub App,
tag push, or manual test step is involved.

The version of record is `mobile-src/src/node_mobile_version.h`. The tag is
`nodejs-mobile-X.Y.Z-R`, pointing at a materialized full-source commit (so
every release remains browsable as a complete tree). Releases ship both
flavors: four zips, `nodejs-mobile-{android,ios}{,-lite}-X.Y.Z-R.zip`.

## Cutting a release

On the `patches` branch, open an ordinary PR (or push directly) that:

1. bumps `mobile-src/src/node_mobile_version.h` (upstream bump → mirror the
   new version, revision 0; mobile-only rebuild → increment `REVISION`);
2. adds a dated `X.Y.Z-R` section to `mobile-src/doc_mobile/CHANGELOG.md`
   (the publish job uses the first `##` section as the release notes);
3. updates `expected-tree.txt` (run `scripts/prepare.sh` locally, or take
   the hash from the failed verify run);
4. lands with the **final commit subject** `release: nodejs-mobile X.Y.Z-R`
   — this exact subject is what triggers the gate chain and what the
   publish job asserts against the version of record.

Merging/pushing that commit runs everything; if every gate is green the
prerelease appears with all four zips. A red gate means no tag and no
release — fix and push a new `release:` commit.

## Dress rehearsal

A commit with subject `release-dryrun: nodejs-mobile X.Y.Z-R` runs the
identical chain — including real devices — but skips the two mutating steps
(tag push, release create), printing what would have been published. Use it
after pipeline changes or before a nervous release.

## Promotion from prerelease

Releases publish with the **prerelease** flag. The Tier-3 device gate has
already passed for the `full` flavor by construction; promote (untick
"prerelease" on the release page) when you're satisfied — `lite` is
emulator/simulator-tested only, so give it a manual device pass first if
your consumers ship lite.

## Post-release

Bump the consumer plugins (`nodejs-mobile-react-native`, `-cordova`) to the
new zips as needed. No version-unflag commit is required: the stack keeps
upstream's release-tagged `NODE_VERSION_IS_RELEASE` as-is.
