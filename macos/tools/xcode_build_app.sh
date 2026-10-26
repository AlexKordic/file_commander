#!/usr/bin/env bash
# Builds through the existing CMake/Swift package workflow, then stages the
# product for Xcode's own app signing, launching and archiving.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
: "${TARGET_BUILD_DIR:?Run this build phase from FileCommander.xcodeproj}"
: "${EXECUTABLE_FOLDER_PATH:?Missing Xcode executable folder}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing Xcode resources folder}"
: "${DERIVED_FILE_DIR:?Missing Xcode intermediates folder}"
: "${WRAPPER_NAME:?Missing Xcode app name}"

args=()
if [[ "${CONFIGURATION:-Debug}" == Debug ]]; then args+=(--debug); fi
# This intermediate bundle is not the Xcode product. Its signing is replaced
# below and by Xcode's final CodeSign task using the team selected in the UI.
FC_CODESIGN_IDENTITY=- "$repo/macos/build_app.sh" ${args[@]+"${args[@]}"}

source_app="$repo/build-macos/File Commander.app"
executables="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
[[ "$EXECUTABLE_FOLDER_PATH" == "$WRAPPER_NAME/Contents/MacOS" &&
   "$UNLOCALIZED_RESOURCES_FOLDER_PATH" == "$WRAPPER_NAME/Contents/Resources" &&
   "$TARGET_BUILD_DIR/$WRAPPER_NAME" != "$source_app" ]] || {
  echo 'error: Expected a separate macOS app product directory.' >&2; exit 1;
}
rm -rf "$executables" "$resources"
mkdir -p "$executables" "$resources" "$DERIVED_FILE_DIR"
/usr/bin/ditto "$source_app/Contents/MacOS" "$executables"
/usr/bin/ditto "$source_app/Contents/Resources" "$resources"

python3 - "$source_app/Contents/Info.plist" "$DERIVED_FILE_DIR/FC-Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
info['CFBundleIdentifier'] = '$(PRODUCT_BUNDLE_IDENTIFIER)'
info['CFBundleExecutable'] = '$(EXECUTABLE_NAME)'
Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  [[ -n "$identity" ]] || { echo 'error: Select a signing team in Signing & Capabilities.' >&2; exit 1; }
  flags=(--force --sign "$identity")
  if [[ "$identity" == - ]]; then flags+=(--timestamp=none); else flags+=(--timestamp); fi
  if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]]; then flags+=(--options runtime); fi
  # Xcode signs the enclosing app after this phase. All embedded executables
  # and resource bundles must already have the same signing identity.
  for code in "$executables"/* "$resources"/*.bundle; do
    [[ -e "$code" && "$code" != "$executables/FileCommander" ]] || continue
    extra=()
    case "${code##*/}" in
      fc|fresh) extra+=(--entitlements "$repo/macos/Xcode/Helpers.entitlements") ;;
    esac
    /usr/bin/codesign "${flags[@]}" ${extra[@]+"${extra[@]}"} "$code"
  done
fi
