# pkg — upgrade flow

**Issue:** R70.M1-006 (#23)
**Wave:** Wave Z (design + skeleton body); the mutating half stays
STUB pending upstream substrate.
**Cross-refs:** `design/install-flow.md`, `design/remove-flow.md`,
`design/manifest-format.md`.

## 1. Position

`pkg upgrade <name>` installs a newer version of an already-installed
package and switches `/pkgs/<name>` to point at it, with the guarantee
that a crash at ANY point during the switch leaves the filesystem
either at the old version or at the new version — never at a partial
install and never at a version-mixed subtree.

The R70 issue body prescribed the POSIX-ish shape ("mkdir-tempdir +
rename"). Per the project's [novel + clean design bias]
(`feedback_novel_clean_design.md` in the user's memory), pkg does
**not** inherit that shape. paideia-os already ships the mechanism
that makes the swap atomic — `KIND_PDXFS_TXN` (`sys_pdxfs_txn_open`
#70, R42-PREP-007) — and the upgrade body composes it, so the
"atomic swap" is a property of a single kernel commit, not of a
userspace mkdir+rename dance.

## 2. Contrast with the POSIX pattern

The R70 body prescribed:

  1. mkdir /pkgs/<name>-<newver>.tmp
  2. extract into the tempdir
  3. rename(2) /pkgs/<name> -> /pkgs/<name>-<oldver>.bak
  4. rename(2) /pkgs/<name>-<newver>.tmp -> /pkgs/<name>
  5. rm -rf /pkgs/<name>-<oldver>.bak

Failure between steps 3 and 4 leaves `/pkgs/<name>` missing; a
concurrent reader between steps 2 and 4 sees stale content; step 5
can leak on crash. Every recovery is a userspace protocol on top of
the filesystem's mtime, and every reader has to know about the
recovery protocol. The whole shape is why `dpkg` and `rpm` accreted
decades of lockfile + journal + fsync bookkeeping.

The paideia-os shape:

  1. audit_begin_op(OP_NAME_UPGRADE, name_ptr)  — I5 audit-first.
  2. Locate the currently-installed manifest for `<name>` (via the
     M3-001 index; readdir gate applies).
  3. Read the *new* manifest.pdxsig (staging read; same gate as
     install).
  4. mc_read_header / mc_verify_body_hash / mc_verify_signatures
     (identical seams to install; SEAM until v0.33-crypto-kdf).
  5. pmf_cap_mint_inner for the NEW manifest row (advisory per
     ENH-010; see `design/enh-010-advisory-status.md`).
  6. elevate_client_acquire(WRITE_PKGS, 60s) — one 60s window
     covers the whole upgrade rather than one per version.
  7. txn_open(TXN_MODE_REPLACE, snap_gen, wal_off, target=
     /pkgs/<name>) — the txn *scope* IS the swap unit; the kernel
     records the old subtree's snap_gen as the pre-image so an
     abort or a crash reverts to it.
  8. Extract new pkg.tar into the txn scope (same per-file walk
     shape as install).
  9. txn_commit — a single kernel operation that BOTH promotes
     the extracted subtree to `/pkgs/<name>` AND reclaims the old
     subtree in one journal record. The kernel guarantees the
     linearisation point; no rename dance, no `.bak`, no cleanup.
  10. audit_commit_op with the from/to version pair.

Steps 5–9 also compose the rollback: any refusal drops back to
txn_abort (revert to the pre-image, kernel-side) + pmf_cap_revoke
(reclaim the .bss row).

## 3. What "upgrade" is NOT

- **Not a new pipeline.** Every seam is the install pipeline's seam,
  with one extra input (the old version's manifest, for the audit
  column). The install and upgrade bodies share `src/install.pdx`'s
  seam constants and the extract inner loop; only the txn open mode
  and the audit op-name differ.
- **Not delta-based.** The Wave-Z upgrade extracts the whole new
  subtree. Delta upgrades are in the 1.0.0 non-goals; they land
  behind their own cap on the fetch side.
- **Not multi-package.** `pkg upgrade <name>` upgrades one package;
  batch upgrades are a shell composition.

## 4. Wave-Z landing shape

`src/upgrade.pdx` at Wave Z ships:

- Module `PkgUpgrade = structure { ... }` with the diagnostic strings,
  the `upgrade_reset` helper, the `pkg_upgrade_body` entry.
- `pkg_upgrade_body`:
  1. audit_begin_op(OP_NAME_UPGRADE) — I5 first.
  2. pos_count == 2 check.
  3. Emit "pkg upgrade: <name>" progress line.
  4. Currently REFUSES at `UPGR_STUB` with EXIT_OP_FAIL and a
     diagnostic naming the four upstream gates (crypto-kdf,
     R48-PREP-005, KIND_PDXFS_FILE readdir, R42-PREP-007 txn
     REPLACE mode).
  5. audit_commit_op with the refusal exit code.
- `Dispatch::dispatch_subcommand` grows a sixth branch (`'u'`,
  distinct from the existing five first bytes). Six-way byte switch
  keeps the linear-cmp inline discipline; no strcmp.

The gate-close diff-flip replaces step 4 with the txn pipeline
described in §2. The dispatch, argv shape, audit and diagnostic
skeleton do not change at that point.

## 5. Version bookkeeping

The audit column at Wave Z carries the target NAME only (op_args =
name_ptr). Once the M3-001 index readdir gate closes, the OLD
version becomes readable from the currently-installed manifest and
the audit payload widens to a 16B `from_ver || to_ver` tuple —
tracked as a follow-up ENH, not landed here.

## 6. Test posture

`tests/m4-003-qemu-smoke/` already runs an `install -> list ->
verify -> remove -> list` chain. A future
`tests/rz-006-upgrade-refuse/` cell will pin the Wave-Z refusal
(`upgrade <n>` -> exit 1, stderr[0] = the UPGRADE_ERR_STUB
diagnostic). Wave Z does NOT land that cell — the pattern is
identical to `m4-001-sig-mismatch`'s expected-file discipline and is
best filed with a real Wave-AA issue.
