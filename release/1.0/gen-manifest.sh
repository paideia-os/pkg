#!/bin/sh
# release/1.0/gen-manifest.sh -- pkg.M5-001
# Generate pkg-1.0.0/manifest.pdxsig + pkg-1.0.0/pkg.tar.
#
# Wave: R49  Milestone: M5  Issue: #16
# Spec: design/manifest-format.md §3-§5 (byte layout)
#       design/release-1.0.md  §3-§4 (release-time content)
#       release/1.0/manifest-layout.md (byte-level per-field annotation)
#
# Usage:
#   release/1.0/gen-manifest.sh <build-out/pkg> <out-dir>
#     <build-out/pkg>  path to the paideia-as-built pkg binary
#     <out-dir>        directory to populate (created if absent)
#
# Env:
#   PDX_AUTHOR_KEY   path to author signing key (default: ~/.pdx/keys/author.pk)
#   PDX_ROOT_KEY     path to paideia-root signing key (default: ~/.pdx/keys/paideia-root.pk)
#   PDX_STUB_SIG     if set to "1", skip paideia-as sign and emit a STUB
#                    sigblock with the PDX_SIG_PENDING_V033 fill pattern.
#                    Default: auto-STUB if `paideia-as sign` unavailable.
#
# Exit codes:
#   0 -- manifest + tar written to <out-dir>/
#   1 -- usage error
#   2 -- source-file missing (bin, caps.decl, deps.list, or doc/pkg.pdxdoc)
#   3 -- paideia-as sign failed (only when PDX_STUB_SIG != 1)
#
# Output artefacts (both under <out-dir>/):
#   pkg.tar              -- POSIX tar with bin/pkg + caps.decl + deps.list +
#                           doc/pkg.pdxdoc + manifest.pdxsig
#   manifest.pdxsig      -- dual-signed (or STUB-signed) manifest
#   manifest-report.txt  -- on-stdout layout report captured for review
#
# At M5-close the auto-STUB path is the default (v0.33-crypto-kdf is not
# yet in the toolchain). When the crypto substrate lands, unset
# PDX_STUB_SIG and re-run this script; the emitted manifest.pdxsig
# diff-flips to real signatures and every offset holds.

set -eu

USAGE="Usage: $0 <build-out/pkg-binary> <out-dir>"

if [ "$#" -ne 2 ]; then
    echo "$USAGE" >&2
    exit 1
fi

BIN_PATH="$1"
OUT_DIR="$2"

: "${PDX_AUTHOR_KEY:=$HOME/.pdx/keys/author.pk}"
: "${PDX_ROOT_KEY:=$HOME/.pdx/keys/paideia-root.pk}"
: "${PDX_STUB_SIG:=auto}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# --- Pre-flight file checks ------------------------------------------------

for f in "$BIN_PATH" "$REPO_ROOT/caps.decl" "$REPO_ROOT/doc/pkg.pdxdoc"; do
    if [ ! -f "$f" ]; then
        echo "gen-manifest: source file missing: $f" >&2
        exit 2
    fi
done

# deps.list is generated from manifest.pdxproj `deps:` block at release
# time. If a static deps.list exists in the repo we use it; else we
# derive one on the fly from manifest.pdxproj so the M5-close artefact
# is self-contained.
if [ -f "$REPO_ROOT/deps.list" ]; then
    DEPS_LIST="$REPO_ROOT/deps.list"
else
    DEPS_LIST="$OUT_DIR/deps.list.gen"
    mkdir -p "$OUT_DIR"
    awk '/^deps:/{f=1;next} /^[^ ]/{f=0} f && /^  - /{sub(/^  - /,""); print}' \
        "$REPO_ROOT/manifest.pdxproj" > "$DEPS_LIST"
fi

mkdir -p "$OUT_DIR"

# --- Stage the file tree ---------------------------------------------------

STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/doc"
cp "$BIN_PATH"                   "$STAGE/bin/pkg"
cp "$REPO_ROOT/caps.decl"        "$STAGE/caps.decl"
cp "$DEPS_LIST"                  "$STAGE/deps.list"
cp "$REPO_ROOT/doc/pkg.pdxdoc"   "$STAGE/doc/pkg.pdxdoc"

chmod 0755 "$STAGE/bin/pkg"
chmod 0644 "$STAGE/caps.decl" "$STAGE/deps.list" "$STAGE/doc/pkg.pdxdoc"

# --- Sign-availability decision --------------------------------------------

if [ "$PDX_STUB_SIG" = "auto" ]; then
    if command -v paideia-as >/dev/null 2>&1 && \
       paideia-as sign --help >/dev/null 2>&1; then
        PDX_STUB_SIG=0
    else
        PDX_STUB_SIG=1
    fi
fi

# --- Manifest bytes: header + body assembly -------------------------------
#
# The body is written first (KV records) so its length + sha3 are known
# before the header is finalised. All integer fields are little-endian.

BODY_FILE="$OUT_DIR/manifest.body.bin"
: > "$BODY_FILE"

# Helper: little-endian u16 to file
put_u16() {
    printf '\\x%02x\\x%02x' \
        $(( $1 & 0xff )) \
        $(( ($1 >> 8) & 0xff )) \
        | xargs printf '%b' >> "$BODY_FILE"
}

# Helper: little-endian u32 to file (into $BODY_FILE unless $2 is a path)
put_u32() {
    _target="${2:-$BODY_FILE}"
    printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $(( $1 & 0xff )) \
        $(( ($1 >> 8)  & 0xff )) \
        $(( ($1 >> 16) & 0xff )) \
        $(( ($1 >> 24) & 0xff )) \
        | xargs printf '%b' >> "$_target"
}

# Helper: little-endian u64 to file (0-arg $1=value, $2=path optional)
put_u64() {
    _target="${2:-$BODY_FILE}"
    _v=$1
    _i=0
    while [ "$_i" -lt 8 ]; do
        printf '\\x%02x' $(( ($_v >> (_i * 8)) & 0xff )) \
            | xargs printf '%b' >> "$_target"
        _i=$((_i + 1))
    done
}

# Helper: fill kv_value with a STUB pattern to exactly $2 bytes,
# then append.  Pattern chosen from $1 (H3 / PK / FPR / SIG).
put_stub_fill() {
    _tag_kind="$1"; _len="$2"
    case "$_tag_kind" in
        H3)  _pat="PDX_H3_PENDING_V033-" ;;
        PK)  _pat="PDX_PK_PENDING_V033-" ;;
        FPR) _pat="PDX_FPR_PENDING_V033-" ;;
        SIG) _pat="PDX_SIG_PENDING_V033-" ;;
        *)   echo "gen-manifest: bad stub kind $_tag_kind" >&2; exit 3 ;;
    esac
    _out=""
    while [ "${#_out}" -lt "$_len" ]; do
        _out="${_out}${_pat}"
    done
    printf '%s' "$_out" | dd bs=1 count="$_len" 2>/dev/null >> "$BODY_FILE"
}

# ---- KV records (order per manifest-layout.md §3) ------------------------

emit_kv_bytes() {
    _tag=$1; _bytes="$2"
    _len=${#_bytes}
    put_u16 "$_tag"
    put_u16 "$_len"
    printf '%s' "$_bytes" >> "$BODY_FILE"
}

emit_kv_stub() {
    _tag=$1; _stubkind="$2"; _len=$3
    put_u16 "$_tag"
    put_u16 "$_len"
    put_stub_fill "$_stubkind" "$_len"
}

emit_kv_u64() {
    _tag=$1; _val=$2
    put_u16 "$_tag"
    put_u16 8
    put_u64 "$_val"
}

# 1. PKG_NAME
emit_kv_bytes 0x0001 "pkg"
# 2. PKG_VERSION
emit_kv_bytes 0x0002 "1.0.0"
# 3. PKG_REPO_URL
emit_kv_bytes 0x0003 "https://github.com/paideia-os/pkg"
# 4. PAIDEIA_AS_VER
emit_kv_bytes 0x0004 "0.33-crypto-kdf"
# 5. AUTHOR_PUBKEY
emit_kv_stub  0x0010 PK  1952
# 6. AUTHOR_FPR
emit_kv_stub  0x0011 FPR 32
# 7. AUTHOR_EXPIRY
emit_kv_u64   0x0012 0
# 8. ROOT_PUBKEY
emit_kv_stub  0x0020 PK  1952
# 9. ROOT_FPR
emit_kv_stub  0x0021 FPR 32
# 10. ROOT_EXPIRY
emit_kv_u64   0x0022 0
# 11. CAPS_DECL_HASH
emit_kv_stub  0x0030 H3  32
# 12. DEPS_LIST_HASH
emit_kv_stub  0x0031 H3  32
# 13. BUILD_REPRODUCER
emit_kv_bytes 0x00F0 "paideia-os/pkg v1.0.0 - reproducible source build"

# 14-18. FILE_INVENTORY records for the packaged files.
# Layout (per §4.3): mode:u32 LE, path_len:u32 LE, sha3_256:32B, path.
emit_file_inv() {
    _path="$1"; _mode="$2"
    _plen=${#_path}
    _kv_len=$(( 40 + _plen ))       # 4 + 4 + 32 + path_len
    put_u16 0x0040                    # tag FILE_INVENTORY
    put_u16 "$_kv_len"
    put_u32 "$_mode"
    put_u32 "$_plen"
    put_stub_fill H3 32               # sha3_256 STUB fill
    printf '%s' "$_path" >> "$BODY_FILE"
}

# Enumerated in lexicographic path order.
emit_file_inv "bin/pkg"          0x000081ED   # regular, 0755
emit_file_inv "caps.decl"        0x000081A4   # regular, 0644
emit_file_inv "deps.list"        0x000081A4
emit_file_inv "doc/pkg.pdxdoc"   0x000081A4
emit_file_inv "manifest.pdxsig"  0x000081A4

BODY_LEN=$(wc -c < "$BODY_FILE" | tr -d ' ')

# ---- Body sha3-256 -------------------------------------------------------

if [ "$PDX_STUB_SIG" = "1" ]; then
    # STUB fill for body_sha3 halves. 16 bytes each half.
    BODY_SHA3_HEX="504458 5F48335F 50454E44 494E475F 56303333 2D504458 5F48335F 50454E44"
    # (Hex of "PDX_H3_PENDING_V033-PDX_H3_PEND"; 32 bytes when unpacked.)
else
    if command -v sha3sum >/dev/null 2>&1; then
        BODY_SHA3_HEX=$(sha3sum -a 256 "$BODY_FILE" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        BODY_SHA3_HEX=$(openssl dgst -sha3-256 "$BODY_FILE" | awk '{print $NF}')
    else
        echo "gen-manifest: no sha3-256 tool (need sha3sum or openssl>=1.1.1)" >&2
        exit 3
    fi
fi

# ---- Header (64 B) -------------------------------------------------------

HEADER_FILE="$OUT_DIR/manifest.header.bin"
: > "$HEADER_FILE"

# Offset 0: magic "pdxsig\0\0"
printf 'pdxsig\0\0' >> "$HEADER_FILE"
# Offset 8: format_version = 1 (u32 LE)
put_u32 1 "$HEADER_FILE"
# Offset 12: header_flags = 0 (u32 LE)
put_u32 0 "$HEADER_FILE"
# Offset 16: body_len (u64 LE)
put_u64 "$BODY_LEN" "$HEADER_FILE"
# Offset 24: body_sha3_256_lo (8B) and 32: body_sha3_256_hi (8B).
# Write the 32-byte hash as raw bytes; lo/hi are just the first 16B / next 16B.
printf '%s' "$BODY_SHA3_HEX" | tr -d ' \n' | \
    sed 's/../\\x&/g' | xargs printf '%b' >> "$HEADER_FILE"
# Offset 40: sigblock_len = 6594 (u64 LE) = 4 + 3293 + 4 + 3293
SIGBLOCK_LEN=$((4 + 3293 + 4 + 3293))
put_u64 "$SIGBLOCK_LEN" "$HEADER_FILE"
# Offset 48: pubkey_len_author = 1952 (u32 LE)
put_u32 1952 "$HEADER_FILE"
# Offset 52: pubkey_len_root   = 1952 (u32 LE)
put_u32 1952 "$HEADER_FILE"
# Offset 56: created_unix_secs = 1787961600 (2026-08-22T00:00:00Z)
put_u64 1787961600 "$HEADER_FILE"

HEADER_LEN=$(wc -c < "$HEADER_FILE" | tr -d ' ')
if [ "$HEADER_LEN" -ne 64 ]; then
    echo "gen-manifest: header is $HEADER_LEN B, expected 64" >&2
    exit 3
fi

# ---- Sigblock ------------------------------------------------------------

SIG_FILE="$OUT_DIR/manifest.sigblock.bin"
: > "$SIG_FILE"

if [ "$PDX_STUB_SIG" = "1" ]; then
    # STUB: two length-prefixed SIG fills.
    put_u32 3293 "$SIG_FILE"
    # STUB fill for author sig
    _out=""
    while [ "${#_out}" -lt 3293 ]; do _out="${_out}PDX_SIG_PENDING_V033-"; done
    printf '%s' "$_out" | dd bs=1 count=3293 2>/dev/null >> "$SIG_FILE"
    put_u32 3293 "$SIG_FILE"
    # STUB fill for root sig
    _out=""
    while [ "${#_out}" -lt 3293 ]; do _out="${_out}PDX_SIG_PENDING_V033-"; done
    printf '%s' "$_out" | dd bs=1 count=3293 2>/dev/null >> "$SIG_FILE"
else
    # Real sign path (v0.33-crypto-kdf).
    SIGN_INPUT="$OUT_DIR/manifest.header-body.bin"
    cat "$HEADER_FILE" "$BODY_FILE" > "$SIGN_INPUT"

    AUTHOR_SIG="$OUT_DIR/author.sig"
    ROOT_SIG="$OUT_DIR/root.sig"

    paideia-as sign --key "$PDX_AUTHOR_KEY" \
        --alg ml-dsa-65 --in "$SIGN_INPUT" --out "$AUTHOR_SIG" || exit 3
    paideia-as sign --key "$PDX_ROOT_KEY" \
        --alg ml-dsa-65 --in "$SIGN_INPUT" --out "$ROOT_SIG"   || exit 3

    AUTHOR_LEN=$(wc -c < "$AUTHOR_SIG" | tr -d ' ')
    ROOT_LEN=$(wc -c   < "$ROOT_SIG"   | tr -d ' ')
    put_u32 "$AUTHOR_LEN" "$SIG_FILE"
    cat "$AUTHOR_SIG" >> "$SIG_FILE"
    put_u32 "$ROOT_LEN" "$SIG_FILE"
    cat "$ROOT_SIG"   >> "$SIG_FILE"

    rm -f "$SIGN_INPUT" "$AUTHOR_SIG" "$ROOT_SIG"
fi

# ---- Assemble manifest.pdxsig -------------------------------------------

cat "$HEADER_FILE" "$BODY_FILE" "$SIG_FILE" > "$OUT_DIR/manifest.pdxsig"
rm -f "$HEADER_FILE" "$BODY_FILE" "$SIG_FILE"

# Copy manifest into the stage tree so the tar carries it.
cp "$OUT_DIR/manifest.pdxsig" "$STAGE/manifest.pdxsig"

# ---- Tar (POSIX ustar, member order lexicographic) -----------------------

tar -C "$STAGE" -cf "$OUT_DIR/pkg.tar" \
    bin/pkg caps.decl deps.list doc/pkg.pdxdoc manifest.pdxsig

# ---- Layout report on stdout + captured to file -------------------------

REPORT="$OUT_DIR/manifest-report.txt"
{
    echo "pkg-1.0.0 manifest generation report"
    echo "======================================"
    date -u +'%Y-%m-%dT%H:%M:%SZ'
    echo
    echo "bin_path       : $BIN_PATH"
    echo "out_dir        : $OUT_DIR"
    echo "body_len       : $BODY_LEN bytes"
    echo "sigblock_len   : $SIGBLOCK_LEN bytes"
    echo "manifest total : $((64 + BODY_LEN + SIGBLOCK_LEN)) bytes"
    if [ "$PDX_STUB_SIG" = "1" ]; then
        echo "sig_mode       : STUB (PDX_SIG_PENDING_V033 fill; v0.33-crypto-kdf gate)"
    else
        echo "sig_mode       : REAL (paideia-as sign, ml-dsa-65)"
    fi
    echo "body_sha3_256  : $BODY_SHA3_HEX"
    echo
    echo "Artifacts under $OUT_DIR/:"
    ls -l "$OUT_DIR"
} | tee "$REPORT"

exit 0
