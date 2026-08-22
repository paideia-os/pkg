# pkg — status

**Wave:** R49 (Wave 1)
**Current milestone:** M2 (core implementation) — CLOSED. Ready for M3
(semantic-pipe / audit integration + libpdx-elevate wiring).

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

## New source layout at M2 close

```
src/
  print.pdx                    -- sys_write helper (M1)
  kind_package_manifest.pdx    -- KIND_PACKAGE_MANIFEST 0x193 (M2-001)
  kind_package_repo.pdx        -- KIND_PACKAGE_REPO     0x192 (M2-002)
  manifest_codec.pdx           -- manifest.pdxsig decoder + verify seams (M2-003)
  txn_client.pdx               -- KIND_PDXFS_TXN userspace wrappers (M2-003)
  install.pdx                  -- pkg install <name> body (M2-003)
  remove.pdx                   -- pkg remove <name> body + undo (M2-004)
  subcommands_m1_stubs.pdx     -- verify + keys stubs (M2 pruned)
  list.pdx                     -- pkg list body (M1; readdir upgrade at M3)
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

## M3 blockers

- **R42-PREP-007** (unfiled) — `sys_pdxfs_txn_open` + `PXT_OP_COMMIT`
  + `PXT_OP_ABORT` handler paths on top of the R48b `kind_pdxfs_txn.pdx`
  substrate. Softarch to file against paideia-os.
- **paideia-as v0.33-crypto-kdf** — Argon2id-KDF + ChaCha20-Poly1305 +
  ML-DSA-65 verify intrinsics. Blocks M3 verify wire-through.
- **`/system/packages/` readdir** — either an extension on
  `KIND_PDXFS_FILE` or a text `index.pdxlist` that pkg_install
  maintains. Blocks M3 `pkg list --available` + `pkg remove` lookup.
