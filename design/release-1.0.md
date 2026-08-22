# pkg — 1.0 release design

**Wave:** R49  Milestone: M5  Issues: #16 (M5-001), #17 (M5-002)
**Upstream:** [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 M5 line ("dual-signed `manifest.pdxsig` for pkg v1.0, CHANGELOG-1.0
entry, `pkgs.paideia-os` mirror push, `pkg keys` documentation of the
paideia_root_pk fingerprint, `.pdxdoc` file for `doc pkg`").
**paideia-as crypto floor:** v0.33-crypto-kdf (ML-DSA-65 sign + verify,
Argon2id-KDF, ChaCha20-Poly1305 AEAD).

## 0. Reading order

- §1 — what M5 ships and what it explicitly defers.
- §2 — the release directory tree (`release/1.0/` +
  `release/mirror-push*`) laid out on disk.
- §3 — the release-time byte layout of `pkg-1.0.0/manifest.pdxsig`
  (what the generator emits per `design/manifest-format.md` §3-§4).
- §4 — the STUB envelope carried at M5-close (structure identical
  to §3; signature bytes marked `PDX_SIG_PENDING_V033`; diff-flips
  to real bytes when the crypto substrate lands).
- §5 — CHANGELOG-1.0.0 discipline (roll-up scope, format, cross-
  milestone attribution).
- §6 — mirror-push protocol (M5-002): what gets uploaded, in what
  order, under what invariants; the POSIX-sh driver at
  `release/mirror-push.sh` and its .pds successor at shell.M3+.
- §7 — `.pdxdoc` shape for `doc pkg` (M5-002).
- §8 — substrate gates the 1.0 release inherits from M4-close;
  diff-flip points documented per gate.

## 1. What M5 lands vs defers

M5 is the "1.0 signed release" milestone. It lands the **release
artefact chain** and the **mirror-push protocol**; every artefact is
byte-deterministic against the M4-close binary, so an uplift of the
crypto substrate (v0.33-crypto-kdf) diff-flips the sigblock bytes and
nothing else.

**In scope at M5-close:**

- `manifest.pdxproj` version bump `0.4.0-m4` → `1.0.0` (drops the
  milestone suffix; the release-ready shape).
- `release/1.0/gen-manifest.sh` — POSIX-sh generator that assembles
  the header + body per `design/manifest-format.md` §3-§4. Wraps
  `paideia-as sign` (blocked on v0.33-crypto-kdf) for the sigblock;
  falls back to a `PDX_SIG_PENDING_V033`-filled sigblock at M5-close
  so the artefact structure is reviewable now.
- `release/1.0/manifest-layout.md` — byte-level layout of the emitted
  manifest, per-field annotation, and the M4→M5 diff points.
- `release/1.0/manifest-preview.hex` — canned hex-dump of the STUB
  envelope so a reviewer at M5-close sees the exact bytes the
  generator emits without running the script.
- `release/1.0/README.md` — release-directory index; names every
  artefact + its diff-flip point.
- `release/1.0/keys-fingerprints.md` — documents the paideia_root_pk
  fingerprint (STUB at M5-close; real fingerprint at v0.33-crypto-kdf
  substrate close). `pkg keys list` at M4 already renders this file
  when it lands; M5-002 wires the doc link.
- `CHANGELOG.md` — v1.0.0 entry rolling up M1-M5 with per-milestone
  attribution + substrate-gate carry-forward.
- `release/mirror-push.md` — protocol document for `pkgs.paideia-os`
  mirror upload.
- `release/mirror-push.sh` — POSIX-sh driver for the pre-shell
  window; a .pds mirror lands at shell.M3+.
- `doc/pkg.pdxdoc` — the `.pdxdoc` file `doc pkg` reads for
  interactive documentation.

**Out of scope at M5 (deferred):**

- **Real signature bytes.** Blocked on paideia-as v0.33-crypto-kdf
  (Argon2id-KDF + ChaCha20-Poly1305 + ML-DSA-65 sign). Diff-flip:
  regenerate `manifest.pdxsig` with real keys once the intrinsic
  lands; the generator's `paideia-as sign` call path is already
  wired.
- **Live mirror upload.** Blocked on `pkgs.paideia-os` being served
  as a static file tree (target: R49-substrate follow-up). Diff-flip:
  `release/mirror-push.sh` uploads to the real host once the
  `PDX_MIRROR_URL` env var points at a live tree.
- **`doc pkg` end-to-end.** Blocked on doc.M4 (test-complete) per
  the r49-r50-plan §5.1 M5 line ("pkg.M5 depends on doc.M2 (needs
  `doc pkg` reachable before release)"). The `.pdxdoc` file ships
  at M5-close; the `doc pkg` invocation binds when doc.M4 closes.

## 2. Release directory tree

At M5-close the repo grows two top-level directories:

```
release/
  1.0/
    README.md                    -- release index + diff-flip pointers
    manifest-layout.md           -- byte layout for pkg-1.0.0/manifest.pdxsig
    manifest-preview.hex         -- hex dump of the STUB envelope
    keys-fingerprints.md         -- paideia_root_pk fingerprint doc
    gen-manifest.sh              -- POSIX-sh manifest generator
  mirror-push.md                 -- pkgs.paideia-os upload protocol
  mirror-push.sh                 -- POSIX-sh mirror-push driver

doc/
  pkg.pdxdoc                     -- doc-tool consumable for `doc pkg`

CHANGELOG.md                     -- v1.0.0 entry (top of file)
```

Nothing in `src/` moves at M5; the codec + install/remove/list bodies
that M2-M3 landed are the 1.0 shape. The M4 test-matrix + smoke
drivers under `tests/` are unchanged (their diff-flip expected files
carry the post-v0.33-crypto-kdf shape already pinned).

## 3. `pkg-1.0.0/manifest.pdxsig` — byte layout

The generator emits a `manifest.pdxsig` conforming to
`design/manifest-format.md` §3 (three sections: header 64B, body
variable, sigblock variable). The pkg-1.0.0 body carries these KV
records in this order:

| Order | Tag                  | Value at v1.0.0                                        |
|-------|----------------------|--------------------------------------------------------|
| 1     | `PKG_NAME`           | `"pkg"`                                                |
| 2     | `PKG_VERSION`        | `"1.0.0"`                                              |
| 3     | `PKG_REPO_URL`       | `"https://github.com/paideia-os/pkg"`                  |
| 4     | `PAIDEIA_AS_VER`     | `"0.33-crypto-kdf"`                                    |
| 5     | `AUTHOR_PUBKEY`      | ML-DSA-65 pubkey bytes (1952B at NIST level 2)         |
| 6     | `AUTHOR_FPR`         | sha3-256(AUTHOR_PUBKEY) — 32B                          |
| 7     | `AUTHOR_EXPIRY`      | u64 unix seconds; 0 = never                            |
| 8     | `ROOT_PUBKEY`        | paideia_root_pk (1952B)                                |
| 9     | `ROOT_FPR`           | sha3-256(ROOT_PUBKEY) — 32B                            |
| 10    | `ROOT_EXPIRY`        | u64 unix seconds; 0 = never                            |
| 11    | `CAPS_DECL_HASH`     | sha3-256(caps.decl) — 32B                              |
| 12    | `DEPS_LIST_HASH`     | sha3-256(deps.list) — 32B                              |
| 13    | `BUILD_REPRODUCER`   | free-form build-repro attribution UTF-8                |
| 14+   | `FILE_INVENTORY`     | one record per file the pkg-1.0.0 tar installs         |

`FILE_INVENTORY` records enumerate every file in the installed tree
at `/pkgs/pkg-1.0.0/`:

```
bin/pkg                            -- elaborated Paideia binary (from build-out/pkg)
caps.decl                          -- packaged cap manifest
deps.list                          -- packaged dependency list
manifest.pdxsig                    -- this file (self-reference; hash covers header+body only)
doc/pkg.pdxdoc                     -- doc-tool consumable
```

Order matters for reproducibility: the generator writes them in
lexicographic path order (`bin/pkg` < `caps.decl` < `deps.list` <
`doc/pkg.pdxdoc` < `manifest.pdxsig`).

The `manifest.pdxsig` self-reference is intentional: `pkg install`
extracts every FILE_INVENTORY entry into KIND_PDXFS_TXN scope, and
the manifest itself sits under `/pkgs/pkg-1.0.0/manifest.pdxsig`
after commit so `pkg verify pkg` can re-verify without touching the
network. The self-reference's sha3-256 covers header || body only
(the sigblock is not signed by itself; see
`design/manifest-format.md` §4.4).

## 4. STUB envelope at M5-close

At M5-close the generator emits a real header + real body + a
STUB sigblock. Every byte range that will hold a signature bit at
v0.33-crypto-kdf is filled with the ASCII pattern
`PDX_SIG_PENDING_V033` (repeated to fill the byte count). Every
byte range that will hold a public key or a fingerprint is filled
with the ASCII pattern `PDX_PK_PENDING_V033` /
`PDX_FPR_PENDING_V033`. Every byte range that will hold a sha3-256
hash is filled with `PDX_H3_PENDING_V033`.

The header still carries **real** `body_len` / `sigblock_len` /
`pubkey_len_*` — the bytes downstream of a STUB fill are structurally
correct, so `mc_read_header` accepts the envelope and
`mc_walk_body` finds every KV record. Only the crypto checks
(`mc_verify_body_hash`, `mc_verify_signatures`) reject at STUB. This
is the same discipline the M4 test matrix already asserts — the
diff-flip at v0.33-crypto-kdf uplifts every STUB fill to real bytes
without moving any offset.

The exact hex dump of the STUB envelope lives at
`release/1.0/manifest-preview.hex`. Reviewers at M5-close can inspect
that file to see every offset + every field's byte range without
running the generator.

## 5. CHANGELOG-1.0.0 discipline

`CHANGELOG.md` follows the "Keep a Changelog" convention with these
per-repo adjustments:

- Roll-up scope: the 1.0.0 entry names every issue closed across
  M1-M5 (17 issues, #1-#17) with one bullet per issue.
- Substrate-gate carry-forward: any substrate gate open at
  M5-close is listed under a `### Known limitations` subsection
  with a reference to the paideia-os / paideia-as issue tracking
  the gate.
- Per-milestone attribution: bullets are grouped under `### M1`
  through `### M5` subsections so a downstream reader sees the
  milestone rollup at a glance.
- Cross-repo dependency snapshot: the version each library was
  pinned against is recorded under a `### Dependency snapshot`
  subsection so the 1.0.0 release is exactly reproducible.

## 6. Mirror-push protocol

`release/mirror-push.md` documents the sequence:

1. `paideia-as build manifest.pdxproj -o build-out/pkg` — builds
   the 1.0.0 binary from source.
2. `release/1.0/gen-manifest.sh build-out/pkg pkg-1.0.0` — assembles
   the tar + manifest.pdxsig under `build-out/pkg-1.0.0/`.
3. `release/mirror-push.sh build-out/pkg-1.0.0/ $PDX_MIRROR_URL` —
   uploads `pkg.tar` + `manifest.pdxsig` to
   `$PDX_MIRROR_URL/pkg/1.0.0/` and refreshes
   `$PDX_MIRROR_URL/index.pdxsig`.

The driver is idempotent: re-running against an existing
`pkg/1.0.0/` fails-fast (a 1.0 release is immutable). Rotation to
1.0.1 uploads to `pkg/1.0.1/` — the mirror keeps every historical
version until GC (mirror-side; not pkg's concern).

## 7. `.pdxdoc` for `doc pkg`

`doc/pkg.pdxdoc` is a text-format document consumable by the `doc`
tool at doc.M2. Format is one-section-per-blank-line-separated block,
sections in this order:

1. `NAME` — one-line synopsis.
2. `SYNOPSIS` — argv grammar (mirrors `design/argv-surface.md`).
3. `DESCRIPTION` — long-form overview.
4. `SUBCOMMANDS` — one paragraph per subcommand.
5. `CAPS` — the `caps.decl` requirements + elevate flow summary.
6. `EXAMPLES` — canonical invocations.
7. `SEE ALSO` — cross-references to doc entries for
   related tools (doc doc-shell, doc-libpdx-cap, etc.).
8. `AUDIT` — the audit-record schema `pkg` emits.

The doc tool at doc.M3 upgrades this file to a `PdxDocEntry[]`
schema-typed stream (§4.3 of the r49-r50-plan.md); at M5-close the
file is human-readable text with section markers that doc.M2 parses
via a byte-compare recognizer.

## 8. Substrate gates inherited from M4-close

Same four gates from `STATUS.md` "Substrate gates still blocking
full-green M4" are carried forward at M5-close. Each gate's diff-flip
in the release artefacts:

| Gate | Diff-flip artefact |
|------|--------------------|
| paideia-as v0.33-crypto-kdf | `release/1.0/manifest.pdxsig` (STUB → real sigblock); `release/1.0/keys-fingerprints.md` (STUB → real fingerprint) |
| paideia-os R48-PREP-005 (svc.elevate-broker) | `bootstrap/self-install.pds` exit code (1 → 0); `tests/m4-002/expected/elevate-refuse.txt` (unchanged; the file already pins the post-uplift shape) |
| paideia-os KIND_PDXFS_FILE staging read | `tests/m4-001/expected/*.txt` (unchanged; already pinned post-uplift) |
| `/system/packages/` readdir | `src/list.pdx` M6+ upgrade (out of scope at 1.0) |

None of the four gates block the M5 artefact chain from landing; they
block the artefacts from carrying real bytes. The release
directory at `release/1.0/` documents each gate explicitly so a
reviewer at M5-close sees the diff-flip surface up-front.
