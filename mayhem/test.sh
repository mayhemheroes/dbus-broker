#!/usr/bin/env bash
#
# dbus-broker/mayhem/test.sh — RUN dbus-broker's own meson UNIT test suite (built by
# mayhem/build.sh) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: the `unit` suite is assertion-based — each src/<sub>/test-*.c builds with
# `#undef NDEBUG` and drives the real code with `c_assert(...)` on expected return codes / parsed
# values (e.g. test-message.c asserts message_new_incoming() returns MESSAGE_E_TOO_LARGE past the
# 128MB cap and 0 below it; test-sasl.c asserts the SASL handshake state machine; test-stitching.c
# asserts message_stitch_sender() rewrites the sender field byte-exactly). These cover the SAME
# wire-protocol parser the fuzzer hits (D-Bus Message Abstraction / SASL Parser / Sender Stitching),
# so a no-op / exit(0) PATCH that breaks parsing cannot pass. We run ONLY the self-contained `unit`
# suite — no running bus, no root, no sockets to external services — so it is hermetic. This script
# only RUNS the pre-built suite via `meson test`; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/build"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "meson-test" 0 1 0; exit 2
fi
if ! command -v meson >/dev/null 2>&1; then
  echo "meson not available — cannot run the test suite" >&2
  emit_ctrf "meson-test" 0 1 0; exit 2
fi

# The sanitized build can leak benign allocations on abort paths; keep the unit suite hermetic.
export ASAN_OPTIONS="detect_leaks=0:${ASAN_OPTIONS:-}"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:${UBSAN_OPTIONS:-}"

echo "=== running meson test --suite unit in $BUILDDIR ==="
out="$(meson test -C "$BUILDDIR" --suite unit --print-errorlogs 2>&1)"; rc=$?
echo "$out"

# meson summary block:  Ok: N / Expected Fail: N / Fail: N / Unexpected Pass: N / Skipped: N / Timeout: N
PASSED=$(printf '%s\n' "$out" | sed -n 's/^Ok:[[:space:]]*\([0-9][0-9]*\).*/\1/p'              | tail -1)
EXPFAIL=$(printf '%s\n' "$out" | sed -n 's/^Expected Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
FAIL=$(printf '%s\n' "$out" | sed -n 's/^Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p'              | tail -1)
UNEXP=$(printf '%s\n' "$out" | sed -n 's/^Unexpected Pass:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
SKIP=$(printf '%s\n' "$out" | sed -n 's/^Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p'           | tail -1)
TIMEOUT=$(printf '%s\n' "$out" | sed -n 's/^Timeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p'        | tail -1)
: "${PASSED:=0}" "${EXPFAIL:=0}" "${FAIL:=0}" "${UNEXP:=0}" "${SKIP:=0}" "${TIMEOUT:=0}"

PASS_TOTAL=$(( PASSED + EXPFAIL ))
FAIL_TOTAL=$(( FAIL + UNEXP + TIMEOUT ))

# If meson produced no parseable summary, fall back to its exit code.
if [ "$(( PASS_TOTAL + FAIL_TOTAL + SKIP ))" -eq 0 ]; then
  echo "could not parse meson test summary; using meson exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "meson-test" 1 0 0; exit 0; }
  emit_ctrf "meson-test" 0 1 0; exit 1
fi

emit_ctrf "meson-test" "$PASS_TOTAL" "$FAIL_TOTAL" "$SKIP"
