#!/usr/bin/env bash
# Windows MSI from the windeployqt folder (CI: Git Bash on windows-latest; needs the WiX v5 dotnet tool).
#   cpp/packaging/windows/make_msi.sh <build-dir> [out-dir]
set -euo pipefail
BUILD=${1:?build dir}; OUT=${2:-$BUILD/dist}
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=$(grep -E '^CMAKE_PROJECT_VERSION:' "$BUILD/CMakeCache.txt" | cut -d= -f2)
[[ -f "$BUILD/deploy/Plane World.exe" ]] || { echo "run: cmake --build $BUILD --target pwapp_deploy"; exit 1; }
cp "$BUILD/src/cli/pwcli.exe" "$BUILD/deploy/"
mkdir -p "$OUT"
MSI="$OUT/PlaneWorld-$VERSION-windows-x64.msi"
wix build -arch x64 -d Version="$VERSION" -bindpath deploy="$(cygpath -w "$BUILD/deploy")" -o "$(cygpath -w "$MSI")" "$(cygpath -w "$HERE/PlaneWorld.wxs")"
echo "$MSI"
