# pkg — Changelog

All notable changes to this repo are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) with
per-milestone attribution.

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
