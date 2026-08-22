# pkg — M4-001 sig-mismatch matrix

**Wave:** R49  Milestone: M4  Issue: #13 (pkg.M4-001)
**Upstream:** `design/tooling/r49-r50-plan.md` §5.1 M4 line ("sig-
mismatch matrix (author bad, root bad, both bad -- all refuse)") in
paideia-os. Local design at `design/test-matrix.md` §2.

## 1. Purpose

Prove that `pkg install` REFUSES every fixture whose sigblock does
not verify against both `AUTHOR_PUBKEY` and `ROOT_PUBKEY` -- the
D4 (dual-signed pillar) load-bearing property. Three cells:

| Cell        | Author sig | Root sig | Expected outcome                |
|-------------|------------|----------|--------------------------------|
| author-bad  | corrupted  | valid    | refuse (exit 1)                 |
| root-bad    | valid      | corrupted| refuse (exit 1)                 |
| both-bad    | corrupted  | corrupted| refuse (exit 1)                 |

At M4 all three refuse at the same diagnostic (`INSTALL_ERR_VERIFY`
-- `mc_verify_signatures` returns `MC_VERIFY_STUB` pending paideia-as
v0.33-crypto-kdf). At M5, when the intrinsic lands, the fixtures
distinguish: `author-bad` -> `MC_ERR_AUTHOR_SIG`, `root-bad` ->
`MC_ERR_ROOT_SIG`, `both-bad` -> `MC_ERR_AUTHOR_SIG` (first-fail).
The driver + fixtures are unchanged across the M4->M5 transition;
the `expected/*.txt` files diff-flip.

## 2. Fixture generation

`gen-fixtures.sh` builds three fixtures deterministically from a
base manifest that carries a well-formed 64B header (magic, version=
1, flags=0, body_len<=1MiB, sigblock_len matching a 2*ML-DSA-65
pair). The three cells then flip one distinct byte per cell (XOR
with 0x5A) at:

- `author-bad`: 100 bytes into the author sig
  (offset = 64 + body_len + 4 + 100).
- `root-bad`:   100 bytes into the root sig
  (offset = 64 + body_len + 4 + sig_len_author + 4 + 100).
- `both-bad`:   both flips.

Because the paideia-as v0.33-crypto-kdf sign path is not on the
toolchain, the base manifest carries a placeholder sigblock (two
3293-byte NUL-padded blocks with a nonzero first byte so
sigblock_len parses). When v0.33 lands, `gen-fixtures.sh` will
re-source the placeholder blocks from a real signer + drop the
placeholder in the same commit that unlocks the real sig
discrimination.

## 3. Driver

`run.sh` walks the three cells. For each:

1. Stages the fixture at `$PDX_STAGING/pkg.pdxsig`.
2. Invokes `$PKG_BINARY install pkg` (default `./build-out/pkg`).
3. Captures exit + first stderr line.
4. Diffs against `expected/<cell>.txt`.

Passes for the cell iff both fields match. The driver exits 0 iff
every cell passed; otherwise exits with the count of failed cells.

## 4. Env vars

- `PKG_BINARY` -- path to the pkg binary (default `build-out/pkg`).
- `PDX_STAGING` -- staging dir (default `/tmp/pkg-staging`).
- `PDX_FIXTURE_DIR` -- fixture output dir (default
  `tests/m4-001-sig-mismatch/fixtures`).

## 5. Substrate gates

- `paideia-as v0.33-crypto-kdf` -- when this lands, the driver's
  expected-outcome files flip from `MC_VERIFY_STUB` diagnostic to
  the specific `MC_ERR_AUTHOR_SIG` / `MC_ERR_ROOT_SIG` refusals.
- `KIND_PDXFS_FILE` staging read -- pkg's `_install_staging` .bss
  buffer is currently populated by convention (staging path is
  the input contract). Once the M3+ file-read wire-through lands
  (`design/install-flow.md` §5), the fixture staging path becomes
  the file read source and this driver moves the fixture into the
  right filesystem path instead of a .bss preload.

## 6. Why every cell asserts the same thing at M4

The M4 driver asserts "refuse" (exit 1) as the primary property.
Discrimination between the three refusal reasons is a `mc_verify_
signatures` property, and that function returns `MC_VERIFY_STUB`
today for every input. Asserting the STUB diagnostic here is
correct at M4 -- it proves the pipeline reached the seam, which is
the load-bearing shape property for M5 when the intrinsic lands.
An assertion that expected the three cells to give three different
error codes today would fail loudly on every run; the M4 assertion
is stable across the M4->M5 substrate transition modulo one edit
per `expected/*.txt`.
