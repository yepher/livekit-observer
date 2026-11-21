#!/bin/sh
# Imports and verifies an export of a synthetic 2 GiB capture, then checks peak RSS.
# Requires macOS and Xcode command-line tools. All generated files are temporary.
set -eu
capture_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
capture_benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/observer-capture-benchmark.XXXXXX")
trap 'rm -rf "$capture_benchmark_dir"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library -O -module-cache-path "$capture_benchmark_dir/modules" \
    "$capture_repo/Sources/LiveKitObserver/PacketCapture.swift" \
    "$capture_repo/Tests/Performance/CaptureBenchmark.swift" \
    -o "$capture_benchmark_dir/check"

/usr/bin/time -l "$capture_benchmark_dir/check" 2147483648 2> "$capture_benchmark_dir/memory.txt"
cat "$capture_benchmark_dir/memory.txt"
awk '/maximum resident set size/ { measured = 1; if ($1 > 268435456) failed = 1 }
     END { if (!measured || failed) { print "FAIL: capture transfer must stay below 256 MiB peak RSS"; exit 1 } }' \
    "$capture_benchmark_dir/memory.txt"
