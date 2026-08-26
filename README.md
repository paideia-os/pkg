# pkg

paideia-os package manager (dual-signed manifests, elevate-integrated)

## Synopsis

```
pkg <subcommand> [ARG]

pkg install <name>
pkg remove  <name>
pkg list
pkg verify
pkg keys
```

`<subcommand>` is the first positional argument (`ParsedArgs::pos_ptrs[0]`).
A zero-positional invocation prints the usage line and exits 2:

```
usage: pkg <install|remove|list|verify|keys> [ARG]
```

`Dispatch::dispatch_subcommand` recognises exactly five names by inline
byte-compare — `install`, `remove`, `list`, `verify`, `keys` — chosen so
their first bytes (`i`/`r`/`l`/`v`/`k`) are distinct. Anything else prints
`pkg: unknown subcommand '<name>'` on stderr and exits 2.

## Description

pkg is the R49-wave package manager: the tool that installs every other
tool in the paideia-os tooling ecosystem, and the one that bootstraps
itself. It is written in `.pdx` and built by `paideia-as` (≥ 0.33) into a
single `build-out/pkg` binary plus a `build-out/pkg.caps` sidecar.

**Dual-signed manifests.** "Dual-signed" means *two distinct signers, one
algorithm*. Every package ships a `manifest.pdxsig` whose 64-byte header
(`ManifestCodec::mc_read_header`) reserves two separate public-key lengths —
`pubkey_len_author` at `+48` and `pubkey_len_root` at `+52` — and whose
signature block is exactly `2 × (4B length + signature)`. Both signatures
are **ML-DSA-65** (NIST level 2) computed over the same byte range,
`header || body`. The first is the *package author's*; the second is the
*paideia_root_pk*, the project's single per-release-cycle re-sign key.
`mc_verify_signatures` verifies author then root, and a final check
cross-references the manifest's `ROOT_FPR` tag against the machine-local
fingerprint at `/system/keys/paideia_root_pk.fpr` — so a valid root
signature made by *some other* root key is still refused. The two keys are
deliberately distinct: a compromised author key does not compromise the
mirror. Verification is all-or-nothing; no output byte reaches the user
until both signatures verify.

**Elevate integration.** pkg never carries ambient write authority on
`/pkgs`. Its `caps.decl` baseline grants read-only authority on
`/system/packages/` and nothing more. `install` and `remove` both
elevate — install between the manifest-mint and transaction-open
stages, remove before its (currently seam-gated) lookup stage — via
the shared `pkg_elevate_request_pdxfs_write_pkgs` wrapper, which asks
`svc.elevate-broker` (over `KIND_ELEVATE_CHANNEL`) for
`KIND_PDXFS_FILE(write, /pkgs)` with a **60-second** window
(`PE_DURATION_60S_NS = 60000000000`). The broker returns a `parent_slot`
in `[1, 256)`, which is threaded into `TxnClient::txn_open`; every failure
collapses to slot `0`, and `txn_open` then refuses with
`PXT_MINT_BAD_PARENT`. `list`, `verify` and `keys` never elevate — they
never mutate `/pkgs`.

**Audit-first.** Every subcommand body calls `AuditWire::audit_begin_op`
*before* any byte reaches stdout or stderr. If the audit broker is
unavailable the subcommand emits no output of its own and exits 4 — pkg
refuses to act un-journalled rather than acting silently.

**Substrate state at 1.0.0.** Several verification and filesystem
primitives that pkg calls are not yet present in the surrounding system,
so the pipelines are wired end to end but halt at named seams. See
[Examples](#examples) for exactly what each subcommand does today, and
`CHANGELOG.md` §"Known limitations" for the open gates.

## Options

`pkg_main` reads `ParsedArgs::flag_names[]` for exactly two flags —
`--help` and `--version` (ENH-006 #31) — via `PkgMain::pkg_meta_flag_check`,
a direct byte scan (pkg registers no `FlagSpec` entries, so there is no
id-based lookup to hook). Both short-circuit before subcommand dispatch,
work with or without a positional argument, and exit 0. Every other
subcommand body still consumes only `ParsedArgs::pos_count` and
`ParsedArgs::pos_ptrs[]`. Flags are still *parsed* by libpdx-argv
(long-form `--flag`, `--flag=value` or `--flag value`; single short flags
`-f`; clustered `-abc` is rejected as `ERR_CLUSTERED_SHORT`, surfacing as
exit 2), but no other flag has a body wired at 1.0.0. The reserved I3
vocabulary is listed in `design/argv-surface.md` §4 and `doc/pkg.pdxdoc`;
passing any of it parses cleanly and has no observable effect.

What *is* enforced per subcommand is positional arity.

### install

| Argument | Type | Default | Description |
|---|---|---|---|
| `<name>` | positional 1 | *required* | Package to install. `pos_count` must be exactly 2 and `pos_ptrs[1]` non-null, else `usage: pkg install <name>` on stderr and exit 2. |

### remove

| Argument | Type | Default | Description |
|---|---|---|---|
| `<name>` | positional 1 | *required* | Installed package to remove. Same arity gate; violation prints `usage: pkg remove <name>` and exits 2. |

### list

Takes no arguments. Extra positionals are ignored — `pkg_list_body` never
reads `pos_count`.

### verify

Takes no arguments today. `pkg_verify_stub` journals the invocation, prints
`pkg verify: body not implemented at M1 (lands at M2)`, and exits 3.

### keys

Takes no arguments today. `pkg_keys_stub` journals the invocation, prints
`pkg keys: body not implemented at M1 (lands at M5)`, and exits 3.

## Semantic pipe output

pkg binds fd 1 to a schema before emitting records, via
libpdx-semantic-pipe. Both schema-hash blobs are 32 bytes: a
human-readable identifier NUL-padded to `SP_SCHEMA_HASH_SIZE`.

**`PackageManifest` — `pdxsig.pkg.pmf.v1`** — emitted by `pkg list`.
Variable-length body, `8 + name_len` bytes:

| Offset | Size | Field | Notes |
|---|---|---|---|
| `+0` | 8 | `name_len` | u64; must be ≤ 256 (`PS_PMF_NAME_MAX`) |
| `+8` | `name_len` | `name` | raw bytes, no NUL terminator |

**`InstallProgressRecord` — `pdxsig.pkg.ipr.v1`** — emitted by
`pkg install`, one record per pipeline stage. Fixed 16-byte body:

| Offset | Size | Field | Notes |
|---|---|---|---|
| `+0` | 8 | `step_id` | u64; see step table below |
| `+8` | 8 | `rc` | u64; `MC_*` / `PMF_*` / `TXN_*` code, `0` == OK |

`step_id` values (`INSTALL_STEP_*`), emitted in this order:
`1` HEADER, `2` HASH, `3` VERIFY, `4` MINT, `5` TXN_OPEN, `7` COMMIT.
(`0` NONE and `6` EXTRACT are defined but never emitted — the extract
stage is a seam that falls through to commit.)

Emit failures are non-fatal: the text side of stdout renders either way.
If the `PackageManifest` bind itself fails, `pkg list` prints
`pkg list: PackageManifest schema bind failed (see errno on rc)` to stderr
and continues.

## Exit codes

There is no `exit_map.pdx`; the codes are defined in `Dispatch` and reused
across every body.

| Code | Name | Meaning |
|---|---|---|
| `0` | `EXIT_OK` | Success. |
| `1` | `EXIT_OP_FAIL` | A pipeline step refused. The failing step names itself on stderr. |
| `2` | `EXIT_USAGE` | argv parse error, no subcommand, unknown subcommand, or wrong positional arity. |
| `3` | `EXIT_NOT_YET_IMPLEMENTED` | Recognised subcommand with no body yet (`verify`, `keys`). |
| `4` | `AUDIT_EXIT_BROKER_FAIL` | The audit broker was unavailable, so the operation refused before any output was emitted and nothing was journalled. Security-relevant: distinct from `3` since ENH-003 (#28) so a caller cannot mistake "un-auditable" for "not yet implemented". |

Code `3` is deliberately distinct from `2` so a caller can tell "pkg knows
this word but has no body" from "pkg does not know this word". Code `4`
is deliberately distinct from `3` for the same reason: a caller must be
able to tell "the subcommand refused" from "nothing was journalled".

## Capabilities

Entry point and subcommand bodies, verbatim from source:

```
pkg_main          : (u64, u64) -> u64 !{mem, sysreg} @{}
pkg_install_body  : ()         -> u64 !{mem, sysreg} @{cap, sched}
pkg_remove_body   : ()         -> u64 !{mem, sysreg} @{cap, sched}
pkg_list_body     : ()         -> u64 !{mem, sysreg} @{cap, sched}
pkg_verify_stub   : ()         -> u64 !{mem, sysreg} @{cap, sched}
pkg_keys_stub     : ()         -> u64 !{mem, sysreg} @{cap, sched}
```

Loader-seeded baseline, verbatim from `caps.decl`:

```
requires:
  - KIND_USER (self)
  - KIND_IPC_ENDPOINT (invoke)
  - KIND_PDXFS_FILE (read, /system/packages/)
  - KIND_ELEVATE_CHANNEL (invoke, svc.elevate-broker)   # 0x191 R48.M7

declares_output_schemas:
  - PackageManifest        # pdxsig.pkg.pmf.v1 -- emitted by `pkg list` (M3-001)
  - InstallProgressRecord  # pdxsig.pkg.ipr.v1 -- emitted per stage by `pkg install` (M3-002)
```

Write authority on `/pkgs` is **not** in this list. It is acquired
per-install through the elevate broker and expires with the 60-second
window.

## Examples

The outputs below are the pinned 1.0.0 behaviour from
`tests/m4-003-qemu-smoke/expected/full-matrix.txt`.

Install a package. The staging read into `_install_staging` is not yet
wired to a file, so the zero-filled buffer fails the `"pdxsig\0\0"` magic
check and the pipeline refuses at the header stage:

```
$ pkg install libpng
pkg install: staging manifest for package 'libpng'
pkg install: header parse failed (see errno)      # stderr
$ echo $?
1
```

List installed packages. Emits one `PackageManifest` record on the typed
side of stdout alongside the text:

```
$ pkg list
installed packages:
  (none — pkg list wires to /system/packages/ readdir at M2)
$ echo $?
0
```

Remove a package. `KIND_PDXFS_FILE` has no readdir at this substrate, so
the lookup stage refuses before any transaction opens — nothing is
written, nothing needs rolling back:

```
$ pkg remove libpng
pkg remove: removing name 'libpng'
pkg remove: /system/packages/ readdir unavailable at M2 (R42)   # stderr
$ echo $?
1
```

Unknown subcommand and missing subcommand both exit 2:

```
$ pkg banana
pkg: unknown subcommand 'banana'
$ pkg
usage: pkg <install|remove|list|verify|keys> [ARG]
$ echo $?
2
```

Re-verify an installed package's signatures:

```
$ pkg verify
pkg verify: body not implemented at M1 (lands at M2)
$ echo $?
3
```

`--help` and `--version` (ENH-006 #31) work with no subcommand present
and exit 0 — the only two flags with a real body at 1.0.0:

```
$ pkg --version
pkg 1.0.0
$ echo $?
0
$ pkg --help
usage: pkg <install|remove|list|verify|keys> [ARG]
  install <name>  fetch, dual-verify (ML-DSA-65), and install a package
  remove <name>   remove an installed package (writes an undo record)
  list            list installed packages
  verify <name>   re-verify an installed package signatures
  keys            show the trusted signing keys
  --help          show this message
  --version       show the version
$ echo $?
0
```

## Audit records

Every subcommand journals to `/system/audit/user-events/` through
`AuditWire` before emitting output. The wire pattern each body follows:

```
audit_id = audit_begin_op(OP_NAME_PTR, OP_ARGS_PTR)
if audit_id == 0: exit 4   # AUDIT_EXIT_BROKER_FAIL (ENH-003 #28)
... subcommand output ...
audit_record_op_output(audit_id, SCHEMA_HASH_PTR)   # skipped by text-only bodies
audit_commit_op(audit_id, exit_code)
```

`audit_record_op_output` is called once by every subcommand that emits
a schema-typed record (ENH-012 #37): `list` records
`pdxsig.pkg.pmf.v1` after a successful `PackageManifest` emit;
`install` records `pdxsig.pkg.ipr.v1` right after the
`InstallProgressRecord` schema bind. `remove`, `verify` and `keys`
emit no schema records at 1.0.0 and skip the call, so their audit
entries carry an empty `output_schema` / `output_hash` column rather
than an absent one.

`OP_NAME_*` are NUL-terminated `.rodata` strings and form the `op_name`
column a supervisor filters on — they are a public interface and stay
stable across milestones:

| Subcommand | Constant | Bytes |
|---|---|---|
| `install` | `OP_NAME_INSTALL` | `"install\0"` |
| `remove` | `OP_NAME_REMOVE` | `"remove\0"` |
| `list` | `OP_NAME_LIST` | `"list\0"` |
| `verify` | `OP_NAME_VERIFY` | `"verify\0"` |
| `keys` | `OP_NAME_KEYS` | `"keys\0"` |

`audit_commit_op` receives the exit code the caller will actually see, so
the ledger records outcomes rather than intentions. `audit_begin_op` fires
*before* the positional-arity check, so even a usage error is journalled.
When the broker is unavailable, `audit_begin_op` returns 0, prints
`pkg: audit broker unavailable -- refusing output per I5 (M3-003)` on
stderr, and the body returns 3 without committing anything.

## See also

- [libpdx-argv](https://github.com/paideia-os/libpdx-argv) — argv parser; supplies `ParsedArgs::pos_count` / `pos_ptrs[]`
- [libpdx-elevate](https://github.com/paideia-os/libpdx-elevate) — elevate-broker client behind the 60s `/pkgs` write window
- [libpdx-cap](https://github.com/paideia-os/libpdx-cap) — capability marshalling and `caps.decl` verification
- [shell](https://github.com/paideia-os/shell) — the shell that invokes pkg

## License

MIT — see LICENSE.
