# pkg — architecture

**Wave:** R49 (Wave 1)
**Repo:** github.com/paideia-os/pkg
**Upstream design:** `design/tooling/r49-r50-plan.md` §5.1 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of pkg. It does not repeat
the wave-level rationale from the paideia-os plan doc; read that first
for the D4 install-model contract (dual-signed manifests, source
fallback, per-install elevate) and for the KIND_PACKAGE_MANIFEST /
KIND_PACKAGE_REPO allocations landing at M2.

**ENH-001 (#26, 2026-08-25):** the R49 shape described in this document
is the surviving design against the open "R70 — pkg MVP" milestone
(#18-#25), which originally proposed replacing it. See
`design/enh-001-reconciliation.md` for the full disposition; nothing
in this document changes as a result.

## 1. Milestone position

M1 lands the frame: the argv surface, the subcommand routing, the
paideia-as build manifest, and the on-disk package-manifest format
spec. It does **not** land any signed-install, any network fetch, any
elevate-broker hop, or any semantic-pipe emission.

The M1 first-runnable shape is one command: `pkg list` walks the
dispatch chain (argv → parse → recognizer → list body → print → exit)
end-to-end and produces a human-readable placeholder on stdout. Real
enumeration of `/system/packages/` is deferred to M2 because
KIND_PDXFS_FILE at the R48-close substrate exposes six query ops
(query_inode, query_len, query_mode, query_birth, query_mtime,
query_refs — see `src/kernel/core/cap/kind_pdxfs_file.pdx` L94-100 in
paideia-os at commit `411ad0e`) and no readdir op. M2 either lands a
readdir extension on KIND_PDXFS_FILE or reads a `/system/packages/
index.pdxlist` text file the pkg_install body maintains — that
substrate choice is a §5.1 M2 concern in the plan doc, not an M1 one.

The three M1 issues are #1 (scaffold + caps.decl + build manifest), #2
(argv surface + subcommand routing + print helper + list body), #3
(package manifest format design doc). The design docs for each land
alongside the code.

## 2. Public surface

M1 has one public entry point, exported by src/main.pdx:

```
pub let pkg_main : (u64, u64) -> u64 !{mem} @{}
```

`pkg_main(argc, argv) -> exit_code`. The loader-supplied `_start` stub
reads argc/argv from the stack per the SysV/x86_64 convention and
calls `pkg_main` with them; `pkg_main`'s return value is the process
exit code passed to sys_exit (paideia-os syscall #60). The rest of the
public surface is the subcommand vocabulary described in
`design/argv-surface.md`.

The internal module layout is:

| Module            | File                          | Responsibility                             |
|-------------------|-------------------------------|--------------------------------------------|
| `PkgMain`         | `src/main.pdx`                | `pkg_main` entry; hands off to dispatch    |
| `Dispatch`        | `src/dispatch.pdx`            | subcommand recognizer + routing            |
| `PkgList`         | `src/list.pdx`                | `pkg list` body (M1: placeholder output)   |
| `PkgSubcommandsM1`| `src/subcommands_m1_stubs.pdx`| install / remove / verify / keys stubs     |
| `Print`           | `src/print.pdx`               | `sys_write(fd=1)` helper for stdout        |

The build manifest at `manifest.pdxproj` names every source file
paideia-as compiles into the binary and sets the entry symbol to
`PkgMain::pkg_main`. The caps manifest at `caps.decl` declares the M1
baseline cap set the loader's InitCap sidecar must seed for pkg to run.

## 3. Storage model (M1)

Every M1 module keeps its scratch state in `.bss` — the singleton
pattern from `src/user/tokenizer.pdx` and `src/user/dispatch.pdx` in
paideia-os. This is deliberate for bootstrap:

- One `pkg_main` call per process. Every pkg invocation is one
  subcommand; M1 does not need to build multiple parse contexts.
- Zero heap dependency. pkg predates any userspace allocator in the R49
  wave; every buffer is a static array.
- Trivial reset. `Dispatch::dispatch_reset` clears the subcommand-index
  slot; `PkgList::list_reset` clears the print-progress counter; the
  print helper is stateless.

The M1 print helper writes bytes directly through `sys_write(1, buf,
len)` (paideia-os syscall #1 fast-path for fd 1 / 2 per
`src/kernel/core/syscall/dispatch.pdx` L25). The buffer is
caller-owned; no `.bss` staging. This is enough for the header + the
placeholder line M1's `pkg list` produces. M3 adds a
libpdx-semantic-pipe wrapper that writes typed records instead of raw
text.

## 4. Subcommand dispatch

`pkg_main(argc, argv)` walks argv via libpdx-argv (calls
`ParsedArgs::reset()` then `Parser::parse_argv(argv, argc)`), then
inspects `ParsedArgs::pos_count`:

- `pos_count == 0` — print short usage on stdout; exit 2 (usage error).
  M1 emits a hand-rolled usage string; M3 wires this to `doc pkg --help`.
- `pos_count >= 1` — dispatch on `pos_ptrs[0]` (the subcommand name).

`Dispatch::dispatch_subcommand(subcmd_ptr) -> exit_code` byte-compares
the subcommand string against the five M1 vocabulary entries in this
order: install / remove / list / verify / keys. Matches route to the
corresponding body:

- `install` / `remove` / `verify` / `keys` — call the M1 stub in
  `PkgSubcommandsM1` which prints one line indicating the milestone at
  which the body lands (M2 for install/remove, M2 for verify, M3 for
  keys) and exits with the reserved code 3 (`EXIT_NOT_YET_IMPLEMENTED`).
- `list` — call `PkgList::pkg_list_body()` which prints the header line
  and the M1 placeholder line, then exits 0.

Unknown subcommands print `pkg: unknown subcommand '<name>'` on stderr
(via sys_write to fd 2) and exit 2. The subcommand recognizer uses the
inline byte-compare idiom from libpdx-argv's `--pdx-schema` well-known
check (see `src/parser.pdx` in libpdx-argv) — no `strcmp` helper exists
at the R49 substrate.

## 5. paideia-as compliance

Every module in this repo follows the constraints in
`design/kernel/paideia-as-conformance.md` (paideia-os) as they apply to
the userspace toolchain at v0.33+:

- Module names are PascalCase basename (`PkgMain`, `Dispatch`, `PkgList`,
  `PkgSubcommandsM1`, `Print`) — no directory prefix.
- No `test` mnemonic; every zero-check uses `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (or sign-extends
  from a negative i32); larger immediates go via r11 staging.
- Register `r11` is scratch and is never assumed live across a call.
- Byte loads use `xor rax, rax; mov_b rax, [ptr]` per the paideia-as
  #1248 mitigation pattern.
- SysV push/pop parity: rsp % 16 == 0 at every nested call site.

## 6. What M1 explicitly does not do

Called out here so a reader of M1 code does not mistake absence for bug:

- No signed-install. The `install` subcommand is a stub that exits 3
  (`EXIT_NOT_YET_IMPLEMENTED`). The pkg_install body lands at M2-003
  and requires KIND_PACKAGE_MANIFEST (M2-001), KIND_PACKAGE_REPO
  (M2-002), the paideia-as v0.33 ml_dsa_65_verify intrinsic, and the
  libpdx-elevate M3 flow.
- No real enumeration in `pkg list`. The M1 body prints a header
  ("installed packages:") and a placeholder ("(none — pkg list body
  wires to /system/packages/ enumeration at M2)"). M2 upgrades this to
  a live walk of the directory.
- No semantic-pipe emission. Every M1 subcommand writes raw text. M3-001
  binds `PackageManifest[]` on `pkg list`, `InstallProgressRecord[]` on
  `pkg install`, `KeyFingerprintRecord[]` on `pkg keys list`.
- No audit journaling. M3-003 wires libpdx-audit's pre-output journal
  invariant. M1 exits do not touch `/system/audit/user-events/`.
- No elevate-broker request. M3-004 wires libpdx-elevate on the install
  path. M1's caps.decl carries a commented-out placeholder for the
  KIND_ELEVATE_CHANNEL entry so the M3 patch is a diff-only unhide.
- No `--help` renderer through `doc`. M1 hand-rolls the usage string
  inline; M3-002 wires `doc pkg --help` after `doc` reaches M2 (see the
  cross-repo dep in the plan doc §5.1 M3 line).

## 7. Cross-repo dependencies

Per r49-r50-plan.md §5.1: **pkg.M1 depends on libpdx-argv.M1** for the
subcommand argv parse. All three of libpdx-argv's M1 issues (#1, #2, #3)
are closed as of 2026-08-21 per the memory index entry
`project_paideia_os_loop_shape`. No other cross-repo dep is required
at M1.

paideia-as ≥ v0.33 is required by the module encoder (the byte-compare
idiom in `Dispatch::dispatch_subcommand` needs the mov_b narrow-load
mnemonic and the @align attribute on .bss slots).

At M2 the following cross-repo deps activate:
- libpdx-cap.M2 (CAP_MANIFEST_MISSING / EXTRA verify at exec time).
- libpdx-semantic-pipe.M1 (schema pipe substrate).
- libpdx-argv.M2 (typed flag arguments for `--from-source`, etc.).
- paideia-os PdxFS readdir extension OR a text-index scheme in
  /system/packages/.
- paideia-as v0.33-crypto tag (ml_dsa_65_verify, argon2id_kdf, chacha20-
  poly1305 for the source-tree signature path).
