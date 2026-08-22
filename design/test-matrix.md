# pkg — M4 test matrix

**Wave:** R49  Milestone: M4  Issues: #13 (M4-001), #14 (M4-002), #15 (M4-003)
**Upstream:** [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 M4 line ("Bootstrap test (install pkg via pkg from a from-source
build), sig-mismatch rejection tests (author sig bad, root sig bad,
both bad), quota-exceeded refusal, elevate-timeout retry, partial-
install rollback via TXN abort. QEMU smoke matrix: install → list →
verify → remove → verify absent.").

## 0. Reading order

- §1 — the shape M4 lands and the shape M4 cannot land yet (substrate
  gates carried in from M3-close).
- §2 — the sig-mismatch matrix (#13) — cells, fixtures, expected
  outcomes at each substrate state.
- §3 — the partial-install rollback matrix (#14) — the three rollback
  branches (elevate-refuse / mint-succeed-then-fail /
  txn-open-succeed-then-fail) and what M4 asserts vs defers.
- §4 — the QEMU smoke matrix (#15) — the install → list → verify →
  remove → verify-absent chain and per-subcommand expected exit
  codes at M4 vs at full substrate.
- §5 — driver conventions (how the scripts under `tests/` invoke
  pkg, capture output, and diff against `expected/`).
- §6 — substrate gates the matrix is currently blind to, filed
  against paideia-os / paideia-as.
- §7 — what M5 upgrades once the substrate closes.

## 1. What M4 can and cannot land

M4 is the "tests + smoke" milestone per the plan doc §5.1. The tests
land against pkg's **observable surface** — exit code, stderr text,
and the `install_step` / `remove_step` .bss slots the M3-003 audit
records surface. Because the M3 seams still refuse pending upstream
substrate (see §6), M4 asserts the **halt point** and the **rollback
shape**, not a successful install.

**In scope at M4:**

- Fixture generation for the three sig-mismatch cells (author bad,
  root bad, both bad) with well-formed headers so the parser
  reaches the verify seam.
- Driver scripts (POSIX-sh) that invoke pkg against each fixture,
  capture (exit, stderr), and diff against the pinned expected
  outcome — one file per cell under `expected/`.
- Rollback-shape assertions: the three cleanup branches in
  `pkg_install_body`'s `pi_epilogue` are exercised via the exit
  paths reachable at M3 substrate (`pi_err_parent` /
  `pi_err_header` / `pi_err_verify`), and the invariants (txn
  never opened when parent-slot is 0, no dangling PMF row, exit == 1)
  are asserted against the diagnostic text.
- A QEMU smoke chain that runs every subcommand in sequence
  (`install → list → verify → remove → list`) and diffs the
  concatenated (exit, stderr) transcript against a pinned
  `expected/full-matrix.txt`.

**Out of scope at M4 (deferred to M5-prep):**

- A successful install (blocked on paideia-as v0.33-crypto-kdf and
  paideia-os R48-PREP-005 elevate broker; see §6).
- Real `ml_dsa_65_verify` differentiation between the three
  sig-mismatch cells (they all halt at `MC_VERIFY_STUB` today; M5
  distinguishes `MC_ERR_AUTHOR_SIG` from `MC_ERR_ROOT_SIG`).
- Post-txn-open abort path (blocked on the elevate broker; the txn
  never opens today because the parent slot is refused).
- Quota-exceeded refusal (blocked on `KIND_USER::quota_bytes` tail
  enforcement in the kernel — see paideia-os R48.M1 §quota).
- Elevate-timeout retry (blocked on the elevate broker replying
  at all).

## 2. Sig-mismatch matrix (#13)

Three fixture manifests are generated at `tests/m4-001-sig-mismatch/
fixtures/` by `gen-fixtures.sh`. All three carry a well-formed 64B
header (magic, version=1, flags=0, body_len<=1MiB, sigblock_len
matching an ML-DSA-65 pair) so `mc_read_header` returns `MC_OK` and
the pipeline reaches `mc_verify_signatures`. The **only** difference
between the three fixtures is which of the two signatures is
corrupted (a single-byte flip in the sigblock area).

### 2.1 Matrix cells

| Cell        | Fixture path                          | Author sig | Root sig | M4 outcome            | Post-wire-in outcome         | M5 outcome           |
|-------------|---------------------------------------|------------|----------|----------------------|-----------------------------|---------------------|
| author-bad  | `fixtures/pkg-author-bad.pdxsig`      | corrupted  | valid    | halt at HEADER (STUB) | halt at VERIFY (STUB)       | `MC_ERR_AUTHOR_SIG` |
| root-bad    | `fixtures/pkg-root-bad.pdxsig`        | valid      | corrupted| halt at HEADER (STUB) | halt at VERIFY (STUB)       | `MC_ERR_ROOT_SIG`   |
| both-bad    | `fixtures/pkg-both-bad.pdxsig`        | corrupted  | corrupted| halt at HEADER (STUB) | halt at VERIFY (STUB)       | `MC_ERR_AUTHOR_SIG` (first-fail) |

At M4 all three cells refuse with **the same** diagnostic
(`INSTALL_ERR_HEADER`: "pkg install: header parse failed (see errno)")
because `_install_staging` is zero-init `.bss` and `mc_read_header`
refuses at the magic check -- the fixture is staged at
`$PDX_STAGING/pkg.pdxsig` but pkg does not yet read it. When the
substrate uplift lands (`KIND_PDXFS_FILE` read into `_install_staging`,
per `design/install-flow.md` §5), all three cells advance to
`INSTALL_ERR_VERIFY` (still `MC_VERIFY_STUB`, still identical across
the three cells). When paideia-as v0.33-crypto-kdf lands after that,
the intrinsic distinguishes: `author-bad` -> `MC_ERR_AUTHOR_SIG`,
`root-bad` -> `MC_ERR_ROOT_SIG`, `both-bad` -> `MC_ERR_AUTHOR_SIG`
(first-fail). The same fixtures walk unchanged across all three
uplift steps; only the `expected/*.txt` files diff-flip per step.

The test proves "all three refuse" -- the load-bearing assertion for
D4 (dual-signed pillar). Discrimination between author-only vs
root-only vs both-bad is a **format-verifier** property that
becomes testable at M5.

### 2.2 Fixture generation

`gen-fixtures.sh` (POSIX-sh) writes each fixture from a base
manifest. Since paideia-as v0.33-crypto-kdf is not on the toolchain,
the base manifest carries a placeholder sigblock (two 3293-byte NUL-
padded blocks with a nonzero first-byte so `sigblock_len` parses).
The three cells then flip one distinct byte:

- `author-bad`: flip byte at `header_len + body_len + 4 + 100`
  (100 bytes into the author sig; well inside the ML-DSA-65 sig).
- `root-bad`: flip byte at `header_len + body_len + 4 + sig_len_author
  + 4 + 100` (100 bytes into the root sig).
- `both-bad`: apply both flips.

The flip is deterministic (XOR with `0x5A`) so the fixtures are
reproducible byte-for-byte from the base manifest, and the diff
against the base is diagnosable by inspection.

### 2.3 Expected-outcome files

Under `tests/m4-001-sig-mismatch/expected/` — one plaintext file per
cell holding the (exit, stderr-signature) pair the driver asserts.
The stderr-signature is the first line of stderr (which uniquely
identifies the halt point via the M2 diagnostic vocabulary at
`src/install.pdx`). Diff-based assertion (line-exact) keeps false-
positives from unrelated output (progress diagnostics on stdout are
NOT part of the assertion — they belong to the semantic-pipe
integration test, not the sig-mismatch matrix).

```
exit=1
stderr[0]=pkg install: sig verify unavailable (paideia-as v0.33-crypto-kdf required)
```

## 3. Partial-install rollback matrix (#14)

`pkg_install_body`'s `pi_epilogue` implements three cleanup branches
depending on how far the install got:

- **Branch A — nothing to roll back.** Install refused before minting
  a PMF row or opening a TXN. The epilogue is a plain return (r15
  carries the exit code).
- **Branch B — PMF row minted but no TXN.** Install refused between
  `pmf_cap_mint_inner` (step MINT) and `txn_open` (step TXN_OPEN).
  Epilogue calls `pmf_cap_revoke(r13)`; PMF stats gain one REVOKE.
- **Branch C — PMF row minted AND TXN opened.** Install refused after
  `txn_open` but before/during commit. Epilogue calls both
  `txn_abort(r14)` and `pmf_cap_revoke(r13)`.

### 3.1 Matrix cells

| Cell                       | Exit path in install.pdx     | Cleanup branch | M4 reachable? |
|----------------------------|------------------------------|----------------|---------------|
| header-refuse              | `pi_err_header`              | A              | yes           |
| hash-seam-refuse           | `pi_err_hash`                | A              | not today (verify seam fires first for the M4 fixture; noted for M5) |
| verify-seam-refuse         | `pi_err_verify`              | A              | yes (this is what the M4-001 fixtures hit) |
| mint-refuse                | `pi_err_mint`                | A              | not today (requires the verify seam to pass; noted for M5) |
| elevate-refuse             | `pi_err_parent`              | A (txn never opened, PMF minted at M5+ only) | yes |
| txn-open-refuse-non-parent | `pi_err_txn`                 | B (PMF row cleaned; TXN was never opened) | not today (elevate refuses first at M3-close) |
| commit-refuse              | `pi_err_txn` after txn_open  | C              | not today (blocked on elevate broker) |

### 3.2 What M4 asserts

The two cells reachable at M3-close substrate (header-refuse via a
corrupted-magic fixture, elevate-refuse via the M3-004 path with
broker unavailable) exercise **Branch A** in both cases. The
assertions are:

- **exit == 1** (`EXIT_OP_FAIL`).
- **stderr[0] identifies the failing step** via the M2 diagnostic
  vocabulary (INSTALL_ERR_HEADER / INSTALL_ERR_PARENT).
- **the install epilogue ran** (implied by the exit code — a crash
  would surface as exit 139 / signal 11 on POSIX, or as a
  paideia-os fault trap in QEMU).

Branches B and C are documented in `tests/m4-002-partial-rollback/
README.md` §3 as **expected-outcome** cells whose driver test lands
at M5 once the substrate closes. The test-matrix design leaves a
runnable slot for each so the M5 uplift is a one-file addition per
cell.

### 3.3 Why M4 does not open a txn today

The M3-004 elevate wrapper (`PkgElevate::pkg_elevate_request_pdxfs_
write_pkgs`) returns 0 (`PE_PARENT_UNAVAILABLE`) at M3 because the
paideia-os elevate broker is not registered (R48-PREP-005). The
zero parent slot then fails `PXT_MINT_BAD_PARENT` inside
`sys_pdxfs_txn_open` at kernel side; the install returns via
`pi_err_parent` with `install_txn_slot == 0xFFFF` (TXN_SLOT_NONE).
The M4 driver asserts the diagnostic line and the exit code; when
the broker lands, the same driver upgrades to assert
`install_txn_slot < 256` on the txn-open-success branch — a one-
line change in the driver, no fixture change.

## 4. QEMU smoke matrix (#15)

The smoke driver at `tests/m4-003-qemu-smoke/smoke.sh` runs pkg with
each of the five subcommands in the sequence the plan doc §5.1 M4
line names: `install → list → verify → remove → list` (the trailing
`list` is the "verify absent" step — a successful remove would leave
the package out of `pkg list`).

### 4.1 Subcommand cells

| Step | Subcommand           | M4 exit | M4 stderr[0] identifier                    | Full-substrate expected |
|------|----------------------|---------|--------------------------------------------|------------------------|
| 1    | `pkg install pkg`    | 1       | `pkg install: header parse failed (see errno)` | exit 0, `/pkgs/pkg-*/` populated |
| 2    | `pkg list`           | 0       | (none -- stdout carries the placeholder)   | exit 0, one line per installed pkg |
| 3    | `pkg verify`         | 3       | `pkg verify: body not implemented at M1 (lands at M2)` | exit 0, cross-verify against installed manifest |
| 4    | `pkg remove pkg`     | 1       | `pkg remove: /system/packages/ readdir unavailable at M2 (R42)` | exit 0, `/pkgs/pkg-*/` moved to trash |
| 5    | `pkg list`           | 0       | (none)                                      | exit 0, no `pkg` in the listing |

Step 1's M4 diagnostic reflects the same substrate gap the sig-
mismatch matrix hits: `_install_staging` is zero-init `.bss` and
`mc_read_header` refuses at the magic check. Step 4 hits the
`/system/packages/` readdir gap. Steps 2, 3, 5 are M4-close-clean:
`list` prints its M1 placeholder and exits 0; `verify` is still a
stub exiting 3; the trailing `list` re-prints the placeholder
(nothing installed).

The M4 assertion is that **every** row's (exit, stderr[0]) pair
matches the pinned `expected/full-matrix.txt`. A change to any
diagnostic string is a deliberate substrate advance and must
update the expected file in the same commit.

### 4.2 What the smoke does not test

- Real durability: no bytes reach `/pkgs/pkg-*/` today.
- Cross-boot survival: the smoke runs one QEMU boot; a "install
  then reboot then list" test lands with PdxFS v1 durability at
  paideia-os R42.M-close.
- Concurrent installs: pkg's install path is single-txn at M4;
  concurrent installs are a M5+ concern.

## 5. Driver conventions

Every driver script under `tests/m4-*/` follows the same shape so a
maintainer scanning three directories at once knows what to expect:

- **Language:** POSIX-sh (no bashisms). Mirror the discipline in
  `bootstrap/self-install.sh`.
- **Env vars:** the driver uses `PKG_BINARY` (default `./build-out/
  pkg`) so a QEMU-hosted run can point at `/bin/pkg` instead.
  Fixture staging uses `PDX_STAGING` (default `/tmp/pkg-staging`) —
  same as `self-install.sh`.
- **Assertion:** the driver captures `(exit, first-stderr-line)`
  and diffs against `expected/<cell>.txt`. On mismatch the driver
  writes a `FAIL: <cell> — expected <a>, got <b>` line to stderr
  and exits non-zero. On match, the driver writes `PASS: <cell>`
  and continues.
- **Exit code:** the driver exits `0` iff every cell passed;
  otherwise exits with the count of failed cells (capped at 127).
- **Reproducibility:** the driver takes no arguments; every input
  is env-var-derived or in-tree. A caller that wants to run one
  cell instead of the whole matrix uses a sh-level filter (grep
  before calling `sh run.sh`).

## 6. Substrate gates the matrix is blind to

Filed against paideia-os / paideia-as. Each gate blocks a specific
row of the matrix from being green today; the M4 landing documents
the gate so the M5 uplift is mechanical.

| Gate | Owner | Blocks | M4 workaround |
|------|-------|--------|---------------|
| paideia-as v0.33-crypto-kdf (ml_dsa_65_verify) | paideia-as | M4-001 cell discrimination; all three cells halt at seam today | fixtures land; expected files pin the STUB halt |
| paideia-os R48-PREP-005 elevate-broker registration | paideia-os | M4-002 Branches B and C; M4-003 install step 1 exit 0 | expected files pin `pi_err_parent` diagnostic |
| paideia-os KIND_PDXFS_FILE readdir | paideia-os | M4-003 remove step 4 exit 0; `pkg remove` cannot look up its target | expected file pins the M2 refusal diagnostic |
| paideia-os KIND_PDXFS_FILE staging read into `_install_staging` | paideia-os | M4-001 fixtures cannot yet exercise the parser end-to-end from a real .pdxsig file | fixtures generated in staging; driver documents the wire-through path |
| paideia-os R42 PdxFS v1 durability | paideia-os | Cross-boot smoke; installed bytes surviving a reboot | M4-003 runs one boot; multi-boot lands at R42 close |

## 7. What M5 upgrades

When the substrate closes:

- **M4-001:** the same three fixtures produce three **distinct**
  return codes (`MC_ERR_AUTHOR_SIG` / `MC_ERR_ROOT_SIG` /
  `MC_ERR_AUTHOR_SIG` first-fail). The `expected/` files diff-flip
  from `VERIFY_STUB` to the specific error; no fixture regen needed.
- **M4-002:** Branches B and C become reachable. Two new driver cells
  land in `tests/m4-002-partial-rollback/` — `run-branch-b.sh` and
  `run-branch-c.sh` — each with its own `expected/` file. The
  Branch A tests remain green unchanged.
- **M4-003:** every step of the chain flips to exit 0. The pinned
  `expected/full-matrix.txt` gets replaced with the successful-run
  transcript; the diagnostic strings that mark M4 substrate gates
  disappear from the expected output.

## 8. Cross-repo activation at M4 close

- `paideia-os` — the smoke matrix at `tests/m4-003-qemu-smoke/` will
  be wired into `tools/run-smoke.sh` as a `pkg-*` block per the
  memory index `feedback_paideia_os_no_cicd`. That wiring is a
  paideia-os PR, not a pkg PR, and lands as an M4-follow-up.
- `libpdx-audit` — the audit records the M4 driver reads to inspect
  the install-step slots come through the shared audit journal; a
  matching cell in `libpdx-audit`'s own M4 lands when the journal
  storage substrate closes.
- `doc` — the diagnostic strings the smoke asserts on are the
  operator-visible surface documented in `doc pkg`'s `.pdxdoc`.
  A change to a string here (M4 or M5) is a change to the
  `.pdxdoc` in the same commit.
