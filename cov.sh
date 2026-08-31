#!/bin/bash
# Coverage for the selftest. Usage: ./cov.sh [--html]
#
# Two bars: the pure-logic files must stay near-total, the whole app must not
# slide back. The app can't reach 100%: recording, whisper, the CGEvent tap and
# the OpenRouter calls all need real hardware, real permissions and a network,
# and faking them here would only test the fakes.
set -e
cd "$(dirname "$0")"
OUT=".cov"
MIN="${COV_MIN:-90}"          # pure-logic files
MIN_ALL="${COV_MIN_ALL:-65}"  # whole app
GATED=(Core.swift L.swift Log.swift)
# Every source but the icon generator, which is its own standalone script — so a
# new file never silently drops out of the coverage build.
SRC=(); for f in *.swift; do [ "$f" = MakeIcon.swift ] || SRC+=("$f"); done

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

# The logic files are gated on all three numbers — line coverage alone is the
# easiest to inflate. The whole app is gated on lines only: most of its missed
# "regions" are SwiftUI branches that never run without a mouse.
fail=0
report "${GATED[@]}" | tail -1 | awk -v m="$MIN" '{
  gsub(/%/, "")
  printf "logic     : regions %s%%  functions %s%%  lines %s%%  (min %s%% each)\n", $4, $7, $10, m
  exit ($4+0 < m+0 || $7+0 < m+0 || $10+0 < m+0)
}' || fail=1
report | tail -1 | awk -v m="$MIN_ALL" '{
  gsub(/%/, "")
  printf "whole app : regions %s%%  functions %s%%  lines %s%%  (min %s%% lines)\n", $4, $7, $10, m
  exit ($10+0 < m+0)
}' || fail=1
[ "$fail" = 0 ] && echo ok || { echo "FAIL: below the coverage bar"; exit 1; }
