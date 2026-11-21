#!/bin/sh
# Exercises the production SQLite store; this measures the worker, not whole-app memory.
set -eu
index_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
index_temp=$(mktemp -d "${TMPDIR:-/tmp}/observer-index-benchmark.XXXXXX")
trap 'rm -rf "$index_temp"' EXIT HUP INT TERM
swift build --package-path "${index_repo}/Packages/ObserverCore" -c release
index_core=$(swift build --package-path "${index_repo}/Packages/ObserverCore" -c release --show-bin-path)
index_count="${1:-1000000}"
if [ -f "${index_core}/libObserverCore.a" ]; then
    set -- "${index_core}/libObserverCore.a"
else
    set -- "${index_core}"/ObserverCore.build/*.o
fi
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx15.0" -I "${index_core}" -I "${index_core}/Modules" "$@" -lsqlite3 -module-cache-path "$index_temp/modules" \
    "$index_repo/Tests/Performance/SessionIndexBenchmark.swift" -o "$index_temp/check"
/usr/bin/time -l "$index_temp/check" "$index_count"
