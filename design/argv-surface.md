# pkg — argv surface

**Wave:** R49  Milestone: M1
**Upstream design:** `design/tooling/r49-r50-plan.md` §5.1 in
[paideia-os](https://github.com/paideia-os/paideia-os); D3 (flag
grammar) + I3 (standard flag vocabulary) in
[`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§3-4.

## 1. Purpose

This document freezes the pkg command-line surface at M1. Every M2
body edit inherits this surface unchanged; adding a new subcommand or
a new flag is an M-diff to this document plus a code change gated on
the review of the diff.

The surface is deliberately narrow at M1: five subcommands, no
subcommand-scoped flags, five standard flags from the I3 vocabulary
(none of them wired to a body). Every real behaviour lands in later
milestones and inherits this surface as its call site.

## 2. Grammar

pkg follows D3 (long primary, short one-per-hyphen — no clustering)
via libpdx-argv. The invocation shape is:

```
pkg [--flag ...] <subcommand> [ARG ...]
```

- `--flag` accepts long-only well-known flags (see §4) and any
  additional subcommand-scoped long flags M2+ subcommands introduce.
  Values follow either `--flag=value` or `--flag value` (libpdx-argv
  lookahead rule; see `design/architecture.md` §4 in libpdx-argv).
- `-f` accepts single-letter short flags. `-abc` is rejected as
  `ERR_CLUSTERED_SHORT` — libpdx-argv M1-002 enforces this at parse
  time; the pkg exit code for that class of failure is 2 (usage).
- `<subcommand>` is the first positional argument (`ParsedArgs::pos_
  ptrs[0]`). It is required; a zero-positional invocation is a usage
  error handled by `Dispatch::dispatch_no_subcommand`.
- Additional positionals after the subcommand are subcommand-specific
  (`pkg install ls` — the second positional is the package name to
  install; `pkg remove ls` — same). M1 recognises the presence of
  additional positionals but does not consume them (the M2 body
  reads them from `ParsedArgs::pos_ptrs[1..pos_count]`).

## 3. Subcommand vocabulary (M1)

| Subcommand | Body module          | Body status | Exit codes           |
|------------|----------------------|-------------|----------------------|
| `install`  | `PkgSubcommandsM1`   | stub (M2)   | `3` (not yet impl)   |
| `remove`   | `PkgSubcommandsM1`   | stub (M2)   | `3` (not yet impl)   |
| `list`     | `PkgList`            | real (M1)   | `0` (ok)             |
| `verify`   | `PkgSubcommandsM1`   | stub (M2)   | `3` (not yet impl)   |
| `keys`     | `PkgSubcommandsM1`   | stub (M5)   | `3` (not yet impl)   |

The five vocabulary entries have distinct first bytes (i/r/l/v/k)
which lets `Dispatch::dispatch_subcommand` use a first-byte switch
+ per-branch inline byte-compare (same idiom as libpdx-argv's
`--pdx-schema` well-known check). Adding a sixth subcommand with a
first byte already in {i,r,l,v,k} — e.g. `refresh` — requires either
a nested compare on the second byte inside the existing branch or an
allocation from the remaining first-byte space. This will be
documented as it happens; M1 has no such collision.

### 3.1 Per-subcommand argument contracts (M1 recognisers; M2 bodies)

For each subcommand the M1 recognizer accepts any number of
additional positionals, and the M2 body enforces the real contract:

- `install <name>[@version]` — name of a package to install, optionally
  with `@version` (semver) selector. Default version resolves via the
  index at the default repo. M2 body enforces exactly one name
  positional; more than one is `EXIT_USAGE`.
- `remove <name>` — name of an installed package to remove. M2 body
  enforces exactly one name positional.
- `list` — no additional positionals (M2 body will accept `--available`
  to list-from-repo rather than list-installed; the flag is standard-
  vocabulary style, `--pdx-schema` gates the schema variant).
- `verify <name>` — name of an installed package to re-verify. Zero
  positionals verifies every installed package.
- `keys` (`list` | `add` | `remove` — nested subcommand). M5 lands the
  key-management surface; M1 stub prints a diagnostic naming M5.

## 4. Standard flag vocabulary (I3)

Every R49 tool implements the I3 vocabulary with identical semantics.
For pkg, the following long flags are recognised by libpdx-argv at M1
(the flag names appear in `ParsedArgs::flag_names[]`); the flag bodies
land in later milestones:

| Flag           | M1 status  | Wired at | Behaviour                                                            |
|----------------|------------|----------|----------------------------------------------------------------------|
| `--help`       | recognised | M3-002   | `doc pkg --help`; requires `doc` at M2                               |
| `--version`    | recognised | M2       | prints `pkg <version> (build <hash>) sig <fingerprint>`              |
| `--dry-run`    | recognised | M2       | previews the effect on install/remove without writing                |
| `--json`       | recognised | M3-001   | emit `PackageManifest[]` etc. as JSON on stdout, suppressing text    |
| `--schema`     | recognised | M3-001   | print the subcommand's output schema definition and exit             |
| `--verbose`    | recognised | M3-003   | additional diagnostic output on stderr, including audit-record ids   |
| `--pdx-schema` | recognised | M3-001   | libpdx-argv's well-known flag; sets `emit_schema=1` in ParsedArgs    |

At M1 all of these flags are recognised by libpdx-argv (they are long-
form and follow the grammar); pkg's own dispatch does not read from
`ParsedArgs::flag_names[]` at M1 and therefore does not enforce any
flag body. Passing `--json` at M1 succeeds at parse and has no
observable effect — the M3 body wires it. This is deliberate for
"first-runnable shape": the argv surface is stable, the flag bodies
fill in behind it without breaking existing call sites.

## 5. Exit codes

| Code | Meaning                                                       | M1 sites                                                            |
|------|---------------------------------------------------------------|---------------------------------------------------------------------|
| `0`  | success                                                       | `pkg list` (real body)                                              |
| `1`  | operation failed (reserved for M2+ bodies)                    | (none at M1)                                                        |
| `2`  | usage error (unknown subcommand, missing positional, parse)   | `Dispatch::dispatch_no_subcommand`, `Dispatch::dispatch_unknown`, `PkgMain` parse-fail |
| `3`  | subcommand recognised, body not yet implemented               | `PkgSubcommandsM1::pkg_*_stub` (install / remove / verify / keys)   |

`3` is deliberately reserved for this M1-only situation so a caller
can distinguish "the pkg vocabulary knows this word but has no body
yet" from "the pkg vocabulary does not know this word" (`2`). Once
every stub is replaced by a real body (M2 for install / remove /
verify; M5 for keys), exit code `3` becomes unused; M5 removes the
reservation.

## 6. Runnable example at M1

Given a freshly-bootstrapped pkg build:

```
$ pkg
usage: pkg <install|remove|list|verify|keys> [ARG]
$ echo $?
2

$ pkg list
installed packages:
  (none — pkg list wires to /system/packages/ readdir at M2)
$ echo $?
0

$ pkg install ls
pkg install: body not implemented at M1 (lands at M2)
$ echo $?
3

$ pkg banana
pkg: unknown subcommand 'banana'
$ echo $?
2
```

## 7. What this surface explicitly does not do at M1

- No environment-variable input. Every input comes from argv.
- No config file (`~/.pkgrc` etc.). Global defaults land at M4 with the
  test matrix that exercises them.
- No interactive prompts. The R49 P0 stance is that every pkg
  invocation is scriptable — an interactive prompt would break
  scriptability. Where a user must consent (elevate flow), it is
  handled by the founder's approver hop in libpdx-elevate, not by pkg
  itself.
- No colour output. pkg's diagnostics are plain text at every
  milestone; the `pdx-color` library is a post-R49 dep for tools that
  need it.
