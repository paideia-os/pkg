# pkg — remove flow (M2-004)

**Wave:** R49  Milestone: M2  Issue: #7 (pkg.M2-004)
**Extended:** R70 M1  Issue: #22 (R70.M1-005) — see §8
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
Step 3  remove_lookup_files(name) -- resolve <name> against
         /system/packages/index.pdxlist, load its file list into
         _remove_inventory, return the count (SEAM -- pkg holds no
         KIND_PDXFS_FILE cap for /system/packages/; fails closed)
Step 4  TxnClient::txn_open(TXN_MODE_DELETE, parent_slot=remove_parent_slot,
         txn_id=remove_id) -- REAL syscall #70
Step 5  ur_write_header -- serialise the pdxundo header (REAL; body
         deferred to M4). Ordered BEFORE any deletion.
Step 6  remove_unlink_all(txn_slot) -- TxnClient::txn_unlink per
         inventory entry, i.e. PXT_OP_UNLINK inside the step-4
         transaction (SEAM -- op is real kernel-side, operand staging
         has no syscall binding; fails closed)
Step 7  TxnClient::txn_commit -- REAL cap_invoke. The registry
         deregistration is staged in this same transaction.
        |
        v
     "pkg remove: ok -- name='<name>' files=<N>"; exit 0

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
| `remove_id`          | monotonic remove-id assigned this call; also the `txn_id` |
| `remove_txn_slot`    | KIND_PDXFS_TXN cap slot (`0xFFFF` if never opened) |
| `remove_parent_slot` | elevate-granted parent_slot (0 = unavailable, ENH-008 #33) |
| `remove_step`        | last step index reached (0..6)                  |
| `remove_last_rc`     | shared per-stage rc lane across the record emits (R70.M1-005 #22) |
| `remove_file_count`  | entries populated in `_remove_inventory` (R70.M1-005 #22) |

`remove_txn_slot`'s "none" sentinel is `0xFFFF`, **not** `0`: cap_slot
`0` is a legitimate `txn_open` return, and the M2 epilogue's
`cmp r13, 0; je skip_abort` gate therefore leaked an open transaction
on every failure path that happened to land on slot 0. Fixed at
R70.M1-005 in step with the identical fix in `install.pdx`.

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
- **Lookup seam** — `remove_lookup_files`. The registry is
  `/system/packages/index.pdxlist` (settled by
  `design/enh-001-reconciliation.md` §2.1). The blocker is **not**
  readdir — `KIND_PDXFS_FILE.readnext` landed at R42-PREP-008 — it is
  that pkg holds no `KIND_PDXFS_FILE` capability for
  `/system/packages/`, so it cannot open the index at all. Same gap
  `src/list.pdx` L198-202 documents for its own enumerator. Refuses
  fail-safe with `REMOVE_LOOKUP_UNAVAILABLE`, a sentinel deliberately
  distinct from a zero count.
- **TXN seam** — *closed.* `txn_open` / `txn_commit` / `txn_abort` are
  real (syscall #70 + `cap_invoke`) since the M3 wire-through.
- **Unlink seam** — `TxnClient::txn_unlink`. `PXT_OP_UNLINK` (11) is
  real kernel-side but unreachable from userspace: its operand-staging
  call `pdxfs_txn_stage_unlink_name` has no syscall binding. Refuses
  with `TXN_UNLINK_UNSTAGED` rather than issuing a blind `cap_invoke`.
  Full rationale in §8.1.
- **Trash-move seam** — one txn write per file, plus the
  `FILE_TRASH_ENTRY` body of the undo record. M4, alongside the
  fixture manifest.

## 7. What M2 explicitly does not do

- **No real /system/packages/ enumeration.** Lookup deliberately
  refuses at M2 so an incomplete remove that skipped the undo record
  is impossible. This is I5-strict: a remove that cannot produce
  an undo record MUST refuse.
- **No pre-output audit journal.** M3-003 wires `libpdx-audit`.
- **No GC of trash subtree.** M3+ cron-shaped path.
- **No `--wipe`.** M3+ flag body.

## 8. R70.M1-005 (#22) disposition — "reverse install via libpdx-audit"

**Issue:** #22  **Gated by:** `design/enh-001-reconciliation.md` §2.1
(Remove row) and §2.2, which directed #22 to be reframed against this
document rather than implemented as filed.

#22 as filed asked for five things. Three are not implementable as
stated against the shipped substrate, one was already shipped, and one
was genuinely missing. This section is the record.

| # | As filed | Disposition |
|---|---|---|
| 1 | Parse `/var/pkg/installed.pdxpkg` | **Retired, not deferred.** ENH-001 §2.1 folded the registry-file idea into "what `/system/packages/index.pdxlist` already is". `remove_lookup_files` names index.pdxlist. |
| 2 | Iterate the entry's recorded file list | **Implemented.** `_remove_inventory` (bounded, 64 entries) + `remove_unlink_all`. |
| 3 | `sys_unlink` each installed path | **Rejected in form, implemented in intent.** Uses `TxnClient::txn_unlink` → `PXT_OP_UNLINK` inside the DELETE transaction. See §8.1. |
| 4 | Append a libpdx-audit record of kind `UNINSTALL` | **No such kind exists.** Already-shipped `TOOL_INVOKE`/`TOOL_EXIT` under `op_name = "remove"` *is* the record. The missing half — `audit_record_op_output` — is now wired. See §8.2. |
| 5 | Rewrite the registry without that entry | **Staged in the same transaction as the unlinks**, so no window exists in which the files are gone but the registry still advertises the package. Behind the same cap gap as (1). |

### 8.1 Why not `sys_unlink`

`sys_unlink` (syscall #81) is real and reachable. It is still the wrong
primitive here, for two independent reasons:

- **D4.** It is ambient write authority over `/pkgs`. The entire reason
  step 2 of this pipeline exists is that pkg must hold a
  bounded-lifetime elevate grant before it touches `/pkgs`. A syscall
  that deletes without consulting that grant makes the elevate stage
  decorative.
- **I5.** It is non-transactional. A failure at file *k* of *N* leaves
  files `0..k-1` permanently gone, with an undo record that either does
  not exist yet or describes a state that no longer holds. §7 of this
  document states the invariant outright: *a remove that cannot produce
  an undo record MUST refuse.* A per-file syscall loop cannot honour it.

`PXT_OP_UNLINK` inside the step-4 transaction has neither problem: the
transaction carries the elevate-derived parent capability, and
`txn_abort` in the epilogue rolls back the entire file set on any
failure.

**Current gap.** `PXT_OP_UNLINK` (op 11) is real kernel-side — paideia-os
R52.M6-003 (#1711) made it durably append a `JOP_DENTRY_DEL` +
`JOP_INODE_WRITE` pair under one `txn_id` — but it is **not reachable
from userspace**. Its operands (`parent_inode`, `name_ptr`, `name_len`)
cannot fit `cap_invoke`'s three-register dispatch surface, so they
travel through the kernel-internal staging table
`pdxfs_txn_stage_unlink_name`, which has **no syscall binding**. That
function's own header flags this: *"no caller in this landing calls this
function yet … flagged for whichever future issue wires a real
vops/syscall path to UNLINK."*

`txn_unlink` therefore validates its arguments and returns
`TXN_UNLINK_UNSTAGED` rather than issuing the `cap_invoke`. Issuing it
would be **strictly worse than refusing**: an unstaged row reads back
`parent_inode = 0`, `name_ptr = 0`, `name_len = 0`, so the kernel would
emit a dentry-delete against a NULL name under the root inode — a blind
unlink whose target the caller never named.

*Upstream ask:* a syscall binding for `pdxfs_txn_stage_unlink_name`.
That is a paideia-os change, not a pkg one.

### 8.2 Why there is no `UNINSTALL` audit kind

The only `UEJ_KIND_*` constants a tool can reach are `TOOL_INVOKE`
(130), `TOOL_OUTPUT` (132), `TOOL_EXIT` (133) and `ELEVATE` (5).
libpdx-audit distinguishes operations by the **`op_name` column**, not
by minting a kind per verb — which is the right design: a kind space
that grows with every tool's vocabulary is a kind space no consumer can
switch over. pkg has emitted `TOOL_INVOKE`/`TOOL_EXIT` under
`op_name = "remove"` since M3-003. That pair *is* the uninstall audit
record.

The sibling tool `mkfs.pdxfs` hit the identical "issue names a
`UEJ_KIND` that does not exist" situation and resolved it the same way
(see its `src/audit_wire.pdx` L35-59).

What *was* genuinely missing: ENH-012 (#37) wired
`audit_record_op_output` into `install` and `list` and skipped `remove`
— so the one subcommand on this tool that destroys data was the only
one whose audit entry carried an empty `output_schema` column. R70.M1-005
fixes that. `remove` now binds `pdxsig.pkg.rpr.v1`
(`RemoveProgressRecord`, a schema distinct from `InstallProgressRecord`
so a supervisor filtering for destructive operations need not parse a
payload field), records it on the audit entry, and emits one record per
stage carrying that stage's real `rc`. The `files=<N>` count leaves on
the typed side as well as in the text fingerprint.

That is what "reverse install via libpdx-audit" should mean, and now
does: **remove is audit-symmetric with install.**

### 8.3 Net state

End-to-end real except two named upstream gaps, failing closed at both:

| Stage | State |
|---|---|
| elevate | real call; broker unregistered upstream (R48-PREP-005) → slot 0 |
| lookup | **SEAM** — no KIND_PDXFS_FILE cap for `/system/packages/` |
| txn_open(DELETE) | **real** (syscall #70) |
| undo header | **real** (`ur_write_header`, which had no caller at all before this round) |
| unlink loop | **SEAM** — no staging syscall for `PXT_OP_UNLINK` |
| txn_commit | **real** (`cap_invoke`) |
| abort-on-failure | **real** |
| audit + record stream | **real** |

Closing either gap is a one-function edit (`remove_lookup_files`,
`txn_unlink`), not a restructure.
