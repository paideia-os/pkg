# pkg — on-disk package manifest format

**Wave:** R49  Milestone: M1  Issue: #3 (pkg.M1-003)
**Upstream design:** [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6.3 (repository model) + §D4 (install model — dual-signed binary
packages + source fallback); [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 (pkg per-tool architectural summary + KIND references).
**paideia-as crypto floor:** v0.33-crypto-kdf (ML-DSA-65 verify,
Argon2id-KDF, ChaCha20-Poly1305 AEAD).

## 0. Reading order

- §1 — the design pillars this format enforces (D4, D1.a, I5, I6).
- §2 — the on-disk file tree that ships a package.
- §3 — the `manifest.pdxsig` file: layout, sections, signing
  envelope, dual-signature verification order.
- §4 — the wire-format-level byte layout for each section, with the
  ML-DSA-65 signature-block spec.
- §5 — verification algorithm (canonical form; both sigs verify
  before any bytes reach the user).
- §6 — evolution rules: how the format grows across R49-R51+ without
  breaking already-signed packages.
- §7 — what M2 wires and what stays for M3-M5.

## 1. Design pillars

The format is a *codec*, not a schema. It has to satisfy four
project-level constraints simultaneously:

- **D4 (install model).** Every tool ships as a *signed* package. The
  authoritative signature set is a *dual* signature: the tool
  author's key (`author_pk`) AND the Paideia manifest re-sign key
  (`paideia_root_pk`, from R32). Neither alone is enough for
  `pkg install` to accept the package. This is the same discipline
  D1.a specifies for driver blob policies elsewhere in the project.
- **I5 (undo).** Every install writes an undo record to
  `/journal/pkg/` (per `design/tooling/plan.md` §6.4). The manifest
  must expose enough per-file state (path, mode, sha3-256 hash,
  pre-image link if any) that `undo pkg install <name>` can
  faithfully reverse the effect. Reversibility is a manifest
  obligation, not a filesystem one.
- **I6 (caps-declared).** Every tool's `caps.decl` ships INSIDE the
  package — it is the callee's authoritative statement of the cap
  set the loader's InitCap sidecar seeds at exec. libpdx-cap's
  cap_manifest_verify (M2) reads it. The manifest binds the
  caps.decl hash into the signed envelope so a caps.decl
  substitution attack is a signature-verification failure.
- **Bootstrappable (D4 bootstrap).** The pkg binary itself is
  distributed as a package (see the bootstrap chain in
  `design/tooling/plan.md` §6.5). The format therefore must be
  parseable by pkg itself when pkg is being installed for the first
  time by the bootstrap `paideia-as build /tmp/pkg.pdx -o /tmp/pkg`
  invocation; recursive-parse cases motivate the byte-oriented
  layout in §4 rather than a self-referential schema.

## 2. On-disk file tree

A package repository is a static file tree served over HTTP(S). At
the repository level (per `design/tooling/plan.md` §6.3):

```
pkgs.paideia-os/
  index.pdxsig                     ← top-level {name, version, hash} table
  <name>/
    <version>/
      pkg.tar                       ← the package archive (see below)
      manifest.pdxsig               ← dual-signed manifest for this pkg
```

Once `pkg install <name>` completes, the local install tree at
`/pkgs/<name>-<version>/` looks like:

```
/pkgs/<name>-<version>/
  bin/<binary>                     ← the elaborated ELF-like Paideia executable
  lib/*.so                         ← shared-library dependencies (if any)
  doc/*.pdxdoc                     ← the doc tool consumes these for --help
  caps.decl                        ← callee's canonical cap manifest
  manifest.pdxsig                  ← the same manifest that shipped in the repo
```

The `pkg.tar` archive is a POSIX tar with the *contents* of
`/pkgs/<name>-<version>/` — pkg's install body untars into
`KIND_PDXFS_TXN` scope, runs the manifest verification (§5), and
either commits the TXN (atomic rename into `/pkgs/`) or aborts.
`manifest.pdxsig` sits inside the tar AND is served alongside it in
the repository — both copies must be byte-identical, and the install
body cross-checks this. The pre-tar copy exists so a `pkg verify`
against a local install can re-verify without touching the network.

## 3. `manifest.pdxsig` — high-level layout

`manifest.pdxsig` is a single file split into three sections:

```
+----------------------------------+   offset 0
|  header  (fixed 64 bytes)        |
+----------------------------------+   offset 64
|  body    (variable, KV records)  |
+----------------------------------+   offset 64 + body_len
|  sigblock (2× ML-DSA-65 sigs)    |
+----------------------------------+   offset 64 + body_len + sigblock_len
```

The **header** is a fixed-size (64-byte) block that names the format
version, the body length, and the sigblock length. It is the only
part of the file whose byte offset is known before the file is read.

The **body** is a sequence of typed KV records (§4.2). It carries
everything a `pkg install` needs before touching the tar:
- Package identity (`name`, `version`, semver).
- Per-file inventory (path, mode, sha3-256, pre-image if the file
  replaces one under `/bin/`).
- Cap manifest hash (sha3-256 of `caps.decl`).
- Dependency list hash (sha3-256 of `deps.list`).
- Author + Paideia-root public keys, key fingerprints, expiry.
- Provenance metadata (repo URL, build reproducer stamp, paideia-as
  toolchain version used).

The **sigblock** contains exactly two ML-DSA-65 signatures — the
author signature and the paideia-root signature — over the
concatenation `header || body`. Both are computed identically over
the same byte range; they differ only in the signing key.

## 4. Byte-level layout

### 4.1 Header (64 bytes)

All integer fields are little-endian.

| Offset | Size | Field                | Semantics                                         |
|--------|------|----------------------|---------------------------------------------------|
| 0      | 8    | `magic`              | ASCII `"pdxsig\0\0"` — quick reject on wrong file |
| 8      | 4    | `format_version`     | `1` at M1; bumped by additive change per §6      |
| 12     | 4    | `header_flags`       | reserved; must be `0` at M1                       |
| 16     | 8    | `body_len`           | length in bytes of the body section               |
| 24     | 8    | `body_sha3_256_lo`   | low  16 bytes of sha3-256(body) (halves are for   |
| 32     | 8    | `body_sha3_256_hi`   | high 16 bytes of sha3-256(body)  → 32 bytes total)|
| 40     | 8    | `sigblock_len`       | length in bytes of the sigblock                   |
| 48     | 4    | `pubkey_len_author`  | length in bytes of author public key (2*ML-DSA-65)|
| 52     | 4    | `pubkey_len_root`    | length in bytes of paideia-root public key        |
| 56     | 8    | `created_unix_secs`  | manifest creation time (seconds since epoch)      |

Rationale for putting `body_sha3_256` in the header: verification (§5)
loads the header first, then decides whether to read the body at all
(a hash mismatch fails-fast without consuming bandwidth). The pair of
`_lo`/`_hi` u64 fields lets the parser stay in u64 loads — no wide-
integer library needed for a hash comparison in the pkg install body.

### 4.2 Body — KV records

The body is a sequence of typed key-value records. Each record is:

```
+--------+--------+----------------------+
| kv_tag | kv_len | kv_value (kv_len B)  |
+--------+--------+----------------------+
    u16      u16      bytes
```

`kv_tag` is one of the tags listed below. `kv_len` is the value byte
count (up to 65535 — larger values split across a repeated tag).
`kv_value` is tag-specific. Unknown tags are IGNORED by pkg install
(forward-compat: §6). The body ends when the parser reaches
`header.body_len` bytes.

**Tag registry (M1):**

| Tag    | Name                | Value shape                                    |
|--------|---------------------|------------------------------------------------|
| 0x0001 | `PKG_NAME`          | UTF-8 (no NUL); e.g. `"ls"`                    |
| 0x0002 | `PKG_VERSION`       | UTF-8 semver; e.g. `"1.2.3"`                   |
| 0x0003 | `PKG_REPO_URL`      | UTF-8 URL of the source repo                   |
| 0x0004 | `PAIDEIA_AS_VER`    | UTF-8 semver of the paideia-as build toolchain |
| 0x0010 | `AUTHOR_PUBKEY`     | binary ML-DSA-65 pubkey (1952 bytes @ level 2) |
| 0x0011 | `AUTHOR_FPR`        | 32-byte sha3-256 fingerprint of `AUTHOR_PUBKEY`|
| 0x0012 | `AUTHOR_EXPIRY`     | u64 unix seconds (0 = never)                   |
| 0x0020 | `ROOT_PUBKEY`       | binary ML-DSA-65 pubkey (paideia_root_pk)      |
| 0x0021 | `ROOT_FPR`          | 32-byte sha3-256 fingerprint of `ROOT_PUBKEY`  |
| 0x0022 | `ROOT_EXPIRY`       | u64 unix seconds (0 = never)                   |
| 0x0030 | `CAPS_DECL_HASH`    | 32-byte sha3-256 of the packaged `caps.decl`   |
| 0x0031 | `DEPS_LIST_HASH`    | 32-byte sha3-256 of the packaged `deps.list`   |
| 0x0040 | `FILE_INVENTORY`    | one per file — see §4.3 below                  |
| 0x00F0 | `BUILD_REPRODUCER`  | UTF-8 free-form build-repro attribution        |

Tag high bit reserved for future use (0x8000+ tags are refused by
pkg install at M2 rather than ignored — pkg install treats a set
high bit as a version-incompatible marker; §6 formalises).

### 4.3 File-inventory record (`FILE_INVENTORY`, tag 0x0040)

One record per file the package installs into `/pkgs/<name>-<version>/`.

```
+------+------+------+------+--------------------+----------------------+----------------------------+
| kv_tag=0x0040 | kv_len | mode | path_len | sha3_256 (32B)                                     |
+---------------+--------+------+----------+-----+----------------------+----------------------------+
                                                | path (path_len B; relative to install root, no NUL) |
                                                +-----------------------------------------------------+
```

Layout inside `kv_value`:

| Offset in kv_value | Size | Field       | Semantics                                       |
|--------------------|------|-------------|-------------------------------------------------|
| 0                  | 4    | `mode`      | POSIX mode bits + file-type nibble              |
| 4                  | 4    | `path_len`  | byte length of the path (utf-8)                 |
| 8                  | 32   | `sha3_256`  | sha3-256 of the file's bytes                    |
| 40                 | var  | `path`      | relative path (no leading `/`, no `..`)         |

The M2 pkg install body walks every FILE_INVENTORY record, extracts
the file from `pkg.tar`, checks its bytes hash to `sha3_256`, and
places it under `/pkgs/<name>-<version>/<path>`. Any mismatch is a
verification failure that aborts the enclosing KIND_PDXFS_TXN.

The `caps.decl` and `deps.list` files ARE part of the file inventory
(their FILE_INVENTORY records name them); their standalone
`CAPS_DECL_HASH` / `DEPS_LIST_HASH` records exist as a fast-lookup so
pkg install can validate the two files' hashes without walking the
whole inventory a second time.

### 4.4 Sigblock (2 × ML-DSA-65 signature)

The sigblock is exactly two ML-DSA-65 signatures back-to-back:

```
+----------------------+----------------------+
| author_sig  (var)    | root_sig  (var)      |
+----------------------+----------------------+
```

Each signature is preceded by a 4-byte little-endian length prefix so
the parser can jump the boundary in one load. ML-DSA-65 at NIST
security level 2 produces signatures of 3293 bytes each; the length
prefix accommodates future rotation to a level-3 or level-5 variant
without changing this layout.

```
+---------------+--------------+---------------+--------------+
| sig_len_author| author_sig   | sig_len_root  | root_sig     |
+---------------+--------------+---------------+--------------+
     u32          sig_len_author      u32         sig_len_root
```

Both signatures cover `header || body` — every byte from offset 0 to
`64 + header.body_len - 1` of the file, inclusive. The sigblock
itself is NOT part of the signed range (a signature over its own
bytes is undefined).

## 5. Verification algorithm

`pkg install` and `pkg verify` share the same verification routine.
Given a `manifest.pdxsig` at path `M`:

```
1. Open M; load the first 64 bytes into a header struct.
2. Check header.magic == "pdxsig\0\0"; else PKG_ERR_MAGIC.
3. Check header.format_version == 1; else PKG_ERR_VERSION.
   (M2 may accept newer minor versions per §6.)
4. Check header.body_len < BODY_LEN_MAX (M2 constant, ≤ 1 MiB); else
   PKG_ERR_BODY_TOO_LARGE.
5. Load exactly header.body_len bytes at offset 64 into a body buffer.
6. Compute sha3-256(body); compare against
   (header.body_sha3_256_lo || header.body_sha3_256_hi);
   else PKG_ERR_BODY_HASH.
7. Parse body KV records. Reject any tag with high bit set;
   reject duplicates of any of the singleton tags (all except
   FILE_INVENTORY); require presence of PKG_NAME, PKG_VERSION,
   AUTHOR_PUBKEY, ROOT_PUBKEY, CAPS_DECL_HASH.
8. Load sigblock at offset 64 + header.body_len; sigblock length
   must match header.sigblock_len.
9. Verify author_sig against AUTHOR_PUBKEY over (header || body)
   using ml_dsa_65_verify (paideia-as v0.33 intrinsic);
   else PKG_ERR_AUTHOR_SIG.
10. Verify root_sig against ROOT_PUBKEY over the same byte range;
    else PKG_ERR_ROOT_SIG.
11. Check the ROOT_FPR against the local paideia_root_pk fingerprint
    (`/system/keys/paideia_root_pk.fpr`); else PKG_ERR_ROOT_FPR.
12. Return PKG_OK.
```

Step 11 catches the "an attacker with a valid root_sig from a
different root key" case — pkg install trusts exactly one root key,
and that key's fingerprint is stamped into `/system/keys/` at
bootstrap. The founder's user (per R48) is the only user allowed to
rotate this fingerprint; the elevate policy at
`src/kernel/core/user/elevate_policy.pdx` in paideia-os gates the
rotation.

Verification is **all-or-nothing**: no output byte reaches the user
until both signatures verify. This is D4 audit-first as it applies to
`pkg install` — the audit journal records the outcome, not a partial
progress trail.

## 5.5 ENH-001 (#26): this format is the survivor

The open "R70 — pkg MVP" milestone (#18-#25) originally proposed a
distinct `<name>-<version>.pdxpkg` JSON-ish manifest with a single
"stub-to-trust-local" signature, replacing this format. `design/
enh-001-reconciliation.md` (2026-08-25) settled that conflict: this
`manifest.pdxsig` codec is kept, unchanged, as the one trust-carrying
manifest format. R70's local-filesystem-path repo idea is reoriented
to be an additive *source* pkg resolves `install <name>` against
ahead of the network mirror -- it still resolves to a `manifest.pdxsig`
+ `pkg.tar` pair that this codec reads and dual-verifies exactly as
described above. `<name>-<version>.pdxpkg` survives only as the repo
*index entry* format (a pointer record), not a manifest.

## 6. Evolution rules

The format is designed to grow across R49-R51+ without breaking
already-signed packages:

- **Additive tags** (new KV tag numbers) are safe. Old pkg
  installations ignore unknown tags (§4.2). New pkg installations
  read them. Bumping `format_version` is NOT required for a tag
  addition; the tag registry (§4.2) grows monotonically.
- **Semantic-change tags** (a change to what an existing tag means)
  are NOT safe. They require a `format_version` bump AND a M-plan
  entry documenting the compatibility break. M1 sets
  `format_version = 1`; M-plans thereafter set it as needed.
- **Signature-block extensions** (a third signature key, e.g. a
  distributor sig alongside author + root) require a
  `header_flags` bit that flags the sigblock as extended, plus a
  format_version bump. The M1 sigblock layout is exactly 2 signatures.
- **Crypto-primitive rotation** (post-quantum-agility). Rotating from
  ML-DSA-65 to a higher-level variant (level 3 or 5) is a
  `format_version` bump; both AUTHOR_PUBKEY and ROOT_PUBKEY tags
  gain an implicit length that identifies the primitive. Rotating to
  a wholly different primitive (Falcon, SLH-DSA) is a new tag
  number (`AUTHOR_PUBKEY_FALCON` = 0x0013 etc.) + a
  `format_version` bump.
- **High-bit-set tags** (0x8000+) are REFUSED by pkg install at parse
  time. This gives the format an escape hatch for a future
  hard-incompatible change without a format_version bump.

## 7. Milestone binding

- **M1 (this doc).** Format spec at v1. No codec, no verifier — just
  the byte-level layout every downstream milestone binds to.
- **M2 (issues #4-#6).** The codec: `manifest_read`, `manifest_write`,
  `manifest_verify` (with ml_dsa_65_verify), and the KIND_PACKAGE_
  MANIFEST derived-kind allocation at 0x193. The `pkg_install` body
  invokes the verifier as step 3 of its 4-step pipeline (fetch →
  verify → unpack → rename).
- **M3.** Semantic-pipe schema `PackageManifest[]` bound via
  libpdx-semantic-pipe. Every subcommand journals to
  `/system/audit/user-events/pkg-<ts>-<audit_id>.pdxevent` via
  libpdx-audit before any output.
- **M4.** Fuzz the parser (arbitrary bytes → parse or reject, never
  crash). Sig-mismatch matrix per the plan doc §5.1 M4 issues.
- **M5.** Real dual-signed manifest.pdxsig for pkg v1.0 itself.

## 8. Non-goals of the M1 format spec

- **No compression.** `pkg.tar` is uncompressed. A compression layer
  can be added at M5+ once the download volume is a measured
  concern.
- **No delta updates.** Every `pkg install` fetches the full
  `<name>/<version>/` tree. Delta between versions is a post-1.0
  concern.
- **No confidentiality.** Package contents are public. The signature
  proves *authenticity*, not privacy — every user sees the same
  bytes.
- **No transitive signing.** A package's `deps.list` names its
  dependencies, but the dependencies' signatures are verified when
  those packages are themselves installed, not transitively here.
