# pkg — M4-003 QEMU smoke matrix

**Wave:** R49  Milestone: M4  Issue: #15 (pkg.M4-003)
**Upstream:** `design/tooling/r49-r50-plan.md` §5.1 M4 line ("QEMU
smoke matrix: install -> list -> verify -> remove -> verify absent")
in paideia-os. Local design at `design/test-matrix.md` §4.

## 1. Purpose

Prove that pkg's five subcommands wire correctly end-to-end in a
paideia-os QEMU boot: argv parse, dispatch, audit-begin, semantic-
pipe bind, subcommand body execution, and exit-code propagation.

The chain runs each subcommand in sequence:

```
pkg install pkg   -> exit 1 (halts at pi_err_header today)
pkg list           -> exit 0 (M1 placeholder line on stdout)
pkg verify         -> exit 3 (M1 stub -- lands at M2 follow-up)
pkg remove pkg    -> exit 1 (halts at UR_ERR_LOOKUP; readdir gap)
pkg list           -> exit 0 (placeholder, still)
```

The "verify absent" step in the plan is the trailing `pkg list` --
a successful `pkg remove` would leave `pkg` out of the listing. At
M4 the placeholder does not change between the two `list` calls
because neither install nor remove actually mutate `/pkgs/`; the
smoke asserts the exit-code + first-stderr-line pair, not the
stdout contents.

## 2. Files

- `smoke.sh` -- POSIX-sh driver, mirrors `bootstrap/self-install.sh`
  discipline.
- `smoke.pds` -- `.pds` equivalent (consumed by `shell` M2 once its
  `.pds` executor lands; kept in tree so a change to the sequence
  updates both scripts).
- `expected/full-matrix.txt` -- pinned five-cell transcript. Diff
  fails the smoke.

## 3. Wiring into paideia-os smoke

Per the memory index `feedback_paideia_os_no_cicd`, paideia-os has
no CI; verification is local-only via `tools/run-smoke.sh`. The M4-
follow-up patch to paideia-os adds a `pkg-*` block to that harness
that invokes `smoke.sh` here after each boot. That paideia-os PR is
NOT part of pkg's M4 landing (it lives in the paideia-os repo).

The pkg M4-close deliverable is:

1. `smoke.sh` runs cleanly against a `build-out/pkg` binary in the
   current shell.
2. `smoke.pds` mirrors the sh script byte-for-byte in intent.
3. `expected/full-matrix.txt` pins the M4-close observable.

## 4. Env vars

- `PKG_BINARY`  (default `build-out/pkg`)
- `PDX_STAGING` (default `/tmp/pkg-staging`)

## 5. Exit code

`smoke.sh` exits 0 iff every cell in the chain matches the pinned
expected transcript. On any mismatch it exits with the count of
failed cells (capped at 127) and prints per-cell diffs to stderr.

## 6. What the smoke does NOT test

- Cross-boot survival (blocked on PdxFS v1 durability at R42.M-close).
- Concurrent installs (single-txn substrate at M4).
- Real fetch (M3-004's elevate broker not registered at M4-close).
- Real `pkg keys list` (M5).
- Real doc integration via `doc pkg --help` (M5).

These cells are documented in `design/test-matrix.md` §7 as the M5+
uplift set.
