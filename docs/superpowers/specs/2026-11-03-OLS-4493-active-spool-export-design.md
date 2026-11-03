# OLS-4493: Phase 2.1 active-spool export design

## Status and scope

Proposed for review on 2026-11-03. Everything described as Phase 2.1 below is **planned**, not implemented. Tracking: [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493), under epic [OLS-4490](https://redhat.atlassian.net/browse/OLS-4490).

Phase 1 is the stock-Collector spool plus the rotated-backup consumer. The stock FileExporter branch is on `lightspeed-otel-collector` main and in the operator; the `otel` consumer (OLS-4370) is on `lightspeed-to-dataverse-exporter` main; OLS-4491 is closed with the released-bundle verification; OLS-4492 is still pending payload verification.

This design covers **consumer-side delivery of complete records from the active `traces.jsonl`**. It does not change the Collector, producers, the CRD, rotation thresholds, or source retention. It does not add exactly-once delivery, durable volumes, or a new transport.

Out of scope: rebuilding the reverted custom Collector exporter, changing the Dataverse trace schema, and replacing the Ingress upload path.

## Problem

The consumer currently considers rotated backups only. FileExporter rotates by size, and `max_days` deletes aged backups only; it never seals an active file. Consequences:

- A quiet active file is never delivered. At low volume, trace data can remain undelivered indefinitely.
- Pod replacement or volume removal loses the undelivered active file because the source is a pod-local `emptyDir`.
- Delivery latency for the newest records is unbounded and depends on future trace volume reaching 1MiB.

Phase 2.1 must deliver complete records from the active file while the Collector may still be writing or rotating it, without modifying the source and without weakening the existing best-effort, at-least-once contract.

## Terms

| Term | Meaning |
|---|---|
| Active file | `traces.jsonl` at the configured source root. FileExporter owns it and may append or rotate at any time. |
| Backup | An immutable rotated file named `traces-<timestamp>-size.jsonl` in the same directory. |
| Record | One JSON object written by FileExporter, representing one native OTLP trace batch. |
| Chunk | A contiguous range of complete records from one source file, packaged as one top-level JSON array in one gzip TAR member. |
| Source identity | `(st_dev, st_ino)` of the open file, used to follow a file across rotation. |

## Verified current behavior

### Deployment settings

Verified from the operator code on 2026-11-03:

| Setting | Value | Source |
|---|---|---|
| Trace path | `/var/lib/lightspeed-data/otel/traces.jsonl` | `internal/controller/utils/constants.go` |
| Rotation | `max_megabytes: 1`, `max_backups: 400`, `max_days: 1` | same |
| Source volume | `emptyDir`, `sizeLimit: 500Mi` | same; `assets.go` |
| Sidecar mount | same volume at `/input`, read-only | `otelcollector/deployment.go` |
| Ledger | `/state/ledger.json`, separate `emptyDir` | `otelcollector/deployment.go` |
| Exporter config | `data_mode: otel`, `data_dir: /input`, `otel_active_file: traces.jsonl`, `archive_path_prefix: agentic-v1/`, `collection_interval: 300`, `cleanup_after_send: false` | `otelcollector/dataverse_exporter.go` |

### FileExporter write and rotation

The distribution pins contrib FileExporter v0.159.0. In rotation mode it writes through `github.com/DeRuina/timberjack` v1.4.6 with no buffering.

- `exportMessageAsLine` writes the record JSON and then `\n` as two writes, serialized by the exporter's mutex (`file_writer.go`).
- Timberjack checks `size + writeLen > max` **before** each write and rotates by closing the file, renaming it to `traces-<timestamp(ms)>-size.jsonl`, and creating a new active file with `O_TRUNC` (`timberjack.go` `Write`, `openNew`).
- On process restart, `openExistingOrNew` appends to the retained active file and rotates first if `size + writeLen >= max`.
- Cleanup (`max_backups`, `max_days`) runs during rotation and on the first write after startup; it never seals or rotates an idle active file.
- Shutdown closes the file; it does not rotate.
- There is no `fsync`, no Collector-side queue, and no upload acknowledgement in the rotator.

Two boundary cases follow directly:

1. **Normal rotation** happens before the next record's JSON. The backup ends with a complete record and LF.
2. **Exact-fill rotation** happens before the LF write when a record exactly fills the file. The backup then ends with a complete JSON object and **no LF**, and the new active file begins with a lone `\n`. This is also recorded in the Collector contract, `lightspeed-otel-collector/.ai/spec/what/data-collection.md` rule 10.

A record larger than 1MiB is rejected whole before any bytes are written. A crash between the JSON and LF writes leaves a complete object without LF; a restart may then append the next object directly, producing two JSON objects on one physical line. A crash mid-JSON leaves an unparseable fragment.

### Local verification

A local experiment against timberjack v1.4.6 with `MaxSize: 1` (MiB) and separate JSON/LF writes, matching the FileExporter sequence, observed:

| Scenario | Observed result |
|---|---|
| Two 600KiB records | First backup 614,401 bytes ending in LF; active recreated and written before the second record |
| One record of exactly 1MiB | Backup 1,048,576 bytes ending **without** LF; new active 1 byte containing `\n` |
| Open descriptor held across rotation | Descriptor continued to address the renamed backup inode at its final size |
| Close and reopen the writer | Reopened and appended to the retained active file |
| Single 1.2MiB write | Rejected with `write length ... exceeds maximum file size`; zero bytes written |

The Collector e2e suite independently tolerates incomplete JSON only at the end of the active file, accepts a complete final object without LF, and ignores blank rollover lines (`test/e2e/file_exporter_test.go`).

### Consumer today

`lightspeed-to-dataverse-exporter` `data_mode: otel`:

- `collect_rotated_files` validates `otel_active_file` as a plain basename and matches direct-child backups by the timestamp pattern; it excludes the active filename.
- Each backup is opened `O_NOFOLLOW`, required to be a regular file, and rejected if its size or mtime changes during conversion.
- Records are split on LF, blank lines skipped, each line parsed as a JSON object, and the objects are placed in one top-level JSON array inside one gzip TAR member named `<archive_path_prefix><backup stem>.json`.
- The upload must return HTTP 202 and a `request_id`; the ledger then records `{filename: {request_id}}` (version 1).
- Ledger pruning happens only after a complete directory scan.
- The source is never modified or deleted. FileExporter retention is independent of upload.
- The ledger and source are pod-local `emptyDir` volumes: container restarts preserve them, pod replacement does not.
- Ledger loss causes retained files to be re-uploaded; downstream deduplication is already required by the collection contract.

### Retention budget

One active file plus 400 backups at 1MiB is about 401MiB, below the 500Mi source volume limit. The consumer does not add source files. The retention-versus-poll budget is discussed in [Omission budget](#omission-budget).

## Requirements

- **R1** Deliver complete records from the active file, not only rotated backups.
- **R2** Never modify, rename, truncate, or delete a source file; `/input` remains read-only.
- **R3** Never ship or commit a partial record, including during a concurrent write.
- **R4** Survive rotation at any point with no loss of complete records and no duplicate upload of the same byte range while the ledger is intact.
- **R5** Preserve at-least-once semantics: duplicates after a crash, acknowledgement loss, or ledger loss are acceptable; downstream deduplication remains authoritative.
- **R6** Resume correctly across container restarts and upgrades; define behavior when the ledger is lost or invalid.
- **R7** Bound memory, ledger size, per-upload payload, and read work per cycle.
- **R8** Keep the consumer's existing failure isolation and error visibility; one bad source must not block other sources.
- **R9** Treat the existing source as untrusted input: no symlink traversal, no unbounded buffering, no content logging.
- **R10** Require no Collector code change and no CRD change.

## Options considered

### A. Consumer tails the active file with an identity-plus-offset ledger (recommended)

The exporter treats the active file as one more read-only source. It remembers how many bytes of each source identity have been acknowledged, reads only complete records beyond that offset, uploads them as chunks, and commits the offset only after the upload is acknowledged. Rotation is handled by identity, not by filename.

### B. Producer-side timed sealing

Timberjack supports `RotationInterval`, but FileExporter v0.159.0 does not expose it, and neither does contrib `main` as of this review. Adding `rotation.rotation_interval` to FileExporter, bumping the pinned version, and setting a short interval would let the existing whole-backup consumer deliver on a timer with no consumer protocol change. It would still seal only on a write: a truly idle active file would not rotate until the next record. It also requires an upstream contribution and review, and it creates many small backups. Deferred as a possible later simplification; it does not satisfy Phase 2.1 without an upstream dependency.

### C. Collector-side sealing or a custom exporter

Reintroduce an exporter that seals files at 1MiB or 30 seconds. This was implemented as the Agentic candidate exporter and then reverted in favor of stock FileExporter (OLS-4248 revert, OLS-0000 standard FileExporter). Rejected: it returns maintenance of a custom exporter and departs from the stock component contract.

### D. Re-upload a snapshot of the active file every cycle

Read the whole active file each cycle and rely downstream on deduplication. Simple but amplifies upload volume by up to the file size per poll (about 1MiB per 300 seconds per pod at the current threshold) and still requires a change to avoid re-sending after rotation. Rejected as a design, not just an optimization.

### E. Keep rotated-only consumption

Rejected: it leaves R1 unmet and keeps undelivered data unbounded for quiet files.

| Dimension | A: active tailing | B: timed sealing | C: custom exporter | D: snapshot re-upload | E: status quo |
|---|---|---|---|---|---|
| Collector change | none | upstream FileExporter change | new/reverted exporter | none | none |
| Consumer change | new framing, identity/offset ledger | none | none | offset or hash to limit re-sends | none |
| Delivers quiet active file | yes, at next poll | only on the next write after the interval | yes | yes, with amplification | no |
| Partial-record risk | handled by framing | none (whole backups) | depends on implementation | handled by framing | none |
| Rotation race | identity-based, no reset | none | none | handling required | none |
| Upstream dependency | none | FileExporter release | none | none | none |
| Duplicate amplification | low | low | low | high | none |

## Recommended design: identity-based active tailing

### Inventory and identity

Each cycle performs one complete, non-recursive scan of the source root:

- The active file is the configured plain basename (`traces.jsonl`).
- Backups are direct children matching the existing timestamp pattern.
- Symlinks and non-regular files are skipped. `O_NOFOLLOW` is used on open.

Each source is identified by `(st_dev, st_ino)`, obtained from `fstat` on the open descriptor. A filename is not an identity: rotation renames the same inode from the active name to a backup name. The ledger entry also stores the last observed basename, size, and content anchors so an inode-reuse mismatch can be detected.

### Ledger version 2

Version 1 keys acknowledgements by rotated filename and stores only `request_id`. It cannot represent a consumed prefix, a rotated identity, or the active file. Phase 2.1 introduces version 2:

```json
{
  "version": 2,
  "sources": {
    "<dev>:<ino>": {
      "name": "traces.jsonl",
      "offset": 0,
      "size": 0,
      "complete": false,
      "prefix_len": 0,
      "prefix_sha256": "",
      "anchor_len": 0,
      "anchor_sha256": "",
      "request_id": ""
    }
  }
}
```

- `offset` is the first byte after the last acknowledged record. Records before it are never re-read while the entry is valid.
- `size` is the file size at the last commit or observation; for a complete backup it must match the current size. For an active file it is informational and may grow.
- `complete` is true only for an immutable backup whose last complete record has been acknowledged.
- `prefix_len`/`prefix_sha256` cover the first up to 64 bytes of the file when first observed.
- `anchor_len`/`anchor_sha256` cover the bytes immediately before `offset`, proving that the file content at the committed boundary is still the same file. This guards against inode reuse.
- `request_id` is informational (the last acknowledgement for this source).

Validation rules:

- The source key must match `^[0-9]+:[0-9]+$`; filenames must be plain basenames; offsets and lengths are non-negative integers; hashes are 64 lowercase hex characters when non-empty.
- If `offset > current_size` or `current_size < size` (the stored size), treat the entry as invalid for this file and reset to offset 0.
- If the stored prefix or anchor does not match the current bytes, reset to offset 0.
- If `complete` is true, the current basename and size must equal the stored values; otherwise reset to offset 0.
- A reset re-uploads from the beginning. It can duplicate data but never skips data.
- Unknown versions, duplicate keys, and non-object entries are rejected at load. Version 1 is migrated: for each filename, if the file is present as a regular backup, create a version 2 entry with `offset = size`, `complete = true`, and the current anchors; absent filenames are dropped. The migrated ledger is persisted before processing. This preserves already-acknowledged backups and cannot omit an existing file.
- Pruning removes entries whose identity is absent from a complete scan. A failed or partial scan must leave the ledger unchanged, matching the Collector contract.

### Read and framing algorithm

Per source, per cycle:

```text
open(O_RDONLY | O_NOFOLLOW)
fstat -> identity, size
entry = ledger.lookup(identity)
if entry exists and does not validate against this file:
    entry = new entry(offset=0)
seek(entry.offset)
buffer = read to EOF in bounded chunks
size = fstat(fd).st_size  # post-read size; a backup is immutable, an active file may have grown
records, end_offset = parse_complete_records(buffer)
if records is not empty:
    chunk = package_array(records)
    request_id = upload(chunk, member_name(...))
    ledger.commit(identity, offset=end_offset, anchors, name, size,
                  complete = is_backup and end_offset == size)
elif end_offset > entry.offset:
    # Whitespace-only progress: commit the offset, acknowledge no record.
    ledger.commit(identity, offset=end_offset, anchors, name, size,
                  complete = is_backup and end_offset == size)
elif is_backup and entry.offset == size and not entry.complete:
    ledger.mark_complete(identity, size)
# a partial trailing record is left at its start offset; nothing is committed
```

Framing rules, shared by active and backup sources:

- Skip ASCII whitespace (`space`, `\t`, `\r`, `\n`) between records. This also consumes the lone LF at the start of a new active file and blank rollover lines.
- A record starts with `{`. Scan bytes with a small structural scanner that tracks `{}`/`[]` depth and string/escape state until the top-level object closes. If the scan reaches the end of the available bytes without closing the object, the record is incomplete: stop and leave `offset` at the record start.
- Once a balanced object is found, decode it as UTF-8 and parse it as JSON. If parsing fails, the source is corrupt at that point: stop the source, keep the last committed offset, log once per source version, and do not acknowledge the corrupt suffix.
- Consecutive objects without whitespace are valid separate records. This covers the restart-after-missing-LF case; the current line-based parser would treat the whole line as one invalid record.
- A final complete object without LF is accepted.
- Records are not truncated, normalized, or semantically validated; the array preserves record JSON apart from whitespace and array punctuation.
- Whitespace consumption may advance the offset without an upload. That commit acknowledges no record; it only avoids re-reading the same whitespace. For a backup, reaching its size this way marks it complete.
- Buffer growth is capped at the hard 100MiB payload ceiling. A normal record is bounded by FileExporter's current 1MiB rotation limit; a record that cannot be framed within the cap is treated as corruption rather than buffered indefinitely.

The current `before/after` size-and-mtime stability check is kept for backups (immutable) using `fstat` on the open descriptor, so an unlink after open does not block delivery. It **must not** be applied to the active file, which is expected to grow during a read.

### Rotation races

| Event during a cycle | Behavior | Result |
|---|---|---|
| Rotation before the read | The active path resolves to a new inode; the old inode appears as a backup in the next scan. | Both are read at their own offsets. No loss. |
| Rotation during the read | The open descriptor continues to address the renamed backup inode. The read reaches its final bytes. | The entry keeps the same identity and later matches the backup name. No reset, no duplicate. |
| Exact-fill rotation between JSON and LF | The backup ends with a complete object without LF; the new active starts with LF. | The parser accepts the no-LF object and skips the LF. No loss. |
| Crash between JSON and LF | The file holding the object ends without LF; a restart may append the next object directly, concatenating two objects on one physical line. | The scanner accepts a no-LF final object and separates concatenated objects. |
| Crash mid-JSON | A partial fragment remains. Later writes may concatenate after it. | The complete prefix is uploaded; the corrupt suffix is reported and left unacknowledged. Those records are lost; no safe resynchronization is possible without producer framing. |
| Backup evicted before it is read | The identity disappears from the inventory. | The ledger entry is pruned; content is lost under existing retention, not by the new protocol. |
| Source unlinked while held open | Reads continue from the open inode; the entry is pruned at the next complete scan. | The read data can still be uploaded; no source modification. |

### Packaging and member naming

The payload stays one top-level JSON array of complete records inside one gzip TAR member.

- A complete backup read from offset 0 to EOF in one chunk keeps the existing member name: `<archive_path_prefix><backup stem>.json`.
- Every other chunk uses `<archive_path_prefix><source stem>.<dev>-<ino>.<start>-<end>.json`, where `start` is the byte offset of the first record in the chunk and `end` is the committed offset after the last record.
- A source may therefore produce several members over its life: active chunks before rotation and a backup suffix afterwards. Member ranges for one identity never overlap while the ledger is intact.
- If a single chunk would exceed the upload payload limit, it is split at record boundaries into multiple uploads, each with its own member name.

This is a packaging change, not a trace-content change. It requires Dataverse owner approval for multiple members per source and for the chunk naming; see [Compatibility and coordination](#compatibility-and-coordination). Member names are deterministic, so a retry after acknowledgement loss reuses the same name and content.

### Acknowledgement and commit ordering

1. Package the complete records into a chunk.
2. Upload the chunk; require HTTP 202 and a request ID.
3. Persist the new offset, anchors, name, size, and `complete` flag atomically (temporary file, fsync, rename, directory fsync).
4. Only then process the next chunk or source.

No offset is committed before an acknowledgement, except for whitespace-only progress that acknowledges no record. A crash after the upload acknowledgement but before the ledger persistence re-uploads the chunk after restart. A crash before the acknowledgement does not commit and re-reads from the old offset. Both outcomes can duplicate when the source is retained; neither omits while the source is retained.

The request ID remains informational. The committed offset is the authoritative delivery state.

### Restart and upgrade behavior

- **Exporter container restart:** the source and ledger `emptyDir`s persist at the pod level; identities and offsets remain valid. The collector keeps its writer open. No reset.
- **Collector container restart:** the source volume persists; timberjack reopens and appends. The last record may lack LF if the crash fell between writes; the parser handles it. No reset.
- **Pod replacement:** both `emptyDir`s are recreated; unuploaded sources and the ledger are lost together. This is existing behavior and is not improved by Phase 2.1.
- **Version 1 ledger upgrade:** migrate in place as described above before processing.
- **Invalid ledger document (parse or validation error):** quarantine the file as `ledger.json.corrupt-<timestamp>` and start a new version 2 ledger, logging an error. Delivery continues with duplicates. An I/O error reading or writing the ledger remains fatal and stops the loop; the process exits and retries on restart.
- **Inode reuse:** a changed prefix or anchor, a smaller size, or a complete entry with a different name or size resets that identity to offset 0. The bias is always toward duplicate delivery, never omission.

### Failure behavior

| Failure | Behavior | Data effect |
|---|---|---|
| Active read returns a partial trailing object | Hold at the record start; retry next cycle | None |
| Active write is large or slow during the read | Read what is available; partial tail held | None |
| Rotation or rename during read | Continue on the held descriptor; identity preserved | None |
| Corrupt source bytes | Upload the complete prefix, log, do not acknowledge the suffix | Corrupt record and later bytes in that source are lost when it is evicted |
| Upload HTTP error or timeout | No commit; retry next cycle | Possible duplicates; loss if the source is evicted before retry |
| Upload accepted but response lost | No commit; retry | Possible duplicates; loss if the source is evicted before retry |
| Ledger persistence failure after acknowledgement | Ledger error stops the loop; restart retries | Possible duplicates; loss if the source is evicted before restart |
| Ledger invalid at startup | Quarantine and start fresh | Duplicates |
| Source disappears between scan and open | Skip; retry next cycle | None if retained elsewhere; otherwise retention loss |
| Source fails regular-file or symlink checks | Skip and log | Source not delivered |
| Source evicted before upload | Prune its ledger entry | Lost under existing retention |
| Pod replacement | New volume and ledger | Undelivered data lost |

### Omission budget

The consumer cannot prevent retention eviction. With 400 backups of 1MiB and a 300-second poll, a sustained rate above about 1.33MiB/s (400MiB per poll interval) can evict backups that have not been uploaded. `max_days: 1` also removes backups after one day. Active tailing removes the idle-file case and lowers the amount of data that must wait for rotation, but it does not change the retention budget.

Phase 2.1 should document the relationship and choose one of:

- keep 300 seconds and state the supported sustained rate;
- reduce the interval (for example, 60 seconds) to raise the supported rate to about 6.7MiB/s;
- raise `max_backups` within the 500Mi volume limit;
- alert on sustained rotation rate or on delivery lag.

The exporter's per-cycle work is bounded by the retained sources: at most 401 stat/open operations and one upload per changed chunk (normally one chunk per source per cycle).

### Observability and security

- Log one summary per cycle: sources scanned, records and bytes delivered, chunks uploaded, incomplete tails held, corrupt sources, and identity resets. Do not log record content, attributes, trace IDs, prompts, or outputs.
- Log a source error once per identity and source version; do not re-log every cycle.
- No new network endpoint, credential, permission, or CRD field.
- Open with `O_NOFOLLOW`, require regular files, validate basenames, keep the ledger outside the source tree, and bound all buffers.
- Reading the active file does not modify content or mtime; atime is irrelevant to the rotator.

### Configuration

- Add `read_active_file` (default `true`) to the exporter's OTEL settings and to the operator-generated ConfigMap. Setting it to `false` restores rotated-only behavior for rollback without an image change. The Collector and CRD remain unchanged.
- Keep `collection_interval: 300` unless review chooses a lower value for latency. The field already exists and bounds active-delivery latency.
- No new volume, mount, or credential is required.

## Compatibility and coordination

- **Collector contract:** `lightspeed-otel-collector/.ai/spec/what/data-collection.md` rule 18 currently limits consumers to closed rotated files. Phase 2.1 requires a planned amendment permitting read-only reads of the active path without modifying, renaming, or deleting it. The Collector code and FileExporter configuration do not change.
- **Operator contract:** `lightspeed-operator/.ai/spec/what/data-collection.md` rules 10 and 11 currently state that the active file is excluded. They need planned updates for active reads and the optional `read_active_file` setting.
- **Parent collection contract:** `.ai/spec/what/agentic-data-collection.md` rules 31, 32, 35, and 36 now carry planned Phase 2.1 amendments; rules 26, 29, 30, and 34 were corrected to the verified operator settings and mount. Rule 41 applies: the affected contract is exporter packaging and member naming, not OTLP trace structure. Dataverse extraction owners must confirm the compatibility classification and whether a data-contract version bump is required before rollout.
- **ADR:** ADR 0047 records the Phase 2.1 decision; ADR 0043 points to it for the consumer rule and retains its historical Phase 1 decision.

## Validation and test plan

- **Unit:** framing scanner (blank lines, leading LF, LF-terminated records, no-LF final object, concatenated objects, partial object, UTF-8 split at the buffer boundary, deeply nested objects, record at the buffer cap); ledger schema validation, version 1 migration, anchor/prefix mismatch resets, complete-entry reuse rules, pruning only after a complete scan.
- **Property/fuzz:** random record sizes and byte splits never yield a partial array element; a fresh reader converges to every complete record exactly once when acknowledgements and the ledger both succeed; no input can make the parser loop or allocate unboundedly.
- **Integration with verified writer semantics:** a test writer that mirrors timberjack v1.4.6 (pre-write rotation, 1MiB threshold, exact-fill LF rotation, reopen/append, crash windows) plus the exporter loop. Assert the union of uploaded records equals the source records, member ranges never overlap with an intact ledger, and the source content hash is unchanged.
- **Fault injection:** crash between upload and ledger commit; crash between JSON and LF; invalid ledger; ledger write failure; upload accepted with a lost response; source deleted after scan and after open; rotation during a read; inode reuse simulation; permission and symlink rejection.
- **Cluster e2e:** released-style deployment with the operator; emit a low-volume trace that never reaches 1MiB; confirm delivery within one collection interval; then emit enough data to rotate and confirm the backup suffix is not duplicated; restart the exporter container and confirm no re-upload with an intact ledger; replace the pod and confirm the documented data-loss behavior, because both `emptyDir`s are recreated.
- **Manual runbook:** inspect the ledger, verify no source file changed (size/mtime/content), and reproduce the exact-fill boundary with the collector's real FileExporter.

Acceptance checks:

1. A low-volume active record is delivered without a size rotation.
2. No test upload contains a partial JSON object.
3. Rotation at any point loses no complete record and, with an intact ledger, does not re-upload a consumed byte range.
4. A version 1 ledger upgrades without re-uploading retained backups.
5. A missing or corrupt source does not block other sources or the loop.
6. The source directory content is unchanged by the consumer.

## Phase 2.1 implementation breakdown

| # | Work item | Repository | Depends on | Observable result |
|---|---|---|---|---|
| 1 | Introduce the stream framing scanner and use it for rotated backups; keep whole-backup member names and version 1 semantics | lightspeed-to-dataverse-exporter | none | Concatenated objects and no-LF finals are accepted; no behavior change for normal backups |
| 2 | Add source identity, version 2 ledger, migration, anchors, and complete-entry rules | exporter | 1 | Version 1 ledgers upgrade; identity resets are covered by tests |
| 3 | Add active and partial-source processing, chunk member naming, and acknowledgement-bound offset commits | exporter | 2 | Active records delivered; backup suffixes not duplicated |
| 4 | Add `read_active_file`, cycle/path logging, and failure isolation | exporter + operator ConfigMap | 3 | Kill switch works without an image rollback |
| 5 | Add fault-injection and cluster e2e tests; update README/ARCHITECTURE | exporter | 3, 4 | The validation plan is executed and recorded |
| 6 | Confirm member naming, multiple members per source, and deduplication with Dataverse extraction owners; record the rule 41 classification and any version bump | Dataverse data products | design approval | Written compatibility decision |
| 7 | Update the parent collection spec, ADR 0043, new ADR 0047, operator rules 10/11, and Collector rule 18 with planned markers | parent spec, operator, collector | design approval | Contracts match the approved design |
| 8 | Decide the poll interval and retention budget; optionally pursue upstream `rotation_interval` as a separate ticket | operator + collector + upstream | design approval | Documented latency and omission budget |
| 9 | Build the exporter image, update the operator bundle pin, and run the released-bundle verification | exporter + operator | 1–7 | Cluster evidence recorded under OLS-4490 |

Items 1–5 are the core implementation. Item 6 is a merge gate for item 3. Item 8 can land in parallel; item 9 is the rollout gate.

## Open questions

1. Will Dataverse owners accept multiple members per source and the `<stem>.<dev>-<ino>.<start>-<end>.json` naming, or do they require a different member contract?
2. Is 300-second active-delivery latency acceptable, or should the operator reduce `collection_interval`?
3. Is the `read_active_file` kill switch required in the operator ConfigMap, or is an image rollback sufficient?
4. Should the team pursue FileExporter `rotation_interval` upstream as a later simplification, and does that change the Phase 2.1 priority?
5. Should sustained-rate or delivery-lag alerting be added now, given the 400MiB-per-interval omission bound?

## References

- [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493), [OLS-4490](https://redhat.atlassian.net/browse/OLS-4490)
- Parent contract: [`.ai/spec/what/agentic-data-collection.md`](../../../.ai/spec/what/agentic-data-collection.md)
- Decision: [ADR 0043](../../../.ai/spec/decisions/0043-agentic-data-collection-via-otel.md), [ADR 0047](../../../.ai/spec/decisions/0047-active-spool-tailing-for-dataverse-export.md)
- Collector contract: [`lightspeed-otel-collector/.ai/spec/what/data-collection.md`](https://github.com/openshift/lightspeed-otel-collector/blob/main/.ai/spec/what/data-collection.md)
- Operator contract: [`lightspeed-operator/.ai/spec/what/data-collection.md`](https://github.com/openshift/lightspeed-operator/blob/main/.ai/spec/what/data-collection.md)
- Operator settings: [`assets.go`](https://github.com/openshift/lightspeed-operator/blob/main/internal/controller/otelcollector/assets.go), [`dataverse_exporter.go`](https://github.com/openshift/lightspeed-operator/blob/main/internal/controller/otelcollector/dataverse_exporter.go), [`constants.go`](https://github.com/openshift/lightspeed-operator/blob/main/internal/controller/utils/constants.go)
- Consumer: [`otel_file_handler.py`](https://github.com/lightspeed-core/lightspeed-to-dataverse-exporter/blob/main/src/otel_file_handler.py), [`otel_ledger.py`](https://github.com/lightspeed-core/lightspeed-to-dataverse-exporter/blob/main/src/otel_ledger.py), [`data_exporter.py`](https://github.com/lightspeed-core/lightspeed-to-dataverse-exporter/blob/main/src/data_exporter.py)
- Pinned FileExporter: contrib `exporter/fileexporter` v0.159.0 (`file_writer.go`, `factory.go`); rotator `github.com/DeRuina/timberjack` v1.4.6 (`timberjack.go`)
- Collector tests: [`file_exporter_test.go`](https://github.com/openshift/lightspeed-otel-collector/blob/main/test/e2e/file_exporter_test.go)
