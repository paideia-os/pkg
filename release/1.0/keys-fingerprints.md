# pkg-1.0.0 — signing key fingerprints

**Wave:** R49  Milestone: M5  Issue: #16 (pkg.M5-001) / #17 (pkg.M5-002)
**Consumed by:** `pkg keys list` (see `src/subcommands_m1_stubs.pdx` M4
   body); `pkg install` at verify step 11 per `design/manifest-format.md`
   §5 (ROOT_FPR cross-check against `/system/keys/paideia_root_pk.fpr`).
**Substrate gate:** paideia-as v0.33-crypto-kdf (real fingerprints
   materialise when the ML-DSA-65 keypair generator ships).

## 1. paideia_root_pk fingerprint (STUB)

The paideia_root_pk is the Paideia project's manifest re-sign key.
Exactly one such key exists per Paideia release cycle; rotating it is a
founder-only elevate operation gated by
`src/kernel/core/user/elevate_policy.pdx` in paideia-os.

At M5-close the key material is not yet generated (v0.33-crypto-kdf
gate). The bootstrap image at `pkg install` time reads the fingerprint
from `/system/keys/paideia_root_pk.fpr` — a 32-byte sha3-256 of the
public key.

| Field           | Value at M5-close                                 |
|-----------------|---------------------------------------------------|
| Algorithm       | ML-DSA-65 (NIST security level 2)                 |
| Fingerprint fn  | sha3-256(pubkey)                                  |
| Fingerprint hex | `PENDING_V033` (32 B; STUB fill in every manifest)|
| Rotation policy | Founder-only via elevate; log to /system/audit/   |
| First rotation  | Not scheduled; 1.0.0 uses the initial-generation key|

## 2. pkg author key (STUB)

The pkg 1.0.0 author key is the second signature on `manifest.pdxsig`.
Distinct from the paideia_root key so a compromised author key does not
compromise every package on the mirror (the D4 dual-signature invariant).

| Field           | Value at M5-close                                 |
|-----------------|---------------------------------------------------|
| Algorithm       | ML-DSA-65 (NIST security level 2)                 |
| Fingerprint fn  | sha3-256(pubkey)                                  |
| Fingerprint hex | `PENDING_V033` (32 B; STUB fill in every manifest)|
| Rotation policy | Author-controlled; a rotation ships as a new     |
|                 | pkg minor version with the new AUTHOR_FPR in the |
|                 | manifest.                                        |
| Held by         | github.com/snunezcr (paideia-os founder /        |
|                 | pkg author for 1.0.0)                            |

## 3. `pkg keys list` output format

The `pkg keys list` subcommand renders one line per known key from
`/system/keys/`:

```
pkg keys — known signing keys
paideia_root  ml-dsa-65  <fingerprint-hex>  (rotated: never)
pkg-author    ml-dsa-65  <fingerprint-hex>  (rotated: never)
```

At M5-close the `<fingerprint-hex>` field renders the STUB pattern
`PENDING_V033` for both entries; downstream tools that filter by
fingerprint will therefore accept every 1.0.0 install as
STUB-signed until the v0.33-crypto-kdf substrate lands.

## 4. Diff-flip discipline

When v0.33-crypto-kdf ships:

1. Generate real ML-DSA-65 keypair for paideia_root and for the pkg
   author.
2. Compute sha3-256 fingerprints; update the two `PENDING_V033`
   entries in §1 and §2 above with the real hex.
3. Re-run `release/1.0/gen-manifest.sh` — the AUTHOR_PUBKEY /
   AUTHOR_FPR / ROOT_PUBKEY / ROOT_FPR STUB fills in the manifest
   diff-flip to real bytes.
4. Regenerate `/system/keys/paideia_root_pk.fpr` on the bootstrap
   image with the real 32-byte fingerprint; verify step 11 of
   `pkg install` (§5 of `design/manifest-format.md`) then passes.
5. Push a new 1.0.0 mirror upload (`release/mirror-push.sh`) with
   the diff-flipped `manifest.pdxsig`. The 1.0.0 version does not
   bump — the STUB envelope is treated as an unreleased pre-artefact.

## 5. Verifying a locally-installed pkg-1.0.0

Once real keys ship, an installed pkg can be re-verified end-to-end:

```
pkg verify pkg                             # verify installed manifest
pkg keys list | grep pkg-author            # confirm author fingerprint
```

At M5-close `pkg verify pkg` refuses at the verify seam (per
`STATUS.md` "M2 seams") and prints the diagnostic naming the missing
intrinsic. The command's shape (exit code, stderr line one) is pinned
in `tests/m4-001-sig-mismatch/expected/` and diff-flips at
v0.33-crypto-kdf.
