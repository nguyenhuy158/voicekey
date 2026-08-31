#!/bin/bash
# Coverage for the selftest. Usage: ./cov.sh [--html]
#
# The gate covers the pure-logic files only. The rest of the app is AppKit and
# SwiftUI driven by a real event loop, a real mic and a real whisper binary —
# a headless --selftest run cannot reach it, and pretending otherwise would
# just mean writing tests that assert nothing.
set -e
cd "$(dirname "$0")"
OUT=".cov"
MIN="${COV_MIN:-90}"
GATED=(Core.swift L.swift Log.swift)
SRC=(main.swift Core.swift Log.swift L.swift AI.swift History.swift HUD.swift
     Settings.swift Stats.swift Account.swift MainWindow.swift SelfTest.swift)

rm -rf "$OUT"; mkdir -p "$OUT"
swiftc -profile-generate -profile-coverage-mapping "${SRC[@]}" -o "$OUT/VoiceKey" \
  -framework Cocoa -framework AVFoundation -framework SwiftUI

LLVM_PROFILE_FILE="$OUT/cov.profraw" "$OUT/VoiceKey" --selftest >"$OUT/selftest.log"
xcrun llvm-profdata merge -sparse "$OUT/cov.profraw" -o "$OUT/cov.profdata"

report() { xcrun llvm-cov report "$OUT/VoiceKey" -instr-profile="$OUT/cov.profdata" "$@"; }
echo "=== whole app (context only, not gated)"; report
echo "=== gated: ${GATED[*]}"; report "${GATED[@]}"

if [ "$1" = "--html" ]; then
  xcrun llvm-cov show "$OUT/VoiceKey" -instr-profile="$OUT/cov.profdata" \
    -format=html -output-dir="$OUT/html" "${GATED[@]}"
  echo "html: $OUT/html/index.html"
fi

# Gate on regions, functions and lines alike — line coverage on its own is the
# easiest of the three to inflate.
report "${GATED[@]}" | tail -1 | awk -v m="$MIN" '{
  gsub(/%/, "")
  printf "gated coverage: regions %s%%  functions %s%%  lines %s%%  (min %s%%)\n", $4, $7, $10, m
  if ($4+0 < m+0 || $7+0 < m+0 || $10+0 < m+0) { print "FAIL: below the coverage bar"; exit 1 }
  print "ok"
}'
