#!/bin/sh
# Run with "debug" to include the costs seen when launching the app from Xcode.
set -eu
mel_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mel_temp=$(mktemp -d "${TMPDIR:-/tmp}/observer-mel-benchmark.XXXXXX")
trap 'rm -rf "$mel_temp"' EXIT HUP INT TERM
case "${1:-release}" in
    debug) mel_optimization=-Onone ;;
    release) mel_optimization=-O ;;
    *) echo 'Usage: sh scripts/check-spectrogram-performance.sh [debug|release]' >&2; exit 2 ;;
esac
swift build --package-path "$mel_repo/Packages/ObserverCore" -c release
mel_core=$(swift build --package-path "$mel_repo/Packages/ObserverCore" -c release --show-bin-path)
if [ -f "$mel_core/libObserverCore.a" ]; then
    set -- "$mel_core/libObserverCore.a"
else
    set -- "$mel_core"/ObserverCore.build/*.o
fi
xcrun swiftc -parse-as-library "$mel_optimization" -target "$(uname -m)-apple-macosx15.0" \
    -I "$mel_core" -I "$mel_core/Modules" "$@" -lsqlite3 -module-cache-path "$mel_temp/modules" \
    "$mel_repo/Sources/LiveKitObserver/Spectrogram.swift" \
    "$mel_repo/Tests/Performance/SpectrogramBenchmark.swift" -o "$mel_temp/check"
/usr/bin/time -l "$mel_temp/check"
