# OLS-4493 — Collector Dataverse Exporter (Phase 2.1) Design

- **Date:** 2026-11-24
- **Status:** Draft for review
- **Jira:** [OLS-4493](https://redhat.atlassian.net/browse/OLS-4493)
  (parent epic OLS-4490)
- **Supersedes the active-file problem statement of this story:** the active
  spool file is eliminated, not consumed.

## Intent and why

Agentic OLS product telemetry (OTLP traces from `lightspeed-agentic-operator`
and `lightspeed-agentic-sandbox`) must reach Red Hat Dataverse for product
analysis: adoption, tool usage, failure modes, and cost. The released
pipeline writes traces to a pod-local JSONL spool via the stock contrib
FileExporter and uploads only size-rotated backups. Rotation is
size-triggered only, so on quiet clusters the active file never rotates and
its data is never uploaded — it sits on an emptyDir until a pod restart
deletes it. Quiet clusters are the majority early in adoption, exactly when
the data matters most.

Phase 2.1 replaces the file spool with a **`dataverse` exporter inside the
Collector** that pushes trace batches directly to the Dataverse ingress API
over the Collector's standard `sending_queue`, with time- and size-based
batching. No component writes or reads intermediate files.

Lineage, for context: OCPSTRAT-3983 (product need) → OLS-3569 (architecture:
OTLP traces → Collector → Dataverse, downstream owns reconstruction) →
OLS-4246 (delivery epic). The original delivery plan (OLS-4248/OLS-4249) had
a custom Collector exporter that sealed files at 1 MiB **or 30 seconds**; the
pivot to the stock FileExporter (OLS-4250) kept the size trigger and silently
dropped the time trigger, which is the gap this design closes. This design is
effectively a return to a custom exporter — with the upload in the Collector
instead of a sidecar, and no files at all.

## Goals

- Quiet clusters' trace data reaches Dataverse within a bounded time
  (`flush_timeout: 10m`) regardless of volume.
- No process reads a file another process is writing; no files are involved.
- Preserve the Dataverse wire format: one JSON array of OTLP trace-batch
  objects per gzip TAR member, `agentic-v1/` prefix, one TAR per upload.
- Reuse the Collector's stock queue/batch/retry machinery (`exporterhelper`)
  — no custom buffering code.
- Preserve producer insulation: producers emit OTLP and are unaffected by
  Dataverse availability.
- Bounded resource usage: queue size caps memory; no unbounded local state.

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

## Anti-goals (failure even if it technically works)

- Reintroducing a shared-volume file contract between two containers (the
  seam that produced this Jira).
- Gold-plated reliability (persistent volumes, fsync, exactly-once) — the
  data is explicitly **not mission critical**; bounded loss windows are
  acceptable.
- Deploying new infrastructure (Kafka, Vector, a message bus) for this path.

## Constraints (inherited)

From ADR 0043 / `.ai/spec/what/agentic-data-collection.md`:

- Collection is opt-out via
  `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` (false or
  absent enables). No new CR field.
- Eligibility is exact `service.name` matching in the routing processor;
  the collection branch stays unbatched at the pipeline level (batching
  belongs to the exporter's queue, which is what `exporterhelper` batching
  is).
- Native OTLP payloads are preserved: identifiers, timestamps, statuses,
  resource/scope context, schema URLs, typed attributes, links, events,
  dropped counts. No OLS-level `schema_version` field.
- Changes that can affect collected-data structure or meaning require
  compatibility review with Dataverse owners before merge (rule 41) — see
  [Compatibility](#compatibility).
- Collector image and generated configuration must roll out together
  (rule 37).

From this conversation (user decisions):

- Not mission critical: pragmatic loss windows acceptable; no coverage of
  every failure path.
- Memory-only queue (no `file_storage`); `flush_timeout: 10m`; latency is
  not critical and 5m was deemed possibly too short.

## Current state (what changes)

Today, in the released operator:

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

**Why A2 wins:** it is the only option that removes the file seam entirely
while reusing stock machinery for everything hard (queueing, batching,
retry) and keeping the wire format byte-compatible for Dataverse. Its
unique cost — a second implementation of ~200 lines of auth/upload logic —
is fixed and small.

## The design

### Component

New package `dataverseexporter/` in `lightspeed-otel-collector`, registered
in `builder-config.yaml` alongside the existing exporters. Pipeline wiring
(generated by the operator):

```yaml
exporters:
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
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 10m

service:
  pipelines:
    traces/data_collection:    # replaces the file/data_collection terminus
      receivers: [otlp]
      processors: [routing/data_collection]
      exporters: [dataverse]
```

Notes verified against exporterhelper v0.159.0 sources:

- Queue batching is default-off behind the
  `pkg.exporterhelper.queueBatchEnabled` feature gate; an explicit `batch:`
  section in config activates it regardless.
- `min_size` must be ≤ `queue_size` (validated).
- `wait_for_result` is not used (and is invalid with persistent queues
  anyway); with the default `false`, producers are acknowledged at enqueue
  time — preserving today's producer-insulation semantics.
- **Measured (spike, 2026-11-24):** the `bytes` sizer counts the serialized
  **protobuf** request size. JSON expansion over proto measured 1.6×
  (incompressible) to 5.9× (pathological control-character-heavy strings);
  after gzip the TAR is typically *smaller* than proto, worst case ≈ JSON
  + framing. Conservative worst case TAR ≈ 6× sizer-measured bytes, so
  `max_size: 4 MiB` keeps the worst-case TAR at ~24% of the 100 MiB payload
  cap; `min_size: 2 MiB` keeps a non-degenerate batch band.

### Push function (the only new logic)

For each flushed batch:

1. Serialize the batch's trace requests to JSON (same marshaller semantics
   as FileExporter's `format: json` — one JSON object per
   `ExportTraceServiceRequest`).
2. Wrap the objects in one top-level JSON array.
3. Build one gzip TAR with member name `agentic-v1/traces-<UTC
   timestamp>.json` — the exact member shape Dataverse receives today.
4. POST multipart to the ingress URL with `Authorization: Bearer <token>`,
   `User-Agent` carrying the cluster ID, and the service-specific content
   type.
5. Accept on HTTP 202 + `request_id`; treat anything else as a retryable
   error (surfaced to `retry_on_failure`).

Batches larger than the payload cap after packaging are split by the
queue's `max_size` before this point; the push function rejects (rather
than truncates) anything that still exceeds the cap — an observable,
counted drop, never a silent partial record.

### Authentication (ported from Python, once)

- **Token:** read `openshift-config/pull-secret` via the Kubernetes API,
  extract `auths["cloud.openshift.com"].auth`. **Identity:** read
  `config.openshift.io/v1` `clusterversions` `version` → `spec.clusterID`.
- Use the pod's projected ServiceAccount token with a minimal REST client
  (plain HTTP against the API server; **not** client-go — keep the
  dependency surface small). Cache both values; on an ingress 401 or API
  403, re-read once before failing, so secret rotation self-heals.
- The required RBAC already exists and is bound to the Collector's
  ServiceAccount today (it was created for the sidecar, same pod SA): read
  `openshift-config` pull-secret (RoleBinding-scoped), get
  `clusterversions`. No RBAC change.

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

- **Proxy:** `confighttp` uses `http.ProxyFromEnvironment`, honoring the
  `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` env vars the operator already
  injects into the Collector container (`GetProxyEnvVars()`). Proxy parity
  with today's sidecar (`requests`-based) is automatic; no new operator
  wiring. The operator's existing Squid-based e2e proxy test extends to
  the new exporter.
- **TLS:** `ca_file`/`ca_pem` are supported knobs, addressing a gap that
  exists today — the sidecar has no custom-CA provision and relies on the
  UBI system trust store, so MITM re-signing proxies cannot work.
  Generated configuration never sets `insecure_skip_verify`, and the
  exporter's config validation rejects it.
- **TLS versions and cipher suites:** the full standard `configtls` knob
  set is available on the same `tls:` block — `min_version` (default
  TLS 1.2, enforced by configtls), `max_version` (default: Go
  `crypto/tls` maximum), `cipher_suites` (IANA names, validated at
  startup), `curve_preferences`, and `include_insecure_cipher_suites`
  (never generated; rejected by validation, same policy as
  `insecure_skip_verify`). **Policy: the operator-generated configuration
  stays silent on versions and ciphers** — defaults already meet modern
  baselines, and pinning cipher lists in generated config breaks clusters
  when the ingress endpoint rotates its suite support. The knobs exist for
  field tuning via an edited ConfigMap. On FIPS builds (cf. OLS-4860), the
  `requirefips`-gated crypto/tls behavior restricts curves/ciphers
  automatically; config can further constrain but never weaken a FIPS
  deployment.
- **Kubernetes API calls** (pull-secret, ClusterVersion) use the
  in-cluster service network, which is excluded from proxying via
  `NO_PROXY` semantics; they use the pod's projected SA token over the
  same client.

### Gating

- **Collection gate (unchanged):** `transcriptsDisabled` false/absent
  enables the `traces/data_collection` pipeline. Opt-out removes the
  pipeline and the exporter.
- **Credential gate:** the exporter requires the pull-secret auth to
  resolve at startup. Mirroring today's sidecar gate, the operator deploys
  the exporter config only when the telemetry credentials are available.
  Unlike today, with no files there is no local collection while
  credentials are absent — accepted consequence of removing the spool
  (data is not collected on clusters that cannot upload; previously it
  was collected and then lost on rotation).

### Failure and loss semantics

| Concern (from the OLS-4493 acceptance criteria) | Behavior in this design |
|---|---|
| Partial records | Eliminated by construction — no file appends, no line framing; batches are whole in-memory requests. |
| Rotation races | Eliminated — no rotation, no active file. |
| Duplicate data | At-least-once: a batch can be uploaded whose success response was lost, then retried. Downstream dedup (already required, ADR 0043) handles it. No ledger is needed because the queue, not filenames, tracks delivery state. |
| Omitted data | Bounded: (a) queue full with `block_on_overflow: false` → enqueue fails, counted in exporter drop metrics, lost; (b) retry budget exhausted → batch dropped, counted; (c) Collector container restart → queued-but-unsent batches lost (≤ ~1 flush interval + in-flight); (d) pod replacement → everything unsent lost. All are small, bounded windows of non-mission-critical telemetry. |
| Acknowledgements | HTTP 202 + `request_id` per upload, logged; request IDs are not persisted locally (no dedup role for them downstream — Dataverse dedups on content). |
| Restarts | Memory-only queue: a restart costs at most the unsent queue contents. This is strictly less durable than today across *container* restarts (today's spool survives them), accepted per the not-mission-critical decision; switching to `file_storage` later is a one-line config change if field data justifies it. |
| Bounded storage/retention | `queue_size: 128 MiB` in `sizer: bytes` bounds memory. No disk. Volume budget previously reserved for the spool (500 MiB) is freed. |
| Producer-visible failures | Enqueue failure on full queue returns a retryable error to the OTLP receiver (producer SDKs retry or drop per their own policy) — comparable to today's rule-33 coupling, but now only under sustained ingress outage with a full queue, instead of on any local write hiccup. |

### Compatibility

- Record contents inside the TAR are byte-identical to today (same OTLP
  JSON objects; whitespace/array punctuation only, as today).
- What changes: array boundaries — one array per queue flush instead of
  one per rotated backup file; and upload cadence — time/size-driven
  instead of rotation/poll-driven. Dataverse flattens arrays and dedups on
  content, so meaning is unaffected, but per rule 41 this still requires
  the compatibility review sign-off from Dataverse owners before rollout
  (classification: packaging-only, no record-level change; no
  schema/data-contract version bump).
- Schema URLs and GenAI convention pins (v1.41.0) pass through untouched.

## Validation and test plan

- **Unit (collector):** push function — array/TAR construction matches the
  Python consumer's output shape (golden files generated from both),
  202/`request_id` parsing, non-202 → retryable error, payload-cap
  rejection, auth client token/clusterID extraction and 401 re-read,
  config validation (queue/batch rules, feature-gate-independent batch
  activation).
- **Integration (collector):** `exporterhelper` queue behavior with a fake
  ingress — flush at `flush_timeout` with tiny volume (the quiet-cluster
  case), batch split at `max_size`, retry/backoff on 5xx, drop counting on
  exhausted retries and on full queue with `block_on_overflow: false`.
- **Operator tests:** generated config contains the exporter when enabled;
  opt-out removes it; credential-absent omits it; sidecar assets absent;
  RBAC unchanged; all generated-config permutations validated as today.
- **Verification spikes (pre-implementation):** (1) confirm `bytes` sizer
  measurement semantics and resulting JSON/TAR expansion factor; (2)
  confirm explicit `batch:` activates batching at v0.159.0 without the
  feature gate; (3) measure a worst-case flush under `max_size` against
  the 100 MiB cap.
- **E2E:** released-bundle upgrade path from the current sidecar layout;
  quiet cluster (single run, no size trigger) delivers within ~2×
  `flush_timeout`; ingress outage > retry budget drops counted data and
  recovers; credential absent → no collection, no crashloop; opt-out → no
  pipeline.
- **Field validation (OLS-4492 track):** confirm Dataverse receives and
  parses payloads from the new exporter; record request IDs and
  array-boundary observations.

## Implementation work breakdown (Phase 2.1)

1. **Collector — exporter package** (`lightspeed-otel-collector`): config
   + factory + push function + auth client + packaging; builder-config
   pin; unit and integration tests.
2. **Verification spikes** (see above) — gate task 3 sizing.
3. **Operator — wiring** (`lightspeed-operator`): generate exporter config
   (gates: transcriptsDisabled + credentials); remove sidecar container,
   ConfigMap, data-collection and ledger volumes; keep RBAC; update
   deployment and config tests.
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

## Decisions and their owners

| Decision | Owner |
|---|---|
| A2 architecture (exporter in Collector, no files) | User (this conversation) |
| Memory-only queue; 10m flush; latency non-critical | User |
| Not mission critical; bounded loss windows acceptable | User |
| Dataverse serves RH product analysis only; audit is a different path | User (correction) |
| `block_on_overflow: false`, `num_consumers: 2`, 128 MiB queue, 2/4 MiB batch sizes (spike-adjusted from 4/16) | Assistant proposal, tunable, user overridable at review |
| Wire format preserved (array/TAR/member naming) | Assistant proposal (avoids downstream change) |
| Minimal REST client, no client-go; token re-read on 401/403 | Assistant call (builder may revisit) |
| Single coordinated rollout; no transition mode | Assistant call |

## Open items for the builder

- Exact `bytes`-sizer semantics and expansion factor (spike).
- Final queue/batch numbers after the spike (stay ≤ ~⅓ of the 100 MiB
  payload cap after JSON/TAR expansion).
- Go module layout and test golden-file strategy for TAR byte-compatibility
  with the Python consumer's output.
- Member-name uniqueness: flushes within the same millisecond need a suffix
  or monotonic sequence so two TAR members never share a name.
- Pod memory: `queue_size: 128 MiB` plus serialization buffers must fit the
  Collector container's requests/limits; adjust resources or queue size in
  the operator task.
- Whether the exporter emits a startup warning when credentials resolve
  but the ingress URL is unreachable (recommended: yes, health-check
  surface stays with the existing collector health endpoint).
