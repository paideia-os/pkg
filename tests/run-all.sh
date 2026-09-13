#!/bin/sh
# tests/run-all.sh -- pkg.ENH-009 (#34, Wave Z)
#
# Walks every test cell under tests/*/ and runs it against either the
# host-native build-out/pkg binary (RUN_MODE=host, default) or a live
# paideia-os QEMU boot (RUN_MODE=qemu). The two modes exist because
# every cell under tests/ asserts a REFUSAL -- each pipeline halts at
# a substrate seam before any interesting syscall issues, so host exec
# and kernel exec produce byte-identical transcripts up through Wave
# Z. When the first substrate gate closes (paideia-as v0.33-crypto-kdf,
# paideia-os R48-PREP-005, or R42-PREP-007 for the txn substrate) the
# first cell that reaches the freshly-live syscall will diverge; the
# QEMU mode makes that divergence visible instead of masking it.
#
# The QEMU mode is intentionally NOT wired to a live smoke image at
# Wave-Z close -- it requires the companion monorepo work
# (paideia-os tools/run-smoke.sh uplift + image seeding) that
# ENH-009's issue body flags as separate. Until that lands,
# RUN_MODE=qemu refuses fast with a clear diagnostic naming the
# gate, so an operator running `sh tests/run-all.sh` knows the
# suite has NOT been through a kernel and does not fabricate green.
#
# Env vars:
#   RUN_MODE      host | qemu                 (default: host)
#   PKG_BINARY    path to build-out/pkg       (default: build-out/pkg)
#   PDX_STAGING   staging dir                 (default: /tmp/pkg-staging)
#   PDX_SMOKE_SH  paideia-os tools/run-smoke.sh (required for RUN_MODE=qemu)
#
# Exit codes:
#   0   every cell PASSed in the requested mode
#   1   one or more cells FAILed
#   2   usage error (unknown RUN_MODE, missing driver, missing smoke.sh)
#   3   RUN_MODE=qemu requested but the paideia-os QEMU wire-in is not
#       yet available (companion monorepo work; see ENH-009 issue body)

set -eu

: ${RUN_MODE:=host}
: ${PKG_BINARY:=build-out/pkg}
: ${PDX_STAGING:=/tmp/pkg-staging}

HERE=$(dirname "$0")
FAIL_COUNT=0
PASS_COUNT=0

case "$RUN_MODE" in
    host|qemu) ;;
    *)
        printf 'run-all: unknown RUN_MODE %s (host|qemu)\n' "$RUN_MODE" >&2
        exit 2
        ;;
esac

# ---- QEMU mode gate ------------------------------------------------
# ENH-009 (#34) landed this scaffold at Wave-Z close. The kernel-side
# wire-in (paideia-os tools/run-smoke.sh calling into these cells with
# PKG_BINARY resolved to an in-boot path) is filed against the
# monorepo. Until it lands, refuse fast rather than pretend the host
# run counts as a kernel run. This is exactly the honesty the issue
# body asks for.
if [ "$RUN_MODE" = "qemu" ]; then
    if [ -z "${PDX_SMOKE_SH:-}" ]; then
        printf 'run-all: RUN_MODE=qemu needs PDX_SMOKE_SH pointing at\n' >&2
        printf '         paideia-os/tools/run-smoke.sh (companion\n' >&2
        printf '         monorepo work; ENH-009 issue body §"Deps")\n' >&2
        exit 3
    fi
    if [ ! -x "$PDX_SMOKE_SH" ]; then
        printf 'run-all: PDX_SMOKE_SH=%s is not executable\n' "$PDX_SMOKE_SH" >&2
        exit 2
    fi
    # Delegate to the paideia-os smoke driver, which sets up the
    # kernel, seeds the /pkgs subtree, and re-invokes THIS script
    # in host mode with PKG_BINARY pointing at the in-boot binary.
    # The driver contract is defined in the paideia-os monorepo,
    # not here.
    exec "$PDX_SMOKE_SH" --tool pkg --cells "$HERE"
fi

# ---- Host mode -----------------------------------------------------
printf 'run-all: mode=host PKG_BINARY=%s\n' "$PKG_BINARY"

if [ ! -x "$PKG_BINARY" ]; then
    printf 'run-all: PKG_BINARY=%s is not executable (did you run\n' "$PKG_BINARY" >&2
    printf '         `paideia-as build` at the repo root?)\n' >&2
    exit 2
fi

mkdir -p "$PDX_STAGING"

# Discover cells: every immediate subdirectory of tests/ that contains
# an executable driver script. Two driver names are recognised:
#   run.sh   -- generic driver (m4-001, m4-002)
#   smoke.sh -- QEMU-smoke driver (m4-003)
# The choice is per-cell; the runner does not distinguish beyond
# picking whichever file is present.
for cell_dir in "$HERE"/*/; do
    cell=$(basename "$cell_dir")
    [ "$cell" = "*" ] && continue           # empty glob

    driver=
    for cand in run.sh smoke.sh; do
        if [ -x "$cell_dir/$cand" ]; then
            driver="$cell_dir/$cand"
            break
        fi
    done

    if [ -z "$driver" ]; then
        printf 'SKIP: %s (no run.sh or smoke.sh)\n' "$cell"
        continue
    fi

    printf '---- %s ----\n' "$cell"
    set +e
    PKG_BINARY="$PKG_BINARY" PDX_STAGING="$PDX_STAGING" "$driver"
    rc=$?
    set -e
    if [ "$rc" = "0" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS: %s\n' "$cell"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL: %s (driver rc=%s)\n' "$cell" "$rc"
    fi
done

printf '\n== run-all summary (RUN_MODE=%s) ==\n' "$RUN_MODE"
printf '  passed: %d\n' "$PASS_COUNT"
printf '  failed: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
