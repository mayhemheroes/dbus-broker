#!/usr/bin/env bash
#
# dbus-broker/mayhem/build.sh — build the OSS-Fuzz `fuzz-message` harness as a sanitized
# libFuzzer target (+ a standalone reproducer), AND dbus-broker's own meson unit-test suite
# for mayhem/test.sh.
#
# Fuzzed surface: the D-Bus WIRE-PROTOCOL message parser. The harness reads attacker-controlled
# bytes, treats the first 16 bytes as a `MessageHeader` (endian byte 'l'/'B', type, flags,
# version, n_body, serial, n_fields — see src/dbus/message.h), constructs an incoming Message
# via message_new_incoming(), copies the declared body, then drives message_parse_metadata()
# (header-field / signature / body parsing via c-dvar) and message_stitch_sender(). The whole
# of libbus (incl. src/dbus/message.c, protocol.c, the c-dvar variant parser) is compiled with
# $SANITIZER_FLAGS so the parsed code — not just the harness — is instrumented.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN. dbus-broker builds with meson+ninja; its c-util libs (c-dvar, c-utf8,
# c-list, c-rbtree, c-stdaux, c-ini, c-shquote) and Rust glue (libc, bus1/sys) are meson git-wrap
# subprojects fetched by `meson setup`, and bindgen generates Rust FFI for libbus — so the build
# needs meson, ninja, rustc, cargo, bindgen, pkg-config, jq (installed in the Dockerfile).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
# Coverage instrumentation for the FUZZED library (SanitizerCoverage, no fuzzer main). libFuzzer's
# engine (-fsanitize=fuzzer) only links the driver; without -fsanitize=fuzzer-no-link on the meson
# build, libbus-static.a carries NO coverage callbacks -> libFuzzer sees 0 edges (Mayhem run:
# edges=0). Match OSS-Fuzz: instrument the parsed code, not just the harness.
: "${COV_FLAGS=-fsanitize=fuzzer-no-link}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS COV_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Sanitized meson build of dbus-broker (the fuzzed parser is instrumented) ────────────────
# -Db_lundef=false: the libFuzzer/standalone main is provided at harness-link time (matches OSS-Fuzz).
# -Dlauncher=false: skip the launcher (expat/libsystemd) — not on the fuzzed path.
# -Dtests=true: also build the unit-test binaries here, sanitized; mayhem/test.sh runs them.
# meson honours $CFLAGS/$CXXFLAGS, so push $SANITIZER_FLAGS + $DEBUG_FLAGS through them.
SANI_BUILD="$SRC/build"
rm -rf "$SANI_BUILD"
CFLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
  meson setup -Db_lundef=false -Dlauncher=false -Dtests=true "$SANI_BUILD" \
  || { cat "$SANI_BUILD/meson-logs/meson-log.txt" 2>/dev/null; exit 1; }
ninja -C "$SANI_BUILD" -v -j"$MAYHEM_JOBS"
echo "built sanitized dbus-broker (libbus-static.a + unit tests)"

# Library set the harness links against (same as OSS-Fuzz build.sh): libbus + c-dvar + c-utf8.
# libbus-static.a already pulls in the Rust glue (rbus_static) via the meson link.
INC="-Isrc -I$(echo subprojects/libcstdaux-*/src)"
LIBS=( "$SANI_BUILD/src/libbus-static.a" )
LIBS+=( $(echo "$SANI_BUILD"/subprojects/libcdvar-*/src/libcdvar-*.a) )
LIBS+=( $(echo "$SANI_BUILD"/subprojects/libcutf8-*/src/libcutf8-*.a) )

# ── 2) Build the harness: compile once, link twice (libFuzzer + standalone reproducer) ─────────
$CC $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -c -o "$SANI_BUILD/fuzz-message.o" \
    $INC -std=c11 -D_GNU_SOURCE "$HARNESS_DIR/fuzz-message.c"

# libFuzzer target -> /mayhem/fuzz-message  (link with clang++ for the C++ libFuzzer runtime)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/fuzz-message \
    "$SANI_BUILD/fuzz-message.o" "${LIBS[@]}" $LIB_FUZZING_ENGINE

# Standalone reproducer (no libFuzzer runtime; reads one input file, runs once, natural crash).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SANI_BUILD/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/fuzz-message-standalone \
    "$SANI_BUILD/fuzz-message.o" "$SANI_BUILD/standalone_main.o" "${LIBS[@]}"

echo "built fuzz-message (+ standalone)"

echo "build.sh complete:"
ls -la /mayhem/fuzz-message /mayhem/fuzz-message-standalone 2>&1 || true
