#!/bin/bash
# Builds "Thermal Inspector.app" (Release) into ./build/Build/Products/Release/
# Requires Xcode and XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project ThermalInspector.xcodeproj -scheme ThermalInspector \
           -configuration Release -derivedDataPath build build | grep -E "error:|warning:|BUILD"

echo
echo "App: $(pwd)/build/Build/Products/Release/Thermal Inspector.app"
