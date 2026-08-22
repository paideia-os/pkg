# pkg — M4-002 partial-install rollback

**Wave:** R49  Milestone: M4  Issue: #14 (pkg.M4-002)
**Upstream:** `design/tooling/r49-r50-plan.md` §5.1 M4 line ("partial-
install rollback via KIND_PDXFS_TXN abort") in paideia-os. Local
design at `design/test-matrix.md` §3.

## 1. Purpose

Prove that `pkg install` cleans up correctly when the install refuses
mid-pipeline. `pkg_install_body`'s `pi_epilogue` implements three
cleanup branches:

- **Branch A** -- nothing to roll back (install refused BEFORE mint
  and BEFORE `txn_open`).
- **Branch B** -- PMF row minted but txn never opened.
  `pmf_cap_revoke` runs; PMF stats gain one REVOKE.
- **Branch C** -- PMF row minted AND txn opened. Both `txn_abort`
  and `pmf_cap_revoke` run.

## 2. Cells reachable at M3-close

Branch A is reachable via the current substrate. Two failure sites
land there today:

- **header-refuse** -- `_install_staging` is zero-init `.bss` and
  `mc_read_header` refuses at the magic check. Exit path
  `pi_err_header`, exit 1, diagnostic `INSTALL_ERR_HEADER`.
- **elevate-refuse** -- would fire if header parse passed. At M3-
  close the header refuse fires first for the M4-001 fixtures; the
  elevate-refuse cell becomes reachable once the fixture wire-in
  lands. Kept here as an expected-outcome cell so the M5 uplift is
  additive.

## 3. Branches B and C at M4

Not reachable at M3-close:

- **Branch B** requires `mc_read_header` + `mc_verify_body_hash` +
  `mc_verify_signatures` + `pmf_cap_mint_inner` to all succeed
  before the `elevate -> txn_open` step refuses. All three verify
  seams return STUBs today; mint never runs. Blocked on paideia-as
  v0.33-crypto-kdf.
- **Branch C** requires elevate to grant a parent slot so `txn_open`
  can succeed, then a later step to refuse. Blocked on paideia-os
  R48-PREP-005 (elevate-broker registration).

The M4 landing pins the SHAPE (which cleanup branch fires per exit
path) in `design/test-matrix.md` §3.1 so the M5 uplift is one
driver file per new-reachable cell.

## 4. Driver

`run.sh` walks the reachable cells and asserts each with the
`(exit, stderr[0])` protocol from `design/test-matrix.md` §5.
Diffs against `expected/*.txt`.

## 5. What M4 cannot assert directly

The driver observes exit code + stderr. It does NOT read the PMF
row table (`_pmf_table` in `src/kind_package_manifest.pdx`) or the
txn slot lifecycle. Those slots become observable through the
audit journal at M5+ (a supervisor querying `/system/audit/user-
events/` sees the per-install `UEJ_KIND_TOOL_INVOKE` +
`UEJ_KIND_TOOL_OUTPUT` records that name the state transitions).
At M4 the epilogue's correctness is inferred from:

1. Exit code == 1 (the pipeline refused).
2. Stderr diagnostic names the failing step.
3. Absence of a crash (a botched abort would surface as a paideia-
   os fault trap).

The direct assertion on `_pmf_table` state lands with the
libpdx-audit journal-replay tool at libpdx-audit.M5.
