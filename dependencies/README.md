# Pinned dependency sources

`dependencies.json` declares the exact inputs; bootstrap does not track moving
branches. FTXUI's FC changes are published on the `fc-integration` branch of
`AlexKordic/FTXUI`. That branch must be pushed before the first public FC build.
LuaJIT and Boost use their public upstream sources.

`lzma-sdk-26.00.tar.gz` contains SDK 26.00 source and documentation, excluding
prebuilt executables and local object directories. Its archive SHA-256 and the
606-file C/C++/assembly/makefile source fingerprint are pinned separately in the
manifest. Bootstrap verifies the archive and extracts it with Python's data
filter, then checks the source fingerprint. An optional `--lzma-source` folder
can still supply the same verified source set. The SDK's public-domain statement
is retained in `DOC/lzma-sdk.txt` and `licenses/lzma-sdk/lzma-sdk.txt`.

## Fresh integration changes

`fresh-fc.bundle` contains the committed FC editor fixes on top of the upstream
`base_revision` in `dependencies.json`. That manifest pins the final commit and
the SHA-256 of the bundle. The source remains the declared upstream repository;
the bundle supplies the additional commits without requiring a private fork.

`tools/bootstrap_dependencies.py` clones the source, verifies and fetches this
bundle, and checks out the exact final revision. Use `--fresh-url` or
`FC_FRESH_MIRROR` for an accessible upstream mirror. Existing input checkouts are
validated and never reset by bootstrap.

To update an existing clean Fresh checkout deliberately:

```sh
git -C ../editor-fresh fetch "$PWD/dependencies/fresh-fc.bundle" refs/heads/fc-editor-workflow
git -C ../editor-fresh checkout --detach FETCH_HEAD
```

When changing Fresh, commit the fix in its checkout, update the
`fc-editor-workflow` branch to that commit, and regenerate the bundle from the
selected upstream base through that branch. Update both the manifest revision
and bundle fingerprint. `test/test_fresh_bundle.py` proves that the final checkout
can be reconstructed using only the base and this bundle.

The current baseline is upstream Fresh 0.5.2 plus the fixes through
`b10f9084f5eae571e9b8dac1a0f3694384bcb53d`. Build with Rust 1.95 and
`cargo build --release --locked -p fresh-editor --bin fresh`. The FC commits
preserve attachment bindings and bounded startup, isolate daemon data, import
legacy checkpoints, fix recovered cursor positions and duplicate untitled
tabs, support checkpoint-confirmed backend restart, and explicitly route local/SSH
locations to filesystem workspaces in the same backend. Remote opens use
Fresh's native SSH agent and preserve dirty local tabs. Write permissions are
evaluated by the remote login rather than comparing remote owners to local UIDs. See
`doc/fresh_cli_contract.md` in the FC source tree for upgrade and restart behavior.

Fresh's license is GPL-3.0-or-later. The packaged license is in
`share/licenses/fresh/LICENSE`; the manifest and this bundle identify the exact
source changes. To reconstruct from packaged metadata, clone
`https://github.com/sinelaw/fresh.git`, check out the manifest's `base_revision`,
fetch `fresh-fc.bundle` as shown above (using its packaged path), then check out
`revision`. Keep these source references and the applicable licenses with release
artifacts.
