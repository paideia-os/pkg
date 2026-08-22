#!/bin/sh
# tests/m4-001-sig-mismatch/gen-fixtures.sh -- pkg.M4-001
#
# Wave: R49  Milestone: M4  Issue: #13 (pkg.M4-001)
# Spec:  design/test-matrix.md  §2.2 fixture generation.
#
# Deterministic fixture generator for the three-cell sig-mismatch
# matrix. Produces three .pdxsig files that share the same 64B
# header + body but differ in the sigblock -- one byte flipped in
# author sig / root sig / both (see design/test-matrix.md).
#
# The base manifest carries a well-formed 64B header + a minimal KV
# body + a placeholder sigblock (two 3293-byte NUL-padded blocks
# with a nonzero first byte so sigblock_len parses cleanly). When
# paideia-as v0.33-crypto-kdf lands, the placeholder is replaced by
# a real sign step + the M4 driver flips its expected/*.txt files
# from MC_VERIFY_STUB to the specific error codes.
#
# Env vars:
#   PDX_FIXTURE_DIR (default tests/m4-001-sig-mismatch/fixtures)
#
# The fixture format mirrors design/manifest-format.md:
#   [ 64B header ]
#   [ body_len bytes body ]
#   [ 4B author_sig_len ][ author_sig ][ 4B root_sig_len ][ root_sig ]
#
# All sizes chosen small so the fixture stays under 4KB (fits pkg's
# _install_staging .bss buffer once the file-read wire-through
# lands; see design/install-flow.md §5).

set -e

: ${PDX_FIXTURE_DIR:=tests/m4-001-sig-mismatch/fixtures}
mkdir -p "$PDX_FIXTURE_DIR"

BASE="$PDX_FIXTURE_DIR/pkg-base.pdxsig"
AUTHOR_BAD="$PDX_FIXTURE_DIR/pkg-author-bad.pdxsig"
ROOT_BAD="$PDX_FIXTURE_DIR/pkg-root-bad.pdxsig"
BOTH_BAD="$PDX_FIXTURE_DIR/pkg-both-bad.pdxsig"

# ---- Constants ------------------------------------------------------
# ML-DSA-65 signature size at NIST level 2 (bytes).
SIG_LEN=3293
# Body: 8B PKG_NAME record ("pkg" = 3 bytes) + minimum required tags
# in trimmed form. Aim: <= 512 bytes for parser simplicity.
BODY_LEN=256
# Header size (fixed).
HDR_LEN=64
# Sigblock length: 4 + SIG_LEN + 4 + SIG_LEN.
SIGBLOCK_LEN=$((4 + SIG_LEN + 4 + SIG_LEN))
TOTAL_LEN=$((HDR_LEN + BODY_LEN + SIGBLOCK_LEN))

# ---- Build the base manifest ---------------------------------------
# printf %b to emit binary bytes; portable across dash / bash / mksh.
# Byte-hex helper: emit one byte from a decimal number.
byte() {
    printf '\\%03o' "$1"
}

# Little-endian u32 -> four escaped bytes.
u32le() {
    v="$1"
    b0=$(( v        & 0xFF ))
    b1=$(( (v >>  8) & 0xFF ))
    b2=$(( (v >> 16) & 0xFF ))
    b3=$(( (v >> 24) & 0xFF ))
    printf '%b%b%b%b' "$(byte $b0)" "$(byte $b1)" "$(byte $b2)" "$(byte $b3)"
}

# Little-endian u64 -> eight escaped bytes.
u64le() {
    v="$1"
    b0=$(( v        & 0xFF ))
    b1=$(( (v >>  8) & 0xFF ))
    b2=$(( (v >> 16) & 0xFF ))
    b3=$(( (v >> 24) & 0xFF ))
    b4=$(( (v >> 32) & 0xFF ))
    b5=$(( (v >> 40) & 0xFF ))
    b6=$(( (v >> 48) & 0xFF ))
    b7=$(( (v >> 56) & 0xFF ))
    printf '%b%b%b%b%b%b%b%b' \
        "$(byte $b0)" "$(byte $b1)" "$(byte $b2)" "$(byte $b3)" \
        "$(byte $b4)" "$(byte $b5)" "$(byte $b6)" "$(byte $b7)"
}

# 1. Header (64 bytes).
# magic "pdxsig\0\0" = 8B ASCII
{
    printf 'pdxsig'
    printf '\0\0'
    # format_version = 1 (u32 LE) | header_flags = 0 (u32 LE)
    u32le 1
    u32le 0
    # body_len (u64 LE)
    u64le $BODY_LEN
    # body_sha3_256_lo / _hi -- placeholder zeros; the M2 hash SEAM
    # returns MC_HASH_STUB regardless. When v0.33-crypto lands and
    # the driver expects a real body-hash match, gen-fixtures.sh
    # will fill these with sha3_256(body).
    u64le 0
    u64le 0
    # sigblock_len (u64 LE)
    u64le $SIGBLOCK_LEN
    # pubkey_len_author (u32 LE) | pubkey_len_root (u32 LE)
    # 1952 = ML-DSA-65 level-2 pubkey; carried in header for the
    # length check; the actual pubkey bytes are in the body's
    # AUTHOR_PUBKEY / ROOT_PUBKEY tags.
    u32le 1952
    u32le 1952
    # created_unix_secs (u64 LE) -- fixed date so fixtures are
    # bit-reproducible; 1735689600 = 2025-01-01T00:00:00Z.
    u64le 1735689600
} > "$BASE.hdr"

# 2. Body (256 bytes).
# We fill with a repeating pattern so bit-flip inspection is easy.
# A real body would carry KV records; the M4 fixture is deliberately
# minimal because mc_walk_body is not on pkg_install's hot path at
# M3-close (the parser walks the header + defers KV walk to M5).
dd if=/dev/zero bs=1 count=$BODY_LEN 2>/dev/null | tr '\0' 'K' > "$BASE.body"

# 3. Sigblock (2 * (4 + 3293) = 6594 bytes).
# author sig -- length prefix + 3293 bytes of pattern 'A'
{
    u32le $SIG_LEN
    dd if=/dev/zero bs=1 count=$SIG_LEN 2>/dev/null | tr '\0' 'A'
    u32le $SIG_LEN
    dd if=/dev/zero bs=1 count=$SIG_LEN 2>/dev/null | tr '\0' 'R'
} > "$BASE.sig"

# 4. Concatenate.
cat "$BASE.hdr" "$BASE.body" "$BASE.sig" > "$BASE"
rm -f "$BASE.hdr" "$BASE.body" "$BASE.sig"

# ---- Compute flip offsets (matches design/test-matrix.md §2.2) -----
# author sig payload starts at 64 + BODY_LEN + 4.
AUTHOR_FLIP=$((HDR_LEN + BODY_LEN + 4 + 100))
# root sig payload starts at 64 + BODY_LEN + 4 + SIG_LEN + 4.
ROOT_FLIP=$((HDR_LEN + BODY_LEN + 4 + SIG_LEN + 4 + 100))

# ---- flip_byte <src> <dst> <offset> [<offset2>] --------------------
# dd-copy src -> dst then overlay one (or two) XOR-with-0x5A bytes.
# Byte at $offset in the original is 'A' (0x41) inside author sig or
# 'R' (0x52) inside root sig; XOR with 0x5A gives 0x1B / 0x08 which
# are visually distinct on hexdump inspection.
flip_byte() {
    src="$1"
    dst="$2"
    off1="$3"
    off2="${4:-}"

    cp "$src" "$dst"

    # Read the byte at off1, XOR with 0x5A, write back.
    orig_byte=$(dd if="$dst" bs=1 skip="$off1" count=1 2>/dev/null | od -An -tuC | tr -d ' ')
    new_byte=$(( orig_byte ^ 0x5A ))
    printf '%b' "$(byte $new_byte)" | dd of="$dst" bs=1 seek="$off1" count=1 conv=notrunc 2>/dev/null

    if [ -n "$off2" ]; then
        orig_byte=$(dd if="$dst" bs=1 skip="$off2" count=1 2>/dev/null | od -An -tuC | tr -d ' ')
        new_byte=$(( orig_byte ^ 0x5A ))
        printf '%b' "$(byte $new_byte)" | dd of="$dst" bs=1 seek="$off2" count=1 conv=notrunc 2>/dev/null
    fi
}

flip_byte "$BASE" "$AUTHOR_BAD" $AUTHOR_FLIP
flip_byte "$BASE" "$ROOT_BAD"   $ROOT_FLIP
flip_byte "$BASE" "$BOTH_BAD"   $AUTHOR_FLIP $ROOT_FLIP

# ---- Sanity: every fixture is exactly TOTAL_LEN bytes --------------
for f in "$BASE" "$AUTHOR_BAD" "$ROOT_BAD" "$BOTH_BAD"; do
    sz=$(wc -c < "$f" | tr -d ' ')
    if [ "$sz" != "$TOTAL_LEN" ]; then
        printf 'FAIL: %s is %d bytes, expected %d\n' "$f" "$sz" "$TOTAL_LEN" >&2
        exit 1
    fi
done

printf 'OK: fixtures at %s\n' "$PDX_FIXTURE_DIR"
printf '     pkg-base.pdxsig       %d bytes\n' "$TOTAL_LEN"
printf '     pkg-author-bad.pdxsig %d bytes (flip @ %d)\n' "$TOTAL_LEN" "$AUTHOR_FLIP"
printf '     pkg-root-bad.pdxsig   %d bytes (flip @ %d)\n' "$TOTAL_LEN" "$ROOT_FLIP"
printf '     pkg-both-bad.pdxsig   %d bytes (flip @ %d, %d)\n' "$TOTAL_LEN" "$AUTHOR_FLIP" "$ROOT_FLIP"
