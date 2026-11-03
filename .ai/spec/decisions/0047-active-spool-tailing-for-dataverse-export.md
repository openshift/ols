# 0047 — Active-Spool Tailing for Dataverse Trace Export

## Status

Proposed under OLS-4493 on 2026-11-03. This is a Phase 2.1 design decision, not a report of delivery. Phase 1 remains the rotated-backup consumer recorded in ADR 0043.

## Context

The Collector FileExporter writes native OTLP trace-batch JSONL to a pod-local active file and rotates it by size. The Dataverse exporter reads closed rotated backups only, so a low-volume active file can remain undelivered indefinitely and is lost on pod replacement. FileExporter retention deletes backups by count and age and has no upload acknowledgement channel.

The pinned behavior was verified on 2026-11-03:

- contrib FileExporter v0.159.0 writes each record's JSON and its LF as two serialized writes through timberjack v1.4.6.
- Timberjack rotates before the write that would exceed the size limit. A record that exactly fills the file rotates before the LF write, so a backup can end with a complete object without LF and the new active file can begin with a lone LF.
- Rotation renames the active inode to a timestamped backup and creates a new active file. A reader holding the old descriptor continues to read the renamed backup.
- A restart appends to the retained active file; a crash between JSON and LF can concatenate the next object after a complete object without LF.
- There is no fsync, no Collector-side retry or acknowledgement, and no timer that seals an idle active file.
- Upstream FileExporter exposes no rotation interval; timed sealing would require an upstream change.

## Decision

The Dataverse exporter consumes complete records from both the active file and rotated backups under a read-only source mount.

- Each source is identified by `(st_dev, st_ino)`, not by filename, so rotation does not reset progress.
- A versioned ledger records, per source identity, the byte offset after the last acknowledged record, content anchors, the last observed name and size, and whether an immutable backup is fully consumed.
- Only complete JSON objects are packaged. Whitespace is skipped, a final complete object without LF is accepted, and concatenated objects are separated. A partial trailing object is held and retried; it is never uploaded.
- A chunk is uploaded as one JSON array in one gzip TAR member. A complete backup read from offset 0 to EOF in one chunk keeps its existing member name; active chunks and partial-backup suffixes use a range-qualified member name.
- The offset is committed only after the Ingress upload returns 202, except for whitespace-only progress, which acknowledges no record. Duplicate delivery is accepted after crashes, acknowledgement loss, ledger loss, or identity resets; downstream deduplication remains authoritative. There is no exactly-once guarantee.
- A version 1 ledger is migrated by marking present backups fully consumed. Invalid ledger content is quarantined and replaced, biased toward duplicate delivery. Ledger I/O failures stop the loop.
- The Collector, producers, source retention, rotation thresholds, and the CRD are unchanged. A configuration switch can disable active reads for rollback.

## Consequences

- Quiet active files are delivered at the next polling interval instead of waiting for rotation. Active delivery latency is bounded by the exporter's collection interval, not by trace volume.
- The consumer gains a source-identity model and a version 2 ledger. The ledger is bounded by the retained source count.
- A source can produce several upload members over its life. Dataverse extraction must accept multiple members per source and deduplicate by native trace/span identity. The affected contract is packaging, not OTLP trace structure; the Dataverse owners must classify it under the collection contract's compatibility rule.
- Retention eviction remains outside the consumer's control. At 400 backups of 1MiB and a 300-second interval, sustained rates above about 1.33MiB/s can evict unuploaded backups; the interval, backup count, or alerting must cover the expected peak.
- A crash mid-JSON can leave an unparseable fragment. The complete prefix is delivered; the corrupt suffix is reported and lost. No safe resynchronization exists without per-record producer framing.
- The Collector contract that restricts consumers to closed rotated files requires a planned amendment permitting read-only reads of the active path without modifying, renaming, or deleting it.
- Source and ledger volumes remain pod-local `emptyDir`s. Pod replacement loses undelivered data and acknowledgement state; this decision does not add durability.

## Rejected Alternatives

- **Producer-side timed sealing:** FileExporter does not expose timberjack's rotation interval; adding it requires an upstream change, and sealing still waits for a write. Deferred as a possible later simplification.
- **Collector-side sealing or a custom exporter:** the custom Agentic exporter was implemented and then reverted in favor of stock FileExporter. Reintroducing it adds maintenance and departs from the pinned component contract.
- **Whole-active snapshot re-upload:** repeats up to the active file size every polling interval and remains incorrect across rotation without an offset. Rejected as an amplification of the problem.
- **Status quo:** leaves quiet active data undelivered indefinitely and loses it on pod replacement.

## References

- [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493), [OLS-4490](https://redhat.atlassian.net/browse/OLS-4490)
- Design: [`docs/superpowers/specs/2026-11-03-OLS-4493-active-spool-export-design.md`](../../../docs/superpowers/specs/2026-11-03-OLS-4493-active-spool-export-design.md)
- Phase 1 decision: [ADR 0043](0043-agentic-data-collection-via-otel.md)
- Parent contract: [`what/agentic-data-collection.md`](../what/agentic-data-collection.md)
- Collector contract: `lightspeed-otel-collector/.ai/spec/what/data-collection.md`
