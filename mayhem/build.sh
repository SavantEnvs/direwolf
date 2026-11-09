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
# it is linked into every harness.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
# -fno-sanitize=shift-base: upstream's fx25 / gen_tone code left-shifts signed values into the sign bit
# on every packet (benign), which would abort every input under halting UBSan.
FLAGS="$SANITIZER_FLAGS -fno-sanitize=shift-base -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S "$SRC" -B "$ASAN" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $BUILD/lsan_off.o" \
      -DUNITTEST:BOOL=OFF
cmake --build "$ASAN" -j"$MAYHEM_JOBS" --target direwolf   # builds the objects the harness links

# 2) Harnesses: every library object of the direwolf program except the one holding main().
mapfile -t LIBOBJS < <(find "$ASAN/src/CMakeFiles/direwolf.dir" -name '*.c.o' ! -name 'direwolf.c.o' | sort)
GEO="$ASAN/external/geotranz/libgeotranz.a"
SYSLIBS=(-lasound -lrt -lm -lpthread)
INC=(-I"$SRC/src" -I"$SRC/external/geotranz" -I"$SRC/external/misc" -I"$SRC/external/regex" -I"$ASAN")

$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

HFLAGS="$SANITIZER_FLAGS -fno-sanitize=shift-base $DEBUG_FLAGS"
$CC $HFLAGS -fsanitize=fuzzer-no-link "${INC[@]}" -c "$SRC/mayhem/dw_stubs.c" -o "$BUILD/dw_stubs.o"

for h in fuzz_kiss; do
  $CC $HFLAGS -fsanitize=fuzzer-no-link "${INC[@]}" -c "$SRC/mayhem/$h.c" -o "$BUILD/$h.o"
  $CC $HFLAGS $LIB_FUZZING_ENGINE "$BUILD/$h.o" "$BUILD/lsan_off.o" "$BUILD/dw_stubs.o" \
      "${LIBOBJS[@]}" "$GEO" "${SYSLIBS[@]}" -o "$SRC/$h"
  $CC $HFLAGS "$BUILD/$h.o" "$BUILD/lsan_off.o" "$BUILD/dw_stubs.o" "$BUILD/standalone_main.o" \
      "${LIBOBJS[@]}" "$GEO" "${SYSLIBS[@]}" -o "$SRC/$h-standalone"
done

# 3) Test suite, built independently with the project's normal flags (clean, no sanitizers).
cmake -S "$SRC" -B "$TESTS" -DCMAKE_BUILD_TYPE=Release -DUNITTEST:BOOL=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TESTS" -j"$MAYHEM_JOBS" --target gen_packets atest decode_aprs \
      dtest ttest tttexttest pftest tlmtest lltest enctest kisstest pad2test xidtest dtmftest \
      fxsend fxrec il2p_test
