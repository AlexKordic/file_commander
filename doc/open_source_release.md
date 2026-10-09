# Open-source publication review and release plan

Reviewed on 2026-10-09. This document separates publishing the source repository
from qualifying and distributing the complete FC/Fresh/7zr binary package.

## Findings and fixes

| ID | Finding | Preparation / next action |
| --- | --- | --- |
| OS-01 | FC had no root license; `log.hpp` contained a proprietary notice in the committed revision. | Added MIT `LICENSE` naming Alex Kordic, at the owner's direction, and replaced the old restriction with MIT attribution in `log.hpp`. Preserve other contributors' and dependencies' attribution. |
| OS-02 | Vendored Boost.Filesystem referred to a missing Boost license text. | Added the full BSL-1.0 text in the subtree and `licenses/boost/`. Original third-party headers remain intact. |
| OS-03 | Packages carried Fresh's GPL text but omitted other top-level dependency notices. | Added an inventory and license copies for FTXUI, LuaJIT/Lua/dlmalloc, Boost and LZMA, plus Fresh's separate asset notices. Packaging must retain them; the package gate rejects missing required notices. This does not complete OS-07. |
| OS-04 | FTXUI bootstrap pointed at localhost; the SDK needed a provisioned local folder. | Changed FTXUI to its public fork and LuaJIT to the public GitHub mirror; included a checksum-verified SDK 26.00 source snapshot. Bootstrap preserves existing inputs, supports mirror overrides and checks the unchanged source fingerprint. Publish the pinned FTXUI branch before FC. |
| OS-05 | No root README, contribution guide or security-reporting policy. | Added build/use/test/license documentation, contribution guidance, a security policy and an unreleased changelog. Removed the personal checkout path from the SSH instructions. |
| OS-06 | GitHub CI expected private self-hosted runners and dependency provisioning. | Added hosted Ubuntu 24.04/GCC 14 core checks for pushes/PRs in the publishing checkout. Full native/sanitizer workflows require explicit maintainer dispatch and use the public bootstrap. Their first GitHub run and full native Linux qualification remain separate checks. Do not execute untrusted fork PRs on internal runners. |
| OS-07 | Fresh's Rust and embedded dependency notices were not fully audited or packaged. | A pinned macOS default-feature normal/build dependency inventory is recorded in `qualification/open-source-license-audit-2026-10-09.json`. Resolve missing notice files from the corresponding upstream source, select permitted alternatives where needed, review embedded grammars/themes/plugins/native libraries, and generate a complete notice bundle for each shipping target. Missing a separate file is a review item, not proof of incompatibility. Block a public binary release until this is complete. |
| OS-08 | Fresh's upstream reference and delta bundle are not our complete binary-source delivery process. | Publish an exact Fresh source archive with locked non-system dependency sources, build instructions and source checksums alongside each binary download. The procedure below is the starting point; verify the exported source builds. Block a public binary release until source delivery and OS-07 are complete. |
| OS-09 | Earlier release evidence is macOS-specific and predates publication changes. | Existing SSH qualification and 197-test automatic macOS run remain historical evidence. Requalify the final source revision, then run the manual lane in a native service context. Qualify Linux on native hosts before claiming Linux release support. |
| OS-10 | The pinned SDK 26.00 predates upstream bug/security fixes. | Review SDK 26.02–26.04 advisories and applicability, deliberately update the snapshot/pins if required, and rerun archive and transfer regressions before binaries are released. Source publication itself does not upgrade this dependency. |
| OS-11 | Public repository settings and confidential-history review need attention. | Enable private vulnerability reporting, set `main` as default, and configure branch protection after hosted checks pass. A limited credential-pattern scan of current files and all 1,374 FC history blobs found no private keys or common GitHub/AWS token literals. Review history and the Fresh bundle for other confidential material before publication; pattern scanning is not a full secrets audit. Historical copyright notices and author emails remain in normal Git history. |
| OS-12 | User-facing release version and support policy need a decision. | Select the first release version/tag, document supported OS/architectures and minimum macOS version, and populate the changelog from the qualified candidate. The existing CMake project version alone does not establish a stable release. Add conventional CLI help/version output in a follow-up. |

`Perun` namespaces and header guards are identifiers, not proprietary license
restrictions. Renaming them is not required to apply MIT. Internal remotes live
in `.git/config` and are not published by a normal branch push. Avoid rewriting
history solely to remove old notices; any history sanitization needs a separate,
explicit decision and review.

## Public source layout

The existing internal repositories remain in their current directories. The
publication workspace uses:

| Checkout | Public branch | Purpose |
| --- | --- | --- |
| `/Users/alex/code/file_commander` | `main` | FC public source, with GitHub `origin` and the current LAN repository as `internal` |
| `/Users/alex/code/FTXUI` | `fc-integration` | Exact modified FTXUI revision; preserve the fork's upstream default branch |
| `/Users/alex/code/fresh` | `fc-editor-workflow` | Exact modified Fresh revision; preserve the fork's upstream default branch |

The owner has verified SSH authentication as `AlexKordic`. Push the dependency
branches first, then FC. No force push or history replacement is required.
FTXUI and Fresh should also retain an `upstream` remote for their original
projects. Do not change those dependencies' upstream licenses to MIT for FC.

## Fresh source archive procedure

Use the exact clean Fresh revision from `dependencies.json` and a working pinned
Rust toolchain. For example, from the FC root after dependency bootstrap:

```sh
mkdir -p build-release/fresh-source
git -C build-deps/fresh archive "$(git -C build-deps/fresh rev-parse HEAD)" \
  | tar -x -C build-release/fresh-source
(
  cd build-release/fresh-source
  mkdir -p .cargo
  cargo vendor --locked --versioned-dirs vendor > .cargo/vendor-config.toml
  cargo --config .cargo/vendor-config.toml build --release --frozen \
    -p fresh-editor --bin fresh
)
tar --exclude=target -czf build-release/fresh-corresponding-source.tar.gz \
  -C build-release fresh-source
```

Use a newly created empty export directory; do not reuse an older export. Check
the exported commit against the manifest before starting. Preserve the upstream
source, `Cargo.lock`, toolchain file, native source dependencies, license/notice
files and any added build configuration. Cargo vendoring includes the locked
registry/Git dependency sources; inspect build scripts for other downloads and
include any additional non-system inputs. Retain a list of changes and build
options, including the default features used by FC.

Publish the source archive and its SHA-256 next to the matching binary package
on the same release page. The package must point recipients to that release's
exact source download. A Git bundle, a moving branch, a Cargo license identifier,
or a promise that upstream source can be found is not a substitute for this
process. Test source reconstruction and build before uploading artifacts.

This follows [GPLv3 section 6](https://www.gnu.org/licenses/gpl-3.0.html#section6)
and uses [Cargo's supported vendoring mechanism](https://doc.rust-lang.org/cargo/commands/cargo-vendor.html).
It is a release procedure, not a claim that those artifacts have already been
published or that the transitive notice audit is finished.

## Remaining sequence

1. Review the preparation commits, the documented history limitation and the
   dependency notices; push FTXUI, Fresh and FC in that order.
2. Verify anonymous bootstrap from GitHub, watch the hosted core checks, enable
   private security reporting and set repository protections. This verifies
   public availability; local mirror tests cannot prove it.
3. Finish Fresh's per-target notice audit, export and rebuild corresponding
   source, and resolve the SDK security-update finding.
4. Select the release version and supported platforms. Run the full automatic
   release lane and separate manual lane on each claimed native target; retain
   source/dependency revision, package hashes and JUnit evidence.
5. Publish immutable source/binary archives, checksums, dependency pins, release
   notes, support limitations and the Fresh source-download instructions.

## Authoritative references

- [MIT license and attribution](https://choosealicense.com/licenses/mit/).
- [Boost Software License](https://www.boost.org/LICENSE_1_0.txt).
- [LZMA SDK public-domain statement and update history](https://www.7-zip.org/sdk.html).
- [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html), particularly sections 5 and 6.
- [GitHub Actions security guidance](https://docs.github.com/en/actions/reference/security/secure-use).

## Preparation verification

The internal preparation through `6b3b9a9` passed the following targeted checks
on macOS arm64 on 2026-10-09:

- Isolated bootstrap and repeat validation using local mirrors for the pinned
  Git objects and the bundled SDK snapshot. GitHub DNS was unavailable in the
  agent environment, so public anonymous bootstrap remains a post-push check.
- `fc.harness.dependencies`, including source corruption, archive checksum and
  unsafe extraction rejection controls.
- `fc.harness.lanes`, including rejection of packages missing dependency notices.
- `fc.harness.fresh_bundle`, reconstructing the exact Fresh integration revision.
- `fc.package_build`, including executable hashes against the build outputs.
- Byte comparison of every packaged checked-in dependency notice and FC's MIT
  license against its source copy.
- Local Markdown link checks and Git whitespace checks.

All four targeted CTest cases passed. This is publication-preparation evidence;
the complete final automatic/manual release qualification has not been rerun.

The publishing checkout's clean Release headless build passed all 38 selected
core cases on macOS arm64. Its pinned FTXUI/Fresh branches and SDK source set
passed dependency verification. GitHub workflow YAML and local documentation
links were checked. The ignored `github-release` user preset selects the sibling
`FTXUI` and `fresh` clones and local verified LuaJIT/SDK inputs. A cached official
Boost archive was checksum-verified by CMake; these local checks do not establish
anonymous download availability or a passing Linux GitHub runner.

The publishing checkout also includes the follow-up Python version guard from
`70cec86`: unsupported Python fails before cloning or creating dependency inputs.
