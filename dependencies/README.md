# Pinned dependency sources

`dependencies.json` declares the exact source inputs for File Commander (FC).
Bootstrap and configure check them; nothing tracks a moving branch. In binary
packages this file is installed as `share/file-commander/README.md`, next to
`dependencies.json`, `fresh-fc.bundle` and `THIRD_PARTY_NOTICES.md`. In the
source tree they live in `dependencies/` and the repository root. Build steps
are in [doc/dev/building.md](../doc/dev/building.md) and licenses in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Pinned inputs

| Component | Source | Pinned revision or version |
| --- | --- | --- |
| Boost | `https://github.com/boostorg/boost/releases/download/boost-1.90.0/boost-1.90.0-cmake.tar.gz` | 1.90.0; tarball SHA-256 `913ca43d49e93d1b158c9862009add1518a4c665e7853b349a6492d158b036d4` |
| Boost.Filesystem | Modified subtree `boost/filesystem` in the FC repository | The same FC commit |
| FTXUI (FC fork) | `https://github.com/AlexKordic/FTXUI.git`, branch `fc-integration` | `ff94e7a1008d41e11ce040702654eed6aff1e52c` |
| LuaJIT | `https://github.com/LuaJIT/LuaJIT.git` | `233ad24035944ece5367157e824e8357df3417d9` |
| Fresh (FC fork) | `https://github.com/sinelaw/fresh.git` plus `dependencies/fresh-fc.bundle`; also branch `fc-editor-workflow` of `https://github.com/AlexKordic/fresh` | `39a8f267c2b1934e8316923e025d035ecf5601f9` on upstream base `b10f9084f5eae571e9b8dac1a0f3694384bcb53d`; bundle SHA-256 `6f74db1381a812b30dce9639ca8b904b01918ec03019b083fe5df3a3989adabc` |
| LZMA SDK | `dependencies/lzma-sdk-26.00.tar.gz` in the FC repository | 26.00; archive SHA-256 `282b4d32b47e83a4b4215b174988d967ba02407e243a46b963779cde38931cc6`; source fingerprint `744ef6617d606d78676e06d3ab30784072c8a936a4c629c76d5877b93710e66c` over 606 files |

FTXUI and Fresh carry FC changes; LuaJIT and Boost come from their public
upstream sources, and FC's Boost.Filesystem changes are listed in
`boost/changes.md` in the source tree.

## Bootstrap

`tools/bootstrap_dependencies.py --root build-deps` creates
`build-deps/ftxui`, `build-deps/luajit`, `build-deps/fresh` and
`build-deps/lzma`. For each Git input it clones the declared source and checks
out the exact revision. For Fresh it first verifies the bundle's SHA-256, runs
`git bundle verify`, and fetches the bundle's `fc-editor-workflow` branch.
Then it validates everything with `tools/check_dependencies.py`.

- `--fresh-url` or `FC_FRESH_MIRROR` replaces the upstream Fresh URL with a
  mirror; `--ftxui-url` or `FC_FTXUI_MIRROR` does the same for FTXUI.
- Existing checkouts are validated, never reset or edited. To move one to a new
  pin, update it yourself (below) or delete it and rerun bootstrap.

## LZMA SDK snapshot

`lzma-sdk-26.00.tar.gz` contains the SDK 26.00 source and documentation,
without prebuilt executables or local object directories. The manifest pins
the archive's SHA-256 and, separately, a fingerprint of its 606 C, C++,
assembly and makefile sources. Bootstrap verifies the archive, extracts it with
Python's `data` filter, then checks the source fingerprint. `--lzma-source` can
supply the same verified source set from a folder instead. The SDK's
public-domain statement is kept in `DOC/lzma-sdk.txt` inside the archive and in
`licenses/lzma-sdk/lzma-sdk.txt`.

## Fresh

Fresh is a separate GPL-3.0-or-later program that FC starts as `fresh`. The
pinned revision is FC's fork of it:

- **Upstream base** (`base_revision`):
  `b10f9084f5eae571e9b8dac1a0f3694384bcb53d`, which is Fresh 0.5.2 plus 40
  upstream commits. It includes the upstream fix that makes daemon sessions run
  the shared editor tick, so recovery saves happen in the background.
- **Pinned revision** (`revision`): `39a8f267c2b1934e8316923e025d035ecf5601f9`,
  the base plus FC's commits on the `fc-editor-workflow` branch.
- **Bundle** (`fresh-fc.bundle`): a Git bundle holding exactly the commits from
  the base to the pinned revision, with the branch head
  `refs/heads/fc-editor-workflow`. It needs a clone that already contains the
  base.

Build with the pinned checkout's toolchain (Rust 1.95, from its
`rust-toolchain.toml`):

```sh
cargo build --release --locked -p fresh-editor --bin fresh
```

How FC drives Fresh, and the rules for changing the pin, are in
[doc/dev/fresh_integration.md](../doc/dev/fresh_integration.md) in the FC
source tree.

### What the FC Fresh fork changes

- Restore recovered text before clamping workspace cursors to it.
- Avoid adopting restored untitled buffers twice.
- Give each FC editor identity a private data directory for workspace and
  recovery state.
- Keep FC's per-client switch key working, and bound daemon startup, on IPC
  protocol 4.
- Import checkpoints from the earlier FC integration, and persist daemon
  recovery before a client detaches.
- Keep full unsaved snapshots when source files change or disappear.
- Stop a daemon this client spawned if it misses the startup deadline.
- Add `prepare-restart`: restart the backend only after it confirms a
  checkpoint of tabs and unsaved text.
- Add `open-location`: route opens by SSH endpoint and workspace root inside
  one backend, keeping dirty local tabs. Remote workspaces use Fresh's own
  remote agent over SSH and can reuse FC's SSH control socket.
- Open FC remote workspaces without starting a remote shell.
- Decide remote write access under the SSH login (the remote agent reports
  `os.access`), instead of comparing remote owners with local UIDs.

### Update an existing checkout

Set `FRESH` to the checkout: `build-deps/fresh` in the bootstrap layout, or
`../editor-fresh` for the sibling checkout that CMake uses when
`FC_FRESH_SOURCE_DIR` is not set. From the FC root, with a clean checkout:

```sh
FRESH=build-deps/fresh
git -C "$FRESH" fetch "$PWD/dependencies/fresh-fc.bundle" refs/heads/fc-editor-workflow
git -C "$FRESH" checkout --detach FETCH_HEAD
git -C "$FRESH" rev-parse HEAD   # must print git.fresh.revision from dependencies.json
```

### Change Fresh

1. In the Fresh checkout, put the `fc-editor-workflow` branch at the pinned
   revision (a bootstrap checkout has a detached HEAD; use
   `git switch -c fc-editor-workflow`) and commit the fix there.
2. Regenerate the bundle from the upstream base through that branch:

   ```sh
   git -C "$FRESH" bundle create "$PWD/dependencies/fresh-fc.bundle" \
       b10f9084f5eae571e9b8dac1a0f3694384bcb53d..fc-editor-workflow
   ```

   Use the new base instead if you rebased onto newer upstream Fresh.
3. In `dependencies.json`, update `git.fresh.revision`,
   `git.fresh.bundle_sha256` (from `shasum -a 256` or `sha256sum`) and, after a
   rebase, `git.fresh.base_revision`.
4. Push the branch to `fc-editor-workflow` in the Fresh fork.
5. Run `test/test_fresh_bundle.py <fresh checkout>` (CTest
   `fc.harness.fresh_bundle`). It proves that the pinned revision can be
   rebuilt from the base and the bundle alone.

### License and source reconstruction

Fresh's license is GPL-3.0-or-later. Binary packages contain it at
`share/licenses/fresh/LICENSE`. The manifest and the bundle identify the exact
source changes. To reconstruct the pinned source from a package, using the
bundle at `share/file-commander/fresh-fc.bundle`:

```sh
BASE=b10f9084f5eae571e9b8dac1a0f3694384bcb53d   # git.fresh.base_revision
REV=39a8f267c2b1934e8316923e025d035ecf5601f9    # git.fresh.revision
BUNDLE=/path/to/share/file-commander/fresh-fc.bundle
git clone --no-checkout https://github.com/sinelaw/fresh.git fresh
git -C fresh cat-file -e "$BASE^{commit}"       # the clone must contain the base
git -C fresh bundle verify "$BUNDLE"
git -C fresh fetch "$BUNDLE" refs/heads/fc-editor-workflow
git -C fresh checkout --detach "$REV"
```

If these values differ from the packaged `dependencies.json`, the manifest
wins. The same history is published on the `fc-editor-workflow` branch of
`https://github.com/AlexKordic/fresh`.

The bundle is additional Git history, not a complete standalone source archive.
Binary releases that include Fresh also publish the corresponding source for
that exact version; see `THIRD_PARTY_NOTICES.md`. Keep these source references
and the applicable licenses with release artifacts.
