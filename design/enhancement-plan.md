# pkg — enhancement plan (v1.x)

**Author:** osarch + softarch combined planning pass
**Date:** 2026-08-25
**Baseline:** `pkg-v1.0.0` (commit `2a9540d`), R49 wave, milestones M1–M5 closed.
**Method:** every claim below was checked against source in this repo. Where a
claim could not be verified in `src/`, it is marked as such rather than
repeated from a doc.

---

## 1. Current state

### 1.1 What actually runs

`pkg_main` (`src/main.pdx`) parses argv via libpdx-argv, then hands
`pos_ptrs[0]` to `Dispatch::dispatch_subcommand` (`src/dispatch.pdx`), which
byte-compares exactly five names — `install`, `remove`, `list`, `verify`,
`keys` — chosen for distinct first bytes (`i`/`r`/`l`/`v`/`k`). Anything else
exits 2.

| Subcommand | Body | Reality at HEAD |
|---|---|---|
| `install` | `PkgInstall::pkg_install_body` (`src/install.pdx`) | Real pipeline; refuses at the header stage (`_install_staging` is zero-init `.bss`, fails the `"pdxsig\0\0"` magic check). Exit 1. |
| `remove` | `PkgRemove::pkg_remove_body` (`src/remove.pdx`) | Real pipeline; refuses at the lookup stage (no readdir on `KIND_PDXFS_FILE`). Exit 1. Never reaches `txn_open`. |
| `list` | `PkgList::pkg_list_body` (`src/list.pdx`) | Real; `pkg_list_enumerate` is a STUB that always returns 0, so output is a fixed placeholder line. Exit 0. |
| `verify` | `SubcommandsM1Stubs::pkg_verify_stub` | **Stub.** Prints `pkg verify: body not implemented at M1 (lands at M2)`. Exit 3. M2 closed 2026-08-22. |
| `keys` | `SubcommandsM1Stubs::pkg_keys_stub` | **Stub.** Prints `pkg keys: body not implemented at M1 (lands at M5)`. Exit 3. M5 closed 2026-08-22. |

Two of five subcommands are stubs at a 1.0.0 tag, each naming a milestone that
has already closed.

### 1.2 Flags

`src/` contains **no reference to `flag_names[]`, `flag_count`, or
`flag_vals`** (verified by grep across all 14 `.pdx` files). pkg reads
`pos_count` and `pos_ptrs[]` only. Every flag in every document is parsed by
libpdx-argv and then discarded. Zero flag bodies exist.

### 1.3 The seams

Four upstream gates keep every mutating path refusing, all honestly recorded in
`STATUS.md` and `CHANGELOG.md` §"Known limitations":

1. **paideia-as v0.33-crypto-kdf** — `mc_verify_body_hash` returns
   `MC_HASH_STUB` (0xFFFFEB70) and `mc_verify_signatures` returns
   `MC_VERIFY_STUB` (0xFFFFEB71) unconditionally (`src/manifest_codec.pdx`
   :333, :353). No signature has ever been verified by this tool.
2. **paideia-os R48-PREP-005** — `svc.elevate-broker` unregistered, so
   `pkg_elevate_request_pdxfs_write_pkgs` always returns 0 and `txn_open`
   refuses with `PXT_MINT_BAD_PARENT`.
3. **`KIND_PDXFS_FILE` staging read** — no fixture manifest can reach
   `_install_staging`.
4. **`/system/packages/` readdir** — blocks `list` enumeration and `remove`
   lookup.

The repo's honesty about these gates is a genuine strength and this plan does
not disturb it. The gaps below are the ones the gates *do not* excuse.

---

## 2. The `.pdxdoc` / source divergence

`doc/pkg.pdxdoc` is the file `doc pkg` renders — it is the tool's user-facing
manual. It documents a substantially larger tool than the one that exists.
`README.md` (refreshed in `2a9540d`) is source-accurate and does not share this
problem; the divergence is confined to `.pdxdoc`, with a smaller amount in
`design/argv-surface.md` §3.1/§4.

### 2.1 Verified divergences

| # | `.pdxdoc` claims | Source reality |
|---|---|---|
| 1 | NAME: "Installs, **upgrades**, removes…" | No `upgrade` branch in `dispatch.pdx`. |
| 2 | `list [--available]` queries the mirror index | No flag read; `pkg_list_enumerate` returns 0. |
| 3 | `verify <name>` re-verifies, example shows exit 0 | Stub, exit 3, takes no name. |
| 4 | `keys list` prints per-key ML-DSA-65 fingerprints | Stub, exit 3. Dispatch matches `keys\0` only and ignores `pos_ptrs[1]`, so `pkg keys list` ≡ `pkg keys`. |
| 5 | "Standard I3 flags (all subcommands): `--help --version --dry-run --json --schema --verbose --quiet --color= --no-cap:<name>`" | None wired. `--quiet`, `--color`, `--no-cap:` are not even in this repo's own reserved vocabulary (`design/argv-surface.md` §4). |
| 6 | `--color={always\|auto\|never}` | Directly contradicts `design/argv-surface.md` §7: "**No colour output.** pkg's diagnostics are plain text at every milestone". |
| 7 | `remove --wipe` shreds the trash entry | Not implemented. The trash-move it would shred is itself a STUB seam (`remove.pdx` step 5). |
| 8 | EXAMPLES: `pkg install --dest /system/tools some-tool` | No `--dest`. The elevate request is hard-bound to `/pkgs` via `PE_CAP_MASK_PDXFS_WRITE_PKGS = 0x01`. |
| 9 | Install stages `RESOLVED, VERIFIED_AUTHOR, VERIFIED_ROOT, CAP_AUDIT, INSTALLED` | Real `INSTALL_STEP_*` constants are `1` HEADER, `2` HASH, `3` VERIFY, `4` MINT, `5` TXN_OPEN, `7` COMMIT. **None of the five documented names exist.** |
| 10 | Every install example ends `exit 0` | Unreachable at HEAD; pinned transcript is a refusal (`tests/m4-003-qemu-smoke/expected/full-matrix.txt`). |
| 11 | CAPS: per-install elevate acquires `KIND_NETWORK(fetch)` + `KIND_SIGNATURE(verify)` | Mask is `0x01` only. `pkg_elevate.pdx` :53-61 says bits `0x02`/`0x04` "land at M4" — M4 closed without them. |
| 12 | AUDIT: records carry `output_schema` + `output_hash` | `audit_record_op_output` is **defined and never called** (`src/audit_wire.pdx`:137; grep finds no call site). Both columns are unpopulated for every subcommand. |
| 13 | `install` refuses if the manifest's caps.decl hash mismatches the tar | `MC_TAG_CAPS_DECL_HASH` exists as a tag constant; the check is inside the stubbed verify path. |

### 2.2 Decisions

Each aspirational item was judged on: does a real paideia-os user at HEAD need
it, and what does it cost once the surrounding substrate exists?

**Implement (each gets an issue):**

- **`verify <name>`** — the cheapest genuine win in the tool. It needs no
  network and no elevate; the manifest travels with the install. It is also the
  only subcommand that gives an operator a reason to trust an already-installed
  package after a root-key rotation. → ENH-004.
- **`keys list`** — low-cost once a file read exists, and it is the operator's
  only window onto the trust root. Note it needs a caps.decl change: the
  baseline grants read on `/system/packages/` only, **not** `/system/keys/`.
  → ENH-005.
- **`--help` / `--version`** — the two flags a real user reaches for first,
  pure `.rodata` print + exit 0, zero substrate dependency. → ENH-006.
- **`--dry-run`** — the operator's only pre-flight against a privileged
  install. It is *most* valuable while the pipeline is seam-blocked, because it
  is the one mode that can meaningfully return 0. → ENH-007.

**Keep reserved, do not implement:**

- **`--json` / `--schema`** — meaningful only once `list`/`install` emit live
  records rather than one demo record. Keep in `design/argv-surface.md` §4 as
  reserved-and-unwired; remove from `.pdxdoc`'s "standard flags (all
  subcommands)" line, which reads as a shipped promise.

**Strip:**

- **`upgrade` from the NAME line** — no body exists, and the work is owned by
  open issue #23. The manual must not advertise it as shipped.
- **`list --available`** — blocked on the readdir gate *and* superseded by the
  index redesign in open issue #20. Restore when ENH-001 settles which index
  format wins.
- **`remove --wipe`** — an irreversible trash-shred while the recoverable trash
  path is still a STUB. Shipping the destructive half of a pair before the
  recoverable half inverts the I5 undo obligation.
- **`install --dest <path>`** — actively harmful documentation. It advertises
  arbitrary-destination *privileged* install while the elevate mask is hard-
  bound to `/pkgs`. A reader who trusts it would expect a cap narrowing that
  does not exist.
- **`--color=`** — contradicts this repo's own design doc.
- **`--quiet` / `--verbose`** — cosmetic for a tool whose entire output surface
  is a handful of fixed lines; `--verbose`'s stated behaviour (audit-record ids
  on stderr) is better served by the audit journal itself.
- **`--no-cap:<name>`** — a loader / libpdx-cap primitive pkg cannot implement
  unilaterally. A package manager that can drop its own capabilities per
  invocation is a footgun, not a feature.
- **`keys add` / `keys remove`** (`argv-surface.md` §3.1) — trust-root mutation
  through the package manager. Out of scope at any milestone.
- **`install <name>[@version]`** (`argv-surface.md` §3.1) — version selector;
  strip until ENH-001 settles the index format that would resolve it.

**Correct in place** (doc overstates existing behaviour, no new feature): rows
1, 2, 9, 10, 11, 12, 13 of §2.1, plus the stale `.pdxdoc-tool-wave R49 /
milestone M5` header now that an R70 milestone exists.

`pkg search` and `pkg info <name>` were considered and **not** proposed. Both
are index-readers, and which index they would read is exactly the question
ENH-001 has to answer first; proposing them now would commit the tool to a
format that may not survive.

---

## 3. R49 (shipped) vs R70 (open) — the blocking conflict

Open issues #18–#25 form milestone "R70 — pkg MVP" and respecify pkg from
scratch, incompatibly with the shipped v1.0.0 design:

| Concern | Shipped (R49, v1.0.0) | R70 plan (open) |
|---|---|---|
| Manifest | `manifest.pdxsig`, 64-byte binary header + TLV body | `<name>-<version>.pdxpkg`, "JSON-ish `{name, version, files[], deps[], signature}`" (#19) |
| Signatures | **Two** distinct signers, ML-DSA-65 each, over `header \|\| body`, plus a ROOT_FPR match against the machine-local fingerprint | **One** `signature` field, "stub-to-trust-local at v0" (#21) |
| Index | `/system/packages/index.pdxlist` + network mirror `pkgs.paideia-os` | `<repo>/index.pdxpkg`, local filesystem-path repo (#20) |
| Install root | `/pkgs/<name>-<version>/` | registered in `/var/pkg/installed.pdxpkg` (#21) |
| Remove | trash subtree + `/journal/pkg/*.pdxundo` + DELETE txn | "reverse install via libpdx-audit" undo record (#22) |
| `upgrade` | not in the vocabulary | new subcommand, atomic swap (#23) |

This is not a refinement of the shipped design; it is a different tool wearing
the same name. Two consequences matter:

1. **R70's single "trust-local" signature is a regression against the
   post-quantum dual-signed trust-root pillar.** The whole reason the shipped
   envelope carries two independent signers is stated in `README.md`: "a
   compromised author key does not compromise the mirror." A local-trust stub
   discards that property. If R70 proceeds as written, that trade must be an
   explicit, documented decision with a stated path back — not a side effect of
   a rewrite.
2. **Nothing else should be built until this is settled.** Half the enhancement
   backlog (paths, index, dry-run targets, cap model) resolves differently
   depending on the answer.

ENH-001 is therefore the gate on most of this plan.

---

## 4. `KIND_PACKAGE_MANIFEST`: advisory, not adjudicated

The parent brief asked whether pkg has been tested against "the real
`KIND_PACKAGE_MANIFEST` cap-invoke path." The premise needs correcting.

`src/kind_package_manifest.pdx`:8-17 quotes the upstream plan directly: the two
kinds pkg introduces (`KIND_PACKAGE_MANIFEST = 0x193`, `KIND_PACKAGE_REPO =
0x192`) are **userspace-defined derived kinds** — "no kernel-side `.pdx` files
needed." Consistent with that, `pmf_cap_mint_inner` issues **no syscall at
all**; it claims a row in a process-local 48-byte-per-row `.bss` table.

So there is no kernel cap-invoke path to test. Holding a row in
`PMF_STATE_VERIFIED` confers **zero kernel-enforced authority** — it is an
in-process boolean asserting "I checked the signatures", written by the same
code that would be compromised if the check were wrong. Against the project's
capability-discipline pillar this is a hole: the kernel never adjudicates the
one claim the entire install pipeline rests on.

The file anticipates this. Lines 27-31 note the row shape deliberately mirrors
the kernel's `kind_pdxfs_file.pdx` layout "so a future migration… is a code
move, not a data-shape redesign." ENH-010 forces the decision: promote to a
kernel-side derived kind, or document the advisory status plainly in `README.md`
and `.pdxdoc` so no reader mistakes it for enforcement.

---

## 5. The testing gap: pkg has never run on paideia-os

`tests/m4-003-qemu-smoke/` is named for QEMU and has never entered it.

- `tests/README.md`, verbatim: "The scripts here run outside QEMU today
  (against the `paideia-as build`-produced binary in `build-out/pkg`)".
- `smoke.sh` executes `"$PKG_BINARY" "$@"` — a **host-native exec**.
- The promised wire-in ("once the `pkg-*` cells wire into `tools/run-smoke.sh`
  in paideia-os") was an M4 follow-up against the monorepo that never landed.
- `tests/run-all.sh`, referenced by `tests/README.md`, **does not exist**.

pkg's kernel-touching paths — `sys_write`, syscall #70 `sys_pdxfs_txn_open`,
syscall #4 `sys_cap_invoke` for `PXT_OP_COMMIT`/`ABORT`, and `sys_exit` #60 —
have therefore never executed under a paideia-os kernel.

The reason this stayed invisible is worth recording: **every test cell asserts a
refusal.** Each pipeline halts at a seam before any interesting syscall issues,
so a host exec and a kernel exec produce byte-identical transcripts. The suite
is green and proves almost nothing about the target platform. The first cell
that ever reaches `txn_open` will be the first real test — and it will run
against code no kernel has ever seen. ENH-009 closes this.

Path resolution compounds it: `src/` contains no `sys_chdir`, no `sys_getcwd`,
and no relative-path handling of any kind. Every path in the tool is an
absolute literal. R70 #20 introduces local filesystem-path repos without saying
how a relative repo path resolves. ENH-013 pins that contract.

---

## 6. Gap vs what a real paideia-os user needs at HEAD

A user who boots paideia-os today and types `pkg`:

1. cannot install anything (four seams, any one of which refuses);
2. gets a milestone-stub string from two of five subcommands;
3. gets no response to `--help` or `--version`;
4. cannot see which keys the machine trusts;
5. cannot tell "not implemented" from "audit broker down, nothing was
   journalled" — both exit 3 (`README.md` exit-code table concedes the
   overload). The second is a security-relevant condition and deserves its own
   code. `design/argv-surface.md` §5 promised "M5 removes the reservation";
   M5 closed and instead a second meaning was added to it.

Items 3, 4 and 5 are gated on nothing upstream. They are landable now.

---

## 7. Issue plan

Filed into milestone **"Enhancement v1.x — pkg"** (milestone 7).

| ID | Issue | Title | Effort | Deps |
|---|---|---|---|---|
| ENH-001 | #26 | Reconcile shipped R49 design against the open R70 MVP plan | M | none |
| ENH-002 | #27 | Pin `doc/pkg.pdxdoc` to source; strip aspirational surface | S | none |
| ENH-003 | #28 | Split exit code 3 into not-implemented vs audit-broker-fail | XS | none |
| ENH-004 | #29 | `pkg verify <name>`: replace the M1 stub with a real body | M | #28 |
| ENH-005 | #30 | `pkg keys list`: real body + `/system/keys/` read authority | M | #28 |
| ENH-006 | #31 | Wire `--help` and `--version` | S | none |
| ENH-007 | #32 | Wire `--dry-run` for install and remove | M | #26 |
| ENH-008 | #33 | Elevate coverage: gate `remove`, and widen or correct the cap mask | M | #26 |
| ENH-009 | #34 | Boot pkg under a live paideia-os kernel; the QEMU smoke never entered QEMU | L | none |
| ENH-010 | #35 | Decide `KIND_PACKAGE_MANIFEST`: kernel-adjudicated or documented as advisory | M | #26 |
| ENH-011 | #36 | Commit a static `deps.list`; release manifest is not reproducible without it | XS | none |
| ENH-012 | #37 | `audit_record_op_output` is defined but never called | S | none |
| ENH-013 | #38 | Path-resolution contract for local filesystem-path repos | S | #26, #20 |

Suggested order: #28, #31, #36, #37 (independent, small, land immediately) →
#26 (unblocks the rest) → #27, #34 → the remainder.

---

## 8. Companion work in the paideia-os monorepo

Flagged for a coordinating pass, **not filed from this repo**:

1. `tools/run-smoke.sh` uplift to include the `pkg-*` cells — the M4 follow-up
   that `tests/README.md` promises and that never landed.
2. Boot-image seeding: `build-out/pkg` into the image, plus the `/system/packages/`,
   `/pkgs/`, `/system/keys/paideia_root_pk.fpr`, `/system/trash/` and
   `/journal/pkg/` subtrees. None exist in a boot today.
3. **R48-PREP-005** — `svc.elevate-broker` registration + auto-approve policy
   table. Blocks every install.
4. `KIND_PDXFS_FILE` staging read and readdir (or a kernel-maintained
   `index.pdxlist`). Blocks install fixtures, `list`, and `remove`.
5. Ownership decision on promoting `0x193` / `0x192` to kernel-side derived
   kinds — belongs to `design/tooling/r49-r50-plan.md` §5.1 (see §4 above).
6. **paideia-as v0.33-crypto-kdf** — ML-DSA-65 verify + sha3-256 intrinsics.
   Blocks the dual-signature pillar entirely.
7. R86 `sys_chdir` / `sys_getcwd` availability, for ENH-013.
8. Issues #24 and #25 both target monorepo paths (`design/tooling/pkg-mvp.md`,
   `design/round-retrospectives/r70-closure.md`) from a `pkg` milestone.

---

## 9. Verdict on the `pkg-v1.0.0` tag

**Not defensible as a 1.0.0.**

- The binary has never executed under a paideia-os kernel (§5).
- Two of five documented subcommands are stubs naming closed milestones (§1.1).
- No package has ever been installed by it; every mutating path refuses at a
  seam.
- The property the release is *named for* — dual-signed manifests — is STUB
  fill for every key, signature and hash byte (`release/1.0/keys-fingerprints.md`,
  `CHANGELOG.md` §"Known limitations"). No signature has ever been verified.
- An open milestone respecifies the manifest format, the index and the trust
  model incompatibly (§3).

A tag whose entire value proposition is stubbed is a milestone marker, not a
release. The repo's own documentation is admirably honest about each gate
individually; it is the `1.0.0` label on top of them that overclaims.

**Recommendation** (maintainer's call): keep the tag as an immutable historical
marker, but add a prominent status banner to `README.md` stating that 1.0.0 is
a shape-complete pre-substrate milestone, and reserve the *semantics* of 1.0.0
for the first release that has installed a package under a live kernel. If
re-tagging is acceptable, `pkg-v0.4.0-r49` describes the artefact accurately.
