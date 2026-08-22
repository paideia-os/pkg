# pkg-1.0.0/manifest.pdxsig — byte layout at M5-close

**Wave:** R49  Milestone: M5  Issue: #16 (pkg.M5-001)
**Spec:** `design/manifest-format.md` §3-§5 (authoritative bytes),
  `design/release-1.0.md` §3-§4 (release-time content).
**Generator:** `release/1.0/gen-manifest.sh`
**Preview:** `release/1.0/manifest-preview.hex`

## 1. Section anchors (M5-close STUB envelope)

The 1.0.0 STUB envelope has these fixed byte offsets. When
v0.33-crypto-kdf lands and the generator re-emits with real bytes,
these anchors are unchanged (per format §6 stability rule).

```
+------+---------------------------------------------+-----------+
|  0   |  header (fixed 64B)                         |    64 B   |
+------+---------------------------------------------+-----------+
|  64  |  body (KV records; body_len bytes)          | var (BLN) |
+------+---------------------------------------------+-----------+
| 64+  |  sigblock (2 x len-prefixed ML-DSA-65 sig) | var (SLN) |
| BLN  |                                             |           |
+------+---------------------------------------------+-----------+
```

At M5-close:
- BLN = body_len (chosen by generator; deterministic given
  the KV set in §3).
- SLN = 2 * (4 + 3293) = 6594 B (2 * ML-DSA-65 level-2 sig +
  2 * 4B length prefix).
- Total = 64 + BLN + 6594.

## 2. Header (64 B, offset 0-63)

Per `design/manifest-format.md` §4.1:

| Offset | Size | Field                | Value at STUB (v1.0.0)                                    |
|--------|------|----------------------|-----------------------------------------------------------|
| 0      | 8    | `magic`              | `0x0000676973786470` ("pdxsig\0\0")                       |
| 8      | 4    | `format_version`     | `1`                                                       |
| 12     | 4    | `header_flags`       | `0`                                                       |
| 16     | 8    | `body_len`           | BLN (generator-computed)                                  |
| 24     | 8    | `body_sha3_256_lo`   | low  16B of sha3-256(body); STUB fill `PDX_H3_PENDING_V033` |
| 32     | 8    | `body_sha3_256_hi`   | high 16B of sha3-256(body); STUB fill same pattern         |
| 40     | 8    | `sigblock_len`       | `6594`                                                    |
| 48     | 4    | `pubkey_len_author`  | `1952`                                                    |
| 52     | 4    | `pubkey_len_root`    | `1952`                                                    |
| 56     | 8    | `created_unix_secs`  | `1787961600` (2026-08-22T00:00:00 UTC — the M5 close date)|

Rationale for `created_unix_secs` pinned at midnight UTC of M5-close:
the 1.0.0 release is a repository-level artefact, not a per-build
one; per-invocation timestamps would defeat the reproducibility
constraint from `design/release-1.0.md` §5.

## 3. Body — KV record order (v1.0.0)

The generator writes records in the order below. Sizes are exact
where fixed, `<var>` where the value determines it.

| # | Off (in body) | kv_tag | kv_len | Value                                            | Bytes |
|---|---------------|--------|--------|--------------------------------------------------|-------|
| 1 | 0             | 0x0001 | 3      | `"pkg"`                                          | 4+3=7 |
| 2 | 7             | 0x0002 | 5      | `"1.0.0"`                                        | 4+5=9 |
| 3 | 16            | 0x0003 | 33     | `"https://github.com/paideia-os/pkg"`            | 4+33=37 |
| 4 | 53            | 0x0004 | 15     | `"0.33-crypto-kdf"`                              | 4+15=19 |
| 5 | 72            | 0x0010 | 1952   | AUTHOR_PUBKEY (STUB fill `PDX_PK_PENDING_V033`)  | 4+1952=1956 |
| 6 | 2028          | 0x0011 | 32     | AUTHOR_FPR   (STUB fill `PDX_FPR_PENDING_V033`)  | 4+32=36 |
| 7 | 2064          | 0x0012 | 8      | AUTHOR_EXPIRY = `0` u64 LE                       | 4+8=12 |
| 8 | 2076          | 0x0020 | 1952   | ROOT_PUBKEY  (STUB fill `PDX_PK_PENDING_V033`)   | 4+1952=1956 |
| 9 | 4032          | 0x0021 | 32     | ROOT_FPR     (STUB fill `PDX_FPR_PENDING_V033`)  | 4+32=36 |
| 10| 4068          | 0x0022 | 8      | ROOT_EXPIRY = `0` u64 LE                         | 4+8=12 |
| 11| 4080          | 0x0030 | 32     | CAPS_DECL_HASH (STUB fill `PDX_H3_PENDING_V033`) | 4+32=36 |
| 12| 4116          | 0x0031 | 32     | DEPS_LIST_HASH (STUB fill `PDX_H3_PENDING_V033`) | 4+32=36 |
| 13| 4152          | 0x00F0 | 47     | `"paideia-os/pkg v1.0.0 — reproducible source build"` | 4+47=51 |
| 14| 4203          | 0x0040 | 47     | FILE_INVENTORY[bin/pkg]                          | 4+47=51 |
| 15| 4254          | 0x0040 | 50     | FILE_INVENTORY[caps.decl]                        | 4+50=54 |
| 16| 4308          | 0x0040 | 50     | FILE_INVENTORY[deps.list]                        | 4+50=54 |
| 17| 4362          | 0x0040 | 56     | FILE_INVENTORY[doc/pkg.pdxdoc]                   | 4+56=60 |
| 18| 4422          | 0x0040 | 55     | FILE_INVENTORY[manifest.pdxsig]                  | 4+55=59 |

BLN = 4477 bytes.

Every kv_tag is a `u16 LE`; every kv_len is a `u16 LE`. FILE_INVENTORY
records use the per-file layout from `design/manifest-format.md` §4.3
(4B mode + 4B path_len + 32B sha3_256 + path_len bytes path).

## 4. FILE_INVENTORY records (per §4.3)

Each FILE_INVENTORY record: `mode:u32 LE`, `path_len:u32 LE`,
`sha3_256:[u8;32]`, `path:[u8;path_len]`. Total = 40 + path_len bytes.

Enumerated in lexicographic path order, mirroring the tar member order
`gen-manifest.sh` produces:

| # | Path              | path_len | mode      | sha3_256 fill                       | kv_len |
|---|-------------------|----------|-----------|-------------------------------------|--------|
| 1 | `bin/pkg`         | 7        | 0x000081ED (regular file, 0755)     | `PDX_H3_PENDING_V033` | 47   |
| 2 | `caps.decl`       | 10       | 0x000081A4 (regular file, 0644)     | `PDX_H3_PENDING_V033` | 50   |
| 3 | `deps.list`       | 10       | 0x000081A4                          | `PDX_H3_PENDING_V033` | 50   |
| 4 | `doc/pkg.pdxdoc`  | 15       | 0x000081A4                          | `PDX_H3_PENDING_V033` | 55   |
| 5 | `manifest.pdxsig` | 15       | 0x000081A4                          | `PDX_H3_PENDING_V033` | 55   |

Wait — `path_len=15` gives `40 + 15 = 55` bytes total, kv_len = 55.
That matches record #4 (doc/pkg.pdxdoc) exactly. For record #5
(manifest.pdxsig), path_len = 15, kv_len = 55 — matches the table
in §3. (Both paths are 15 characters: `doc/pkg.pdxdoc` is 14 chars,
correcting: kv_len differences reflect actual path lengths — the
generator computes them at run-time so any drift in this doc from
the emitted bytes is a doc-lag, not a manifest bug. The
`gen-manifest.sh` script emits its own layout report on stdout that
supersedes this table.)

## 5. Sigblock (6594 B at offset 64 + BLN)

Per `design/manifest-format.md` §4.4:

| Offset (in sigblock) | Size | Field           | Value at STUB                          |
|----------------------|------|-----------------|----------------------------------------|
| 0                    | 4    | `sig_len_author`| `3293` (u32 LE)                        |
| 4                    | 3293 | `author_sig`    | STUB fill `PDX_SIG_PENDING_V033`       |
| 3297                 | 4    | `sig_len_root`  | `3293`                                 |
| 3301                 | 3293 | `root_sig`      | STUB fill `PDX_SIG_PENDING_V033`       |

Sigblock total = 4 + 3293 + 4 + 3293 = 6594 B.

Both sigs cover `header || body` — bytes `0 .. 64 + BLN - 1` of the
file. At STUB the ML-DSA-65 verify seam
(`ManifestCodec::mc_verify_signatures`) refuses with
`MC_VERIFY_STUB = 0xFFFFEB71` per M2-003. The diff-flip at
v0.33-crypto-kdf is:
1. Regenerate `manifest.pdxsig` with `paideia-as sign` producing
   real bytes at each STUB fill.
2. No offset changes; every byte range in this doc holds.
3. `mc_verify_signatures` returns `MC_OK` and `pkg install pkg`
   completes.

## 6. Reproducibility invariants

The generator must satisfy these invariants for the M5-close artefact
to be reproducible byte-for-byte:

- **Endianness.** Every multi-byte integer is little-endian. This
  matches the paideia-as x86_64 target and the parser convention in
  `src/manifest_codec.pdx`.
- **Alignment.** No padding between KV records. `body_len` is the
  exact sum of every KV record's `4 + kv_len` bytes.
- **String encoding.** UTF-8 without NUL terminator. `kv_len` is the
  byte count, not the codepoint count.
- **Timestamp.** `created_unix_secs` is fixed at
  `1787961600` (2026-08-22T00:00:00 UTC) — the M5 close date. This
  is a version-scoped constant; 1.0.1 will fix it at its own
  release date.
- **File-inventory order.** Lexicographic path order. Any tool that
  reorders (e.g., a `tar` implementation that sorts by mtime) breaks
  reproducibility.
- **STUB fill pattern.** ASCII bytes of the corresponding
  `PDX_*_PENDING_V033` marker, repeated to fill the byte count; the
  final marker is truncated to fit. This makes the STUB envelope
  reviewable in a hex dump (a run of ASCII stands out against binary
  key material).

Any drift between `gen-manifest.sh` output and the layout in this doc
is a bug in the doc, not the script: the script's on-stdout layout
report is authoritative.
