# 0052: Dataverse Export from the Collector

**Status:** Accepted (design approved under OLS-4493; Collector implementation in review — openshift/lightspeed-otel-collector#134; operator wiring pending). Supersedes the file-transport part of [0043](0043-agentic-data-collection-via-otel.md).
**Applies to:** lightspeed-otel-collector, lightspeed-operator, lightspeed-core/lightspeed-to-dataverse-exporter
**Tracking:** [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493) (parent epic OLS-4490)

## Context

ADR 0043 routed Agentic product traces to a pod-local JSONL spool. A Python sidecar uploaded rotated files. On clusters with little traffic, the active file might never reach the rotation threshold. Replacing the pod would then discard traces that the sidecar had never seen.

## Decision

Send eligible traces directly from the Collector to Dataverse. The `dataverse` exporter uses a memory queue and flushes partial batches after 10 minutes when a consumer is available. It posts each batch to the Red Hat ingress API in the sidecar's archive format: one OTLP JSON array in a gzip-compressed TAR, under `agentic-v1/`.

The operator enables this pipeline only when transcript collection is enabled and the cluster has an upload credential. It mounts the projected ServiceAccount token in the Collector and removes the sidecar and shared spool. On its first upload, the exporter reads the pull-secret token and cluster ID from the Kubernetes API.

A full queue drops the incoming batch rather than asking the producer to retry a request that another trace backend may already have accepted. The exporter retries transient upload failures for up to one hour per batch. It counts permanent failures and queue refusals in `otelcol_dataverse_exporter_dropped_*` by reason. These trade-offs apply to product analysis, not enterprise audit.

## Consequences

- The quiet-cluster gap closes: low-volume batches need not reach a size threshold.
- Delivery is best effort. Queue capacity limits the backlog in bytes, not time. A full queue drops new arrivals even during short outages. A restart or pod replacement loses all unsent data, including in-flight batches. Retry exhaustion is reported by `otelcol_exporter_send_failed_spans`, not the custom drop counters. Downstream deduplication remains required.
- With no files there is no local collection while upload credentials are absent — clusters that cannot upload are not collected.
- The Collector now holds the ingress credential. Classic keeps its Python uploader, so both implementations must remain compatible with the ingress API.
- Two FileExporter-era failure modes disappear: oversized single-write rejection and file-write failures rejecting producer requests.
- `data_mode: otel` in lightspeed-to-dataverse-exporter is superseded; removal follows the operator release that stops generating it.
- Record contents and wire format are unchanged (packaging-only change: new array boundaries); rule-41 compatibility sign-off with Dataverse owners is still required before rollout.

## Rejected Alternatives

- **Tail the active file (inode+offset checkpoint, Vector file-source pattern):** keeps files, the cross-container file contract, the ledger, and the FileExporter failure coupling; the most complex reader considered.
- **Collector pushes to the sidecar over OTLP/HTTP:** keeps a second container and adds a network hop; code-reuse argument is weak because Classic keeps the Python uploader regardless.
- **Revive the OLS-4248/4249 sealing exporter:** re-introduces custom Collector staging code the team deliberately removed, and still needs the upload half.
- **PostgreSQL as the queue:** new Go exporter and Python client, and couples product data to the compliance/templog database.
- **Read the Collector's bbolt queue from the sidecar:** exclusive lock, internal format — not viable.
- **Ship Vector or a message bus:** new infrastructure in the product stack for non-critical data; cannot perform the ingress upload anyway.
