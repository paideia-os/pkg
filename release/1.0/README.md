# release/1.0/ — pkg-1.0.0 release artefacts

**Wave:** R49  Milestone: M5  Issues: #16 (M5-001), #17 (M5-002)
**Version:** 1.0.0 (`manifest.pdxproj` version)
**Signing state at M5-close:** STUB (v0.33-crypto-kdf gate; see below)
**Design:** `design/release-1.0.md` (§1-§8)

## 1. Directory contents

| File                     | Purpose                                              | Diff-flip point                  |
|--------------------------|------------------------------------------------------|----------------------------------|
| `README.md`              | This file — index + release-time invariants          | (unchanged)                      |
| `manifest-layout.md`     | Byte-level layout of the emitted `manifest.pdxsig`   | v0.33-crypto-kdf: STUB → real    |
| `manifest-preview.hex`   | Hex dump of the STUB envelope for review at M5-close | v0.33-crypto-kdf: STUB fills → key/sig bytes |
| `keys-fingerprints.md`   | `paideia_root_pk` + `pkg-author` fingerprints (STUB) | v0.33-crypto-kdf: `PENDING_V033` → hex |
| `gen-manifest.sh`        | POSIX-sh generator that emits `manifest.pdxsig` + `pkg.tar` | v0.33-crypto-kdf: `PDX_STUB_SIG=0` becomes default |

The generator is idempotent (given the same source tree and same
`PDX_STUB_SIG` mode) and reproducible (byte-for-byte across hosts).
Reproducibility depends on every packaged member being either a
committed file or a deterministic derivation from one; `../../deps.list`
(repo root, ENH-011 #36) closes the one gap that existed at M5-close --
before it landed, `deps.list` was regenerated from `manifest.pdxproj`'s
`deps:` block at release time, coupling a hashed, packaged artefact to
that block's comment formatting rather than to a committed file.

## 2. Invocation

```
release/1.0/gen-manifest.sh <path-to-pkg-binary> <out-dir>
```

At M5-close, from the repo root, the canonical invocation is:

```
paideia-as build manifest.pdxproj -o build-out/pkg
release/1.0/gen-manifest.sh build-out/pkg build-out/pkg-1.0.0
```

This produces:

```
build-out/pkg-1.0.0/
  pkg.tar                    -- POSIX ustar; bin/pkg + caps.decl + deps.list +
                                doc/pkg.pdxdoc + manifest.pdxsig
  manifest.pdxsig            -- 64B header + 4477B body + 6594B sigblock (STUB)
  manifest-report.txt        -- byte counts + sha3 hash + sig mode
  stage/                     -- staging subtree (mirrors the packaged layout)
```

`build-out/pkg-1.0.0/` is what the mirror-push protocol
(`release/mirror-push.sh` — issue #17 / M5-002) uploads to
`pkgs.paideia-os/pkg/1.0.0/`.

## 3. Signing state

At M5-close the manifest carries STUB bytes for every field the
paideia-as v0.33-crypto-kdf substrate would populate:

- Every ML-DSA-65 signature (2 × 3293 B) is filled with the ASCII
  pattern `PDX_SIG_PENDING_V033-` (repeated).
- Every ML-DSA-65 public key (2 × 1952 B) is filled with
  `PDX_PK_PENDING_V033-`.
- Every 32-B fingerprint (`AUTHOR_FPR`, `ROOT_FPR`) is filled with
  `PDX_FPR_PENDING_V033-`.
- Every 32-B sha3-256 hash (`CAPS_DECL_HASH`, `DEPS_LIST_HASH`,
  `body_sha3_256`, per-file `sha3_256` in FILE_INVENTORY) is filled
  with `PDX_H3_PENDING_V033-`.

`pkg install pkg` against a STUB-signed manifest refuses at the
verify seam (`ManifestCodec::mc_verify_signatures` returns
`MC_VERIFY_STUB = 0xFFFFEB71`). This is the same halt path the M4
test matrix pins (see `tests/m4-001-sig-mismatch/expected/`).

When v0.33-crypto-kdf lands:

1. `paideia-as` gains a `sign` subcommand exposing the ML-DSA-65
   signing intrinsic.
2. Re-run `release/1.0/gen-manifest.sh` with `PDX_STUB_SIG=0` (or
   unset — the script auto-detects when `paideia-as sign --help`
   succeeds).
3. The emitted `manifest.pdxsig` diff-flips every STUB fill to real
   bytes; every offset and length in `manifest-layout.md` §2-§5
   holds.
4. `pkg install pkg` succeeds end-to-end (given paideia-os
   R48-PREP-005 elevate-broker also closed).

## 4. Reproducibility

Given the same source tree at commit hash `<H>` and the same
`PDX_STUB_SIG` mode, `gen-manifest.sh` produces byte-for-byte
identical `manifest.pdxsig` output. This is the invariant the mirror
consumer relies on for `pkg verify pkg` — the manifest downloaded
from `pkgs.paideia-os/pkg/1.0.0/manifest.pdxsig` must match what
`gen-manifest.sh` produces locally.

Timestamp discipline: `created_unix_secs` in the header is a
version-scoped constant (`1787961600` for 1.0.0 = 2026-08-22T00:00:00
UTC), not a per-invocation timestamp. See
`release/1.0/manifest-layout.md` §6 for the reproducibility
invariants.

## 5. Cross-milestone references

- **M1-003** — `design/manifest-format.md`: authoritative byte layout
  (§3-§5). The generator emits bytes conforming to that spec.
- **M2-001** — `KIND_PACKAGE_MANIFEST = 0x193`: the derived kind
  `pkg install` mints once the manifest verifies.
- **M2-003** — `src/manifest_codec.pdx`: the parser + verify seams
  that `pkg install` and `pkg verify` invoke against a manifest
  emitted by this generator.
- **M3-002** — `src/pipe_schemas.pdx`: `PackageManifest[]` schema
  bound at `pkg list` — the 1.0.0 manifest is one of the records
  the schema emits.
- **M4-001** — `tests/m4-001-sig-mismatch/`: sig-mismatch matrix
  against fixtures generated with corrupted STUB bytes; the same
  refusal path a STUB-signed 1.0.0 manifest triggers.

## 6. Mirror push (M5-002)

Uploading this directory's `build-out/pkg-1.0.0/` output to the
public mirror is the M5-002 issue's scope. See
`release/mirror-push.md` for the protocol, and
`release/mirror-push.sh` for the driver.
