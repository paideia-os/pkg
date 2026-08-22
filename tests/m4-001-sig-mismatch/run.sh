#!/bin/sh
# tests/m4-001-sig-mismatch/run.sh -- pkg.M4-001
#
# Wave: R49  Milestone: M4  Issue: #13 (pkg.M4-001)
# Spec:  design/test-matrix.md §2 sig-mismatch matrix.
#
# Walks the three sig-mismatch fixtures against `pkg install pkg` and
# asserts each cell refuses with the pinned (exit, stderr[0]) pair.
# Exits 0 iff every cell passes; else exits with the count of
# failed cells (capped at 127).
#
# At M4-close every cell refuses at the crypto seam (INSTALL_ERR_
# VERIFY / MC_VERIFY_STUB) because paideia-as v0.33-crypto-kdf is
# not yet on the toolchain. When v0.33 lands, the expected/*.txt
# files diff-flip to the discriminating error codes -- the driver
# is unchanged.
#
# Env vars:
#   PKG_BINARY      (default build-out/pkg)
#   PDX_STAGING     (default /tmp/pkg-staging)
#   PDX_FIXTURE_DIR (default tests/m4-001-sig-mismatch/fixtures)

set -eu

: ${PKG_BINARY:=build-out/pkg}
: ${PDX_STAGING:=/tmp/pkg-staging}
: ${PDX_FIXTURE_DIR:=tests/m4-001-sig-mismatch/fixtures}

HERE=$(dirname "$0")
EXPECTED_DIR="$HERE/expected"

# Regenerate fixtures if any are missing (idempotent).
for f in pkg-author-bad.pdxsig pkg-root-bad.pdxsig pkg-both-bad.pdxsig; do
    if [ ! -f "$PDX_FIXTURE_DIR/$f" ]; then
        sh "$HERE/gen-fixtures.sh"
        break
    fi
done

mkdir -p "$PDX_STAGING"

FAIL_COUNT=0
CELLS='author-bad root-bad both-bad'

for cell in $CELLS; do
    fixture="$PDX_FIXTURE_DIR/pkg-$cell.pdxsig"
    expected="$EXPECTED_DIR/$cell.txt"

    if [ ! -f "$fixture" ]; then
        printf 'FAIL: %s -- fixture missing (%s)\n' "$cell" "$fixture" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if [ ! -f "$expected" ]; then
        printf 'FAIL: %s -- expected file missing (%s)\n' "$cell" "$expected" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # Stage the fixture where pkg install reads from.
    cp "$fixture" "$PDX_STAGING/pkg.pdxsig"

    # Invoke pkg install pkg; capture exit + first stderr line.
    STDERR_FILE=$(mktemp)
    set +e
    "$PKG_BINARY" install pkg > /dev/null 2> "$STDERR_FILE"
    ACTUAL_EXIT=$?
    set -e
    ACTUAL_STDERR0=$(head -n 1 "$STDERR_FILE" || true)
    rm -f "$STDERR_FILE"

    # Read expected values -- format:
    #   exit=<int>
    #   stderr[0]=<line>
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
done

if [ "$FAIL_COUNT" = "0" ]; then
    printf 'M4-001: all %d cells passed\n' "$(printf '%s\n' $CELLS | wc -l | tr -d ' ')"
    exit 0
fi

if [ "$FAIL_COUNT" -gt 127 ]; then
    FAIL_COUNT=127
fi
exit "$FAIL_COUNT"
