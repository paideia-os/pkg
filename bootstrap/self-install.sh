#!/bin/sh
# bootstrap/self-install.sh -- pkg.M2-005
# POSIX-sh translation of bootstrap/self-install.pds for the pre-shell
# window (before shell.M2-004 lands the .pds executor).
#
# Wave: R49  Milestone: M2  Issue: #8 (pkg.M2-005)
# Spec:  design/self-install-bootstrap.md §2 + §5
#
# The .pds and .sh files run the same ten steps in the same order with
# the same environment-variable contract. A change to one MUST touch
# the other; the M4 smoke matrix diffs the two.

set -e

: ${PDX_BUILD_OUT:=/tmp/pkg-stage0-build}
: ${PDX_STAGING:=/tmp/pkg-staging}
: ${PDX_AUTHOR_KEY:=$HOME/.pdx/keys/author.pk}
: ${PDX_ROOT_KEY:=$HOME/.pdx/keys/paideia-root.pk}

mkdir -p "$PDX_BUILD_OUT"
mkdir -p "$PDX_STAGING"

# Step 1
paideia-as build manifest.pdxproj -o "$PDX_BUILD_OUT/pkg-stage0"

# Steps 2-3
cp "$PDX_BUILD_OUT/pkg-stage0"       "$PDX_BUILD_OUT/pkg-stage0.bin"
cp caps.decl                          "$PDX_BUILD_OUT/pkg-stage0.caps"

# Step 4
tar cf "$PDX_BUILD_OUT/pkg-stage0.tar" \
    -C "$PDX_BUILD_OUT" pkg-stage0.bin pkg-stage0.caps

# Step 5
if [ -n "$PDX_FIXTURE_SIG" ] && [ -f "$PDX_FIXTURE_SIG" ]; then
    cp "$PDX_FIXTURE_SIG" "$PDX_BUILD_OUT/pkg-stage0.pdxsig"
else
    paideia-as sign \
        --author-key "$PDX_AUTHOR_KEY" \
        --root-key   "$PDX_ROOT_KEY" \
        "$PDX_BUILD_OUT/pkg-stage0.tar" \
        -o           "$PDX_BUILD_OUT/pkg-stage0.pdxsig"
fi

# Steps 6-7
cp "$PDX_BUILD_OUT/pkg-stage0.pdxsig"  "$PDX_STAGING/pkg.pdxsig"
cp "$PDX_BUILD_OUT/pkg-stage0.tar"     "$PDX_STAGING/pkg.tar"

# Step 8
"$PDX_BUILD_OUT/pkg-stage0" install pkg
INSTALL_RC=$?

exit $INSTALL_RC
