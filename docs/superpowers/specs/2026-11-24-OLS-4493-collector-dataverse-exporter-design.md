# OLS-4493 — Collector Dataverse Exporter (Phase 2.1) Design

- **Date:** 2026-11-24
- **Status:** Draft for review
- **Jira:** [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493)
  (parent epic OLS-4490)

## Why change the upload path?

Red Hat uses Agentic traces to understand adoption, tool use, failures, and cost.
The existing FileExporter writes traces to a pod-local JSONL file. The Python
sidecar uploads rotated files, but rotation depends on size. On a low-volume
cluster, the file may never rotate before the pod is replaced.

Phase 2.1 sends batches directly from the Collector to Dataverse. A timer
flushes partial batches even when no more traces arrive. This restores the
time-based trigger proposed in OLS-4248/4249 without requiring a shared file.

## Goals

- Flush partial batches after 10 minutes when an exporter consumer is available.
- Remove the shared spool and its polling sidecar.
- Preserve the Dataverse wire format: one JSON array of OTLP trace-batch
  objects per gzip TAR member, `agentic-v1/` prefix, one TAR per upload.
- Reuse the Collector's stock queue/batch/retry machinery (`exporterhelper`)
  — no custom buffering code.
- Preserve fan-out isolation: producers emit OTLP and are unaffected by
  Dataverse availability, and other trace consumers (trace backend,
  customer-configured destinations) never receive duplicates or errors
  caused by the dataverse exporter.
- Limit queued data by byte size; do not write product traces to disk.

## Non-goals

- Enterprise audit or compliance delivery — that is the separate
  compliance-audit path and is untouched by this design. Dataverse here
  serves Red Hat product analysis only.
- Exactly-once delivery. Duplicates are possible; downstream deduplication
  remains required and already owned by Dataverse (ADR 0043).
- Durability across pod replacement. Queue contents die with the pod; this
  is the same durability class as today's emptyDir spool.
- Any change to the Classic app-server transcript/feedback export path or
  its Python uploader.
- Any Collector-side product-semantic transformation. The exporter packages
  bytes; it does not classify, join, or redact.

The exporter uses the Collector's existing queue and retry support. This
design does not add persistent storage or a separate messaging service.

## Constraints (inherited)

From ADR 0043 / `.ai/spec/what/agentic-data-collection.md`:

- Collection is opt-out via
  `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` (false or
  absent enables). No new CR field.
- The routing connector selects resources by exact `service.name`. Only the
  exporter batches data on the collection branch.
- Native OTLP payloads are preserved: identifiers, timestamps, statuses,
  resource/scope context, schema URLs, typed attributes, links, events,
  dropped counts. No OLS-level `schema_version` field.
- Changes that can affect collected-data structure or meaning require
  compatibility review with Dataverse owners before merge (rule 41) — see
  [Compatibility](#compatibility).
- Collector image and generated configuration must roll out together
  (rule 37).

## Deployment changes

| Piece | Repo | Today | After this design |
|---|---|---|---|
| Producers (agentic operator, sandbox) | `lightspeed-agentic-operator`, `lightspeed-agentic-sandbox` | OTLP to Collector | unchanged |
| Collector | `lightspeed-otel-collector` (image build; pins contrib FileExporter v0.159.0) | `file/data_collection` exporter writes `traces.jsonl`, size rotation 1 MiB / 400 backups / 1 day, 500 MiB emptyDir | new `dataverse` exporter; FileExporter, volume, rotation gone |
| Dataverse exporter sidecar | `lightspeed-to-dataverse-exporter` (Python) | `data_mode: otel` polls rotated backups every 300 s, RO mount, ledger, TAR upload | container removed from the Collector pod; Classic path in this repo untouched |
| OLS operator | `lightspeed-operator` | generates collector config, sidecar config/RBAC/volumes | generates `dataverse` exporter config; sidecar assets removed; RBAC retained (same ServiceAccount) |
| Ingress / Dataverse | external | multipart POST, Bearer pull-secret token, 202 + `request_id` | unchanged |

The `data_mode: otel` code in `lightspeed-to-dataverse-exporter` becomes
unused for new deployments; its removal is follow-up work, not part of
Phase 2.1 rollout.

## Approaches considered

**A1 — Collector pushes to the sidecar over OTLP/HTTP.** Replace
FileExporter with stock `otlphttpexporter` (JSON) targeting a small HTTP
endpoint in the existing Python sidecar; the sidecar wraps each request as
the array/TAR and uploads with its existing `IngressClient`/auth.
Trade-offs: reuses the Python auth/upload code verbatim and stock collector
components; but keeps the sidecar container, its config/volumes, and adds an
HTTP hop plus a new endpoint to write and secure. Rejected in favor of A2
for fewer moving parts; the code-reuse argument is weak because Classic
keeps the Python uploader anyway, so the logic exists twice regardless of
language.

**A2 — new `dataverse` exporter in the Collector (chosen).** A custom
exporter package in `lightspeed-otel-collector` (sibling of
`postgresexporter`), built on `exporterhelper`, that serializes trace
batches to the existing wire format and POSTs them to ingress. Trade-offs:
~7 KB of auth/upload logic ported from Python to Go (pull-secret token
read, ClusterVersion cluster ID, multipart POST, 202 check); the Collector
process now holds the ingress credential. In exchange: no sidecar, no
shared volume, no files, no poll loop, no ledger — and two existing failure
modes disappear (oversized single write rejected at 1 MiB; FileExporter
write failures rejecting producer requests, rule 33).

**B — revive the OLS-4248/4249 custom sealing exporter.** Time+size seals
with atomic rename; sidecar's `json` mode picks up sealed files. Rejected:
keeps the two-container file contract and re-introduces custom Collector
code the team already deliberately removed — while still needing the upload
half.

**C — stage traces in the existing PostgreSQL templog database.** Collector
writes a trace table; a consumer polls and uploads. Rejected: needs a new
Go Postgres trace exporter, a Python DB client, and couples product data to
the compliance/templog database.

**D — sidecar tails the active file with an inode+offset checkpoint**
(Vector-style `file` source). No Collector change; format unchanged.
Rejected: keeps the shared-file seam, the ledger, rotation-following logic,
and the FileExporter failure coupling; the most complex reader of the set.

Also rejected without full write-up: reading the Collector's bbolt
`file_storage` queue directly from the sidecar (exclusive lock, no stable
format), and introducing Kafka/NATS/Vector (new infrastructure for
non-critical data; Vector also cannot do pull-secret auth or the ingress
API).

**Decision:** A2 removes the shared volume and sidecar without introducing a
new service. The trade-off is maintaining upload and authentication code in
both the Go exporter and the Classic Python uploader.

## The design

### Component

New package `dataverseexporter/` in `lightspeed-otel-collector`, registered
in `builder-config.yaml` alongside the existing exporters. Minimal pipeline wiring (the operator retains its configured OTLP endpoints and backend route):

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: localhost:4317

connectors:
  routing/data_collection:
    table:
      - context: resource
        condition: attributes["service.name"] == "lightspeed-agentic-operator" or attributes["service.name"] == "lightspeed-agentic-sandbox"
        pipelines: [traces/data_collection]

exporters:
  nop: {}
  dataverse:
    endpoint: https://console.redhat.com/api/ingress/v1/upload
    service_id: ols            # or rhos-lightspeed, per the existing label rule
    archive_path_prefix: agentic-v1/
    sending_queue:
      sizer: bytes
      queue_size: 134217728    # 128 MiB
      num_consumers: 2
      block_on_overflow: false
      batch:
        sizer: bytes
        min_size: 2097152      # 2 MiB
        max_size: 4194304      # 4 MiB
        flush_timeout: 10m
    retry_on_failure:
      enabled: true
      initial_interval: 30s
      max_interval: 5m
      max_elapsed_time: 1h

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [nop, routing/data_collection] # retain the existing backend route where configured
    traces/data_collection:
      receivers: [routing/data_collection]
      exporters: [dataverse]
```

Notes verified against exporterhelper v0.159.0 sources:

- Queue batching is default-off behind the
  `pkg.exporterhelper.queueBatchEnabled` feature gate; an explicit `batch:`
  section in config activates it regardless.
- `min_size` must be ≤ `queue_size` (validated).
- With `wait_for_result: false`, producers do not wait for the upload.
- The byte sizer measures protobuf, not JSON or compressed archive size.
  Test payloads expanded by 1.6–5.9× when serialized as JSON. This informed
  the 2 MiB batching threshold and 4 MiB split size; the exporter still
  checks each compressed archive against the upload limit.

### Packaging and upload

For each flushed batch:

1. Serialize the batch as native OTLP JSON and wrap it in a one-element array.
2. Write the array as the sole member of a gzip-compressed TAR archive. The
   member name is `agentic-v1/traces-<UTC timestamp>-<sequence>.json`.
3. Check the archive size. If it exceeds the configured limit, count and
   discard the batch; do not truncate it.
4. POST the archive as multipart form data with the service-specific content
   type, the pull-secret bearer credential, and the cluster ID in the user agent.
5. Treat HTTP 202 with a `request_id` as success. See [Error classification](#error-classification)
   for retry and drop behavior.

The 100 MiB cap is an assumption mirroring the ingress service's
`DefaultMaxSize` (100 MB), not a published contract: the ingress does
not advertise the limit on any queryable endpoint (its OpenAPI spec at
`/api/ingress/v1/openapi.json` has no size fields), and per-content-type
limits are deployment configuration on the ingress side
(`INGRESS_MAXSIZEMAP`, per the insights-ingress-go deployment
guidelines). The authoritative runtime signal is the HTTP 413 response,
classified as a permanent counted drop (`reason=http_413`).

### What happens when the queue is full?

The same producer request can feed both Dataverse and a trace backend. If
the Dataverse queue rejects a batch and the receiver returns an error, the
producer may resend data the backend has already accepted.

The exporter therefore handles `exporterhelper.ErrQueueIsFull` locally: it
drops the refused batch, increments the drop counters with `reason=queue_full`,
logs at most one warning per minute, and returns success. Other enqueue
errors pass through unchanged.

### Error classification

Permanent errors are counted drops (never retried — identical bytes or
identical credentials cannot succeed); retryable errors go to
`retry_on_failure` with backoff (30s initial, 5m max, **1h budget**).

| Condition | Class | Counter reason |
|---|---|---|
| Network error, timeout, HTTP 408, 429, 5xx | Retryable | — |
| HTTP 401 | Retryable. Refresh the token if the refresh interval has elapsed. | — |
| API-server errors while loading credentials | Retryable (transient API-server unavailability) | — |
| Pull-secret has no `cloud.openshift.com` entry, malformed `.dockerconfigjson` | Permanent | `credentials` |
| HTTP 403 and other 4xx (including 413) | Permanent | `http_<status>` |
| Packaged TAR above the payload cap | Drop without retry | `payload_too_large` |
| Queue full | Drop at enqueue | `queue_full` |

The exporter counts permanent failures and queue refusals by reason. A
permanent failure inside the upload function returns success to exporterhelper,
so `sent_spans` includes those spans. A queue refusal never reaches the upload
function. Retry exhaustion is reported by `otelcol_exporter_send_failed_spans`,
not the Dataverse drop counters.

### Authentication

The Collector uses its projected ServiceAccount token and CA to make HTTPS
requests to the Kubernetes API. It reads the upload token from
`auths["cloud.openshift.com"].auth` in `openshift-config/pull-secret` and the
cluster ID from `ClusterVersion/version.spec.clusterID`. The sidecar uses the
same ServiceAccount, so these reads need no new RBAC permissions.

At startup, the exporter requires the in-cluster API address and CA file.
It reads the pull-secret and cluster ID on the first upload rather than at
startup, so an unavailable secret does not prevent the other pipelines from
starting. It caches both values and reads the projected ServiceAccount token
from disk for each API call.

An ingress 401 can trigger a pull-secret refresh and one more upload attempt.
Within the one-minute refresh interval, the exporter instead returns the
401 to exporterhelper for backoff. The interval limits API reads; it is not
a deadline for recovery after credential rotation.

### Egress proxy and TLS

The exporter's HTTP client is built on `confighttp.ClientConfig` — the
standard config block used by every Collector HTTP component:

```yaml
exporters:
  dataverse:
    endpoint: https://console.redhat.com/api/ingress/v1/upload
    tls:
      ca_file: /etc/pki/trusted-ca/tls-ca-bundle.pem   # optional
    timeout: 30s
```

- **Ingress proxy:** the HTTP client honors `HTTPS_PROXY`, `HTTP_PROXY`, and
  `NO_PROXY` from the Collector environment. Exercise this path in the
  operator's Squid-based proxy test.
- **Ingress TLS:** use `ca_file` or `ca_pem` when a proxy signs certificates
  with a private CA. Validation must reject `insecure_skip_verify` and
  `include_insecure_cipher_suites`.
- **TLS policy:** protocol versions, cipher suites, and curve preferences use
  the standard `configtls` settings. The operator must decide whether to use
  defaults or derive settings from the OpenShift TLS security profile, and
  whether to mount the injected trusted CA bundle.
- **Kubernetes API:** a separate HTTPS client trusts the projected
  ServiceAccount CA and connects directly, without the egress proxy.
- **IPv4 and IPv6:** the exporter uses `net.JoinHostPort` for the Kubernetes
  service address. The operator uses a DNS name for ingress. Enclose an IPv6
  literal in brackets if specifying an endpoint manually.

### Gating

The operator configures the exporter only when `transcriptsDisabled` is false
or unset **and** the pull-secret contains a cloud credential. Otherwise it
omits the collection pipeline; there is no local spool. If credentials become
unavailable after deployment, uploads follow the [error classification](#error-classification)
above without preventing the other pipelines from starting.

### Failure and loss semantics

| Concern (from the OLS-4493 acceptance criteria) | Behavior in this design |
|---|---|
| Partial records | Eliminated by construction — no file appends, no line framing; batches are whole in-memory requests. |
| Rotation races | Eliminated — no rotation, no active file. |
| Duplicate data | If ingress accepts an upload but the response is lost, a retry can deliver the batch again. Dataverse deduplicates on content. |
| Omitted data | A full queue drops new arrivals. Permanent failures and exhausted retries drop the affected batch. Restarts lose all unsent memory-resident data, with no one-flush-interval age bound. |
| Ingress outage | Admitted batches retry with backoff (30s→5m) for up to 1h per batch. Queue capacity can be exhausted before that budget. |
| Acknowledgements | HTTP 202 + `request_id` per upload, logged; request IDs are not persisted locally (no dedup role for them downstream — Dataverse dedups on content). |
| Restarts | A container restart loses queued and in-flight batches. The previous `emptyDir` spool survived a container restart but not pod replacement. |
| Storage | The queue holds up to 128 MiB measured as protobuf. In-flight data and serialization buffers require additional memory. The 500 MiB spool volume is no longer needed. |
| Credentials | A malformed pull-secret or missing cloud entry drops the batch (`credentials`). A failed API read is retryable. Neither prevents the other pipelines from running. |
| Producer-visible failures | A full Dataverse queue does not cause a producer retry. See [What happens when the queue is full?](#what-happens-when-the-queue-is-full). |

### Compatibility

- The exporter preserves OTLP span fields and the JSON-array/TAR format.
  A queue flush, rather than a rotated file, determines which spans travel
  together and when they are uploaded. Rule 41 requires Dataverse owner
  sign-off on this packaging change before rollout.
- Schema URLs and GenAI convention pins (v1.41.0) pass through untouched.

## Validation and test plan

- **Unit (collector):** push function — array/TAR construction matches the
  Python consumer's output shape (golden files generated from both),
  202/`request_id` parsing, permanent versus retryable response handling, payload-cap
  rejection, auth client token/clusterID extraction and 401 re-read,
  config validation (queue/batch rules, feature-gate-independent batch
  activation).
- **Integration (collector):** `exporterhelper` queue behavior with a fake
  ingress — flush at `flush_timeout` with tiny volume (the quiet-cluster
  case), batch split at `max_size`, retry/backoff on 5xx, drop counting on
  exhausted retries and on full queue with `block_on_overflow: false`;
  queue-full is swallowed (nil returned, `reason=queue_full` counted,
  producer sees success) while other errors propagate.
- **Operator tests:** generated config contains the exporter when enabled;
  opt-out removes it; credential-absent omits it; sidecar assets absent;
  RBAC unchanged; all generated-config permutations validated as today.
- **Batch sizing checks:** (1) confirm `bytes` sizer
  measurement semantics and resulting JSON/TAR expansion factor; (2)
  confirm explicit `batch:` activates batching at v0.159.0 without the
  feature gate; (3) measure a worst-case flush under `max_size` against
  the 100 MiB cap.
- **E2E:** released-bundle upgrade path from the current sidecar layout;
  quiet cluster (single run, no size trigger) delivers within ~2×
  `flush_timeout`; ingress outage > retry budget drops counted data and
  recovers; credential absent → collector starts, uploads fail with
  counted errors, no crashloop; pull-secret restored → uploads resume
  without restart; opt-out → no pipeline.
- **Field validation (OLS-4492 track):** confirm Dataverse receives and
  parses payloads from the new exporter; record request IDs and
  array-boundary observations.

## Implementation work breakdown (Phase 2.1)

1. **Collector — exporter package** (`lightspeed-otel-collector`): config
   + factory + push function + auth client + packaging; builder-config
   pin; unit and integration tests.
2. **Sizing:** use the measurements above when configuring the operator.
3. **Operator — wiring** (`lightspeed-operator`): generate exporter config
   (gates: transcriptsDisabled + credentials); remove sidecar container,
   ConfigMap, data-collection and ledger volumes; keep RBAC; update
   deployment and config tests. Open operator decisions recorded here:
   (a) **mount the projected ServiceAccount token into the collector
   container** (read-only, at the conventional path) — the pod sets
   `automountServiceAccountToken: false` and today's token volume is
   mounted only into the sidecar, so without this the exporter cannot
   read in-cluster credentials at all; (b) whether generated TLS values
   are defaults or derived from the OpenShift TLS security profile
   (`ResolveTLSProfile` + `CipherCodes`); (c) whether to wire the
   `inject-trusted-cabundle` ConfigMap into `tls.ca_file` for
   TLS-inspecting proxies.
4. **Rollout ordering:** collector image containing `dataverseexporter`
   ships in a released bundle first; operator config follows (rule 37).
   Transition is a single coordinated upgrade — in-flight spool data on
   upgrading clusters is abandoned (bounded loss, accepted).
5. **Compatibility review** (rule 41) with Dataverse owners:
   packaging-only change, no version bump; recorded before merge of
   task 3.
6. **E2E + field validation** per the test plan.
7. **Follow-ups (separate stories, not Phase 2.1):** retire `data_mode:
   otel` from `lightspeed-to-dataverse-exporter`; revisit `file_storage`
   queue if field data shows restart losses matter.

## Remaining rollout checks

- Confirm that the queue, in-flight batches, and serialization buffers fit
  the Collector container's memory limit. Adjust the queue size or pod
  resources in the operator configuration if necessary.
- Compare the exported archives with sidecar fixtures and confirm that
  Dataverse parses them before enabling the new pipeline in a release.
