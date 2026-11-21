#!/bin/sh
# A real 2 GiB / 128-stream RTP scan, including bounded charts and sequence tracking.
set -eu
analysis_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
analysis_temp=$(mktemp -d "${TMPDIR:-/tmp}/observer-analysis-benchmark.XXXXXX")
trap 'rm -rf "$analysis_temp"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -O -module-cache-path "$analysis_temp/modules" \
    "$analysis_repo/Sources/LiveKitObserver/PacketCapture.swift" \
    "$analysis_repo/Sources/LiveKitObserver/PacketInspection.swift" \
    "$analysis_repo/Sources/LiveKitObserver/RTPAnalysis.swift" \
    "$analysis_repo/Sources/LiveKitObserver/CaptureAnalysis.swift" \
    "$analysis_repo/Tests/Performance/AnalysisBenchmark.swift" -o "$analysis_temp/check"
/usr/bin/time -l "$analysis_temp/check" 2147483648 2> "$analysis_temp/memory.txt"
cat "$analysis_temp/memory.txt"
awk '/maximum resident set size/ { measured = 1; if ($1 > 268435456) failed = 1 }
     END { if (!measured || failed) { print "FAIL: analysis must stay below 256 MiB peak RSS"; exit 1 } }' "$analysis_temp/memory.txt"
