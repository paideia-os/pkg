# R70 — `pkg` round-closure retro (repo-local slice)

**Issue:** R70.M1-008 (#25)
**Wave:** Wave Z (2026-09-13)
**Scope:** the pkg-repo half of the R70 closure. The paideia-os
monorepo half — `design/round-retrospectives/r70-closure.md` — is
tracked separately against `paideia-os/paideia-os` and is not
authored here.

## 1. Disposition

**R70 (the "pkg MVP" milestone chain: #18-#25 in this repo) is
closed as subsumed.**

The R70 issues were originally filed against the pkg repo before the
R49 wave landed. R49 shipped the entire M1-M5 chain — repo scaffold,
argv surface, manifest format, install / remove / list / verify /
keys bodies, semantic-pipe schemas, audit-first journaling,
elevate-broker integration, sig-mismatch + rollback test matrix, QEMU
smoke chain, and the 1.0.0 signed-release chain. Every observable
correctness fingerprint the R70 issues named is satisfied by the R49
code path already in tree. The full mapping is in
`design/enh-001-reconciliation.md` (from ENH-001 #26); the disposition
is repeated here so the round-closure record stands on its own.

| R70 issue | Fingerprint | R49 satisfier |
|-----------|-------------|---------------|
| #18 M1-001 Repo bootstrap | source tree + build integration + README | `manifest.pdxproj`, `README.md`, `bootstrap/` — landed at pkg.M1-001 (#1) |
| #19 M1-002 Manifest format | `<name>-<version>.pdxpkg` schema | `design/manifest-format.md`, `src/manifest_codec.pdx` — landed at pkg.M1-003 (#3) and pkg.M2-003 (#6) |
| #20 M1-003 Repo index | `index.pdxpkg` + `pkg list` | `src/list.pdx` + `src/pipe_schemas.pdx` — landed at pkg.M3-001 (#9); `/system/packages/index.pdxlist` enumeration remains gated on paideia-os R42-PREP-005 (readdir) |
| #21 M1-004 `pkg install <name>` | fetch, verify, extract, register | `src/install.pdx` — landed at pkg.M2-003 (#6); every mutating step refuses on the four upstream gates (crypto-kdf, R48-PREP-005, R42-PREP-006, R42-PREP-007) |
| #22 M1-005 `pkg remove <name>` | reverse install via libpdx-audit | `src/remove.pdx` + `src/audit_wire.pdx` — landed at pkg.M2-004 (#7) + pkg.M3-003 (#11) |
| #23 M1-006 `pkg upgrade <name>` | atomic swap | **Wave Z:** `src/upgrade.pdx` skeleton + `design/upgrade-flow.md`. Kernel-side commit path (KIND_PDXFS_TXN in TXN_MODE_REPLACE) still gated on R42-PREP-007; body refuses at UPGR_STUB with a diagnostic naming the four gates. Novel design over the R70 mkdir-tempdir + rename prescription; see `design/upgrade-flow.md` §2. |
| #24 M1-007 Design doc: `pkg-mvp.md` | Document the MVP shape | Authored against the paideia-os monorepo (`design/tooling/pkg-mvp.md`), NOT this repo, per the issue body's "Files touched" line. No pkg-side file. |
| #25 M1-008 Round closure retro + tag | this document | THIS FILE + the `r70-closed` tag applied to `pkg` by main after the Wave-Z merge (`git tag r70-closed <sha>`). |

## 2. Why R70 stayed open after R49 closed

Two accidents:

1. **Sequencing.** R70 was filed *before* R49 landed and never
   re-planned once R49 shipped. The issues remained on the tracker
   as orphans of an earlier plan generation.
2. **Duplication radar.** The R49 M1-M5 issue titles (M1-001 etc.)
   collide with the R70 M1-001..M1-008 titles at the milestone-tag
   level; scans that dedupe by title-substring missed the collision
   and left both sets open.

The corrective is this closure record + the ENH-001 reconciliation
doc. No shape change to any of the R49 code lands.

## 3. Wave-Z landing

- `design/enh-010-advisory-status.md` (ENH-010 #35): documents that
  KIND_PACKAGE_MANIFEST / KIND_PACKAGE_REPO stay userspace-defined.
- `design/upgrade-flow.md` (R70.M1-006 #23): the novel upgrade shape
  and the Wave-Z skeleton body.
- `src/upgrade.pdx` (R70.M1-006 #23): audit-first skeleton;
  dispatch route in `src/dispatch.pdx`; manifest source list bump.
- `caps.decl` + `src/pkg_elevate.pdx` (R90-XREPO.013.M3-008 #39):
  named `/system/packages` write authority as elevate-mediated;
  added `PE_CAP_MASK_PDXFS_WRITE_SYSTEM_PACKAGES = 0x08`.
- `tests/run-all.sh` + `tests/README.md` + `design/test-matrix.md`
  (ENH-009 #34): two-mode runner with an honest fast-refuse on
  `RUN_MODE=qemu` pending the paideia-os companion.
- `CHANGELOG.md` `## 1.2.0 — Wave Z` entry (covers all five above).
- `manifest.pdxproj` version bump 1.1.0 -> 1.2.0.

## 4. Follow-ups

- **`r70-closed` tag on pkg** — applied by main after the Wave-Z
  commit lands. Content: this closure doc's git SHA. NOT applied
  here (softarch does not tag).
- **Wave-AA test cell** for the upgrade skeleton — filed once R49's
  m4-* pattern is generalised to a `rz-*` cell prefix (out of scope
  at Wave Z; see `design/upgrade-flow.md` §6).
- **KIND_PACKAGE_MANIFEST promotion** — remains a monorepo decision
  in the paideia-os plan doc §5.1. If reopened, the code move is a
  ~40-line diff per `design/enh-010-advisory-status.md` §2.
