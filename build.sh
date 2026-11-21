#!/bin/sh
# Builds LiveKit Observer into build/ and, with --test, runs the unit tests first.
#
# Signs with your Apple Development certificate when you have one (or SIGN_IDENTITY, a name or SHA-1),
# so the app keeps the same identity across rebuilds and the Keychain remembers "Always Allow" for the
# storage secret. Without one it signs ad hoc, and macOS asks for the secret again after each rebuild.
set -eu
cd "$(dirname "$0")"
# Leave the open Xcode project's package graph intact when the spec and source list
# have not changed. Regenerating on every build can leave Xcode with stale packages.
xcodegen generate --use-cache --quiet

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
signing=""
if [ -n "$identity" ]; then
  team="$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')"
  signing="CODE_SIGN_IDENTITY=$identity"
  [ -n "$team" ] && signing="$signing
DEVELOPMENT_TEAM=$team"
  echo "Signing with: $identity"
else
  echo "No Apple Development certificate found; signing ad hoc."
fi

build() {
  # One setting per line, so names with spaces stay whole.
  old_ifs="$IFS"; IFS='
'
  # shellcheck disable=SC2086
  xcodebuild -project LiveKitObserver.xcodeproj -scheme LiveKitObserver -derivedDataPath build/DerivedData "$@" CODE_SIGN_STYLE=Manual $signing -quiet
  IFS="$old_ifs"
}

if [ "${1:-}" = "--test" ]; then
  swift test --package-path Packages/ObserverCore
  build test
fi
build -configuration Release build
rm -rf "build/LiveKit Observer.app"
cp -R "build/DerivedData/Build/Products/Release/LiveKit Observer.app" build/
echo "Built: $(pwd)/build/LiveKit Observer.app"
