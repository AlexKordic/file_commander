#!/usr/bin/env bash
# Generates macos/Sources/FreshKit/Generated/scene.pb.swift, FreshKit's types
# for the scene channel, from Fresh's scene.proto (crates/fresh-editor/src/
# webui/scene.proto in the Fresh checkout: $FC_FRESH_SOURCE_DIR, else
# ../editor-fresh). Rerun after the Fresh pin moves to a scene.proto change.
# Needs protoc; builds protoc-gen-swift from the swift-protobuf version the
# package pins, so generator and runtime match.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fresh="${FC_FRESH_SOURCE_DIR:-$repo/../editor-fresh}"
proto="$fresh/crates/fresh-editor/src/webui/scene.proto"
[[ -f "$proto" ]] || { echo "gen_scene_proto: no scene.proto at $proto" >&2; exit 1; }
swift package --package-path "$repo/macos" resolve >/dev/null
plugin_build="$repo/macos/.build/protoc-gen-swift"
swift build -c release --package-path "$repo/macos/.build/checkouts/swift-protobuf" \
  --scratch-path "$plugin_build" --product protoc-gen-swift >/dev/null
out="$repo/macos/Sources/FreshKit/Generated"
mkdir -p "$out"
protoc --plugin=protoc-gen-swift="$plugin_build/release/protoc-gen-swift" \
  --swift_opt=Visibility=Public --swift_out="$out" \
  --proto_path="$(dirname "$proto")" "$proto"
echo "gen_scene_proto: wrote $out/scene.pb.swift from $proto"
