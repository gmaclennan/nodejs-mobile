# Contributing

Only changes that fall within the [project goals](../README.md#project-goals-and-license)
will be accepted. For a major feature or a semantic change, please open an
issue for discussion first; for minor fixes, open a pull request directly.

## The development loop

```sh
scripts/prepare.sh                    # → ./out, a complete verified source tree
cd out
# ... edit, build (see BUILDING.md), run tests (see TESTING.md) ...
git commit -am "what I changed"       # any commit shape is fine
cd ..
scripts/regenerate-patches.py out     # fold changes back into patches/ + mobile-src/
```

Commit the regenerated `patches/` and `mobile-src/`, plus the
`expected-tree.txt` hash the script prints, and open a PR against `patches`.

What goes where is enforced by the tooling: an edit to an upstream file
updates its owning patch, a new file lands in `mobile-src/`, and an edit to
an upstream file no patch owns is an error until you assign it in
`patches/files.map`. See [PATCHES.md](./PATCHES.md) for the rules and the
reasoning.

## Commit messages

Follow the [Node.js commit message guidelines](https://github.com/nodejs/node/blob/main/CONTRIBUTING.md#commit-message-guidelines):
a subsystem prefix, imperative mood, a body explaining *why*. Patch commits
carry the same convention — their subjects become the patch file names, and
their bodies are what a future maintainer reads when deciding whether
upstream has made a patch obsolete. Platform-specific work should say so
(`android:` / `ios:`).

## Review process

Open PRs against the `patches` branch. Diffs are small by construction —
patch files, `mobile-src/` files, and the tree hash — so review is a normal
code review, not an archaeology exercise. CI is tiered:

- **on the PR** (minutes): byte-for-byte reconstruction (`verify`), per-patch
  `./android-configure` validation, and the host smoke build;
- **on merge**: the full build matrix, both flavors, plus the Tier-1 boot
  smokes and the NAPI symbol smoke;
- **on release**: everything above plus the Tier-2 emulator/simulator suites
  and the Tier-3 real-device smoke, all gating an automated publish (see
  [RELEASING.md](./RELEASING.md)).

A clean `git am` is not proof of correctness — when a patch touches C++ or
the build system, let the post-merge matrix finish before assuming an
upgrade is sound.

## Upgrading to a newer upstream Node.js

See [UPGRADING.md](./UPGRADING.md).

<a id="developers-certificate-of-origin"></a>

## Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

* (a) The contribution was created in whole or in part by me and I
  have the right to submit it under the open source license
  indicated in the file; or

* (b) The contribution is based upon previous work that, to the best
  of my knowledge, is covered under an appropriate open source
  license and I have the right under that license to submit that
  work with modifications, whether created in whole or in part
  by me, under the same open source license (unless I am
  permitted to submit under a different license), as indicated
  in the file; or

* (c) The contribution was provided directly to me by some other
  person who certified (a), (b) or (c) and I have not modified
  it.

* (d) I understand and agree that this project and the contribution
  are public and that a record of the contribution (including all
  personal information I submit with it, including my sign-off) is
  maintained indefinitely and may be redistributed consistent with
  this project or the open source license(s) involved.
