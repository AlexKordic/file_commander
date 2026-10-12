#!/usr/bin/env bash
# Builds File Commander.app: the C++ engine with CMake (preset macos-app),
# then the Swift package, then the bundle with fresh and 7-Zip's 7z.so inside.
#
#   macos/build_app.sh            release build into build-macos/File Commander.app
#   macos/build_app.sh --debug    debug Swift build (faster to compile)
#   macos/build_app.sh --open     build, then open the app
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
configuration=release
open_app=0
for arg in "$@"; do
  case "$arg" in
    --debug) configuration=debug ;;
    --open) open_app=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build_app: unknown option $arg" >&2; exit 2 ;;
  esac
done

say() { printf 'build_app: %s\n' "$*"; }

if [[ -f "$HOME/.cargo/env" ]]; then . "$HOME/.cargo/env"; fi
if [[ ! -f build-macos/CMakeCache.txt ]]; then
  extra=()
  # Reuse the dependency checkouts the terminal build was configured with.
  if [[ -f build-release/CMakeCache.txt ]]; then
    for name in FC_FTXUI_SOURCE_DIR FC_FRESH_SOURCE_DIR FC_LUAJIT_SOURCE_DIR FC_SEVENZIP_SOURCE_DIR; do
      value="$(grep "^$name:" build-release/CMakeCache.txt | cut -d= -f2- || true)"
      [[ -n "$value" ]] && extra+=("-D$name=$value")
    done
  fi
  say "configuring the engine (preset macos-app)"
  cmake --preset macos-app ${extra[@]+"${extra[@]}"} > /dev/null
fi
say "building the engine, fresh and 7-Zip"
cmake --build --preset macos-app | grep -E "error|FAILED" || true
[[ -f build-macos/libfc_engine_bundle.a ]] || { echo "build_app: the engine did not build" >&2; exit 1; }

say "building the Swift package ($configuration)"
swift build -c "$configuration" --package-path macos --product FileCommander
swift build -c "$configuration" --package-path macos --product fc-relaunch
swift build -c "$configuration" --package-path macos --product fc-askpass
bin="$(swift build -c "$configuration" --package-path macos --show-bin-path)"

app="build-macos/File Commander.app"
say "assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FileCommander" "$bin/fc-relaunch" "$bin/fc-askpass" "$app/Contents/MacOS/"
cp -R "$bin"/*.bundle "$app/Contents/Resources/"
cp build-macos/third_party/7zip/_o/7z.so "$app/Contents/MacOS/7z.so"
# The terminal interface, for fc run (Lua scripts) and for people who want it.
cp build-macos/fc "$app/Contents/MacOS/fc"
if [[ -x build-macos/third_party/fresh/bin/fresh ]]; then
  cp build-macos/third_party/fresh/bin/fresh "$app/Contents/MacOS/fresh"
else
  say "warning: fresh was not built; the editor uses fresh from PATH"
fi
version="$(grep -m1 'project(fc' CMakeLists.txt | sed -E 's/.*VERSION ([0-9.]+).*/\1/')"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.perun.filecommander</string>
  <key>CFBundleName</key><string>File Commander</string>
  <key>CFBundleDisplayName</key><string>File Commander</string>
  <key>CFBundleExecutable</key><string>FileCommander</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>File Commander</string>
</dict>
</plist>
PLIST
if [[ ! -f build-macos/AppIcon.icns || macos/tools/make_icon.swift -nt build-macos/AppIcon.icns ]]; then
  say "drawing the app icon"
  rm -rf build-macos/AppIcon.iconset
  swift macos/tools/make_icon.swift build-macos/AppIcon.iconset
  iconutil -c icns build-macos/AppIcon.iconset -o build-macos/AppIcon.icns
fi
cp build-macos/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
signed="$(macos/tools/sign_app.sh "$app")"
say "$signed"
say "done: $app"
if [[ $open_app == 1 ]]; then open "$app"; fi
