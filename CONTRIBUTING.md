# Contributing

Use GitHub Issues for reproducible bugs and feature proposals, and pull requests
for changes. Discuss substantial behavior changes before implementing them.
Keep communication respectful and focused on the work.

## Development

Follow the [README](README.md) to provision pinned dependencies. Build instructions,
test lanes and sanitizer configurations are in [doc/build_test_setup.md](doc/build_test_setup.md).
Use the existing C++ style and `.clang-format`; avoid unrelated formatting changes.
Core behavior should remain independent of terminal rendering. Filesystem work
belongs off the UI thread, with updates delivered through the existing dispatch
and lifetime mechanisms.

Include a focused regression test for behavior changes and run the relevant test
lane. Describe what changed, the trigger it fixes, and the checks you actually
ran. Manual tests require native capabilities; clearly state when they were not
run. New registered tests must also be added to the independent release registry.

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
