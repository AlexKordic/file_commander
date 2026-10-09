# Open-source status and binary-release requirements

Reviewed on 2026-10-09. FC's MIT source and its modified FTXUI and Fresh
dependencies are published on GitHub. This document records the source setup,
validation evidence, and requirements for distributing the complete
FC/Fresh/7zr binary package.

## Review findings and current status

| ID | Finding | Current status / binary-release requirement |
| --- | --- | --- |
| OS-01 | FC had no root license; `log.hpp` contained a proprietary notice. | FC has an MIT `LICENSE` naming Alex Kordic and MIT attribution in `log.hpp`. Other contributors' and dependencies' attribution is preserved. |
| OS-02 | Vendored Boost.Filesystem referred to a missing Boost license text. | The full BSL-1.0 text is in the subtree and `licenses/boost/`. Original third-party headers remain intact. |
| OS-03 | Packages omitted some top-level dependency notices. | The inventory and license copies cover FTXUI, LuaJIT/Lua/dlmalloc, Boost and LZMA, plus Fresh's separate asset notices. Packaging retains them; the package gate rejects missing required notices. The transitive audit in OS-07 remains incomplete. |
| OS-04 | Dependency bootstrap required private or locally provisioned inputs. | FTXUI uses its published FC fork and LuaJIT uses its public GitHub mirror. The source includes a checksum-verified SDK 26.00 snapshot. Bootstrap preserves existing inputs, supports optional mirrors and checks the pinned source fingerprint. |
| OS-05 | Root contributor and user documentation was missing. | The repository includes build/use/test/license documentation, contribution guidance, a security policy and an unreleased changelog. SSH instructions use portable checkout paths. |
| OS-06 | CI depended on private runners and dependency provisioning. | The GitHub repository has hosted Ubuntu 24.04/GCC 14 core checks for pushes and pull requests. Full native/sanitizer workflows require explicit maintainer dispatch and use public pinned inputs. Hosted core checks do not qualify a full native binary release. Untrusted fork PRs do not run on internal runners. |
| OS-07 | Fresh's Rust and embedded dependency notices were not fully audited or packaged. | A pinned macOS default-feature normal/build dependency inventory is recorded in `qualification/open-source-license-audit-2026-10-09.json`. Resolve missing notice files from the corresponding upstream source, select permitted alternatives where needed, review embedded grammars/themes/plugins/native libraries, and generate a complete notice bundle for each shipping target. Missing a separate file is a review item, not proof of incompatibility. Block a public binary release until this is complete. |
| OS-08 | Fresh's upstream reference and delta bundle do not provide complete binary-source delivery. | Each binary download requires an exact Fresh source archive with locked non-system dependency sources, build instructions and source checksums. The archive procedure below includes reconstruction and build verification. Source delivery and OS-07 are requirements for a public binary release. |
| OS-09 | Earlier release evidence is macOS-specific and predates the source, license and CI changes. | Existing SSH qualification and the 197-test automatic macOS run are historical evidence. The final binary candidate requires automatic and manual qualification for the same revision on each supported native target. Linux release support requires native Linux qualification. |
| OS-10 | The pinned SDK 26.00 predates upstream bug/security fixes. | Binary qualification requires reviewing SDK 26.02–26.04 advisories and applicability, deliberately updating the snapshot/pins if required, and rerunning archive and transfer regressions. The GitHub source retains the SDK 26.00 pin. |
| OS-11 | Repository maintenance and history review have explicit limits. | Public FC development uses `main`; security reports follow `SECURITY.md`. GitHub security settings and branch protections are maintainer controls. A limited credential-pattern scan of current files and all 1,374 FC history blobs found no private keys or common GitHub/AWS token literals. This is not a full secrets or confidentiality audit of FC history or the Fresh bundle. Historical copyright notices and author emails remain in normal Git history. |
| OS-12 | A stable binary version and support policy are not established. | The first stable binary release requires a version/tag, supported OS/architectures and minimum macOS version, and a changelog for the qualified candidate. The CMake project version alone does not establish a stable release. Conventional CLI help/version output remains a follow-up. |

`Perun` namespaces and header guards are identifiers, not proprietary license
restrictions. Renaming them is not required to apply MIT. Internal remotes are
local checkout settings in `.git/config`, outside the published source tree.
Historical notices remain part of normal Git history.

## Published source repositories

| Repository | Branch | Contents |
| --- | --- | --- |
| [File Commander](https://github.com/AlexKordic/file_commander) | `main` | FC source, MIT license, documentation, dependency manifest and bootstrap |
| [FTXUI fork](https://github.com/AlexKordic/FTXUI/tree/fc-integration) | `fc-integration` | Modified FTXUI history containing FC's exact pinned revision |
| [Fresh fork](https://github.com/AlexKordic/fresh/tree/fc-editor-workflow) | `fc-editor-workflow` | Modified Fresh history containing FC's exact pinned revision |

Builds use the exact revisions in `dependencies.json`, not moving branch tips.
FTXUI and Fresh retain their upstream history and licenses. Their upstream
projects are [ArthurSonzogni/FTXUI](https://github.com/ArthurSonzogni/FTXUI) and
[sinelaw/fresh](https://github.com/sinelaw/fresh). Fresh's integration bundle also
reconstructs the pinned revision from its public upstream base.

## Fresh source archive procedure for binary releases

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

Each binary release page must include the matching source archive and its
SHA-256. The package must point recipients to that release's exact source
download. A Git bundle, a moving branch, a Cargo license identifier, or a promise
that upstream source can be found does not satisfy this process. Test source
reconstruction and build before uploading binary release artifacts.

This follows [GPLv3 section 6](https://www.gnu.org/licenses/gpl-3.0.html#section6)
and uses [Cargo's supported vendoring mechanism](https://doc.rust-lang.org/cargo/commands/cargo-vendor.html).
The published GitHub repositories do not establish completeness of a binary
release's corresponding-source archive or transitive notice audit.

## Outstanding binary-release requirements

1. Complete Fresh's per-target notice audit, export and rebuild corresponding
   source, and resolve the SDK security-update finding.
2. Select the binary release version and supported platforms. Run the full
   automatic release lane and separate manual lane on each claimed native
   target; retain source/dependency revisions, package hashes and JUnit evidence.
3. Assemble immutable source/binary archives, checksums, dependency pins, release
   notes, support limitations and the Fresh source-download instructions for
   each binary release.

## Authoritative references

- [MIT license and attribution](https://choosealicense.com/licenses/mit/).
- [Boost Software License](https://www.boost.org/LICENSE_1_0.txt).
- [LZMA SDK public-domain statement and update history](https://www.7-zip.org/sdk.html).
- [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html), particularly sections 5 and 6.
- [GitHub Actions security guidance](https://docs.github.com/en/actions/reference/security/secure-use).

## Recorded validation

Source revision `6b3b9a9` passed the following targeted checks on macOS arm64 on
2026-10-09:

- Isolated bootstrap and repeat validation using local mirrors for the pinned
  Git objects and the bundled SDK snapshot. GitHub DNS was unavailable in the
  test environment; this run did not verify anonymous GitHub downloads.
- `fc.harness.dependencies`, including source corruption, archive checksum and
  unsafe extraction rejection controls.
- `fc.harness.lanes`, including rejection of packages missing dependency notices.
- `fc.harness.fresh_bundle`, reconstructing the exact Fresh integration revision.
- `fc.package_build`, including executable hashes against the build outputs.
- Byte comparison of every packaged checked-in dependency notice and FC's MIT
  license against its source copy.
- Local Markdown link checks and Git whitespace checks.

All four targeted CTest cases passed. The complete final automatic/manual binary
release qualification has not been rerun.

The GitHub source checkout's local clean Release headless build passed all 38
selected core cases on macOS arm64. Its pinned FTXUI/Fresh branches and SDK
source set passed dependency verification. GitHub workflow YAML and local
documentation links were checked. A cached official Boost archive was
checksum-verified by CMake. These local checks do not establish anonymous
download availability or a passing Linux GitHub runner.

The Python version guard from `70cec86` rejects unsupported Python before
cloning or creating dependency inputs.
