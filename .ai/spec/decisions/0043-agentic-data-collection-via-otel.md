# 0043 — Agentic Data Collection via OTLP Traces

## Status

Accepted under OLS-4246. This is the target architecture, not a report of delivery. Status reviewed 2026-10-03: Collector integration, sandbox producer work, operator first-rollout wiring, and the Dataverse OTel consumer remained proposals rather than confirmed delivery. The first operator rollout is local-file-only; Dataverse consumption and its operator wiring are later work. This record does not establish a full operator/OLSConfig rollout or production end-to-end delivery. Agentic operands remain subject to ADR 0037's OCP ≥ 5.0/v2 support boundary.

## Context

Agentic OLS needs product-analysis data for adoption, outcomes, model and tool behavior, and complete ordered transcripts. Agentic applications already produce correlated OTLP traces. Classic OLS has a separate app-server transcript-file exporter path.

Collection uses the existing trace transport without duplicating transport and filesystem behavior in Go and Python producers. The Collector routes and writes native trace evidence; downstream data products interpret it. OTLP logs remain on the templog/PostgreSQL path, and trace-backend batching remains independently configured.

## Decision

Agentic product collection uses the existing OTLP trace path. The Collector routes only resources whose `service.name` is exactly `lightspeed-agentic-operator` or `lightspeed-agentic-sandbox`. The FileExporter branch has no `batch` processor; the independent trace-backend branch retains its configured batch processor.

Contrib FileExporter v0.159.0 writes each complete native OTLP trace batch as one JSON object followed by LF to `/var/lib/lightspeed-data/otel/traces.jsonl`. A line may contain multiple resource spans, scopes, spans, and attached events. The trace payload preserves native identifiers, timestamps, statuses, resource and scope context, schema URLs, typed attributes, links, events, and dropped counts when present; it has no OLS `schema_version` field.

The first operator rollout uses `transcriptsDisabled` as the sole gate for this local branch: false or unset enables it, and true disables it. Local file creation requires neither telemetry credentials nor a separate OCP-version gate; Agentic operands remain subject to ADR 0037's OCP ≥ 5.0/v2 boundary. The operator provides a 500Mi pod-local `emptyDir` at `/var/lib/lightspeed-data`, mounted read-write only in the Collector, with 16MiB files, 16 backups, and one day of backup age. File rotation is size-triggered, and FileExporter manages backup deletion independently of upload acknowledgment.

The first rollout has no Agentic Dataverse sidecar. Later operator wiring adds the existing Dataverse exporter in `data_mode: otel`, with a read-only source and a separate writable ledger outside that source. The consumer reads rotated backups only, packages each backup's native batch JSONL objects as one JSON array in a gzip TAR member, and uploads the backup. It does not consume the active file or control FileExporter rotation and retention.

Sandbox traces use GenAI Semantic Conventions v1.41.0 and instrumentation `schema_url` `https://opentelemetry.io/schemas/1.41.0`. Product collection is opt-out and retains source content without product-path redaction. A successful native tool callback result remains trace evidence even when inspection rejects it; inspection controls whether that content reaches a subsequent model request or application result, not whether the trace retains it. Native tool failures do not create a success-result record.

The Collector performs transport and file export without product-semantic transformations. Dataverse data products own native OTLP extraction, deduplication, joins, ordered transcript assembly, run and phase reconstruction, outcome derivation, aggregation, and analytics, including logical Actions and transcripts. Changes to collected trace structure or meaning require versioned coordination with downstream Dataverse owners.

## Consequences

- Local files are bounded, pod-local retention rather than a durability or delivery guarantee. Pod replacement or volume removal can lose data, and size- or age-based cleanup does not wait for upload acknowledgment.
- Active files rotate only by size; quiet active files can remain unavailable to the later consumer. FileExporter adds no Collector-side queue or retry wrapper, and oversized writes or filesystem failures can reject a shared OTLP trace request even after the backend branch accepted it.
- Upload success followed by failed ledger persistence can cause duplicate delivery, so downstream deduplication remains necessary. Versioned downstream coordination remains required. The current design does not define a complete OLS contract discriminator or compatibility check; selecting and wiring that mechanism remains an explicit integration gap.
- The shared transcript opt-out continues to disable Classic transcripts. The Classic exporter, compliance audit, templog/PostgreSQL, configured trace backend, and Classic feedback under its existing control retain their independent ownership and behavior.
- Upstream content attributes are designated Opt-In, while this product collection target is opt-out and retains source content whenever traces are recorded. That policy difference requires explicit governance resolution; semantic-convention alignment alone does not provide full upstream content-consent conformance.

## Rejected Alternatives

- **Direct application filesystem writes:** Rejected because each producer would duplicate transport and filesystem behavior and take on local staging and upload concerns.
- **Collector-built logical Actions and transcripts:** Rejected because run reconstruction, tool pairing, outcome derivation, deduplication, and aggregation belong in the Dataverse layer.
- **OTLP logs as a product source:** Rejected because logs are the templog transport and can contain bridged or duplicated application logging. Product collection is trace-only.
