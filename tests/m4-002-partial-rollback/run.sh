#!/bin/sh
# tests/m4-002-partial-rollback/run.sh -- pkg.M4-002
#
# Wave: R49  Milestone: M4  Issue: #14 (pkg.M4-002)
# Spec:  design/test-matrix.md §3 partial-install rollback.
#
# Drives the two Branch A cells reachable at M3-close substrate:
# header-refuse (fixture-less bare invocation hits pi_err_header)
# and elevate-refuse (would fire post-wire-in; documented for M5).
# Branches B and C land as separate driver files at M5 per
# design/test-matrix.md §3.3.
#
# Env vars:
#   PKG_BINARY  (default build-out/pkg)
#   PDX_STAGING (default /tmp/pkg-staging)

set -eu

: ${PKG_BINARY:=build-out/pkg}
: ${PDX_STAGING:=/tmp/pkg-staging}

HERE=$(dirname "$0")
EXPECTED_DIR="$HERE/expected"

mkdir -p "$PDX_STAGING"

FAIL_COUNT=0

# ---- Cell 1: header-refuse -----------------------------------------
# Bare `pkg install pkg` -- no fixture, _install_staging is zero-init.
# mc_read_header refuses at magic check -> pi_err_header -> exit 1.
# Cleanup: Branch A (nothing to roll back).

cell=header-refuse
expected="$EXPECTED_DIR/$cell.txt"

if [ ! -f "$expected" ]; then
    printf 'FAIL: %s -- expected file missing (%s)\n' "$cell" "$expected" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    # Clear staging so no stale fixture from a previous run leaks in
    # (once the fixture wire-in lands this becomes a real property).
    rm -f "$PDX_STAGING/pkg.pdxsig"

    STDERR_FILE=$(mktemp)
    set +e
    "$PKG_BINARY" install pkg > /dev/null 2> "$STDERR_FILE"
    ACTUAL_EXIT=$?
    set -e
    ACTUAL_STDERR0=$(head -n 1 "$STDERR_FILE" || true)
    rm -f "$STDERR_FILE"

    EXPECTED_EXIT=$(grep '^exit=' "$expected" | sed 's/^exit=//')
    EXPECTED_STDERR0=$(grep '^stderr\[0\]=' "$expected" | sed 's/^stderr\[0\]=//')

    ok=1
    if [ "$ACTUAL_EXIT" != "$EXPECTED_EXIT" ]; then
        printf 'FAIL: %s -- exit expected %s, got %s\n' "$cell" "$EXPECTED_EXIT" "$ACTUAL_EXIT" >&2
        ok=0
    fi
    if [ "$ACTUAL_STDERR0" != "$EXPECTED_STDERR0" ]; then
        printf 'FAIL: %s -- stderr[0] expected %s\n              got %s\n' \
            "$cell" "$EXPECTED_STDERR0" "$ACTUAL_STDERR0" >&2
        ok=0
    fi

    if [ "$ok" = "1" ]; then
        printf 'PASS: %s\n' "$cell"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# ---- Cell 2: elevate-refuse (documented; unreachable at M4) --------
# Not driven at M4 -- the header-refuse cell fires first for every
# input. When the fixture wire-in lands, this cell fires with
# INSTALL_ERR_PARENT and Branch A cleanup (txn never opened because
# elevate returned 0 -> PXT_MINT_BAD_PARENT). Kept as an
# expected-outcome cell so the M5 driver uplift is additive.
printf 'SKIP: elevate-refuse (unreachable at M4-close; see README §3)\n'

# ---- Cell 3: mint-then-refuse (Branch B, M5 only) ------------------
printf 'SKIP: mint-then-refuse (Branch B, M5-substrate-only; see README §3)\n'

# ---- Cell 4: commit-then-refuse (Branch C, M5 only) ----------------
printf 'SKIP: commit-then-refuse (Branch C, M5-substrate-only; see README §3)\n'

if [ "$FAIL_COUNT" = "0" ]; then
    printf 'M4-002: header-refuse cell passed (3 cells skipped, pending substrate)\n'
    exit 0
fi

if [ "$FAIL_COUNT" -gt 127 ]; then
    FAIL_COUNT=127
fi
exit "$FAIL_COUNT"
