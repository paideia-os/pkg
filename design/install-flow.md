# pkg — install flow (M2-003)

**Wave:** R49  Milestone: M2  Issue: #6 (pkg.M2-003)
**Upstream:** [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 M2 line; [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6 install model; local `design/manifest-format.md` §5 verification
algorithm.

## 1. Purpose

Freeze the sequence pkg follows when a user runs `pkg install <name>`.
M2 lands the full call graph with two documented seams; M3 fills the
seams; M4 fuzzes the parser; M5 signs the release.

## 2. Runtime pipeline

```
                pkg install <name>
                         |
                         v
    +--- ParsedArgs::pos_count == 2? ---+  no -> exit 2 (usage)
    | yes
    v
+--- pos_ptrs[1] non-NULL? ---+          no -> exit 2 (usage)
| yes
v
Step 1  install_reset + mc_reset
Step 2  progress diagnostic on stdout ("staging manifest for '<name>'")
Step 3  ManifestCodec::mc_read_header (64B header, 8 fields)
Step 4  ManifestCodec::mc_verify_body_hash (SEAM #1a -- sha3-256)
Step 5  ManifestCodec::mc_verify_signatures (SEAM #1b -- ml_dsa_65_verify x2)
Step 6  KindPackageManifest::pmf_cap_mint_inner (record author + root fpr halves)
Step 7  TxnClient::txn_open(TXN_MODE_CREATE) (SEAM #2a)
Step 8  extract pkg.tar (SEAM -- per-FILE_INVENTORY walk, deferred to M4)
Step 9  TxnClient::txn_commit (SEAM #2b)
        |
        v
     exit 0

  on any step failure:
    - if txn_slot valid: TxnClient::txn_abort  (best-effort)
    - if pmf_row valid:  KindPackageManifest::pmf_cap_revoke  (best-effort)
    - exit 1  (EXIT_OP_FAIL) with diagnostic naming the failed step
```

## 3. The two M2 seams

### 3.1 Crypto seam (paideia-as v0.33-crypto-kdf)

`ManifestCodec::mc_verify_body_hash` and `mc_verify_signatures` return
`MC_HASH_STUB` (0xFFFFEB70) / `MC_VERIFY_STUB` (0xFFFFEB71) at M2.

- Upstream dependency: paideia-as v0.33-crypto-kdf (Argon2id-KDF,
  ChaCha20-Poly1305, ML-DSA-65 verify), filed at paideia-as issues
  #1302..#1306 per memory index `project_paideia_as_bootstrap`.
- Wire-through: replace the STUB body with `mov rax, <intrinsic>;
  call <intrinsic>` (see paideia-as design/kernel/paideia-as-conformance.md
  for the intrinsic call convention).
- Test: fixture manifest.pdxsig (built with the v0.33 signer) exercises
  both intrinsics through the M4 sig-mismatch matrix (issue #10, filed
  in the M4 wave).

pkg's exit-code behaviour when the seam returns STUB: exit 1
(EXIT_OP_FAIL) with diagnostic `pkg install: body hash unavailable
(paideia-as v0.33-crypto-kdf required)` or `... sig verify unavailable
...`. **This is deliberate**: a "silent skip" would violate D4 (dual-
signed pillar) and I5 (audit-first). The exit-code + diagnostic pair
is what a caller matches on to know the substrate gate is still open.

### 3.2 TXN seam (R42-PREP-007)

`TxnClient::txn_open` / `txn_commit` / `txn_abort` return `TXN_STUB`
(0xFFFFEA80) at M2.

- Upstream dependency: an as-yet-unfiled paideia-os substrate-prep
  issue that lands `sys_pdxfs_txn_open` + `PXT_OP_COMMIT` +
  `PXT_OP_ABORT` handler paths on top of the R48b `kind_pdxfs_txn.pdx`
  substrate (read-side query ops already landed at commit `2ff76d4`).
- Softarch action: file `R42-PREP-007 KIND_PDXFS_TXN write-side ops
  (COMMIT/ABORT/OPEN via sys_pdxfs_txn_*)` against paideia-os as part
  of the R49-substrate milestone; block M3 wire-through on it.
- Wire-through: replace each STUB body with the `mov rsi, rdi; mov
  rdi, 4; mov rdx, <PXT_OP_*>; syscall` shape documented in the
  wrapper's justification.

Exit-code behaviour: `pkg install: KIND_PDXFS_TXN unavailable
(R42-PREP-007 required)`. Same D4/I5 discipline as the crypto seam.

## 4. Install-progress .bss slots

`PkgInstall` exposes five `.bss` slots the M4 test harness reads after
`pkg_install_body` returns:

| Slot                  | Meaning                                              |
|-----------------------|------------------------------------------------------|
| `install_name_ptr`    | pos_ptrs[1] (the package name pointer)               |
| `install_manifest_rc` | last `ManifestCodec::mc_*` return code               |
| `install_pmf_row`     | `KindPackageManifest` row id (0xFF if never minted)  |
| `install_txn_slot`    | `KIND_PDXFS_TXN` cap slot (0 if never opened)        |
| `install_step`        | last step index reached (0..7 per INSTALL_STEP_*)    |

The `install_step` slot is the primary M4 assertion: a test that pushes
an invalid manifest expects step == INSTALL_STEP_HEADER and
`install_manifest_rc` == the specific `MC_ERR_*` for the corruption.

## 5. Staging buffer

M2 reads the manifest bytes from a 4160-byte `.bss` staging buffer
(`PkgInstall::_install_staging`). The bootstrap script (M2-005) copies
the manifest into this buffer before `pkg install` runs.

M3 replaces this with a `KIND_PDXFS_FILE` read at the manifest path
`/system/packages/<name>/<version>/manifest.pdxsig`. The buffer stays
in tree for the M4 fuzz corpus loader.

## 6. Cleanup on failure

The epilogue always runs (single `jmp pi_epilogue` target). It:

1. If `install_txn_slot` looks live (non-zero, below the seam sentinel
   band) AND we bailed (r15 != 0), call `txn_abort` best-effort.
2. If `install_pmf_row` looks live (below `PMF_ROW_NONE`) AND we
   bailed, call `pmf_cap_revoke` best-effort.
3. Return `r15` as the exit code.

The "we bailed" gate matters: on success the txn is already committed
(step 9), so calling `txn_abort` after `txn_commit` would be a fault.

## 7. What M2 explicitly does not do

- **No fetch.** The manifest is expected pre-staged; `pkg install` does
  not touch the network at M2. M3-004 wires `libpdx-elevate` for the
  fetch-cap request; M4-003 exercises the elevate-timeout retry.
- **No per-file tar walk.** Step 8 is a no-op at M2. The one-file-per-
  FILE_INVENTORY-record walk lands at M4 alongside the fixture manifest.
- **No pre-output audit journal.** M3-003 wires `libpdx-audit`. Until
  then the diagnostics go straight to stderr via `Print::print_err`.
- **No elevate request.** M3-004 wires the `KIND_PDXFS_FILE(write,
  /pkgs)` + `KIND_NETWORK(fetch, pkgs.paideia-os)` +
  `KIND_SIGNATURE(verify, paideia_root_pk)` request for the 60s window.

## 8. Cross-repo dependencies activated by this milestone

- `libpdx-cap.M2` (`cap_manifest_verify` at exec time). Already
  landed as of 2026-08-21.
- `libpdx-argv.M2` (positional-argument list handling for
  `pos_ptrs[1]`). Already landed.
- `KindPdxfsFile` / `KindPdxfsTxn` (paideia-os `2ff76d4`). Read-side
  query ops present; write-side (R42-PREP-007) needed for M3.
- `KindPackageManifest` (this repo, M2-001). Landed.
- `KindPackageRepo` (this repo, M2-002). Landed.
