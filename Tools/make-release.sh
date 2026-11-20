#!/bin/bash
# Builds a release of "Thermal Inspector.app" and packs it as a zip for GitHub releases.
#
#   ./Tools/make-release.sh        →  dist/Thermal-Inspector-<version>.zip
#
# The app is NOT signed with a developer certificate. It only gets an "ad-hoc"
# signature (no identity, no certificate), which macOS requires to run apps on
# Apple Silicon at all. Users therefore have to allow the app once – see README.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
DERIVED_DATA=build/release
APP="$DERIVED_DATA/Build/Products/Release/Thermal Inspector.app"
ZIP="dist/Thermal-Inspector-$VERSION.zip"

echo "Building Thermal Inspector $VERSION …"
xcodegen generate --quiet
rm -rf "$DERIVED_DATA"
xcodebuild -project "Thermal Inspector.xcodeproj" -scheme "Thermal Inspector" -configuration Release \
    -derivedDataPath "$DERIVED_DATA" -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
    CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
    build | grep -E "error:|BUILD" || true

test -d "$APP" || { echo "Build failed"; exit 1; }

# Make sure no paths of the build machine (e.g. /Users/<name>/…) ended up in the app.
if grep -r -a -l "$HOME" "$APP" >/dev/null 2>&1; then
    echo "Error: the app contains paths from this computer:"
    grep -r -a -l "$HOME" "$APP"
    exit 1
fi

codesign --verify --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Thermal Inspector")"

mkdir -p dist
rm -f "$ZIP"
# ditto keeps the app bundle intact (symlinks, permissions) – better than zip for .app files.
ditto -c -k --keepParent "$APP" "$ZIP"
echo
echo "Created $ZIP"
shasum -a 256 "$ZIP"
