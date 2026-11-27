# 0052 — In-Collector Dataverse Exporter for Agentic Traces

## Status

Proposed under OLS-4493 (parent epic OLS-4490). Supersedes the file transport part of [0043](0043-agentic-data-collection-via-otel.md): FileExporter, the shared `data-collection` volume, and the Dataverse exporter sidecar in `otel` mode. The rest of 0043 (trace-only collection, exact service-name routing, native OTLP payload, downstream ownership) still applies.

## Context

The released file transport wrote native OTLP trace-batch JSONL with contrib FileExporter v0.159.0 to a pod-local `emptyDir`. A Python sidecar uploaded rotated backups only. That design loses data in ways that are cheap to avoid:

- FileExporter rotates by size only, so a quiet active file never becomes a backup and never uploads.
- FileExporter deletes backups by count and age, regardless of upload.
- A write larger than the rotation size, or a crash between the JSON and LF writes, makes data unusable.
- A FileExporter write failure rejects the producer's OTLP request even when the trace backend accepted it.

Data collection is not mission critical. The goal is to remove the structural gap (data that never ships) and these cheap loss paths, not to cover every failure.

## Decision

A new OLS exporter `dataverse` (module `dataverseexporter` in `lightspeed-otel-collector`) replaces FileExporter on the `traces/data_collection` branch. It uses the standard `exporterhelper` in-memory queue to batch traces by size (4 MiB) or time (5 minutes). It packages each batch as one native OTLP trace-batch JSON object, in a one-element JSON array, inside a gzip TAR under `agentic-v1/`. It uploads directly to the Red Hat ingress service with the existing Python exporter's ingress contract. No trace files exist, and no component reads a file another component writes.

- The exporter reads the pull-secret token and cluster ID through the Kubernetes API, with a projected ServiceAccount token mounted only into the Collector container. The operator does not copy the token or widen who can read it.
- The branch is enabled only when transcripts are enabled and the pull secret holds a `cloud.openshift.com` token.
- Queue-full errors return success to the pipeline, so producers and other trace consumers never see the exporter's problems.
- Every TLS connection follows the OpenShift TLS security profile. Uploads use the cluster-wide proxy from the environment, and trust an injected trusted CA bundle.
- Failures are silent to users. Logs and metrics serve support; each successful upload logs the ingress `request_id` at info level.

The full contract is in [`agentic-data-collection.md`](../what/agentic-data-collection.md) rules 24-37.

## Consequences

- Every accepted trace uploads within about 5 minutes plus upload time, at any volume.
- The ingress upload logic exists twice: in Go for Agentic traces and in Python for Classic data. The team accepted this duplication.
- The Collector process gains the same Kubernetes API read access the sidecar had. It does not gain access to other credentials.
- Without upload credentials, no local trace copy exists.
- Data in the queue is lost when the Collector stops or the pod is replaced, when an outage exceeds the 1-hour retry window, or when the 32 MiB queue fills. The upgrade from the file-based release loses the old pod's unuploaded files once.
- Downstream deduplication remains required: a lost 202 response causes a duplicate upload.
- Each TAR member holds one trace-batch object instead of an array of many. This packaging change requires Dataverse compatibility review (0043, `agentic-data-collection.md` rule 41).
- `fileexporter` leaves the Collector image. The Dataverse exporter's `otel` mode and ledger can be removed after the operator release that stops using them.

## Rejected Alternatives

- **Tail the active file:** a sidecar tracks inode and byte offset in `traces.jsonl` and follows rotation, as Vector does for container logs. Rejected because it keeps files and cross-container file coordination.
- **Collector pushes to the sidecar:** an `otlphttp` exporter sends batches to a localhost endpoint in the Python sidecar, which packages and uploads. Rejected because it keeps a second container and an extra network hop.
- **Custom staging exporter from OLS-4248:** a custom writer seals files at 1 MiB or 30 s for the sidecar. Rejected because it keeps files and a custom staging writer.
- **PostgreSQL as a queue:** the Collector writes traces to a table that the sidecar polls. Rejected because it needs a new exporter and client and couples product data to templog.
- **Sidecar reads the Collector's persistent queue:** not viable. bbolt holds an exclusive lock, and the record format is internal.
- **OpenShift Logging (Vector):** not allowed. It brings another product into the stack and cannot perform the ingress upload.
