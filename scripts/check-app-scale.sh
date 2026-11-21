#!/bin/sh
# Hosted app benchmark: creates only synthetic temporary data, uses no Cloud services.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --use-cache --quiet
rm -f /private/tmp/observer-whole-app-scale.json
TEST_RUNNER_OBSERVER_SCALE_TEST=1 xcodebuild -project LiveKitObserver.xcodeproj -scheme LiveKitObserver \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
    -configuration Release ONLY_ACTIVE_ARCH=YES ARCHS=arm64 ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO \
    -only-testing:LiveKitObserverTests/ScaleAcceptanceTests test CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- -quiet
cat /private/tmp/observer-whole-app-scale.json
