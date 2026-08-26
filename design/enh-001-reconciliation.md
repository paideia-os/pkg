# pkg — ENH-001 reconciliation: shipped R49 design vs open R70 MVP

**Wave:** Enhancement v1.x (milestone 7)  **Issue:** #26 (ENH-001)
**Deps:** none. **Gates:** ENH-007 (#32), ENH-008 (#33, already
landed against the R49 shape), ENH-010 (#35), ENH-013 (#38), and
every R70 issue (#18-#25).
**Fingerprint:** no behaviour change. This is the decision record the
issue asked for: surviving manifest format, index format, install
root, trust model, and a disposition line per #19-#23, plus the
`pkg-v1.0.0` tag question.

## 1. The conflict, restated

Milestone "R70 — pkg MVP" (#18-#25) respecifies pkg from a blank
slate: a JSON-ish `<name>-<version>.pdxpkg` manifest with a single
"stub-to-trust-local" signature, a local-filesystem-path repo with a
walkable `index.pdxpkg`, and an install/remove/upgrade surface that
shares no data shape with what shipped at `pkg-v1.0.0`.

`design/enhancement-plan.md` §3 is the full side-by-side; the load-
bearing sentence is in its intro: R70's single signature is *"a
regression against the post-quantum dual-signed trust-root pillar"*
and discarding it "must be an explicit, documented decision with a
stated path back — not a side effect of a rewrite." This document is
that explicit decision.

## 2. Decision

**R70 is reoriented to extend the shipped R49 substrate, not replace
it.** None of R70's manifest format, signature model, or install root
survive as specified. What R70 is actually chasing — "the first real
package-manager use in the OS," per its own milestone description,
via a **local filesystem-path repo** rather than a network mirror — is
a genuine, valuable, and much narrower goal than a full respec. That
goal is achievable as an additive repo-source variant on top of the
R49 codec, not a new codec.

Rationale: the dual-signed envelope is not incidental complexity R70
can shed to move faster. `README.md`'s own framing — "a compromised
author key does not compromise the mirror" — is a property of the
*trust model*, not the *transport*. A local-path repo changes how the
bytes arrive (filesystem read vs. network fetch); it says nothing
about whether they should be trusted. Trusting a `.pdxpkg` file
because it sits on the local disk, with a stub signature that is
"trust-local at v0," inverts the actual threat this format defends
against — a compromised or careless build of a *locally staged*
package is exactly the case dual-signing catches. There is also no
stated migration path in #19/#21 back to dual-signing once a
single-signature format ships and packages exist under it; ENH-001
requires that path to be stated up front, and the only way to state it
credibly is to not take the detour.

### 2.1 Per-concern disposition

| Concern | Shipped (R49, kept) | R70 as originally filed (#18-25) | Disposition |
|---|---|---|---|
| Manifest format | `manifest.pdxsig`: 64B binary header + TLV body | `<name>-<version>.pdxpkg`: JSON-ish `{name, version, files[], deps[], signature}` | **Kept: `manifest.pdxsig`.** #19 is redirected: `.pdxpkg` becomes the **repo index entry** format (a pointer record: name, version, path to the real `manifest.pdxsig` + `pkg.tar`), not a competing manifest. See §3. |
| Signatures | Two ML-DSA-65 signers (author + root) over `header \|\| body`, plus ROOT_FPR match | One `signature` field, "stub-to-trust-local at v0" | **Kept: dual ML-DSA-65.** #21's single-signature model is rejected as a release contract. A local-repo package is still a `manifest.pdxsig` and still verifies both signatures; "local" describes the transport, not a trust exemption. |
| Index | `/system/packages/index.pdxlist` + network mirror `pkgs.paideia-os` | `<repo>/index.pdxpkg`, local filesystem-path repo | **Both, layered.** `/system/packages/index.pdxlist` stays the record of *what is installed*. A local filesystem-path repo (#20's actual goal) becomes a second, additive *source* pkg can resolve `install <name>` against before or instead of the network mirror — see §3. Its index entries are `.pdxpkg` pointer records per the redirected #19. |
| Install root | `/pkgs/<name>-<version>/` | `/var/pkg/installed.pdxpkg` (a registry file, not a root) | **Kept: `/pkgs/<name>-<version>/`.** #21's registry-file idea is folded into "what `/system/packages/index.pdxlist` already is" rather than a second registry. |
| Remove | Trash subtree + `/journal/pkg/*.pdxundo` + DELETE txn (already implemented, ENH-008 wired elevate into it) | "Reverse install via libpdx-audit" undo record | **Kept, reframed.** #22's "reverse install via libpdx-audit" is not a different mechanism from the shipped trash-subtree + pdxundo journal — it is a description of the same undo obligation from the audit side. No implementation change; #22 closes as a documentation reframing once the wording in its milestone doc is corrected to point at `design/remove-flow.md`. |
| `upgrade` | not in the vocabulary | new subcommand, atomic swap (#23) | **Proceeds, unchanged in shape.** Nothing about the dual-signed model conflicts with an atomic install-then-swap; #23 is compatible with §2's decision as filed and is not blocked by this record. |

### 2.2 What #18-25 mean going forward

- **#18 (repo bootstrap: source tree + build integration + README)** —
  proceeds. No conflict; scaffolding work.
- **#19 (manifest format: `<name>-<version>.pdxpkg` schema)** —
  **redirected**, not closed. Same filename convention, but the
  record it defines is a repo-index pointer entry (name, version,
  path/URI to the real `manifest.pdxsig` + `pkg.tar`), not an
  alternate manifest. Re-scope the issue body before implementation
  starts.
- **#20 (repo index: `index.pdxpkg` + `pkg list`)** — proceeds as the
  additive local-repo source described in §3, walking entries defined
  by the redirected #19.
- **#21 (`pkg install <name>`: fetch, verify, extract, register)** —
  proceeds, but "verify" means the real dual-ML-DSA-65 path against
  the resolved `manifest.pdxsig` (still gated on the paideia-as
  ML-DSA-65 *verify* intrinsic — sign landed at v0.23.0, verify has
  not), and "register" means the existing
  `/system/packages/index.pdxlist`, not a new `/var/pkg/installed.pdxpkg`.
- **#22 (`pkg remove <name>`: reverse install via libpdx-audit)** —
  reframed per §2.1; no new implementation, correct the milestone doc
  to reference the shipped trash-subtree + pdxundo journal.
- **#23 (`pkg upgrade <name>`: atomic swap install)** — proceeds
  unchanged.
- **#24 (design doc: `pkg-mvp.md`)** and **#25 (round closure retro)**
  — proceed once #19-#22 are re-scoped per the above; the design doc
  should cite this record for the manifest/index/trust decisions
  rather than re-deriving them.

## 3. How a local-path repo composes with the shipped codec

A "repo" (R70's contribution) is a location `pkg` can resolve
`install <name>` against, ahead of or instead of
`pkgs.paideia-os`. Its `index.pdxpkg` is a flat list of pointer
records (name, version, path). Resolving an install from a local repo
still ends at the same place a mirror install does: a `manifest.pdxsig`
+ `pkg.tar` pair that `ManifestCodec` reads and dual-verifies exactly
as today. The only new work R70 introduces is *locating* that pair —
a path-resolution question, which is exactly why ENH-013 (#38, path-
resolution contract) depends on this record and on #20 settling the
index entry shape first.

This composition is why "layered on top of, not replacing" is
tractable: nothing in `ManifestCodec`, `TxnClient`, `PkgElevate`, or
the trash/undo path in `remove.pdx` needs to change for a local repo
to exist. Only the *source resolution* step ahead of `mc_reset` /
`mc_read_header` gains a second implementation.

## 4. The `pkg-v1.0.0` tag

Per `design/enhancement-plan.md` §9's own recommendation: **kept as an
immutable historical marker.** Nothing in this record retags or
un-ships it. A prominent status banner is warranted in `README.md`
stating that 1.0.0 is a shape-complete pre-substrate milestone (no
signature has ever been verified, no package has ever been installed
under a live kernel) and that the *semantics* of "1.0.0" as a release
claim are reserved for the first version that has actually installed
a package under a live paideia-os kernel — tracked by ENH-009 (#34).
Landing that banner is folded into ENH-009's own closure rather than
duplicated here, since ENH-009 is the issue that will actually observe
the first live install.

## 5. What this record does NOT do

- It does not implement anything in #19-#23 — those issues re-scope
  but stay open under their own effort estimates.
- It does not wire the ML-DSA-65 verify intrinsic (still blocked
  upstream on paideia-as; sign landed at v0.23.0, verify has not).
- It does not decide `KIND_PACKAGE_MANIFEST`'s kernel-adjudicated-vs-
  advisory question — that is ENH-010 (#35), which this record
  unblocks but does not answer.
- It does not design the path-resolution contract for local repos —
  that is ENH-013 (#38), which this record unblocks (§3 gives it the
  shape to resolve against) but does not itself specify.
