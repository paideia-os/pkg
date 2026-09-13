# ENH-010 — KIND_PACKAGE_MANIFEST / KIND_PACKAGE_REPO: advisory,
# not kernel-adjudicated

**Author:** softarch (Wave Z)
**Date:** 2026-09-13
**Issue:** #35 (`pkg.ENH-010`)
**Baseline:** `pkg` v1.1.0 (Wave S), commits through the caps.decl adoption
at #39.
**Decision:** documented advisory. Promotion to kernel-side derived kinds
is a paideia-os monorepo concern tracked at `design/tooling/r49-r50-plan.md`
§5.1 and is NOT re-opened here.

## 1. What #35 said

The full text is in the issue. The reduced form: `pmf_cap_mint_inner`
(`src/kind_package_manifest.pdx`) issues **no syscall**. It claims a row
in a process-local `.bss` table, and the state byte
`PMF_STATE_VERIFIED` is set by the same code that would be compromised
if the verify were wrong. Nothing outside pkg can observe or refuse the
claim. The kernel-flavoured naming (`pmf_cap_mint_inner`,
`pmf_cap_revoke`, `KIND_*` ordinals) obscures this; a reader who does
not open the file may infer kernel adjudication.

## 2. The decision

**Documented advisory.** The two kinds `KIND_PACKAGE_MANIFEST = 0x193`
and `KIND_PACKAGE_REPO = 0x192` remain userspace-defined derived kinds,
per the upstream plan (`design/tooling/r49-r50-plan.md` §5.1: "no
kernel-side `.pdx` files needed"). No syscall is added at Wave Z.

The rationale for NOT promoting here:

1. Promotion moves an ordinal from pkg's `.pdx` files into the kernel's
   `kind_registry.pdx`, adds a `sys_*` handler, and locks the row shape
   into a kernel ABI. All three are monorepo-owned decisions that this
   repo cannot land alone. Filing the decision here without landing the
   kernel side would leave a partial state worse than the current one
   (a promoted-in-doc / userspace-in-code split).

2. The **honest** posture is naming the current state plainly. A
   documented advisory is not weaker than an undocumented advisory —
   it is the same state, correctly labelled. That is the entire
   deliverable of this issue.

3. Every downstream consumer that would benefit from kernel adjudication
   (`pkg upgrade` at #23, the `pkg verify` real body at ENH-004, the
   `/system/packages` index at ENH-011) already refuses on the paideia-as
   v0.33-crypto-kdf gate; the row's `VERIFIED` bit is unreachable at
   HEAD. The exposure window is **future work**, not present code.

Promotion remains desirable and is retained in the plan doc as an
option; this issue does not remove it from the roadmap.

## 3. What Wave Z lands against #35

Four file edits, all documentation:

- `src/kind_package_manifest.pdx` — the module preamble grows a
  `## 3. Advisory status (ENH-010, #35)` block that says, plainly, that
  the mint is a `.bss` row claim, that `PMF_STATE_VERIFIED` is an
  in-process boolean written by the code that would be compromised if
  verify were wrong, and that the kernel never adjudicates. Cross-refs
  this doc.
- `src/kind_package_repo.pdx` — the same block, mirrored.
- `README.md` — a new `### Kind ordinals: advisory` subsection under
  `## Description` names the same reality in operator-facing language.
- `doc/pkg.pdxdoc` — the `SEE ALSO` section grows a line pointing at
  this decision record, and any prose that could be read as "kernel
  enforces" gets a corrective phrase.
- `design/architecture.md` — ENH-010 disposition block near the top
  (mirrors the ENH-001 disposition block that already sits there).

No `.pdx` executable code changes. `manifest.pdxproj` sources are
unchanged.

## 4. What would flip this decision

Promotion becomes appropriate the first time one of these lands:

- A **second** userspace tool wants to consume `KIND_PACKAGE_MANIFEST`
  rows minted by `pkg` (today, only `pkg` produces and only `pkg`
  consumes; the kind is effectively private state). At two consumers
  the userspace-only story breaks: consumer B has no way to check
  that consumer A actually verified the signatures.
- The `.bss` table needs to survive an exec (a `pkg install` that
  needs to hand the row to a helper it spawned). Cross-exec survival
  is a kernel-cap property; a `.bss` table cannot supply it.
- An audit finds a code path where `PMF_STATE_VERIFIED` can be set
  without a passing verify. Today the mint helper only runs on the
  OK arm of `mc_verify_signatures`; a refactor that changes this
  should promote rather than patch the .bss table.

None of these are present at Wave Z.

## 5. Cross-references

- Upstream plan: `design/tooling/r49-r50-plan.md` §5.1
  (`paideia-os/paideia-os`).
- Row shape rationale: `src/kind_package_manifest.pdx` lines 27-31
  ("row shape deliberately mirrors the kernel's `kind_pdxfs_file.pdx`
  layout so a future migration ... is a code move, not a data-shape
  redesign").
- ENH-001 reconciliation: `design/enh-001-reconciliation.md` (the
  broader R49-vs-R70 disposition; ENH-010 is one strand of it).
- Wave-Z closure: `CHANGELOG.md` `## 1.2.0 — Wave Z` entry.
