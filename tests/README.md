# pkg — tests

The correctness matrix per `design/test-matrix.md` (in this repo) and
`design/tooling/r49-r50-plan.md` §5.1 M4 in
[paideia-os](https://github.com/paideia-os/paideia-os).

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
