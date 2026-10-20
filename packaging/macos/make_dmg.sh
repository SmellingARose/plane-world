#!/usr/bin/env bash
# Build a self-contained, ad-hoc signed "Plane World.app" and a drag-to-Applications .dmg.
#   packaging/macos/make_dmg.sh <build-dir> [out-dir]
# Env: PW_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). With a "Developer ID Application: ..." identity the
#                        bundle is signed with the hardened runtime and a secure timestamp, ready for notarization
#                        (see docs/PACKAGING.md).
set -euo pipefail
BUILD=${1:?build dir}
OUT=${2:-$BUILD/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC_APP="$BUILD/src/app/Plane World.app"
[[ -d "$SRC_APP" ]] || { echo "missing $SRC_APP (build pwapp first)"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC_APP/Contents/Info.plist")
IDENTITY=${PW_SIGN_IDENTITY:--}

MACDEPLOYQT=$(grep '^PW_MACDEPLOYQT:' "$BUILD/CMakeCache.txt" | cut -d= -f2-)
[[ -x "$MACDEPLOYQT" ]] || MACDEPLOYQT=$(command -v macdeployqt)

STAGE="$OUT/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$SRC_APP" "$STAGE/Plane World.app"
APP="$STAGE/Plane World.app"
cp "$BUILD/src/cli/pwcli" "$APP/Contents/MacOS/pwcli"     # headless CLI travels inside the bundle

"$MACDEPLOYQT" "$APP" -qmldir="$HERE/../../src/app/qml" -executable="$APP/Contents/MacOS/pwcli" -always-overwrite

# Sign inside-out (frameworks / plugins / dylibs, then helpers, then the bundle). --deep is deprecated for signing.
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN+=(--options runtime --timestamp --entitlements "$HERE/entitlements.plist"); fi
find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -type f -print0 | xargs -0 -n1 "${SIGN[@]}"
find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 | xargs -0 -n1 "${SIGN[@]}"
"${SIGN[@]}" "$APP/Contents/MacOS/pwcli"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# Smoke: the deployed bundle must not reference the build machine's Qt.
if otool -L "$APP/Contents/MacOS/Plane World" | grep -E '/opt/homebrew|/usr/local/opt|/Qt/6' ; then
  echo "error: bundle still links a non-bundled Qt"; exit 1
fi

# A fixed name, so the README can link to releases/latest/download/PlaneWorld-macOS.dmg (the version is in the volume name)
DMG="$OUT/PlaneWorld-macOS.dmg"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Plane World $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[[ "$IDENTITY" == "-" ]] || codesign --force --sign "$IDENTITY" --timestamp "$DMG"
rm "$STAGE/Applications"
echo "$DMG"
