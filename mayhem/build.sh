#!/usr/bin/env bash
#
# mayhem/build.sh — build direwolf's fuzz harnesses (sanitized) and its unit/regression tests
# (normal flags). Air-gapped and idempotent: no network, safe to re-run in place.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image exports
# the build contract: CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS DEBUG_FLAGS STANDALONE_FUZZ_MAIN SRC.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BUILD="$SRC/mayhem/build"
ASAN="$BUILD/asan"
TESTS="$BUILD/tests"

# 1) Sanitized + DWARF-3 build of the whole project. -fsanitize=fuzzer-no-link adds libFuzzer's
#    coverage instrumentation to the library code without linking the fuzzer runtime.
# Always configure from scratch: cmake discards its cache (and the -D options with it) when the compiler
# path differs between runs (ccache pre-fill wrapper in the image build vs. plain clang on a re-run).
rm -rf "$ASAN" "$TESTS"
mkdir -p "$BUILD"
# lsan_off.cc turns leak detection off (a long-lived daemon's one-time init allocations are not defects);
# it is linked into atest and every harness.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
# -fno-sanitize=shift-base: upstream's fx25 / gen_tone code left-shifts signed values into the sign bit
# on every packet (benign), which would abort every input under halting UBSan.
FLAGS="$SANITIZER_FLAGS -fno-sanitize=shift-base -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S "$SRC" -B "$ASAN" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $BUILD/lsan_off.o" \
      -DUNITTEST:BOOL=OFF
cmake --build "$ASAN" -j"$MAYHEM_JOBS" --target direwolf atest   # builds objects; atest is re-linked below

# 2) Harnesses: every library object of the direwolf program except the one holding main().
mapfile -t LIBOBJS < <(find "$ASAN/src/CMakeFiles/direwolf.dir" -name '*.c.o' ! -name 'direwolf.c.o' | sort)
GEO="$ASAN/external/geotranz/libgeotranz.a"
SYSLIBS=(-lasound -lrt -lm -lpthread)
INC=(-I"$SRC/src" -I"$SRC/external/geotranz" -I"$SRC/external/misc" -I"$SRC/external/regex" -I"$ASAN")

$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

HFLAGS="$SANITIZER_FLAGS -fno-sanitize=shift-base $DEBUG_FLAGS"
$CC $HFLAGS -fsanitize=fuzzer-no-link "${INC[@]}" -c "$SRC/mayhem/dw_stubs.c" -o "$BUILD/dw_stubs.o"

for h in fuzz_aprs fuzz_monitor fuzz_kiss fuzz_encode; do
  $CC $HFLAGS -fsanitize=fuzzer-no-link "${INC[@]}" -c "$SRC/mayhem/$h.c" -o "$BUILD/$h.o"
  $CC $HFLAGS $LIB_FUZZING_ENGINE "$BUILD/$h.o" "$BUILD/lsan_off.o" "$BUILD/dw_stubs.o" \
      "${LIBOBJS[@]}" "$GEO" "${SYSLIBS[@]}" -o "$SRC/$h"
  $CC $HFLAGS "$BUILD/$h.o" "$BUILD/lsan_off.o" "$BUILD/dw_stubs.o" "$BUILD/standalone_main.o" \
      "${LIBOBJS[@]}" "$GEO" "${SYSLIBS[@]}" -o "$SRC/$h-standalone"
done

# 3) The sanitized modem decoder (file-input target: decodes a WAV file). Re-link it by hand: cmake's
#    link line carries -ffast-math, which pulls in libgcc's crtfastmath.o (DWARF 5) and breaks the DWARF<4 rule.
#    atest trusts the WAV header's sample rate, while direwolf.c / gen_packets.c reject a rate outside
#    MIN_SAMPLES_PER_SEC..MAX_SAMPLES_PER_SEC before any modem is initialised. Mirror that check in a patched
#    copy of atest.c (the tracked source is untouched) so header-driven driver crashes (int overflow in
#    one_filetime, the gen_lowpass assert, the float->int cast in demod_afsk_init) are not reported as defects.
#    The copy is compiled with the exact flags cmake used for atest.c and replaces that object.
ATEST_SRC="$BUILD/atest_ratecheck.c"
sed '/^[[:space:]]*my_audio_config\.adev\[0\]\.samples_per_sec = format\.nsamplespersec;/i\
\	if (format.nsamplespersec < MIN_SAMPLES_PER_SEC || format.nsamplespersec > MAX_SAMPLES_PER_SEC) {\
\	  text_color_set(DW_COLOR_ERROR);\
\	  dw_printf ("Sorry, sample rate must be %d to %d Hz.  This file has %d.\\n", MIN_SAMPLES_PER_SEC, MAX_SAMPLES_PER_SEC, format.nsamplespersec);\
\	  exit (EXIT_FAILURE);\
\	}' "$SRC/src/atest.c" > "$ATEST_SRC"
grep -q 'MIN_SAMPLES_PER_SEC' "$ATEST_SRC" || { echo "build.sh: atest.c rate-check patch did not apply" >&2; exit 1; }
FLAGSMK="$ASAN/src/CMakeFiles/atest.dir/flags.make"
ATEST_CFLAGS_STR="$(sed -n 's/^C_DEFINES = //p;s/^C_INCLUDES = //p;s/^C_FLAGS = //p' "$FLAGSMK" | tr '\n' ' ')"
eval "ATEST_CFLAGS=($ATEST_CFLAGS_STR)"   # flags.make is shell-quoted (e.g. -DMAJOR=\"...\" with spaces)
ATEST_OBJ="$ASAN/src/CMakeFiles/atest.dir/atest.c.o"
$CC "${ATEST_CFLAGS[@]}" -I"$SRC/src" -c "$ATEST_SRC" -o "$ATEST_OBJ"
mapfile -t ATESTOBJS < <(find "$ASAN/src/CMakeFiles/atest.dir" -name '*.c.o' | sort)
$CC $HFLAGS "$BUILD/lsan_off.o" "${ATESTOBJS[@]}" -lrt -lm -lpthread -o "$SRC/atest"

# 4) Test suite, built independently with the project's normal flags (clean, no sanitizers).
cmake -S "$SRC" -B "$TESTS" -DCMAKE_BUILD_TYPE=Release -DUNITTEST:BOOL=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TESTS" -j"$MAYHEM_JOBS" --target gen_packets atest decode_aprs \
      dtest ttest tttexttest pftest tlmtest lltest enctest kisstest pad2test xidtest dtmftest \
      fxsend fxrec il2p_test
