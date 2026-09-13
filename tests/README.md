# pkg — tests

The correctness matrix per `design/test-matrix.md` (in this repo) and
`design/tooling/r49-r50-plan.md` §5.1 M4 in
[paideia-os](https://github.com/paideia-os/paideia-os).

## Running the suite

Two modes at Wave-Z close (ENH-009 #34):

- `sh tests/run-all.sh` (default `RUN_MODE=host`) — walks every cell
  under `tests/*/`, invoking its `run.sh` or `smoke.sh` driver
  against the host-native `build-out/pkg` binary. Fast; equivalent to
  the M4 status quo. Exit 0 iff every cell PASSes.
- `RUN_MODE=qemu PDX_SMOKE_SH=/path/to/paideia-os/tools/run-smoke.sh
  sh tests/run-all.sh` — delegates to the paideia-os smoke driver,
  which boots a QEMU image, seeds `/pkgs`, and re-invokes the runner
  in host mode with `PKG_BINARY` pointed at the in-boot binary. **Not
  wired at Wave-Z close** — the companion monorepo work (image
  seeding + `run-smoke.sh` uplift) is the deferred slice of #34.
  Requesting `RUN_MODE=qemu` today refuses fast (exit 3) with a
  diagnostic naming the missing driver so an operator does not
  fabricate a "kernel-verified" transcript from a host-only run.

Reason for the two modes: every cell here asserts a **refusal**. Each
pipeline halts at a substrate seam before any interesting syscall
issues, so host exec and kernel exec produce byte-identical
transcripts through Wave Z. When the first substrate gate closes
(paideia-as v0.33-crypto-kdf, paideia-os R48-PREP-005, or
R42-PREP-007 for the txn substrate) the first cell reaching the newly
live syscall will diverge; the QEMU mode makes that divergence
visible instead of hiding it.

## Layout at M4 close

```
tests/
  m4-001-sig-mismatch/         issue #13 -- three-cell sig-mismatch matrix
    README.md                  matrix cells + driver conventions
    gen-fixtures.sh            deterministic fixture generator (POSIX-sh)
    run.sh                     driver -- walks cells, diffs vs expected/
    fixtures/                  generated .pdxsig files (not committed)
    expected/                  pinned (exit, stderr[0]) per cell
      author-bad.txt
      root-bad.txt
      both-bad.txt

  m4-002-partial-rollback/     issue #14 -- three cleanup branches
    README.md                  Branch A/B/C rationale + M4 vs M5 reach
    run.sh                     Branch A driver (header-refuse + elevate-refuse)
    expected/
      header-refuse.txt
      elevate-refuse.txt

  m4-003-qemu-smoke/           issue #15 -- install -> list -> verify -> remove -> list
    README.md                  smoke runbook + expected exit/diagnostic per subcommand
    smoke.sh                   POSIX-sh driver
    smoke.pds                  .pds equivalent (consumed by shell.M2)
    expected/
      full-matrix.txt          pinned per-subcommand (exit, stderr[0])
```

## Convention

Every driver script is POSIX-sh (no bashisms), takes no arguments,
reads its inputs from env vars (`PKG_BINARY`, `PDX_STAGING`), and
diffs against a pinned `expected/<cell>.txt`. On any mismatch the
driver writes a `FAIL: <cell> -- expected <a>, got <b>` line to
stderr and exits non-zero.

Same discipline as `bootstrap/self-install.sh` (M2-005). The scripts
here run outside QEMU today (against the `paideia-as build`-produced
binary in `build-out/pkg`) and inside a paideia-os QEMU boot at M4-
close (once the `pkg-*` cells wire into `tools/run-smoke.sh` in
paideia-os).

## Substrate gates (see `design/test-matrix.md` §6)

The matrix at M4 cannot exercise a successful install -- it asserts
the halt point + rollback shape. The gates blocking a green install
are documented per row of the test matrix.

## Running

```
sh tests/m4-001-sig-mismatch/gen-fixtures.sh
sh tests/m4-001-sig-mismatch/run.sh
sh tests/m4-002-partial-rollback/run.sh
sh tests/m4-003-qemu-smoke/smoke.sh
```

A wrapper `tests/run-all.sh` lands with the paideia-os `tools/run-
smoke.sh` uplift (an M4 follow-up in paideia-os, not in this repo).
