# pkg — pkgs.paideia-os mirror-push protocol

**Wave:** R49  Milestone: M5  Issue: #17 (pkg.M5-002)
**Driver:** `release/mirror-push.sh` (POSIX-sh for pre-shell window;
   .pds mirror lands at shell.M3+ per r49-r50-plan.md §5.2 M3 line).
**Design:** `design/release-1.0.md` §6.

## 0. Reading order

- §1 — what the mirror-push protocol is and what it is not.
- §2 — mirror layout on `pkgs.paideia-os` (per
  `design/manifest-format.md` §2).
- §3 — upload sequence: what gets pushed, in what order, under
  what invariants.
- §4 — index update (`index.pdxsig`) — the atomic-swap protocol
  that keeps a partial upload invisible to concurrent `pkg install`.
- §5 — driver invocation + env vars.
- §6 — immutability + rotation policy (1.0.0 is immutable; 1.0.1
  is a new upload).
- §7 — substrate gates (`pkgs.paideia-os` service, host, cert).

## 1. Scope

The mirror-push protocol is the sequence by which a release of pkg
(or of any R49/R50 tool) is uploaded to `pkgs.paideia-os` so
`pkg install <name>` can fetch it. This document specifies:

- The on-mirror layout the upload must produce.
- The upload order + atomicity invariants.
- The idempotency + immutability discipline (a 1.0.0 upload cannot
  be overwritten; a corrected release ships as 1.0.1).
- The env-var contract the POSIX-sh driver reads.

Out of scope:

- The mirror server itself (the software serving pkgs.paideia-os over
  HTTPS). At 1.0-close the mirror is a static file tree; the R50 wave
  or later ships a dedicated broker.
- Delta uploads between versions. Every release re-uploads the full
  tree; delta shipping is a post-1.0 concern (see
  `CHANGELOG.md` non-goals).
- Signature verification on upload. The mirror does not verify the
  pushed manifest; verification is done at the `pkg install` client
  side per D4. A mirror is untrusted infrastructure.

## 2. Mirror layout

Per `design/manifest-format.md` §2:

```
pkgs.paideia-os/
  index.pdxsig                   -- top-level {name, version, hash} table
  <name>/
    <version>/
      pkg.tar                    -- the packaged tar
      manifest.pdxsig            -- dual-signed manifest for this pkg+version
```

For pkg 1.0.0 the resulting tree fragment is:

```
pkgs.paideia-os/
  index.pdxsig
  pkg/
    1.0.0/
      pkg.tar
      manifest.pdxsig
```

The top-level `index.pdxsig` is itself a signed manifest (its body is
a table of {name, version, manifest_hash, upload_ts} rows). It is
re-signed on every push by the paideia_root key (never the
per-tool author key). The mirror serves `index.pdxsig` from the top
of its file tree; `pkg install` fetches it first, resolves
`<name> → <version>`, then fetches
`<name>/<version>/manifest.pdxsig`.

## 3. Upload sequence

The driver `release/mirror-push.sh` runs these steps in order:

1. **Verify local artefacts.** Read `<in-dir>/manifest.pdxsig` and
   `<in-dir>/pkg.tar` (produced by `release/1.0/gen-manifest.sh`).
   Refuse if either is missing, if the header magic does not match
   `"pdxsig\0\0"`, or if `body_len` overflows `MC_BODY_LEN_MAX`.
2. **Extract identity.** Read the `PKG_NAME` + `PKG_VERSION` KV
   records from the manifest body; use these to derive the upload
   path `<name>/<version>/`.
3. **Check remote for prior upload.** HTTP-HEAD
   `$PDX_MIRROR_URL/<name>/<version>/manifest.pdxsig`. If it
   returns 200, refuse: a released version is immutable. Diagnose
   with the SHA-256 of the local vs remote manifest so the operator
   can see whether the upload is redundant or a mismatch.
4. **Upload pkg.tar to a staging path.** PUT to
   `$PDX_MIRROR_URL/<name>/<version>/pkg.tar.pending`. Upload the
   raw bytes with Content-Type `application/x-tar`. Chunked upload
   is acceptable.
5. **Upload manifest.pdxsig to a staging path.** PUT to
   `$PDX_MIRROR_URL/<name>/<version>/manifest.pdxsig.pending`.
   Content-Type `application/vnd.paideia.pdxsig`.
6. **Atomic-swap the pending pair to canonical names.** Two moves:
   `pkg.tar.pending → pkg.tar` and
   `manifest.pdxsig.pending → manifest.pdxsig`. Any pkg install that
   fetched the manifest before the swap gets the old (missing) or
   pending (partial) tree; after the swap, every fetch sees the
   full pair.
7. **Fetch existing index.pdxsig.** HTTP-GET
   `$PDX_MIRROR_URL/index.pdxsig`. If it does not exist (first-ever
   upload to this mirror), start with an empty index body.
8. **Add or update the row for `<name>`.** Append a row `{name,
   version, manifest_sha3_256, upload_ts}` to the index body. If a
   row for `<name>` at a lower version exists, keep it — the mirror
   holds every historical version until GC.
9. **Re-sign the updated index.pdxsig with the paideia_root key.**
   The index is signed by root only (single-signature; the D4 dual-
   sig applies to per-tool manifests, not to the mirror index).
10. **Upload the re-signed index to a staging path + atomic-swap.**
    Same discipline as steps 5-6: `index.pdxsig.pending →
    index.pdxsig`. A concurrent `pkg install` that reads the index
    before the swap sees the prior index; after the swap, sees the
    updated one.

Steps 1-3 are pre-flight; step 4 begins the write. A failure at any
step past step 4 leaves the `.pending` files behind. The driver's
`--rollback` flag (M5 followup) removes stale `.pending` files.

## 4. Index update — atomic-swap invariants

The index is the mirror-wide lookup table. Every `pkg install` reads
it first. Correctness requires:

- **Read-old-or-read-new, never partial.** The swap is atomic on the
  mirror storage backend. The M5-close driver uses HTTP `MOVE` (or
  the equivalent `Copy + Delete-source` for backends that lack
  atomic rename); a backend without atomicity is a substrate gap
  and refuses at step 10 with a clear diagnostic.
- **Version-monotonic per pkg.** The index row for `<name>` at a
  higher version supersedes the lower — `pkg install <name>` without
  an explicit version resolves to the highest available. Historical
  rows stay for `pkg install <name>@<version>` and for audit.
- **Re-signed on every push.** The index signature covers the entire
  post-push body; a corrupted or unverified index is a hard failure
  at `pkg install` (fetch index, verify signature, then resolve).
- **Never removed.** Even a `pkg-remove-mirror-side` operation
  (post-1.0) is expressed as an index update, not an index deletion.

## 5. Driver invocation

```
release/mirror-push.sh <in-dir> [<mirror-url>]
```

`<in-dir>` is the directory `release/1.0/gen-manifest.sh` produced
(contains `pkg.tar` + `manifest.pdxsig`). `<mirror-url>` overrides
the `PDX_MIRROR_URL` env var.

Env vars:

| Var                | Default                              | Purpose                                        |
|--------------------|--------------------------------------|------------------------------------------------|
| `PDX_MIRROR_URL`   | `https://pkgs.paideia-os/`           | Base URL for the mirror.                       |
| `PDX_MIRROR_AUTH`  | `~/.pdx/keys/mirror-token`           | Bearer token for PUT/MOVE.                     |
| `PDX_ROOT_KEY`     | `~/.pdx/keys/paideia-root.pk`        | Key used to re-sign `index.pdxsig`.            |
| `PDX_DRY_RUN`      | `0`                                  | If `1`, log the sequence without any PUT.      |
| `PDX_FORCE_STUB`   | `0`                                  | If `1`, upload STUB-signed artefacts (M5 gate). |

The driver refuses if `PDX_MIRROR_URL` is unreachable, if the auth
token is missing, or if `PDX_ROOT_KEY` cannot sign (blocked on
paideia-as v0.33-crypto-kdf at M5-close). `PDX_DRY_RUN=1` is the
canonical M5-close invocation: the driver walks the sequence and
prints every intended request without any network write. This is
how a reviewer at M5-close confirms the shape without needing a
live mirror.

## 6. Immutability + rotation

- A released version is **immutable**. A push against an existing
  `<name>/<version>/manifest.pdxsig` is refused (step 3). The
  correction path is a version bump: 1.0.0 → 1.0.1.
- The mirror keeps **every historical version** indefinitely. GC
  is a mirror-side concern (post-1.0 op-doc). A `pkg install
  <name>@<version>` for an old version must always succeed.
- The `paideia_root_pk` **rotation** is a mirror-wide event: the
  founder re-signs every existing `index.pdxsig` + every per-tool
  `manifest.pdxsig` under the new key, and updates
  `/system/keys/paideia_root_pk.fpr` on every bootstrap image.
  Rotation is out of scope for pkg 1.0; the discipline is
  documented at `design/user/model.md` §11 in paideia-os.

## 7. Substrate gates at M5-close

Same shape as `STATUS.md` substrate-gate carry-forward:

| Gate                                    | Effect on mirror-push                                     |
|-----------------------------------------|-----------------------------------------------------------|
| paideia-as v0.33-crypto-kdf             | Cannot re-sign `index.pdxsig` (step 9); refuses at step 9 |
| `pkgs.paideia-os` host not provisioned  | Cannot resolve `PDX_MIRROR_URL`; refuses at step 3 pre-flight |
| Mirror ACL for `PDX_MIRROR_AUTH`        | Cannot PUT; refuses at step 4                             |
| Atomic-rename backend                   | Some backends lack it; refuses at step 6 (with fallback) |

`PDX_DRY_RUN=1` bypasses all four gates and produces a byte-perfect
log of the intended sequence. The M5-002 close artefact under
`release/mirror-push.sh` is intended to be exercised via
`PDX_DRY_RUN=1` at review time; live uploads wait on the paideia-as
+ pkgs.paideia-os substrate.

## 8. Post-1.0 followups

- **`.pds` mirror.** Once shell.M3 lands, port `release/mirror-
  push.sh` to a `.pds` script that runs under the semantic-native
  shell rather than a POSIX-sh host.
- **Delta uploads.** Add a `--delta <base-version>` mode that
  uploads only the changed files, and a manifest-side `PARENT_
  MANIFEST` KV tag (format additive; §6 evolution rules).
- **Content-addressed storage.** Optional: switch pkg.tar members
  to CAS storage so unchanged files across versions dedupe. Not
  needed at 1.0-close scale.
- **`--rollback` flag on the driver.** Clean up stale `.pending`
  files from an interrupted push. Currently manual (mirror-admin
  op).
