# pkg — self-install bootstrap (M2-005)

**Wave:** R49  Milestone: M2  Issue: #8 (pkg.M2-005)
**Upstream:** [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 M2 line ("Bootstrapped self-install path: `pkg install pkg` runs
against a from-source build"); [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6.5 bootstrap chain.

## 1. The chicken-and-egg problem

Every tool in the R49/R50 wave ships as a signed package installed by
pkg. Pkg is a tool. Therefore pkg must install pkg. The first-ever
install has no prior pkg to invoke — that is the bootstrap.

The plan-doc D4/§6.5 resolution:

1. The first pkg binary is produced directly by `paideia-as build`
   against this repo's sources. Call this the **stage-0 pkg**.
2. The stage-0 pkg runs against the same repo's sources to produce a
   signed package and install it under `/pkgs/pkg-0.2.0-m2/` +
   symlink `/bin/pkg`. This is the **self-install** step.
3. All subsequent installs go through the signed `/bin/pkg`.

At M2, this doc plus `bootstrap/self-install.pds` freeze the sequence.
The signing step at (2) becomes real at M5 when paideia-as v0.33-crypto-
kdf lands. Until then, self-install exercises the pipeline shape and
refuses at the crypto seam per `design/install-flow.md` §3.1 — the M4
smoke matrix asserts the refusal.

## 2. Sequence

The `bootstrap/self-install.pds` script (see companion file) implements
the ten-step chain below. It is a `.pds` script per
[`design/terminal/pds-format.md`](https://github.com/paideia-os/paideia-os/blob/main/design/terminal/pds-format.md)
(consumed by shell M2 once shell.M2-004 lands; a POSIX-sh subset
translation lives in `bootstrap/self-install.sh` for the pre-shell
window).

```
Step 1  paideia-as build manifest.pdxproj -o /tmp/pkg-stage0
Step 2  cp /tmp/pkg-stage0 /tmp/pkg-stage0.bin
Step 3  cp caps.decl        /tmp/pkg-stage0.caps
Step 4  tar cf /tmp/pkg-stage0.tar -C /tmp pkg-stage0.bin pkg-stage0.caps
Step 5  paideia-as sign --author-key ~/.pdx/keys/author.pk \
                      --root-key ~/.pdx/keys/paideia-root.pk \
                      /tmp/pkg-stage0.tar \
                      -o /tmp/pkg-stage0.pdxsig
        # At M2 this step is a paideia-as v0.33-crypto-kdf gate. The
        # M2 harness copies a fixture .pdxsig into /tmp/pkg-stage0.pdxsig
        # so the pipeline reaches the install verify SEAM and refuses
        # deterministically -- the M4 assertion.
Step 6  cp /tmp/pkg-stage0.pdxsig   /tmp/pkg-staging/pkg.pdxsig
Step 7  cp /tmp/pkg-stage0.tar      /tmp/pkg-staging/pkg.tar
Step 8  /tmp/pkg-stage0 install pkg
        # Reaches PkgInstall::pkg_install_body's ManifestCodec::
        # mc_verify_signatures SEAM which returns MC_VERIFY_STUB at M2.
        # Exit 1 with the "sig verify unavailable" diagnostic per
        # design/install-flow.md §3.1 -- the intended M2 halt point.
Step 9  # M3+ only: verify the newly-installed /bin/pkg matches
        #           /tmp/pkg-stage0 by fingerprint.
Step 10 # M3+ only: remove the stage-0 binary + tar.
```

## 3. Why the pipeline halts at MC_VERIFY_STUB is a feature

The M2 self-install intentionally stops at the crypto seam. Two
outcomes both prove the M2 milestone:

- **Green**: pkg_install_body reaches step 5 (INSTALL_STEP_VERIFY),
  refuses with the "sig verify unavailable" diagnostic, exit 1.
  The `install_step` .bss slot reads `3` (INSTALL_STEP_VERIFY).
  This is the M4 smoke assertion.
- **Red**: pkg_install_body exits at any earlier step (header parse,
  usage error, or a non-seam failure). This means the M2 pipeline is
  broken and the M4 matrix will fail loudly.

A "green" M2 self-install is not a functioning install — no bytes
land under `/pkgs/pkg-0.2.0-m2/`. What it proves is:

1. The paideia-as build chain compiles pkg's own sources.
2. The stage-0 binary runs (loader executes it, argv reaches
   `PkgMain::pkg_main`).
3. Argv parses (`pos_count == 2`, `pos_ptrs[1]` non-NULL).
4. Manifest header decodes (`mc_read_header` returns MC_OK against
   a well-formed fixture).
5. The verify seam is reachable — meaning M3's wire-through will
   flip the exit code from 1 to 0 without needing any shape change.

## 4. Cross-repo dependencies activated at self-install

Nothing new — the bootstrap consumes only:

- `paideia-as build` (already the toolchain).
- Fixture manifest + tar (this repo's `tests/fixtures/` — populated
  at M4 alongside the sig-mismatch matrix).
- `PkgMain::pkg_main` + `PkgInstall::pkg_install_body` (this repo,
  M1 + M2-003).

At M3 the self-install additionally depends on paideia-as v0.33-
crypto-kdf (for the `paideia-as sign` step + the `ml_dsa_65_verify`
intrinsic at PkgInstall's verify SEAM). At M5 the fixture becomes
the real dual-signed pkg-1.0 release.

## 5. Where the pds file lives

`bootstrap/self-install.pds` — a shell-executable `.pds` script per
`design/terminal/pds-format.md`. Once shell.M2-004 (`.pds` script
executor) lands, the invocation is:

```
$ shell bootstrap/self-install.pds
```

Before shell.M2-004 (and for CI / test-harness use), a POSIX-sh
translation `bootstrap/self-install.sh` runs the same ten steps.
Both files are kept in tree so a change to the sequence updates both;
divergence is a M4 test failure.
