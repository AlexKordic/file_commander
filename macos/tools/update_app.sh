#!/usr/bin/env bash
# Updates build-macos/File Commander.app in place after a change to the Swift
# code, without rebuilding the engine or assembling the bundle again: builds
# the Swift products, puts them in the bundle and signs it again. Build the
# bundle once with macos/build_app.sh (and again after engine changes).
#
#   macos/tools/update_app.sh                 debug Swift build (faster)
#   macos/tools/update_app.sh --release       release Swift build
#   macos/tools/update_app.sh --fresh <path>  also install that fresh binary
#
# fc, fresh and 7z.so from build-macos are installed too when they are newer
# than the bundle's. Executables are copied next to the old file and moved
# over it, never written over: macOS kills a signed program whose file was
# changed in place ("Code Signature Invalid"), at its next launch.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
configuration=debug
fresh=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) configuration=release ;;
    --fresh) fresh="${2:?update_app: --fresh needs a path}"; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "update_app: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf 'update_app: %s\n' "$*"; }

app="build-macos/File Commander.app"
[[ -d "$app/Contents/MacOS" ]] || { echo "update_app: no $app yet; build it with macos/build_app.sh" >&2; exit 1; }

products=(FileCommander fc-relaunch fc-askpass)
log="$(mktemp -t fc-update-app)"
trap 'rm -f "$log"' EXIT
for product in "${products[@]}"; do
  if ! swift build -c "$configuration" --package-path macos --product "$product" > "$log" 2>&1; then
    sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E "error:" | sort -u >&2 || cat "$log" >&2
    echo "update_app: the Swift build failed; the app is unchanged" >&2
    exit 1
  fi
done
bin="$(swift build -c "$configuration" --package-path macos --show-bin-path)"

# Copy next to the old file, then move over it: a new file, never an edited one.
place() {
  cp "$1" "$app/Contents/MacOS/$2.new"
  mv -f "$app/Contents/MacOS/$2.new" "$app/Contents/MacOS/$2"
}

for product in "${products[@]}"; do place "$bin/$product" "$product"; done
for bundle in "$bin"/*.bundle; do
  rm -rf "$app/Contents/Resources/$(basename "$bundle")"
  cp -R "$bundle" "$app/Contents/Resources/"
done
for pair in "build-macos/fc:fc" "build-macos/third_party/fresh/bin/fresh:fresh" "build-macos/third_party/7zip/_o/7z.so:7z.so"; do
  from="${pair%%:*}" name="${pair##*:}"
  if [[ -x "$from" && "$from" -nt "$app/Contents/MacOS/$name" ]]; then
    place "$from" "$name"
    say "installed $from"
  fi
done
if [[ -n "$fresh" ]]; then
  place "$fresh" fresh
  say "installed $fresh"
fi

python3 macos/tools/bundle_dylibs.py "$app"
signed="$(macos/tools/sign_app.sh "$app")"
say "$signed"
say "done: $app ($configuration)"
