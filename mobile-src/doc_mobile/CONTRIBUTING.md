# Contributing to Node.js for Mobile Apps

## Code Contributions
Only changes that fall within the scope of the [project goals](../README.md#project-goals) will be accepted.

If you want to implement a major feature or a semantical change, please open an issue for discussion first. For minor fixes, feel free to just open a pull request.

### Commit guidelines
Please ensure that commits messages adhere to the [Node.js commit message guidelines](https://github.com/nodejs/node/blob/master/CONTRIBUTING.md#commit-message-guidelines).

Platform-specific fixes for Android or iOS should be implemented in separate commits, and the titles of those commits should include `android` or `ios` in the list of affected subsystems.

## Review process

Development happens on the [`patches` branch](../../../tree/patches) — the
canonical patches-only representation. Open PRs against it; the diffs are
small and reviewable by construction (patch files, `mobile-src/` files, and
the `expected-tree.txt` anchor). CI is tiered:

- **on the PR** (minutes): byte-for-byte reconstruction (`verify`),
  per-patch `./android-configure` validation, host smoke;
- **on merge**: the full build matrix + Tier-1 smokes;
- **on release** (via the "Cut release" button and its reviewed PR — see
  [RELEASING.md](./RELEASING.md)): everything, including the Tier-2
  emulator/simulator suites and the Tier-3 real-device smoke, gating an
  automated publish.

## Updating nodejs-mobile from upstream nodejs/node

The squash-merge `format-patch` flow and the rebased in-tree patch stack
that followed it are both **superseded** — see
[MAINTENANCE_MODEL.md](./MAINTENANCE_MODEL.md) for the current model and
[UPGRADING.md](./UPGRADING.md) for the step-by-step upgrade procedure.

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
