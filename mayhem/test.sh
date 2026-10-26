#!/usr/bin/env bash
#
# mayhem/test.sh — RUN direwolf's own test suite (already built by mayhem/build.sh with normal flags).
# exit 0 = pass. Oracle: every upstream unit-test binary must print its own success line (not just
# exit 0), every modem regression script (gen_packets -> atest) must actually decode packets, and two
# known-input/known-output checks (APRS text decode; modem round trip) assert exact content.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


B="$SRC/mayhem/build/tests"
for f in "$B/src/atest" "$B/src/gen_packets" "$B/src/decode_aprs" "$B/test/dtest"; do
  [ -x "$f" ] || { echo "missing $f — mayhem/build.sh should have built it" >&2; emit_ctrf "direwolf" 0 1; exit 1; }
done

strip() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
passed=0; failed=0
ok()   { passed=$((passed+1)); echo "PASS $1"; }
bad()  { failed=$((failed+1)); echo "FAIL $1: $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# 1) Upstream unit tests: exit 0 AND the program's own success marker in its output.
unit() {
  local name="$1" marker="$2" out rc
  out="$("$B/test/$name" 2>&1 | strip)"; rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF -- "$marker"; then ok "$name"; else bad "$name" "rc=$rc, missing '$marker'"; fi
}
unit dtest      "SUCCESS -- All digipeater tests passed."
unit ttest      "All tests passed."
unit tttexttest "SUCCESS!  All tests passed."
unit pftest     "Packet Filtering Test - SUCCESS!"
unit tlmtest    "TEST WAS SUCCESSFUL."
unit lltest     "Location Coordinate Conversion Test - SUCCESS!"
unit enctest    "Encode APRS test PASSED with no errors."
unit kisstest   "Quick KISS test passed OK."
unit pad2test   "SUCCESS!"
unit xidtest    "XID test:  Success."
unit dtmftest   "Success!"

# 2) Modem regression scripts (gen_packets -> atest with -L/-G bounds). Each atest run must print
#    "N packets decoded" with N > 0, once per invocation in the script.
for s in "$B"/test/check-*; do
  name="$(basename "$s")"
  out="$("$s" 2>&1 | strip)"; rc=${PIPESTATUS[0]}
  want="$(grep -c 'atest ' "$s")"
  got="$(printf '%s\n' "$out" | grep -cE '^[1-9][0-9]* packets decoded in ')"
  if [ "$rc" -ne 0 ]; then bad "$name" "rc=$rc"
  elif [ "$want" -gt 0 ] && [ "$got" -ne "$want" ]; then bad "$name" "expected $want decoding runs, saw $got"
  elif [ "$want" -eq 0 ] && ! printf '%s\n' "$out" | grep -qF "SUCCESS!"; then bad "$name" "no SUCCESS! marker"
  else ok "$name"; fi
done

# 3) Known answer: APRS position report decodes to exact fields.
printf 'WB2OSZ-5>APDW17,WIDE1-1:!4237.14N/07120.83W#PHG7140Digi\n' > kat.txt
out="$("$B/src/decode_aprs" kat.txt 2>&1 | strip)"
if printf '%s\n' "$out" | grep -qF "Position, Generic digipeater, WB2OSZ DireWolf, 49 W height(HAAT)=20ft=6m 4dBi omni" \
   && printf '%s\n' "$out" | grep -qF "N 42 37.1400, W 071 20.8300"; then
  ok "decode_aprs known answer"; else bad "decode_aprs known answer" "unexpected output: $out"; fi

# 4) Known answer: 1200 baud modem round trip. gen_packets modulates a known frame, atest demodulates it.
"$B/src/gen_packets" -n 3 -o kat.wav >/dev/null 2>&1
out="$("$B/src/atest" -F1 kat.wav 2>&1 | strip)"
if printf '%s\n' "$out" | grep -qF "[0] WB2OSZ-15>TEST:,The quick brown fox jumps over the lazy dog!  0001 of 0003" \
   && printf '%s\n' "$out" | grep -qE '^[23] packets decoded in '; then
  ok "modem round trip known answer"; else bad "modem round trip known answer" "unexpected output"; fi

emit_ctrf "direwolf" "$passed" "$failed" 0
