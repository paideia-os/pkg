# Path-resolution contract for local filesystem-path repos

**Issue:** [pkg #38](https://github.com/paideia-os/pkg/issues/38) — ENH-013.
**Authors:** softarch (drafted 2026-09-13).
**Scope:** what `pkg install <arg>` does when `<arg>` names a path on the
local filesystem rather than a package identifier resolved through a
registered repo.
**Status:** contract only — no `.pdx` code lands with this doc. The
resolver lives in an install-body pre-pass added at a later ENH-013 patch
once `sys_chdir` / `sys_getcwd` land (paideia-os R86 gate).

Related design authorities: `design/argv-surface.md` §3.1 (positional
shape), `design/install-flow.md` §2 (staging path derivation),
`design/enhancement-plan.md` §5 (repo model), `design/manifest-format.md`
§5 (verification algorithm applies verbatim regardless of where the
bytes came from).

---

## 1. Why a distinct contract

Every install pipeline stage past the fetch (`ManifestCodec::mc_read_
header` onwards) operates on bytes in a caller-owned buffer and treats
their provenance as opaque. This is deliberate: it lets the fetch stage
be a repo pull, a local `.pkg` file, or a fixture blob without moving
any downstream step. But the fetch stage itself has to distinguish
those cases, and the resolution rule must be a *contract* — a user who
types `pkg install ./foo.pkg` and a supervisor tailing the audit
journal must both know what the tool did without reading `src/`.

At HEAD `PkgInstall::pkg_install_body` reads from a hard-coded
`.bss` staging buffer (`_install_staging`) and never consults its
positional at fetch time. Every "install" path is therefore the same
STUB — the shape below is what the fetch-stage upgrade lands on, and
what `pkg install /path/to/foo.pkg` will resolve to today once the
substrate is present. Pinning it now (rather than after the fact)
means the M4+ fetch-stage patch is a body-swap inside one clearly
labelled seam, not a reshape of `pkg_install_body`.

---

## 2. Positional discrimination

`ParsedArgs::pos_ptrs[1]` is the sole input. The first byte and the
presence of a `/` decide the branch:

| First byte / shape                     | Class          | Example              |
|----------------------------------------|----------------|----------------------|
| `/` (leading slash)                    | absolute path  | `/tmp/foo.pkg`       |
| `.` followed by `/` or `.`             | relative path  | `./foo.pkg`, `../f`  |
| any byte, string contains `/` anywhere | relative path  | `staging/foo.pkg`    |
| any byte, string contains **no** `/`   | repo identifier | `foo`, `pkg-cli-1.2` |

The discrimination is a single pass over the NUL-terminated positional:
if a `/` appears before the NUL, treat as a filesystem path; otherwise
treat as a repo identifier and hand off to the existing (M4+) repo-
lookup path.

Rationale for including "any byte + `/`" as a path: a package
identifier that legally contains `/` would collide with a filesystem
path spelling for the same operator. The R70 repo grammar
(`design/argv-surface.md` §3.1) reserves `/` as the delimiter between
repo host and package name (e.g. `pkgs.paideia-os/foo`), which would
force this discriminator into a mode flag. That is a deliberate future
choice — this contract picks the simpler rule today and revisits when
R70 lands.

Empty positional is a usage error (already enforced at `pi_usage_error`).

---

## 3. Absolute paths

An absolute path (`/tmp/foo.pkg`) is used as-is. It must:

1. Point to a regular file (not a directory, not a symlink to a
   directory) whose name ends in `.pkg`. Any other extension is a
   usage error — the tool refuses to guess at file format from
   content. `KIND_PDXFS_FILE.query_mode` (paideia-os R42 substrate)
   is the mode oracle.
2. Be readable by the caller's KIND_PDXFS_FILE(read) cap. pkg's
   `caps.decl` grants ambient read only on `/system/packages/` and
   `/system/keys/`; an absolute path outside those subtrees requires
   an elevate for **read** authority (mask bit `PE_CAP_MASK_PDXFS_
   READ_LOCAL = 0x08`, allocated but not yet wired — see §6). Without
   that elevate the fetch stage refuses with `EXIT_OP_FAIL` and a
   diagnostic naming the missing cap.
3. Not cross a mount boundary the caller lacks traversal authority
   for. PdxFS mount policy is enforced by the kernel; pkg surfaces
   any traversal refusal verbatim.

Absolute paths are **not** canonicalised. `.` / `..` segments in an
absolute path are a usage error (returned before any fetch attempt);
the caller intended a canonical path and the tool refuses to guess.

---

## 4. Relative paths

A relative path is resolved against the caller's current working
directory at process entry — captured once via `sys_getcwd` (paideia-os
R86 gate) into a process-lifetime .bss slot (`_pkg_initial_cwd`). The
resolver does **not** consult the CWD again after that point, so a
subsequent `sys_chdir` (a future `pkg install --cd`-style flag; not in
scope here) cannot re-target a resolution mid-pipeline.

The join produces an absolute path which is then subject to §3's
rules verbatim. In particular:

* `.` and `..` segments in the *user-supplied* relative path are
  resolved against the captured CWD before the §3 canonicalisation
  check runs. A `..` that escapes the caller's cwd-subtree is a
  usage error.
* Symlinks in the joined path are followed once per component; a
  loop is a usage error (bounded at 32 hops, matching PdxFS's own
  `PDXFS_SYMLINK_MAX`).
* The joined path is subject to the same length ceiling PdxFS
  enforces on any path argument (`PDXFS_PATH_MAX = 4096` bytes
  including the NUL); an over-length join is a usage error before
  the fetch attempts to open.

Rationale for CWD-capture-once: a `pkg install ./a.pkg && cd /elsewhere
&& pkg install ./b.pkg` sequence must resolve `./b.pkg` in `/elsewhere`,
not in the first invocation's cwd. That is per-process, so capturing
CWD at pkg's own process entry is the right scope.

---

## 5. Manifest derivation

Regardless of how the fetch stage acquired the bytes, downstream steps
require the **manifest.pdxsig** to be adjacent to (or embedded in)
the fetched artefact:

* If the caller pointed at `foo.pkg`, the fetch stage looks for a
  sibling `foo.pkg.pdxsig` in the same directory and reads it into
  `_install_staging`. Absence of the sibling is `EXIT_OP_FAIL` with a
  diagnostic naming the missing file.
* If the caller pointed at `foo.pkg.pdxsig` directly, the fetch stage
  reads it and derives the pkg path by stripping the `.pdxsig` suffix.
  The pkg file must be a sibling.

An embedded manifest (a `.pkg` archive with a `manifest.pdxsig` member
readable by the archive walker) is deferred past 1.x — `design/manifest-
format.md` §6 evolution notes explicitly keep the sidecar-only shape
for now to avoid a "read the manifest before you trust the archive"
bootstrap problem.

---

## 6. Cap discipline

Local-path installs do not bypass any pillar. In particular:

* **D3 audit-first.** `audit_begin_op` fires before the resolver
  inspects the positional, so a supervisor sees an INVOKE record
  naming `install` regardless of whether the resolver branch is
  "repo lookup" or "local path".
* **D4 no ambient /pkgs write.** Local-path installs still request a
  `KIND_PDXFS_FILE(write, /pkgs)` cap via `PkgElevate::pkg_elevate_
  request_pdxfs_write_pkgs` before opening the txn. The install
  destination is *always* `/pkgs/<name>-<version>/` — a local `.pkg`
  does not target its own directory.
* **Local-read elevate.** A local path outside pkg's ambient
  `/system/packages/` + `/system/keys/` grants needs a *read* cap
  distinct from the write cap install already requests. Allocate
  bit `PE_CAP_MASK_PDXFS_READ_LOCAL = 0x08` in `pkg_elevate.pdx`
  (companion to bits `0x02` KIND_NETWORK, `0x04` KIND_SIGNATURE
  which are already reserved), narrowed to the *parent directory*
  of the caller's positional so the traversal check has scope.
  Not wired at this doc's landing — the elevate broker itself
  remains unregistered (paideia-os R48-PREP-005).

The audit record's `op_args` field carries the *canonical* joined
path (§4) rather than the raw positional so the ledger's forensic
value survives a `chdir` between invocations.

---

## 7. Diagnostics

Each refusal path names the class and the reason:

| Class            | Diagnostic (stderr)                                                                     |
|------------------|------------------------------------------------------------------------------------------|
| absolute-not-file | `pkg install: '<path>': not a regular file`                                             |
| bad-extension    | `pkg install: '<path>': expected .pkg or .pdxsig`                                        |
| relative-escape  | `pkg install: '<path>': relative path escapes cwd subtree`                               |
| path-too-long    | `pkg install: '<path>': joined path exceeds PDXFS_PATH_MAX (4096)`                       |
| missing-sidecar  | `pkg install: '<path>': manifest.pdxsig sibling not found`                               |
| no-read-cap      | `pkg install: '<path>': libpdx-elevate did not grant KIND_PDXFS_FILE(read) for parent`   |

All classes return `EXIT_OP_FAIL` (1). Usage errors that the resolver
catches before starting fetch (bad extension, path-too-long,
relative-escape) return `EXIT_USAGE` (2) so a script can distinguish
"the operator's argv was wrong" from "the tool refused a plausible
argv at fetch time".

---

## 8. Future work

* R70 repo grammar decides whether `repo/pkg-name` should be parsed
  as a repo-qualified identifier (in which case §2's discriminator
  needs a mode flag). Deferred until that grammar lands.
* Embedded-manifest `.pkg` archives (§5).
* `pkg install --local-only` / `--repo-only` mode flags to lock
  the resolver into one branch, for supervisors that want to refuse
  a class of installs at policy time (currently only enforceable at
  cap-narrowing time via elevate mask).
* Fixture-manifest bootstrap: the M4 test harness will thread
  fixture `.pkg` files through the local-path branch, so this
  contract's landing is a prerequisite for the M4 install-cell
  fixtures actually reaching `pi_pipeline` in a QEMU boot.
