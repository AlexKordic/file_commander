# Contributing

Use GitHub Issues for reproducible bugs and feature proposals, and pull requests
for changes. Discuss substantial behavior changes before implementing them.
Keep communication respectful and focused on the work.

## Development

- [Building](doc/dev/building.md) covers dependencies, presets and packages.
- [Testing](doc/dev/testing.md) explains the test suite and how to run it.
- [Architecture](doc/dev/architecture.md) describes how FC is put together and
  the design rules that changes must keep.

Use the existing C++ style and `.clang-format`; avoid unrelated formatting
changes. Core behavior should remain independent of terminal rendering.
Filesystem work belongs off the UI thread, with updates delivered through the
existing dispatch and lifetime mechanisms.

Include a focused regression test for behavior changes. Before sending a pull
request, run at least the fast tests:

```sh
python3 tools/run_test_lane.py fast --build build-release
```

Use the `release` lane for broader changes. Manual tests need real devices or
hosts; state clearly in the pull request when you didn't run them. New
registered tests must also be added to `test/release_required.json`.

Keep the documentation in step with the code. A new command or key belongs in
[doc/keys.md](doc/keys.md), and a new Lua function in
[doc/scripting.md](doc/scripting.md); `fc.harness.docs` checks both, along with
the links between documents.

Dependency changes need an intentional revision update, preserved upstream
notices, and the checks described in [dependencies/README.md](dependencies/README.md).
Fresh changes belong in its GPL-licensed fork and integration bundle. Do not
copy dependency code into FC under an MIT label.

## Contributions and attribution

By submitting original FC code, you agree that your contribution may be
distributed under FC's MIT license. You retain copyright in your contribution.
Contributions to vendored components remain under their existing licenses.
Identify copied or adapted third-party material and include its source and terms.
No contributor license agreement or copyright assignment is required.
