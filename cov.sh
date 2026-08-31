#!/bin/bash
# Coverage for the selftest. Usage: ./cov.sh [--html]
set -e
cd "$(dirname "$0")"
OUT=".cov"
MIN="${COV_MIN:-90}"
# UI is driven by AppKit/SwiftUI at runtime, not by the selftest — exclude it from
# the gate instead of pretending a headless run can cover it.
SKIP='(Settings|HUD|MainWindow|Account|Stats|History|MakeIcon|SelfTest)\.swift'

rm -rf "$OUT"; mkdir -p "$OUT"
swiftc -profile-generate -profile-coverage-mapping \
  main.swift Log.swift L.swift AI.swift History.swift HUD.swift Settings.swift \
  Stats.swift Account.swift MainWindow.swift SelfTest.swift -o "$OUT/VoiceKey" \
  -framework Cocoa -framework AVFoundation -framework SwiftUI

LLVM_PROFILE_FILE="$OUT/cov.profraw" "$OUT/VoiceKey" --selftest >"$OUT/selftest.log"
xcrun llvm-profdata merge -sparse "$OUT/cov.profraw" -o "$OUT/cov.profdata"

report() { xcrun llvm-cov report "$OUT/VoiceKey" -instr-profile="$OUT/cov.profdata" "$@"; }
echo "=== all files"; report
echo "=== gated files"; report --ignore-filename-regex="$SKIP"

if [ "$1" = "--html" ]; then
  xcrun llvm-cov show "$OUT/VoiceKey" -instr-profile="$OUT/cov.profdata" \
    -format=html -output-dir="$OUT/html" --ignore-filename-regex="$SKIP"
  echo "html: $OUT/html/index.html"
fi

PCT=$(report --ignore-filename-regex="$SKIP" | command tail -1 | command awk '{print $(NF-3)}' | tr -d '%')
echo "line coverage (gated): $PCT%  (min $MIN%)"
command awk -v p="$PCT" -v m="$MIN" 'BEGIN { exit (p+0 >= m+0) ? 0 : 1 }'
