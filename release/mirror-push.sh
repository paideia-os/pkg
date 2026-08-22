#!/bin/sh
# release/mirror-push.sh -- pkg.M5-002
# pkgs.paideia-os mirror-push driver
#
# Wave: R49  Milestone: M5  Issue: #17
# Spec: release/mirror-push.md (protocol; steps 1-10)
#       design/manifest-format.md §2 (mirror layout)
#       design/release-1.0.md §6 (release-time content)
#
# Usage:
#   release/mirror-push.sh <in-dir> [<mirror-url>]
#     <in-dir>       directory produced by release/1.0/gen-manifest.sh
#                    (must contain pkg.tar + manifest.pdxsig)
#     <mirror-url>   optional override for $PDX_MIRROR_URL
#
# Env:
#   PDX_MIRROR_URL    default: https://pkgs.paideia-os/
#   PDX_MIRROR_AUTH   default: $HOME/.pdx/keys/mirror-token
#   PDX_ROOT_KEY      default: $HOME/.pdx/keys/paideia-root.pk
#   PDX_DRY_RUN       if "1", log the sequence without any PUT (default at M5)
#   PDX_FORCE_STUB    if "1", upload STUB-signed artefacts
#
# Exit codes:
#   0  -- push succeeded (or dry-run completed)
#   1  -- usage error
#   2  -- source-file missing (pkg.tar or manifest.pdxsig)
#   3  -- pre-flight failure (magic mismatch / body_len over ceiling /
#         remote 200 on immutable path / auth missing)
#   4  -- upload failure (curl non-zero / atomic swap failed)
#   5  -- index re-sign failure (paideia-as v0.33-crypto-kdf gate)

set -eu

USAGE="Usage: $0 <in-dir> [<mirror-url>]"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "$USAGE" >&2
    exit 1
fi

IN_DIR="$1"
: "${PDX_MIRROR_URL:=${2:-https://pkgs.paideia-os/}}"
: "${PDX_MIRROR_AUTH:=$HOME/.pdx/keys/mirror-token}"
: "${PDX_ROOT_KEY:=$HOME/.pdx/keys/paideia-root.pk}"
: "${PDX_DRY_RUN:=1}"     # default DRY_RUN at M5-close per mirror-push.md §5
: "${PDX_FORCE_STUB:=0}"

# --- Step 1: verify local artefacts ---------------------------------------

MANIFEST="$IN_DIR/manifest.pdxsig"
TAR="$IN_DIR/pkg.tar"

if [ ! -f "$MANIFEST" ]; then
    echo "mirror-push: missing $MANIFEST" >&2
    exit 2
fi
if [ ! -f "$TAR" ]; then
    echo "mirror-push: missing $TAR" >&2
    exit 2
fi

# Magic check: first 8 bytes must be "pdxsig\0\0" (0x70 0x64 0x78 0x73 0x69 0x67 0x00 0x00).
MAGIC_HEX=$(od -An -tx1 -N8 "$MANIFEST" | tr -d ' \n')
if [ "$MAGIC_HEX" != "7064787369670000" ]; then
    echo "mirror-push: bad magic in $MANIFEST (got $MAGIC_HEX)" >&2
    exit 3
fi

# body_len ceiling: 1 MiB per MC_BODY_LEN_MAX in src/manifest_codec.pdx.
BODY_LEN=$(od -An -tu8 -N8 -j16 "$MANIFEST" | tr -d ' \n')
if [ "$BODY_LEN" -gt 1048576 ]; then
    echo "mirror-push: body_len=$BODY_LEN exceeds MC_BODY_LEN_MAX (1 MiB)" >&2
    exit 3
fi

# --- Step 2: extract identity (name + version) from manifest body ---------
#
# The first two KV records are PKG_NAME (tag 0x0001) and PKG_VERSION (tag
# 0x0002), by generator convention (release/1.0/manifest-layout.md §3).
# Parse them via od + shell arithmetic; refuse if the order differs
# (a v1.0.0 manifest that reorders is a generator bug we surface here).

read_kv_string() {
    # $1 = manifest path, $2 = expected tag (hex string), $3 = starting offset
    _f="$1"; _expected_tag="$2"; _off="$3"
    _tag=$(od -An -tx2 -N2 -j"$_off" "$_f" | tr -d ' \n')
    _len=$(od -An -tu2 -N2 -j"$((_off + 2))" "$_f" | tr -d ' \n')
    if [ "$_tag" != "$_expected_tag" ]; then
        echo "mirror-push: expected tag $_expected_tag at offset $_off, got $_tag" >&2
        exit 3
    fi
    _val=$(dd if="$_f" bs=1 count="$_len" skip="$((_off + 4))" 2>/dev/null)
    printf '%s|%d' "$_val" "$_len"
}

# Body starts at offset 64.
NAME_KV=$(read_kv_string "$MANIFEST" "0100" 64)
NAME=$(printf '%s' "$NAME_KV" | awk -F'|' '{print $1}')
NAME_LEN=$(printf '%s' "$NAME_KV" | awk -F'|' '{print $2}')

VER_OFF=$((64 + 4 + NAME_LEN))
VER_KV=$(read_kv_string "$MANIFEST" "0200" "$VER_OFF")
VERSION=$(printf '%s' "$VER_KV" | awk -F'|' '{print $1}')

REMOTE_PATH="$NAME/$VERSION"

echo "mirror-push: identity = $NAME @ $VERSION"
echo "mirror-push: remote   = $PDX_MIRROR_URL$REMOTE_PATH/"
echo "mirror-push: dry_run  = $PDX_DRY_RUN"

# --- Step 3: check remote for prior upload (immutability) ----------------

REMOTE_MANIFEST_URL="$PDX_MIRROR_URL$REMOTE_PATH/manifest.pdxsig"
REMOTE_TAR_URL="$PDX_MIRROR_URL$REMOTE_PATH/pkg.tar"

if [ "$PDX_DRY_RUN" = "0" ]; then
    if command -v curl >/dev/null 2>&1; then
        HEAD_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
                    -I "$REMOTE_MANIFEST_URL" || echo 0)
        if [ "$HEAD_CODE" = "200" ]; then
            LOCAL_HASH=$(sha256sum "$MANIFEST" | awk '{print $1}')
            REMOTE_HASH=$(curl -s "$REMOTE_MANIFEST_URL" | sha256sum | awk '{print $1}')
            echo "mirror-push: REFUSE - $NAME@$VERSION already uploaded" >&2
            echo "  local  sha256:  $LOCAL_HASH" >&2
            echo "  remote sha256:  $REMOTE_HASH" >&2
            exit 3
        fi
    else
        echo "mirror-push: curl unavailable; cannot pre-flight remote" >&2
        exit 3
    fi
fi

# --- Steps 4-5: upload pkg.tar + manifest.pdxsig to .pending paths ------

do_put() {
    _local="$1"; _remote="$2"; _ctype="$3"
    if [ "$PDX_DRY_RUN" = "1" ]; then
        echo "  [dry-run] PUT $_remote  <-  $_local  (Content-Type: $_ctype)"
        return 0
    fi
    if [ ! -r "$PDX_MIRROR_AUTH" ]; then
        echo "mirror-push: missing auth token at $PDX_MIRROR_AUTH" >&2
        exit 3
    fi
    _token=$(cat "$PDX_MIRROR_AUTH")
    curl -sS -X PUT \
        -H "Authorization: Bearer $_token" \
        -H "Content-Type: $_ctype" \
        --data-binary "@$_local" \
        "$_remote" >/dev/null
}

do_move() {
    _from="$1"; _to="$2"
    if [ "$PDX_DRY_RUN" = "1" ]; then
        echo "  [dry-run] MOVE $_from  ->  $_to"
        return 0
    fi
    _token=$(cat "$PDX_MIRROR_AUTH")
    curl -sS -X MOVE \
        -H "Authorization: Bearer $_token" \
        -H "Destination: $_to" \
        "$_from" >/dev/null
}

echo "mirror-push: upload sequence ---"
do_put "$TAR"      "$REMOTE_TAR_URL.pending"       "application/x-tar"
do_put "$MANIFEST" "$REMOTE_MANIFEST_URL.pending"  "application/vnd.paideia.pdxsig"

# --- Step 6: atomic-swap pending pair to canonical names -----------------

do_move "$REMOTE_TAR_URL.pending"      "$REMOTE_TAR_URL"
do_move "$REMOTE_MANIFEST_URL.pending" "$REMOTE_MANIFEST_URL"

# --- Steps 7-10: index update ---------------------------------------------

INDEX_URL="$PDX_MIRROR_URL/index.pdxsig"
INDEX_LOCAL="$IN_DIR/index.pdxsig.new"
MANIFEST_HASH=$(sha256sum "$MANIFEST" | awk '{print $1}')
UPLOAD_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Step 7: fetch existing index.pdxsig (may be absent -> empty body).
INDEX_PRIOR="$IN_DIR/index.pdxsig.prior"
if [ "$PDX_DRY_RUN" = "1" ]; then
    echo "  [dry-run] GET $INDEX_URL  ->  $INDEX_PRIOR"
    : > "$INDEX_PRIOR"     # simulate empty prior
else
    curl -sS -o "$INDEX_PRIOR" "$INDEX_URL" || : > "$INDEX_PRIOR"
fi

# Step 8: append/update the row for <name>.
# The index body is a newline-separated text table at v1 (post-1.0 will
# migrate to a KV format matching manifest.pdxsig; kept simple for the
# M5-close scaffolding). Format:
#     <name> <version> <manifest_sha256> <upload_ts>
# The row for <name> at this version replaces any prior row for the same
# (name, version) pair; historical (name, older-version) rows are
# preserved for `pkg install <name>@<older>`.
{
    if [ -s "$INDEX_PRIOR" ]; then
        awk -v n="$NAME" -v v="$VERSION" '$1 == n && $2 == v {next} {print}' \
            "$INDEX_PRIOR"
    fi
    echo "$NAME $VERSION $MANIFEST_HASH $UPLOAD_TS"
} > "$INDEX_LOCAL"

echo "mirror-push: index rows ---"
sed 's/^/  /' "$INDEX_LOCAL"

# Step 9: re-sign index.pdxsig with paideia_root key.
INDEX_SIGNED="$IN_DIR/index.pdxsig.signed"
if [ "$PDX_FORCE_STUB" = "1" ] || [ ! -r "$PDX_ROOT_KEY" ]; then
    echo "  [stub] re-sign index skipped (PDX_FORCE_STUB=1 or missing root key)"
    # STUB envelope: prepend an 8-byte "pdxsig\0\0" magic + zero-length
    # marker so the shape is a valid pdxsig envelope even without the
    # real signing pipeline.
    {
        printf 'pdxsig\0\0'
        printf '\0\0\0\0\0\0\0\0'   # sig_len_root = 0 STUB
        cat "$INDEX_LOCAL"
    } > "$INDEX_SIGNED"
else
    if ! paideia-as sign --key "$PDX_ROOT_KEY" \
            --alg ml-dsa-65 \
            --in "$INDEX_LOCAL" \
            --out "$INDEX_SIGNED"; then
        echo "mirror-push: index re-sign failed (v0.33-crypto-kdf gate)" >&2
        exit 5
    fi
fi

# Step 10: upload re-signed index + atomic swap.
do_put  "$INDEX_SIGNED" "$INDEX_URL.pending" "application/vnd.paideia.pdxsig"
do_move "$INDEX_URL.pending" "$INDEX_URL"

# --- Cleanup + report ------------------------------------------------------

REPORT="$IN_DIR/mirror-push-report.txt"
{
    echo "pkg mirror-push report"
    echo "======================"
    date -u +'%Y-%m-%dT%H:%M:%SZ'
    echo
    echo "name           : $NAME"
    echo "version        : $VERSION"
    echo "manifest sha256: $MANIFEST_HASH"
    echo "remote base    : $PDX_MIRROR_URL$REMOTE_PATH/"
    echo "index url      : $INDEX_URL"
    echo "dry_run        : $PDX_DRY_RUN"
    if [ "$PDX_DRY_RUN" = "1" ]; then
        echo "state          : DRY-RUN COMPLETE (no network writes)"
    else
        echo "state          : PUSH COMPLETE"
    fi
} | tee "$REPORT"

if [ "$PDX_DRY_RUN" != "1" ]; then
    rm -f "$INDEX_PRIOR" "$INDEX_LOCAL" "$INDEX_SIGNED"
fi

exit 0
