#!/usr/bin/env bash
# Signs File Commander.app to run on this Mac.
#
#   macos/tools/sign_app.sh "build-macos/File Commander.app"
#
# The identity is FC_CODESIGN_IDENTITY when it is set ("-" signs ad hoc), else
# the first valid "Apple Development" identity in the keychain, else ad hoc. A
# real identity keeps the app's identity the same from build to build, so the
# permissions macOS asks for (such as files on network volumes) are asked once;
# an ad hoc signature differs with every build, and macOS asks again.
set -euo pipefail

app="${1:?usage: sign_app.sh <app>}"
[[ -d "$app/Contents/MacOS" ]] || { echo "sign_app: $app is not an app bundle" >&2; exit 2; }

identity="${FC_CODESIGN_IDENTITY:-}"
name="$identity"
if [[ -z "$identity" ]]; then
  # The certificate's hash, not its name: a renewed certificate shares the name.
  line="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development: ' || true)"
  identity="$(sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/' <<< "$line")"
  name="$(sed -E 's/.*"(.*)".*/\1/' <<< "$line")"
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  identity="-"
  name="an ad hoc signature"
fi

sign() {
  local out
  out="$(codesign --force --timestamp=none --sign "$identity" "$1" 2>&1)" || {
    printf 'sign_app: %s\n' "$out" >&2
    exit 1
  }
}

# Inside out: the helpers and resource bundles, then the app itself.
for code in "$app"/Contents/MacOS/* "$app"/Contents/Resources/*.bundle; do
  [[ -e "$code" && "$code" != "$app/Contents/MacOS/FileCommander" ]] || continue
  sign "$code"
done
sign "$app"
echo "signed with $name"
