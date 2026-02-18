# Build and Test Setup

This project is currently built and tested with Ninja in `build/`.

## Configure

Use this exact command:

```bash
/opt/homebrew/bin/cmake \
  -DCMAKE_BUILD_TYPE:STRING=Debug \
  -DPKG_CONFIG_PATH:STRING=/Users/alexkordic/compiled/lib/pkgconfig \
  -DC_INCLUDE_PATH:STRING=${C_INCLUDE_PATH:-}:/Users/alexkordic/compiled/include \
  -DLD_LIBRARY_PATH:STRING=/Users/alexkordic/compiled/lib \
  -DPERPETUAL:STRING=1 \
  -DLOAD_BALANCE:STRING=1 \
  -DCMAKE_PREFIX_PATH:STRING=/Users/alexkordic/compiled \
  -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE \
  -DCMAKE_C_COMPILER:FILEPATH=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/clang++ \
  --no-warn-unused-cli \
  -S/Users/alexkordic/code/file_commander \
  -B/Users/alexkordic/code/file_commander/build \
  -G Ninja
```

Notes:
- CMake is configured to use a local Boost tarball (`boost-1.90.0-cmake.tar.gz`) from the repo.
- Generator is `Ninja`.

## Build

Use 10 parallel jobs:

```bash
cmake --build /Users/alexkordic/code/file_commander/build -j10
```

The executable is generated at:

```bash
./build/fc
```

## Test

Run the copy test suite with:

```bash
./build/fc run test/test_copy.lua
```

Expected success signal includes:

```text
[PASS] ALL COPY TESTS PASSED
```

Run editor integration test with a fake Fresh binary:

```bash
FC_FRESH_BIN=./test/fakes/fresh_fake.sh \
FC_FRESH_FAKE_LOG=/tmp/fc_fresh_fake.log \
./build/fc run test/test_editor_integration.lua
```

Run static-plan smoke tests:

```bash
cmake --build /Users/alexkordic/code/file_commander/build -j10 --target smoke_lua_suite
```

## Packaging

Create a self-contained distribution tarball:

```bash
cmake --build /Users/alexkordic/code/file_commander/build -j10 --target package_static_dist
```

Expected output:
- `/Users/alexkordic/code/file_commander/build/dist/fc-Darwin-arm64.tar.gz`
- Tarball contains `bin/fc`, `bin/fresh` (if built), and `bin/7zr` (if built).

## Linux static (Zig)

Requires `zig` available on `PATH`.

Configure:

```bash
cmake -S /Users/alexkordic/code/file_commander \
  -B /Users/alexkordic/code/file_commander/build-static-linux-x86_64 \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=/Users/alexkordic/code/file_commander/cmake/toolchains/zig-musl-x86_64.cmake \
  -DFC_STATIC_MODE=ON \
  -DFC_BUILD_FRESH=OFF \
  -DFC_BUILD_LZMA_TOOL=OFF
```

For ARM64 Linux, use `cmake/toolchains/zig-musl-aarch64.cmake`.

## Troubleshooting

If CMake reports a generator mismatch in `build/_deps/boost-subbuild`, clear only the Boost subbuild folders and re-run configure:

```bash
rm -rf build/_deps/boost-subbuild build/_deps/boost-build
```
