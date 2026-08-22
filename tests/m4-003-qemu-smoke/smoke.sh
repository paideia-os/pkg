#!/bin/sh
# tests/m4-003-qemu-smoke/smoke.sh -- pkg.M4-003
#
# Wave: R49  Milestone: M4  Issue: #15 (pkg.M4-003)
# Spec:  design/test-matrix.md §4 QEMU smoke matrix.
#
# Runs the five-subcommand chain `install -> list -> verify ->
# remove -> list` and diffs the per-cell (exit, stderr[0]) against
# the pinned expected/full-matrix.txt.
#
# Runs cleanly against a `build-out/pkg` binary in the current
# shell; wires into paideia-os's tools/run-smoke.sh via an M4
# follow-up patch to that repo.
#
# Env vars:
#   PKG_BINARY  (default build-out/pkg)
#   PDX_STAGING (default /tmp/pkg-staging)

set -eu

: ${PKG_BINARY:=build-out/pkg}
: ${PDX_STAGING:=/tmp/pkg-staging}

HERE=$(dirname "$0")
EXPECTED_FILE="$HERE/expected/full-matrix.txt"

if [ ! -f "$EXPECTED_FILE" ]; then
    printf 'FAIL: expected transcript missing (%s)\n' "$EXPECTED_FILE" >&2
    exit 1
fi

mkdir -p "$PDX_STAGING"

# Clear any leftover fixture so the chain starts from a known baseline.
rm -f "$PDX_STAGING/pkg.pdxsig"

# ---- Cell runner ---------------------------------------------------
# Args: <cell-name> <expected-exit> <expected-stderr[0]> <cmd> [args...]
# Prints PASS/FAIL. Bumps FAIL_COUNT on mismatch.
FAIL_COUNT=0

run_cell() {
    cell="$1"
    exp_exit="$2"
    exp_stderr0="$3"
    shift 3

    STDERR_FILE=$(mktemp)
    set +e
    "$PKG_BINARY" "$@" > /dev/null 2> "$STDERR_FILE"
    act_exit=$?
    set -e
    act_stderr0=$(head -n 1 "$STDERR_FILE" || true)
    rm -f "$STDERR_FILE"

    ok=1
    if [ "$act_exit" != "$exp_exit" ]; then
        printf 'FAIL: %s -- exit expected %s, got %s\n' "$cell" "$exp_exit" "$act_exit" >&2
        ok=0
    fi
    if [ "$act_stderr0" != "$exp_stderr0" ]; then
        printf 'FAIL: %s -- stderr[0] expected %s\n              got %s\n' \
            "$cell" "$exp_stderr0" "$act_stderr0" >&2
        ok=0
    fi

    if [ "$ok" = "1" ]; then
        printf 'PASS: %s\n' "$cell"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ---- Parse expected/full-matrix.txt --------------------------------
# Format (one block per cell; blocks separated by "---"):
#   cell=<name>
#   exit=<int>
#   stderr[0]=<line>
#
# Iterate blocks; for each, invoke run_cell with the corresponding
# subcommand from the chain below. The chain sequence is fixed here
# and MUST match the block order in full-matrix.txt.

# Chain sequence -- five pkg invocations in order.
CHAIN_ARGS='install:pkg list verify remove:pkg list'
# The colon-separated form encodes "subcmd:posarg" so `install pkg`
# and `remove pkg` fit alongside the argless `list` / `verify` /
# trailing `list`. Split at expansion.

# Read expected blocks -- awk-like walk in pure sh.
i=0
cell=
exp_exit=
exp_stderr0=

# Read blocks separated by "---".
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '#'*) continue ;;
        '') continue ;;
        'cell='*)   cell=${line#cell=} ;;
        'exit='*)   exp_exit=${line#exit=} ;;
        'stderr[0]='*) exp_stderr0=${line#stderr\[0\]=} ;;
        '---')
            # Emit cell.
            i=$((i + 1))
            # Select ith arg-encoding from CHAIN_ARGS.
            j=0
            for spec in $CHAIN_ARGS; do
                j=$((j + 1))
                if [ "$j" = "$i" ]; then
                    subcmd=$(printf '%s' "$spec" | cut -d: -f1)
                    posarg=$(printf '%s' "$spec" | cut -d: -sf2)
                    if [ -n "$posarg" ]; then
                        run_cell "$cell" "$exp_exit" "$exp_stderr0" "$subcmd" "$posarg"
                    else
                        run_cell "$cell" "$exp_exit" "$exp_stderr0" "$subcmd"
                    fi
                    break
                fi
            done
            cell=; exp_exit=; exp_stderr0=
            ;;
    esac
done < "$EXPECTED_FILE"

# Trailing cell (no final "---").
if [ -n "$cell" ]; then
    i=$((i + 1))
    j=0
    for spec in $CHAIN_ARGS; do
        j=$((j + 1))
        if [ "$j" = "$i" ]; then
            subcmd=$(printf '%s' "$spec" | cut -d: -f1)
            posarg=$(printf '%s' "$spec" | cut -d: -sf2)
            if [ -n "$posarg" ]; then
                run_cell "$cell" "$exp_exit" "$exp_stderr0" "$subcmd" "$posarg"
            else
                run_cell "$cell" "$exp_exit" "$exp_stderr0" "$subcmd"
            fi
            break
        fi
    done
fi

if [ "$FAIL_COUNT" = "0" ]; then
    printf 'M4-003: full chain passed (%d cells)\n' "$i"
    exit 0
fi

if [ "$FAIL_COUNT" -gt 127 ]; then
    FAIL_COUNT=127
fi
exit "$FAIL_COUNT"
