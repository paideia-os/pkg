# pkg — Changelog

All notable changes to this repo are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) with
per-milestone attribution.

## 1.3.0 — R70.M1-005 (2026-09-13, unreleased)

`pkg remove <name>` moves from an M2 shape that refused at a hardcoded
`jmp` to an end-to-end wired pipeline that fails closed at two named
upstream gaps. Full disposition record: `design/remove-flow.md` §8.

- `#22` R70.M1-005 — `pkg remove <name>`. The issue asked for a
  registry parse of `/var/pkg/installed.pdxpkg`, a `sys_unlink` loop,
  and an audit record of kind `UNINSTALL`. None of the three survive
  contact with the shipped substrate, and §8 records why:
  - `/var/pkg/installed.pdxpkg` was **retired** by ENH-001 §2.1 in
    favour of `/system/packages/index.pdxlist`; re-adding it would
    give pkg two disagreeing sources of truth with no reconciler.
    `remove_lookup_files` (new) names the index.
  - `sys_unlink` is ambient `/pkgs` write authority (D4) and
    non-transactional (I5): a failure at file *k* of *N* leaves a
    half-removed package no undo record covers. Replaced by
    `TxnClient::txn_unlink` (new) — `PXT_OP_UNLINK` inside the DELETE
    transaction — driven by `remove_unlink_all` (new).
  - Audit kind `UNINSTALL` **does not exist**; libpdx-audit keys on the
    `op_name` column, and pkg has emitted `TOOL_INVOKE`/`TOOL_EXIT`
    under `"remove"` since M3-003. What *was* missing: ENH-012 (#37)
    wired `audit_record_op_output` into install and list and skipped
    remove, leaving the one destructive subcommand with an empty
    `output_schema` column. Now fixed.
- New `pdxsig.pkg.rpr.v1` (`RemoveProgressRecord`) schema —
  `ps_bind_remove_progress` / `ps_emit_remove_progress` in
  `src/pipe_schemas.pdx`. Distinct from `InstallProgressRecord` so a
  supervisor filtering for destructive operations need not parse a
  payload field. One record per stage carrying that stage's real `rc`;
  the unlink stage carries the file count, so `files=<N>` is
  machine-readable, not just printed.
- `ur_write_header` gains its first caller, ordered **before** any
  deletion. `removed_ns` is an explicit `0` — pkg has no clock
  wrapper, and a fabricated timestamp in a durable undo record is
  worse than a zero a reader can recognise as unset.
- Success fingerprint `pkg remove: ok -- name='<name>' files=<N>` via
  `remove_print_u64` (new; the div-by-10 idiom from mount.pdxfs /
  mkfs.pdxfs).
- Two epilogue bug fixes on the same path:
  - `remove_txn_slot`'s "none" sentinel was `0`, which is a **valid**
    `txn_open` return — the `cmp r13, 0; je skip_abort` gate leaked an
    open transaction on every failure landing on cap_slot 0. Now
    `0xFFFF` with the `jae TXN_SLOT_CAP_MAX` range check `install.pdx`
    already used.
  - The abort fired even after a **successful** commit, driving the row
    `COMMITTED -> abort` and surfacing `PXT_BAD_TRANSITION` on every
    clean remove. Now gated on a non-zero exit code.
- Upstream ask (paideia-os, not pkg): a syscall binding for
  `pdxfs_txn_stage_unlink_name`. `PXT_OP_UNLINK` is real since
  R52.M6-003 (#1711) but its operands travel through a kernel-internal
  staging table with no user-facing entry point, so the op is
  unreachable. `txn_unlink` refuses rather than issuing a `cap_invoke`
  against an unstaged row — that would emit a dentry-delete for a NULL
  name under inode 0, a blind unlink.

Files: `src/remove.pdx`, `src/txn_client.pdx`, `src/pipe_schemas.pdx`,
`design/remove-flow.md`, `manifest.pdxproj`.

## 1.2.0 — Wave Z (2026-09-13, unreleased)

Round-closure drain of the R70 orphan chain plus the two open ENH
substrate-context items and the XREPO caps.decl adoption. No R49-M1..M5
code path shifts; every landing is skeleton, doc, or caps-boundary text.

- `#23` R70.M1-006 — `pkg upgrade <name>`: Wave-Z skeleton body
  (`src/upgrade.pdx`, new) + dispatch route (`src/dispatch.pdx` six-way
  first-byte switch, `USAGE_MSG` widened 51→59 bytes) + design record
  (`design/upgrade-flow.md`, new). The upgrade adopts a NOVEL shape
  over the R70 issue body's POSIX mkdir-tempdir + rename prescription:
  paideia-os' `KIND_PDXFS_TXN` in `TXN_MODE_REPLACE` covers the whole
  swap in one journal record, so the "atomic swap" is a kernel commit
  property rather than a userspace rename dance. Body refuses at
  `UPGR_STUB` with a diagnostic naming the four upstream gates
  (crypto-kdf, R48-PREP-005, R42-PREP-006, R42-PREP-007); audit-first
  via `audit_begin_op(OP_NAME_UPGRADE)` before every argv check.
  `src/audit_wire.pdx` grows `OP_NAME_UPGRADE`; `manifest.pdxproj`
  sources gain `src/upgrade.pdx`.
- `#25` R70.M1-008 — R70 round-closure retro (repo-local slice):
  `design/round-retrospectives/r70-pkg-closure.md` (new) records that
  R70 is closed as subsumed by the R49 M1-M5 chain (the ENH-001
  reconciliation, extended with the per-issue satisfier table). The
  `r70-closed` git tag is applied by main after the Wave-Z merge;
  softarch does not tag.
- `#34` ENH-009 — `tests/run-all.sh` (new) + `tests/README.md` +
  `design/test-matrix.md`. Two-mode runner: `RUN_MODE=host` (the M4
  status quo, the default) and `RUN_MODE=qemu` (delegates to
  `paideia-os/tools/run-smoke.sh`, refuses fast at Wave-Z close
  because the companion monorepo work is not yet wired). Reason for
  the two modes is documented up front: every cell asserts a refusal
  at a substrate seam, so host and kernel exec have been
  byte-identical through M5-close; the QEMU mode makes the first
  gate-close divergence visible instead of hiding it.
- `#35` ENH-010 — KIND_PACKAGE_MANIFEST advisory-status decision:
  `design/enh-010-advisory-status.md` (new) records the "documented
  advisory" disposition; module preambles in
  `src/kind_package_manifest.pdx` and `src/kind_package_repo.pdx`,
  the `README.md` `### Kind ordinals: advisory` subsection, the
  `doc/pkg.pdxdoc` `KIND ORDINALS` section, and the ENH-010 block in
  `design/architecture.md` all name plainly that the mint helpers
  issue no syscall and the state bytes are in-process booleans.
  Promotion to a kernel-side derived kind remains a paideia-os
  monorepo option per plan doc §5.1.
- `#39` R90-XREPO.013.M3-008 — caps.decl adoption for the XREPO wave:
  `caps.decl` elevate-broker binding section names both `/pkgs` and
  `/system/packages` write authority explicitly (on-demand per
  R90-XREPO.011), and `src/pkg_elevate.pdx` gains
  `PE_CAP_MASK_PDXFS_WRITE_SYSTEM_PACKAGES = 0x08` (non-adjacent to
  bit 0 so the older /pkgs-only mask remains a subset comparison).
  Constant is declared but not claimed at Wave-Z close; call site
  lands when the M3-001 index writer wires against readdir.

Version bump 1.1.0 → 1.2.0 per Wave-Z close. `PDX_TOOL_NAME` unchanged.

## 1.1.0 — Wave S (unreleased)

Enhancement-milestone drain over the open ENH backlog. Retires the
two remaining M1-era subcommand stubs (`verify`, `keys`), lands the
operator's pre-flight (`--dry-run`), tracks libpdx-elevate's promotion
of `elevate_client_acquire` as the sole supported entry point, and
pins the contract for local-filesystem-path installs so the fetch-
stage upgrade is a body-swap rather than a reshape.

- `#29` ENH-004 — `pkg verify <name>`: real body replacing the M1
  stub. Runs the ManifestCodec decode + dual-signature pipeline
  (header → body-hash → sig-verify) read-only; SEAM refusals
  (`MC_HASH_STUB`, `MC_VERIFY_STUB` pending paideia-as v0.33-crypto-kdf)
  surface as `EXIT_OP_FAIL` with an actionable diagnostic. `src/verify.pdx`
  (new), `src/dispatch.pdx` routing.
- `#30` ENH-005 — `pkg keys [list]`: real body replacing the M5-tagged
  stub. Positional check accepts bare `pkg keys` and `pkg keys list`;
  header + placeholder emission gated on the SEAM enumerator that
  wires against `/system/keys/` once paideia-os R42-PREP-008 lands.
  `src/keys.pdx` (new), `src/dispatch.pdx` routing, `caps.decl` +1
  read authority on `/system/keys/`.
- `#32` ENH-007 — `--dry-run` for install + remove. New shared
  `DryRun` module caches the flag from `ParsedArgs::flag_names[]`;
  install / remove bodies short-circuit past every mutating step
  (elevate, txn, mint, extract, commit) and emit
  `pkg <cmd>: --dry-run: would <cmd> '<name>' (no side effects)`.
  Audit ledger still records a matched INVOKE/EXIT pair with
  exit_code = 0. `src/dry_run.pdx` (new), `src/main.pdx` wiring,
  `src/install.pdx` + `src/remove.pdx` gates.
- `#38` ENH-013 — path-resolution contract for local filesystem-path
  repos. `design/local-filesystem-repos.md` pins how `pkg install
  /path/to/foo.pkg` and `pkg install ./foo.pkg` resolve (absolute
  vs relative, sidecar manifest derivation, elevate for local-read
  outside the ambient grants). Contract only — no `.pdx` code with
  this doc; fetch-stage upgrade lands once `sys_getcwd` (paideia-os
  R86) is in place.
- `#40` LE-001 — mechanical rename `elevate_client_request_norealize`
  → `elevate_client_acquire` (the interim `_norealize` symbol
  retired at libpdx-elevate 1.2). Same signature and semantics; pkg's
  fail-closed disposition on non-zero rc is unchanged.
  `src/pkg_elevate.pdx`, `src/install.pdx` comment,
  `manifest.pdxproj` dep bump `^1.0` → `^1.2`, `deps.list`.
- Retirement of `src/subcommands_m1_stubs.pdx` (dropped from
  `manifest.pdxproj` sources; the last two stubs it hosted were
  replaced by `#29` + `#30`).

Wave S closed against every ENH issue in scope for this session
(`#29`, `#30`, `#32`, `#38`, `#40`). ENH-006 (#31 `--help` /
`--version`), ENH-008 (#33 elevate coverage), ENH-011 (#36 static
`deps.list`) and ENH-012 (#37 `audit_record_op_output` call site)
were already landed in the 1.0.0 line; the enhancement-plan.md
issue-table is now fully drained modulo the paideia-os-owned
substrate gates (`#26`, `#34`, `#35`).

## 1.0.0 — 2026-08-22

The first signed release of pkg — the R49 wave package manager. Ships
the full M1-M5 milestone chain: repo scaffolding, argv surface,
package-manifest format, KIND_PACKAGE_MANIFEST + KIND_PACKAGE_REPO
allocations, install / remove / list / verify / keys subcommand
bodies, semantic-pipe schemas, audit-first journaling, elevate-broker
integration, sig-mismatch + rollback test matrix, QEMU smoke chain,
and the 1.0.0 release-artefact chain (`release/1.0/`, `CHANGELOG.md`,
`doc/pkg.pdxdoc`, `release/mirror-push.*`).

Upstream design authority:
[`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 in the paideia-os repo.

### M1 — repo + argv + format spec

- `#1` M1-001 — scaffold paideia-as manifest + `caps.decl` (KIND_USER +
  KIND_IPC_ENDPOINT baseline).
- `#2` M1-002 — argv surface: install, remove, list, verify, keys
  parsed via libpdx-argv; first-runnable `pkg list`.
- `#3` M1-003 — on-disk package manifest format spec
  (`design/manifest-format.md`, dual-signed envelope).

### M2 — happy-path core

- `#4` M2-001 — `KIND_PACKAGE_MANIFEST = 0x193` derived-kind alloc +
  mint helper.
- `#5` M2-002 — `KIND_PACKAGE_REPO = 0x192` derived-kind alloc +
  fetch-rights narrowing.
- `#6` M2-003 — `pkg_install` body: fetch → ml_dsa_65_verify ×2
  (SEAM) → KIND_PDXFS_TXN unpack (SEAM) → rename.
- `#7` M2-004 — `pkg_remove` body: reverse-symlink undo record +
  PdxFS trash-subtree entry.
- `#8` M2-005 — self-install bootstrap (`bootstrap/self-install.pds`
  + POSIX-sh mirror).

### M3 — semantic-pipe + audit + elevate

- `#9` M3-001 — semantic-pipe `PackageManifest[]` schema bind + emit
  on `pkg list`.
- `#10` M3-002 — semantic-pipe `InstallProgressRecord[]` per install
  stage (HEADER / HASH / VERIFY / MINT / TXN_OPEN / COMMIT).
- `#11` M3-003 — libpdx-audit pre-output journal on every subcommand.
- `#12` M3-004 — libpdx-elevate `KIND_PDXFS_FILE(write,/pkgs)` request
  with 60s window.

### M4 — tests + smoke

- `#13` M4-001 — sig-mismatch matrix (author bad, root bad, both bad —
  all refuse).
- `#14` M4-002 — partial-install rollback via KIND_PDXFS_TXN abort.
- `#15` M4-003 — QEMU smoke: install → list → verify → remove →
  verify absent.

### M5 — 1.0 signed release

- `#16` M5-001 — dual-signed `manifest.pdxsig` for pkg v1.0 +
  CHANGELOG entry; `release/1.0/` release-artefact chain landed
  (`gen-manifest.sh` + `manifest-layout.md` + `manifest-preview.hex`
  + `keys-fingerprints.md` + `README.md`); `manifest.pdxproj`
  version bumped `0.4.0-m4` → `1.0.0`.
- `#17` M5-002 — `pkgs.paideia-os` mirror-push protocol
  (`release/mirror-push.md` + `release/mirror-push.sh`); `.pdxdoc`
  file for `doc pkg` (`doc/pkg.pdxdoc`).

### Dependency snapshot

Version pins for a byte-reproducible 1.0.0 build:

- paideia-as ≥ 0.33 (module encoder + mov_b + @align + real
  paideia-as v0.33-crypto-kdf for real signatures — STUB at
  M5-close, diff-flip when the crypto substrate lands).
- paideia-os kernel ≥ R48-close (KIND_USER = 0x190,
  KIND_ELEVATE_CHANNEL = 0x191, KIND_PDXFS_FILE = 0x195,
  KIND_PDXFS_TXN = 0x196; syscall #70 sys_pdxfs_txn_open).
- libpdx-argv ≥ 0.1 (typed flag parse + I3 vocab).
- libpdx-cap ≥ 0.2 (cap_manifest_verify + cap_pack_narrowed).
- libpdx-semantic-pipe ≥ 0.2 (send_record, recv_record, pipe_forward).
- libpdx-audit ≥ 0.2 (audit_begin, audit_record_output, audit_commit).
- libpdx-elevate ≥ 0.2 (elevate_client_request).

### Known limitations (substrate gates open at M5-close)

Every gate below has an M4-close test-cell pinned against its
current refusal path; diff-flip when the gate closes.

- **paideia-as v0.33-crypto-kdf.** Argon2id-KDF + ChaCha20-Poly1305
  AEAD + ML-DSA-65 sign/verify intrinsics missing. `pkg install`
  refuses at `ManifestCodec::mc_verify_body_hash` / `mc_verify_
  signatures` seams (returns `MC_HASH_STUB` / `MC_VERIFY_STUB`);
  1.0.0 `release/1.0/manifest.pdxsig` ships with STUB fill for
  every key/sig/hash byte range.
- **paideia-os R48-PREP-005** (svc.elevate-broker registration +
  auto-approve policy table). `pkg install` at the elevate stage
  hits `ELVC_ERR_LOOKUP_FAIL`; the mint fails with
  `PXT_MINT_BAD_PARENT`.
- **paideia-os KIND_PDXFS_FILE staging read.** `pkg install` cannot
  read a fixture `.pdxsig` into `_install_staging`; every M4-001
  fixture cell halts at `pi_err_header`.
- **`/system/packages/` readdir.** `pkg list --available` cannot
  enumerate; the M3-001 schema emits one demo record instead of a
  live walk.

### Non-goals (deferred past 1.0)

- Compression in `pkg.tar` (out of scope until download volume is
  measured).
- Delta updates between versions.
- Transitive signature verification (`deps.list` signatures are
  verified when the dependency is itself installed).
- Compressed / hash-tree-indexed manifest files.
- GUI variant of pkg (D1 explicitly Tier-3-only).
