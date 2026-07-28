# Release Instructions

Releases are **automated and guarded**: a maintainer opens a release PR by
dispatching a workflow, CI proves the binaries build and pass the test gate, and
merging the reviewed PR triggers the tag + GitHub Release behind a human
approval. **No one pushes a tag by hand**, and nothing publishes unless the
tests passed first.

Two workflows drive it:

- [`prepare-release.yml`](../.github/workflows/prepare-release.yml) — opens the
  release PR (version bump + CHANGELOG + release flag).
- [`publish-release.yml`](../.github/workflows/publish-release.yml) — on merge,
  tags and publishes, behind the `release` Environment approval.

The version of record is `src/node_mobile_version.h`. The tag is
`nodejs-mobile-<node-version>-<rev>` (e.g. `nodejs-mobile-24.15.0-0`); the
`-<rev>` suffix increments for a mobile-only rebuild of the same upstream
Node.js version. Releases ship **both flavors** — `full` (the default
binary) and `lite` (size-reduced; see the
[lite variant](./README.md#the-lite-variant)).

---

## One-time setup (admin)

1. **Release GitHub App** — create a GitHub App (org or personal) with repository
   permissions **Contents: write** + **Pull requests: write**, install it on this
   repo, and store its App ID as the `RELEASE_APP_ID` **variable** and its private
   key as the `RELEASE_APP_PRIVATE_KEY` **secret**. prepare/publish-release mint a
   short-lived, repo-scoped token from it via `actions/create-github-app-token`.
   (An App token is used, not the default `GITHUB_TOKEN`, because a branch pushed
   with `GITHUB_TOKEN` does *not* trigger the Build/gate workflows — and an App
   token is short-lived and scoped, unlike a long-lived personal PAT.)
2. **`release` Environment** (Settings → Environments) with **required
   reviewers**. `publish-release.yml` runs its tag+publish job in this
   Environment, so it pauses for human approval before the irreversible step.
3. **Branch protection** on `mobile/v24` — run
   [`scripts/mobile/setup-branch-protection.sh`](../scripts/mobile/setup-branch-protection.sh).
   It requires the always-run checks (`smoke-android`, `smoke-ios`,
   `smoke-host`, `napi-smoke-android`) and a review, and enforces linear history.

---

## Cutting a release

1. **Dispatch `prepare-release`** with the version (e.g. `24.15.0`). It opens a
   `release/vX.Y.Z` PR that bumps `src/node_mobile_version.h`, flags
   `NODE_VERSION_IS_RELEASE`, prepends a CHANGELOG stub, and adds the
   `mobile-test` label so the Tier-2 curated gate runs.
2. **Fill in the CHANGELOG** entry in the PR and review the diff.
3. **Wait for green.** Required checks (build + smoke + NAPI) must pass to merge;
   the Tier-2 curated gate (both platforms) also runs via the label —
   `publish-release` re-checks it before tagging, so it must be green for the
   release commit.
4. **Real-device smoke** (Tier 3) — **automatic and required**: on
   `release/**` branches the Build workflow's `device-smoke` job runs
   [`browserstack-smoke.yml`](../.github/workflows/browserstack-smoke.yml)
   against this run's artifacts — boot + crc-native N-API addon load on a
   physical Android arm64 device (Pixel 9, 16 KB pages) and a physical
   iPhone via BrowserStack App Automate — and `publish-release.yml` refuses
   to tag unless a green Build run for the release SHA contains these jobs.
   No manual step; the dispatch trigger remains for ad-hoc runs.
   (It smokes the `full` flavor; a physical smoke of `lite` remains manual —
   `tools/mobile-test/addon/build-{android,ios}-addon.sh` + 
   `test-napi-addon.js` — if the release is promoted for lite-only consumers.) This is a manual gate; GitHub-hosted runners
   have no physical devices, so the `release` Environment approval (step 6)
   attests it was done.
5. **Merge the PR** with **rebase/fast-forward** (linear history is required, so
   the merge commit keeps the PR's SHA and its green gate run applies).
6. **Approve the `release` Environment.** Merging fires `publish-release.yml`; it
   waits for your approval, then tags `nodejs-mobile-X.Y.Z`, builds **both
   flavors**, and creates the GitHub Release with four zips:
   `nodejs-mobile-{android,ios}{,-lite}-X.Y.Z.zip`.
7. **Post-release:** open a follow-up PR unflagging `NODE_VERSION_IS_RELEASE`
   (`src: unflag NODE_VERSION_IS_RELEASE`), and bump the consumer plugins
   (`nodejs-mobile-react-native`, `-cordova`).

---

## Why this shape

The old flow was 16 manual steps ending in `git push origin --tags` with nothing
enforcing that CI had passed — a single-point-of-failure we removed. We already
produce the two combined artifacts that *are* the release payload and a credible
test gate ([`TESTING.md`](./TESTING.md)); this just wires them so the tag
can only exist after the gate is green and a human approves the publish.
