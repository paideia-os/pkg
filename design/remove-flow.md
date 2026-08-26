# pkg — remove flow (M2-004)

**Wave:** R49  Milestone: M2  Issue: #7 (pkg.M2-004)
**Upstream:** [`design/tooling/r49-r50-plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/r49-r50-plan.md)
§5.1 M2 line; [`design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
§6.4 undo model + I5 invariant.

## 1. Purpose

Freeze the sequence pkg follows when a user runs `pkg remove <name>`.
Every remove ships with an undo record so `undo pkg remove <name>`
can reinstall from the PdxFS trash subtree within a bounded retention
window. Removes that cannot produce an undo record REFUSE — a silent
remove would violate I5.

## 2. Pipeline

```
                pkg remove <name>
                         |
                         v
    +--- ParsedArgs::pos_count == 2? ---+  no -> exit 2 (usage)
    | yes
    v
Step 1  remove_reset
Step 1a assign monotonic remove_id (remove_id_next)
Step 1b progress diagnostic ("removing name '<name>'")
Step 2  PkgElevate::pkg_elevate_request_pdxfs_write_pkgs -- request a
         60s KIND_PDXFS_FILE(write, /pkgs) cap (ENH-008 #33; result in
         remove_parent_slot). Wired ahead of the lookup gate so remove
         never gains a live unelevated destructive path once it
         closes; broker unregistered today (R48-PREP-005) -> slot 0.
Step 3  look up /system/packages/<name>-* (SEAM -- no readdir at HEAD)
Step 4  TxnClient::txn_open(TXN_MODE_DELETE, parent_slot=remove_parent_slot) (SEAM)
Step 5  serialise pdxundo header + FILE_TRASH_ENTRY body
         (header REAL at M2; body deferred to M4)
Step 6  move /pkgs/<name>-<version>/ into /system/trash/<remove_id>-*
         via per-file txn writes (SEAM)
Step 7  TxnClient::txn_commit (SEAM)
        |
        v
     exit 0

  on any step failure:
    - if txn_slot valid: TxnClient::txn_abort
    - exit 1 with diagnostic naming the failing step
```

## 3. Undo-record byte layout (`pdxundo`)

64-byte header, then a sequence of `FILE_TRASH_ENTRY` records:

### 3.1 Header (64 bytes)

| Offset | Size | Field                | Semantics                                     |
|--------|------|----------------------|-----------------------------------------------|
| 0      | 8    | `magic`              | `"pdxundo\0"` little-endian                   |
| 8      | 4    | `format_version`     | `1` at M2                                     |
| 12     | 4    | `header_flags`       | reserved; must be `0`                         |
| 16     | 8    | `remove_id`          | monotonic within a process                    |
| 24     | 8    | `removed_ns`         | wall-clock timestamp of the remove            |
| 32     | 8    | `replay_deadline_ns` | absolute deadline (24h default)               |
| 40     | 8    | `body_len`           | length in bytes of the FILE_TRASH_ENTRY seq   |
| 48     | 8    | `body_sha3_lo`       | halves of sha3-256(body) -- integrity gate    |
| 56     | 8    | `body_sha3_hi`       |                                               |

`ur_write_header` in `src/remove.pdx` serialises this layout. The
verifier for a subsequent `undo` reads the header, hashes the body,
and refuses if the hashes do not match — protecting against
trash-subtree corruption.

### 3.2 FILE_TRASH_ENTRY

Mirrors `manifest.pdxsig`'s `FILE_INVENTORY` (see
`design/manifest-format.md` §4.3) inverted:

```
+------+------------+------------+------------------------+-----------+
| mode | orig_len   | trash_len  | sha3_256 (32B)         | orig_path |
|      |            |            |                        | trash_path|
+------+------------+------------+------------------------+-----------+
   u32       u32          u32              bytes             bytes
```

- `orig_path` — path under `/pkgs/<name>-<version>/` (relative,
  no leading `/`, no `..`).
- `trash_path` — path under `/system/trash/<remove_id>-<name>-<version>/`
  where the bytes now live. `undo` reads from `trash_path`, writes to
  `orig_path` under a fresh KIND_PDXFS_TXN.
- `sha3_256` — file bytes hash; the undo replayer verifies before
  restoring so a tampered trash entry surfaces as a refusal.

## 4. Retention

Default retention: `UR_DEFAULT_RETENTION_NS = 86_400_000_000_000` ns
(24 hours). After `replay_deadline_ns` the trash subtree entry is
garbage-collected (M3+ GC path); `undo` reads the header, sees the
deadline in the past, and returns `ENOENT-with-diagnostic` per the
plan-doc §6.4 semantics.

`rm --wipe` (per `design/user/model.md` §7.1) shreds the trash entry
immediately, still writing the audit record but with a flag noting
the intentional non-recoverability. `pkg remove --wipe` inherits the
same discipline at M3+.

## 5. Remove-progress .bss slots

| Slot                 | Meaning                                       |
|----------------------|------------------------------------------------|
| `remove_name_ptr`    | pos_ptrs[1]                                     |
| `remove_id`          | monotonic remove-id assigned this call          |
| `remove_txn_slot`    | KIND_PDXFS_TXN cap slot (0 if never opened)     |
| `remove_parent_slot` | elevate-granted parent_slot (0 = unavailable, ENH-008 #33) |
| `remove_step`        | last step index reached (0..6)                  |

`_remove_id_counter` is a process-lifetime monotonic. `remove_reset`
does NOT clear it — the M4 test harness resets it explicitly when it
wants a clean slate.

## 6. Seams

Same discipline as install (see `design/install-flow.md` §3):

- **Elevate seam** — `PkgElevate::pkg_elevate_request_pdxfs_write_pkgs`
  resolves `svc.elevate-broker` but the broker is not registered at
  paideia-os HEAD (R48-PREP-005), so the request never dispatches and
  `remove_parent_slot` stays `0` (ENH-008 #33). Wired ahead of the
  lookup seam below on purpose, matching install's ordering.
- **Lookup seam** — `/system/packages/` readdir is not exposed at
  paideia-os HEAD. M3 either wires a readdir extension on
  `KIND_PDXFS_FILE` OR reads `/system/packages/index.pdxlist` (a
  text file `pkg install` maintains). M2 refuses fail-safe.
- **TXN seam** — same `R42-PREP-007` block as install.
- **Trash-move seam** — one txn write per file. Enabled by the TXN
  write-side ops.

## 7. What M2 explicitly does not do

- **No real /system/packages/ enumeration.** Lookup deliberately
  refuses at M2 so an incomplete remove that skipped the undo record
  is impossible. This is I5-strict: a remove that cannot produce
  an undo record MUST refuse.
- **No pre-output audit journal.** M3-003 wires `libpdx-audit`.
- **No GC of trash subtree.** M3+ cron-shaped path.
- **No `--wipe`.** M3+ flag body.
