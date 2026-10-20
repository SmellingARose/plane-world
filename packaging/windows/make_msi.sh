#!/usr/bin/env bash
# Windows MSI from the windeployqt folder (CI: Git Bash on windows-latest; needs the WiX v5 dotnet tool).
#   packaging/windows/make_msi.sh <build-dir> [out-dir]
set -euo pipefail
BUILD=${1:?build dir}; OUT=${2:-$BUILD/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=$(grep -E '^CMAKE_PROJECT_VERSION:' "$BUILD/CMakeCache.txt" | cut -d= -f2)
[[ -f "$BUILD/deploy/Plane World.exe" ]] || { echo "run: cmake --build $BUILD --target pwapp_deploy"; exit 1; }
cp "$BUILD/src/cli/pwcli.exe" "$BUILD/deploy/"
mkdir -p "$OUT"
MSI="$OUT/PlaneWorld-Windows.msi"   # a fixed name, so the README can link to releases/latest/download/PlaneWorld-Windows.msi
wix build -arch x64 -d Version="$VERSION" -bindpath deploy="$(cygpath -aw "$BUILD/deploy")" -o "$(cygpath -aw "$MSI")" "$(cygpath -aw "$HERE/PlaneWorld.wxs")"
SIZE=$(stat -c %s "$MSI")
ls -la "$MSI"
(( SIZE > 10000000 )) || { echo "error: $MSI is only $SIZE bytes; the deploy folder was not harvested"; exit 1; }
echo "$MSI"
