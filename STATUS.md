# pkg — status

**Wave:** R49 (Wave 1)
**Current milestone:** M4 (tests + smoke) — CLOSED. Ready for M5
(dual-signed pkg v1.0 release + `pkgs.paideia-os` mirror push +
`.pdxdoc` for `doc pkg`).

## Milestone rollup

| ID     | Title                                                          | State  | Issue |
|--------|----------------------------------------------------------------|--------|-------|
| M1-001 | scaffold paideia-as manifest + caps.decl                       | LANDED | #1    |
| M1-002 | argv surface + first-runnable pkg list                         | LANDED | #2    |
| M1-003 | draft on-disk package manifest format                          | LANDED | #3    |
| M2-001 | KIND_PACKAGE_MANIFEST = 0x193 + mint helper                    | LANDED | #4    |
| M2-002 | KIND_PACKAGE_REPO = 0x192 + fetch-rights narrowing             | LANDED | #5    |
| M2-003 | pkg_install body: fetch → verify → txn → rename                | LANDED | #6    |
| M2-004 | pkg_remove body: reverse-symlink undo + trash entry            | LANDED | #7    |
| M2-005 | self-install bootstrap                                         | LANDED | #8    |
| M3-001 | semantic-pipe: PackageManifest[] schema bind + emit on pkg list | LANDED | #9    |
| M3-002 | semantic-pipe: InstallProgressRecord[] per install stage       | LANDED | #10   |
| M3-003 | libpdx-audit: pre-output journal on every subcommand           | LANDED | #11   |
| M3-004 | libpdx-elevate: KIND_PDXFS_FILE(write,/pkgs) 60s window        | LANDED | #12   |
| M4-001 | sig-mismatch matrix (author bad, root bad, both bad -- all refuse) | LANDED | #13   |
| M4-002 | partial-install rollback via KIND_PDXFS_TXN abort              | LANDED | #14   |
| M4-003 | QEMU smoke: install -> list -> verify -> remove -> verify absent | LANDED | #15   |

See `design/tooling/r49-r50-plan.md` §5.1 in paideia-os for the full
breakdown (M1-M5) and cross-repo dependencies.

## M2 seams (two, both intentionally halting the install)

1. **Crypto seam** — `ManifestCodec::mc_verify_body_hash` and
   `mc_verify_signatures` return `MC_HASH_STUB` (0xFFFFEB70) /
   `MC_VERIFY_STUB` (0xFFFFEB71). Blocked on paideia-as v0.33-crypto-kdf
   (Argon2id-KDF, ChaCha20-Poly1305 AEAD, ML-DSA-65 verify). Wire-through
   at M3 replaces the STUB bodies with paideia-as intrinsic calls;
   nothing else moves.
2. **TXN seam** — `TxnClient::txn_open` / `txn_commit` / `txn_abort`
   return `TXN_STUB` (0xFFFFEA80). Blocked on `R42-PREP-007
   KIND_PDXFS_TXN write-side ops` (softarch to file against paideia-os
   as part of the R49-substrate milestone).

`pkg install` at M2 refuses at the crypto seam with EXIT_OP_FAIL and a
diagnostic naming the missing intrinsic. `pkg remove` refuses at the
lookup seam (no readdir on `KIND_PDXFS_FILE` at paideia-os HEAD) with
the same discipline. Silent-skip on either seam would violate D4
(dual-signed install pillar) and I5 (undo record obligatory).

## New source layout at M3 close

```
src/
  print.pdx                    -- sys_write helper (M1)
  audit_wire.pdx               -- libpdx-audit wire helper (M3-003)
  pipe_schemas.pdx             -- libpdx-semantic-pipe schema bind/emit (M3-001/M3-002)
  pkg_elevate.pdx              -- libpdx-elevate wrapper for /pkgs write (M3-004)
  kind_package_manifest.pdx    -- KIND_PACKAGE_MANIFEST 0x193 (M2-001)
  kind_package_repo.pdx        -- KIND_PACKAGE_REPO     0x192 (M2-002)
  manifest_codec.pdx           -- manifest.pdxsig decoder + verify seams (M2-003)
  txn_client.pdx               -- KIND_PDXFS_TXN userspace wrappers (M3 real syscall)
  install.pdx                  -- pkg install <name> body (M2-003 + M3-002/003/004)
  remove.pdx                   -- pkg remove <name> body + undo (M2-004 + M3-003)
  subcommands_m1_stubs.pdx     -- verify + keys stubs (M3-003 audit)
  list.pdx                     -- pkg list body (M1 + M3-001 schema + M3-003 audit)
  dispatch.pdx                 -- routes install/remove to real bodies
  main.pdx                     -- pkg_main entry
design/
  architecture.md              -- pkg internal shape
  argv-surface.md              -- pkg CLI grammar
  manifest-format.md           -- on-disk pdxsig byte layout
  install-flow.md              -- M2-003 install pipeline + seams
  remove-flow.md               -- M2-004 remove pipeline + pdxundo
  self-install-bootstrap.md    -- M2-005 bootstrap chain
bootstrap/
  self-install.pds             -- ten-step bootstrap script (shell.M2)
  self-install.sh              -- POSIX-sh translation (pre-shell)
```

## Cross-repo state at M2 close

- **libpdx-cap M2** landed (commits d9f0784, 965e526, 9a0eef3) --
  `cap_manifest_verify`, `cap_pack_narrowed`, `cap_unpack_checked`
  usable.
- **libpdx-semantic-pipe M2** landed (907cd43, 06f5dc3, eb6a7bc) --
  `send_record`, `recv_record`, `pipe_forward` usable. Consumed at
  M3-001 (schema bind for `PackageManifest[]` etc.).
- **libpdx-argv M2** landed (30a0902, 0b79d76, 4a9587c) -- typed flags
  + I3 vocab usable. Consumed at M2-003/M2-004 (pos_ptrs[1]).
- **libpdx-audit M2** landed (d0c5c8d, 29c68d2, 0423d77) -- `audit_begin`,
  `audit_record_output`, `audit_commit` usable. Consumed at M3-003.
- **libpdx-elevate M2** landed (9dc708d, c56d01c, 4ae682f) -- elevate
  client usable (cap-narrow stubbed). Consumed at M3-004.
- **paideia-os** R48 substrate closed: `KIND_USER = 0x190`,
  `KIND_ELEVATE_CHANNEL = 0x191`, `KIND_PDXFS_FILE = 0x195`,
  `KIND_PDXFS_TXN = 0x196` (commits 411ad0e, e56a95b, 2ff76d4).

## M3 close status

- **R42-PREP-007** — LANDED at paideia-os (syscall #70 sys_pdxfs_txn_
  open + PXT_OP_COMMIT/ABORT). TxnClient wire-through complete.
- **libpdx-audit AuditWire** — wired for every subcommand
  (list/install/remove/verify/keys); pre-output audit_begin + post-
  emit audit_commit; broker-unavailable refuses with EXIT=3 per I5.
- **libpdx-semantic-pipe PipeSchemas** — PackageManifest[] bound + one
  demo record emitted on `pkg list`; InstallProgressRecord[] bound + one
  record per stage (HEADER/HASH/VERIFY/MINT/TXN_OPEN/COMMIT) on
  `pkg install`. Schema hashes are stable placeholder identifiers
  (`pdxsig.pkg.pmf.v1` / `pdxsig.pkg.ipr.v1`) until M4 regenerates
  BLAKE3s from the schema-definition files.
- **libpdx-elevate PkgElevate** — request path wired for
  KIND_PDXFS_FILE(write,/pkgs) with a 60s window. At M3 the paideia-os
  elevate broker is not registered (paideia-os R48-PREP-005) so
  elevate_client_request returns ELVC_ERR_LOOKUP_FAIL; pkg surfaces
  this as parent_slot=0, txn_open refuses with PXT_MINT_BAD_PARENT, and
  pi_err_parent renders the diagnostic. Path is shape-complete for M4.

## M4 close status

M4 landed scaffolding (tests + smoke drivers) that assert the
observable surface (exit code + first stderr line) against pinned
expected files. Because upstream substrate gates still refuse (see
below), every M4 cell today asserts a REFUSAL. The `expected/*.txt`
files diff-flip per substrate step; the driver scripts and
fixtures are unchanged across each uplift.

- **M4-001** (issue #13) -- three-cell sig-mismatch fixture matrix
  under `tests/m4-001-sig-mismatch/` with deterministic generator
  (`gen-fixtures.sh`) + driver (`run.sh`) + pinned expected files.
- **M4-002** (issue #14) -- partial-install rollback shape driver
  under `tests/m4-002-partial-rollback/`. Branch A (nothing to roll
  back) cell reachable at M4-close; Branches B and C documented
  for M5 uplift.
- **M4-003** (issue #15) -- QEMU smoke chain (install -> list ->
  verify -> remove -> list) driver + `.pds` mirror + pinned five-
  cell transcript under `tests/m4-003-qemu-smoke/`.
- **`design/test-matrix.md`** -- M4 test taxonomy design doc
  documenting every cell + expected outcome at each substrate
  state (M4, post-wire-in, M5).

## Substrate gates still blocking full-green M4 (upstream)

Filed against paideia-os / paideia-as. Each gate's exit path is
pinned in the M4 expected files; when the gate closes, the pin
diff-flips.

- **paideia-as v0.33-crypto-kdf** -- Argon2id-KDF + ChaCha20-Poly1305 +
  ML-DSA-65 verify intrinsics. Blocks M4-001 discrimination between
  author-bad / root-bad / both-bad cells (all halt at seam today).
- **paideia-os R48-PREP-005** -- svc.elevate-broker registration +
  auto-approve policy table wiring for KIND_ELEVATE_CHANNEL. Blocks
  M4-002 Branches B and C and M4-003 install step exit 0.
- **paideia-os KIND_PDXFS_FILE staging read** -- reads a fixture
  .pdxsig into `_install_staging` so `mc_read_header` observes
  fixture bytes instead of zero-init .bss. Blocks the M4-001 fixture
  wire-in; every cell hits pi_err_header until this closes.
- **`/system/packages/` readdir** -- either an extension on
  `KIND_PDXFS_FILE` or a text `index.pdxlist` that pkg_install
  maintains. Blocks M4-003 remove step exit 0 and `pkg list --
  available` full enumeration.

## M5 (next milestone)

Per `design/tooling/r49-r50-plan.md` §5.1 M5 line: dual-signed
`manifest.pdxsig` for pkg v1.0, CHANGELOG-1.0 entry, `pkgs.paideia-
os` mirror push, `pkg keys` documentation of the paideia_root_pk
fingerprint, `.pdxdoc` file for `doc pkg`. Depends on paideia-as
v0.33-crypto-kdf (author + root signing) + doc.M2 reachable.
