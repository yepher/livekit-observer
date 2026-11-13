#!/bin/sh
# Builds LiveKit Observer into build/ and, with --test, runs the unit tests first.
set -eu
cd "$(dirname "$0")"
xcodegen generate --quiet
if [ "${1:-}" = "--test" ]; then
  xcodebuild -project LiveKitObserver.xcodeproj -scheme LiveKitObserver -derivedDataPath build/DerivedData test -quiet
fi
xcodebuild -project LiveKitObserver.xcodeproj -scheme LiveKitObserver -configuration Release -derivedDataPath build/DerivedData build -quiet
rm -rf "build/LiveKit Observer.app"
cp -R "build/DerivedData/Build/Products/Release/LiveKit Observer.app" build/
echo "Built: $(pwd)/build/LiveKit Observer.app"
