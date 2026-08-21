# pkg — status

**Wave:** R49 (Wave 1)
**Current milestone:** M1 (design + skeleton) — in progress

## Milestone map

- **M1 — design + skeleton (in progress).** Scaffold (caps.decl +
  build manifest — issue #1), argv surface with install / remove / list
  / verify / keys via libpdx-argv (issue #2), package manifest format
  design doc (issue #3). First-runnable shape: `pkg list` walks the
  full dispatch chain (parse → recognize → list body → print → exit)
  and produces a header + placeholder line on stdout via sys_write
  (paideia-os syscall #1 fast-path). Real /system/packages/ enumeration
  deferred to M2.
- **M2 — core implementation (not started).** KIND_PACKAGE_MANIFEST =
  0x193 and KIND_PACKAGE_REPO = 0x192 minted internally; pkg_install
  body (fetch → ml_dsa_65_verify ×2 → KIND_PDXFS_TXN unpack → atomic
  rename); pkg_remove body with reverse-symlink undo; self-install
  bootstrap.
- **M3 — semantic-pipe / audit integration (not started).**
  PackageManifest[], InstallProgressRecord[], KeyFingerprintRecord[]
  schemas via libpdx-semantic-pipe; libpdx-audit pre-output journal on
  every subcommand; libpdx-elevate KIND_PDXFS_FILE(write, /pkgs) with
  60s window.
- **M4 — tests + smoke (not started).** Sig-mismatch matrix,
  partial-install rollback via KIND_PDXFS_TXN abort, QEMU smoke:
  install → list → verify → remove → verify absent.
- **M5 — 1.0 signed release (not started).** Dual-signed
  manifest.pdxsig for pkg v1.0 + CHANGELOG entry, pkgs.paideia-os
  mirror push, .pdxdoc for `doc pkg`.

See `design/tooling/r49-r50-plan.md` §5.1 in paideia-os for the full
breakdown and cross-repo dependencies.

## Cross-repo state at M1 close

- libpdx-argv M1 landed (issues #1, #2, #3 closed 2026-08-21) — the
  subcommand argv parse dep is met.
- libpdx-cap M1 landed — indirect (loader-side manifest verify still
  uses the M1 skeleton; M2 flips to the real OK|MISSING|EXTRA compare).
- libpdx-audit / libpdx-elevate / libpdx-semantic-pipe M1 all landed —
  none are direct deps at pkg.M1.
- paideia-os R48 substrate closed: KIND_USER = 0x190,
  KIND_ELEVATE_CHANNEL = 0x191, KIND_PDXFS_FILE = 0x195,
  KIND_PDXFS_TXN = 0x196 (commits 411ad0e, e56a95b, 2ff76d4).
