# Agentic Data Collection

Canonical cross-repository contract for Agentic product-analysis data. Agentic product traces travel through the existing OpenTelemetry Collector. The released first stage wrote native OTLP trace-batch JSONL with FileExporter, and a Dataverse exporter sidecar in `otel` mode uploaded rotated backups. [PLANNED: OLS-4493] An OLS `dataverse` exporter inside the Collector replaces that file transport: it batches product traces in memory and uploads them directly to the Red Hat ingress service. No trace files exist. Decision [0052](../decisions/0052-in-collector-dataverse-exporter.md) records the change.

[Agentic data collection map](agentic-data-collection-map.svg) shows the planned in-Collector export path.

## Principles

1. [PLANNED: OLS-4246] Agentic product data MUST use the existing OTLP **trace** path. Agentic applications MUST NOT write product-data files.
2. [PLANNED: OLS-4246] OTLP log records remain exclusively on the templog/PostgreSQL path. The Agentic exporter consumes traces only, not separate log or metric signals. Any event attached to an eligible trace span remains native trace evidence and MUST NOT be stripped or classified as a separate log by the Collector.
3. [PLANNED: OLS-4246] Collection is opt-out. Native product traces are retained without product-path PII, secret, CR-field, prompt, context, tool-payload, skill-content, output, or reasoning redaction. On a recording sandbox source span, available raw callback output from successful native tool execution is retained independently of inspection, including a result rejected later. “Complete” means data exposed by the SDK callback after existing upstream limits, not unlimited process output. `LIGHTSPEED_CAPTURE_CONTENT` filters compliance copies only, not source or product traces. Reasoning is represented as ordered message parts, not separate reasoning events.
4. [PLANNED: OLS-4246] The Collector routes eligible resources and exports native OTLP trace batches; it performs no product-semantic transformations.
5. [PLANNED: OLS-4246] Downstream consumers own flattening, deduplication, joins, ordered transcript assembly, run/phase reconstruction, outcome derivation, aggregation, logical SQL/dbt, and final model names.
6. [PLANNED: OLS-4246] Preserve existing compliance audit, templog/PostgreSQL, configured trace-backend, and Classic product-collection behavior. The shared transcript opt-out still disables Classic transcripts; it MUST NOT disable independent compliance, templog, backend tracing, or Classic feedback under its existing control. [PLANNED: OLS-4493] The `dataverse` exporter's failures do not reach producers or other trace consumers (rule 33).

## End-to-End Flow

```text
agentic-operator + batch sandbox
              |
              | existing OTLP traces
              v
      lightspeed-otel-collector
              |                              |
              | exact service-name route     | independent backend route
              | no batch processor           | batch processor
              v                              v
      dataverse exporter                configured trace backend
      own in-memory queue + batch
      (4 MiB or 5 minutes)
              |
              | one JSON array in a gzip TAR per batch
              | HTTPS POST, cluster-wide proxy, OpenShift TLS profile
              v
      console.redhat.com ingress (HTTP 202 + request_id)
              |
              v
      Dataverse: logical Actions, transcripts, and analytics
```

## Enablement and Topology

7. [PLANNED: OLS-4493] The product branch is enabled when `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` is false or absent **and** `openshift-config/pull-secret` holds a nonempty `.dockerconfigjson.auths["cloud.openshift.com"].auth` token. Without that token the operator generates no product route and no product pipeline, so no local trace copy exists. The branch does not require a configured trace backend and has no separate OCP-version/bundle gate. This does not expand Agentic product support: Agentic operands and their handoff require the runtime OCP ≥ 5.0 gate under decision 0042; OCP 4.x runs Classic workloads only even though Agentic APIs and controller infrastructure are installed.
8. [PLANNED: OLS-4246] `transcriptsDisabled` is the sole user control for both Classic transcripts and the Agentic product branch. `feedbackDisabled` continues to control only Classic feedback. `AgenticOLSConfig.spec.audit.enabled` controls compliance audit only. No new product-collection CR field is introduced.
9. [PLANNED: OLS-4246] Existing Classic behavior is unchanged: its feedback-or-transcripts and telemetry-credential gates, app-server transcript production, app-server Dataverse exporter sidecar, storage, service identity, and upload behavior remain as they are. That sidecar does not consume Collector files.
10. [PLANNED: OLS-4493] The classic operator owns the product branch gate. When the gate is off, the operator omits the product route, the `traces/data_collection` pipeline, the `dataverse` exporter, and its credential mount, while preserving existing Collector consumers. No Agentic Dataverse sidecar, collection volume, or ledger volume is deployed.
11. [PLANNED: OLS-4246] Agentic producers neither receive nor evaluate collection state. The existing `lightspeed-agentic-configuration` ConfigMap key `otel-collector-endpoint` remains the Collector handoff; the agentic operator consumes it and uses the existing `OTEL_EXPORTER_OTLP_ENDPOINT` for itself and batch sandbox pods. OLS-4246 adds no endpoint environment variable or handoff ConfigMap key. Disabling templog does not disable product traces.

## Input Contract

12. [PLANNED: OLS-4246] Eligible product input is limited to OTLP trace resources whose `service.name` is exactly `lightspeed-agentic-operator` or `lightspeed-agentic-sandbox`. All their spans and attached events are routed, regardless of operation name, GenAI content, inspection outcome, or run-correlation attributes. Unmatched resources do not enter the product branch; backend forwarding remains independent.
13. [PLANNED: OLS-4246] Run correlation is producer evidence, not a Collector eligibility predicate. Producers MUST stamp available literal `agenticrun.uid` and `agenticrun.phase` as span attributes; missing correlation does not exclude a span from the product branch. The Collector MUST NOT infer missing correlation from resources, other spans, trace/span IDs, names, payloads, or topology.
14. [PLANNED: OLS-4246] `agenticrun.uid` is the hyphenated `AgenticRun.metadata.uid` and is the stable cross-phase key. `agenticrun.phase` is one of `analysis`, `approval`, `execution`, `verification`, `escalation`, or `terminal`. Each phase may use a separate standard OTEL trace ID.
15. [PLANNED: OLS-4246] For batch sandboxes, the operator propagates active trace context and correlation through the Kubernetes input ConfigMap and Pod environment (`TRACEPARENT`, `LIGHTSPEED_AGENTICRUN_UID`, and `LIGHTSPEED_AGENTICRUN_STEP`); the sandbox publishes its Result CR through the Kubernetes API. This collection contract does not use `/v1/agent/run`.
16. [PLANNED: OLS-4246] The sandbox MUST translate the run UID and step supplied through its existing invocation configuration into literal span attributes on agent/model/tool and `tool_result.inspection` spans when supplied. Missing inspection correlation remains absent; no Resource, re-read process environment, parent-context, or other-span fallback is introduced. Attached events retain their native attributes without duplicating correlation solely for collection.

## Producer Evidence and Downstream Interpretation

The producer facts and analytical goals below do not define Collector record classes or filters beyond exact resource service names. Native OTLP nesting, spans, and attached events remain evidence for downstream interpretation.

### GenAI Producer Evidence

17. [PLANNED: OLS-4246] Eligible `lightspeed-agentic-sandbox` spans may carry the standard [OpenTelemetry GenAI Semantic Conventions v1.41](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai). The operation names and attributes below are producer evidence and possible downstream meaning; Collector routing depends only on the exact `service.name` values in rule 12.

| Span operation | Producer evidence / downstream meaning |
|---|---|
| `invoke_agent` | Agent-level effective user prompt (including formatted context), separate `gen_ai.system_instructions` when supplied, and the exact post-shaped `AgentResult.output` as an assistant output message whenever a terminal result is normally produced, including domain `success=false`; pre-terminal failures have no fabricated output; `gen_ai.agent.name=lightspeed` |
| `chat` | Captured main-agent and tool-free shaping model requests/responses as JSON-string arrays of v1.41 messages, with separate `gen_ai.system_instructions` and `gen_ai.tool.definitions` when known; shared DeepAgents capture for every implemented sandbox route, including Vertex Gemini and Azure |
| `execute_tool` | Actual tool execution with `gen_ai.tool.name`, a provider/SDK call ID only when exposed, JSON arguments and the complete raw callback result for successful native execution even if later rejected by inspection; native failures retain the error type and `ERROR` span status, without a success result |

18. [PLANNED: OLS-4246] `invoke_agent lightspeed` is the INTERNAL parent of sibling `{gen_ai.operation.name} {model}` CLIENT inference and `execute_tool {name}` INTERNAL spans. Each captured main-agent or tool-free shaping model request receives its own `chat` model span through shared DeepAgents/LangChain callbacks; isolated classifier, summarization, and named nested-agent calls are excluded from this canonical generation capture; timestamps and ordered message arrays preserve flow order. Text, available reasoning, tool-call, and tool-response parts use the pinned standard message representation. Provider-supplied finish reasons are retained when available; `unknown` is a sandbox-defined fallback accepted by the message schema, not an OTel-standardized finish reason. Observed models and token counts are recorded when available.

19. [PLANNED: OLS-4246] A common provider/SDK-assigned call ID connects a model tool-call part, actual tool span, and later model tool-response part only when that ID is exposed at the relevant boundaries; the Collector MUST NOT synthesize missing IDs or pair by tool name, content, or arrival order. All implemented sandbox routes use SDK-observed LangChain message/tool metadata, including Vertex Gemini and Azure; no finalized ADK Event or retired OpenAI Agents hook is used. Missing IDs remain absent, and supplied provider IDs remain unchanged. A registered skill instruction load is recorded only when it actually executes as an ordinary provider tool (`load_skill` only when that is its real SDK tool name), with its actual arguments and raw successful result on the tool span and any SDK-trimmed model-visible result in the next request. No synthetic skill-load span or `gen_ai.skill.used` event is added; an arbitrary `SKILL.md` read does not establish a skill load. Producers do not synthesize GenAI choice, tool-content, reasoning, input, output, or error span events.

### Logical Action and Transcript Goals

20. [PLANNED: OLS-4246] Agentic operator and sandbox producers record lifecycle, approval, Result CR, and terminal evidence as native trace spans/events. Literal CR payloads, including text-bearing fields, remain raw operational evidence.
21. [PLANNED: OLS-4246] Downstream data products may derive the following logical Actions and ordered transcript analytics from raw native OTLP evidence:

| Logical Action | Required raw evidence and datapoints |
|---|---|
| Run created | `agenticrun.received` timestamp and literal AgenticRun CR: UID, name, namespace, creation timestamp, spec, and initial status |
| Phase completed | Phase span start/end/native status, corresponding `agenticrun.<phase>.completed` event, literal Result CR, conditions/failures, and source timestamps; attempts remain separate atoms |
| Approval decision | `agenticrun.approval.completed` timestamp, authenticated approver UID/username, decision, selected option index/title, and literal AgenticRunApproval CR |
| Analysis result | `agenticrun.analysis.completed`: Result UID/name, option count, full AnalysisResult spec/status, options, conditions, failures, and source timestamps |
| Execution result | `agenticrun.execution.completed`: Result UID/name, actions-taken count, full ExecutionResult spec/status, action statuses, conditions, and failures |
| Verification result | `agenticrun.verification.completed`: Result UID/name, check count, full VerificationResult spec/status, check statuses, summary, conditions, and failures |
| Escalation result | `agenticrun.escalation.completed`: Result UID/name, full EscalationResult spec/status, summary, conditions, and failures |
| Terminal outcome | `agenticrun.terminal` timestamp, final phase, condition reason, and literal terminal AgenticRun spec/status; confirmed cancellation is `Failed` with reason `CancelledByUser`, an unconfirmed cancellation is `Failed` with reason `CancellationFailed`, and global suspension is `EmergencyStopped` or `Failed` with reason `EmergencyStopFailed`; analytics MAY derive a downstream cancellation label |
| LLM operation | `chat {model}` source span start/end/native status for current DeepAgents routes, provider, observed requested/response model and input/output/reasoning token counts when available, error attributes, run UID, and phase; historical evidence retains its producer's emitted operation, with compatibility governed by rules 41–42 |
| Tool operation | `execute_tool {name}` source span start/end/native status, tool name/type, call ID, error attributes, run UID, and phase |

22. [PLANNED: OLS-4246] Expected terminal evidence also covers `Completed / NoActionRequired`, ordinary failure, denial, escalation, `EmergencyStopped`, `Failed / CancellationFailed`, and `Failed / EmergencyStopFailed`. Product analytics MUST NOT invent a `Cancelled` product phase or rewrite the recorded `Failed / CancelledByUser` or failed-stop outcome.
23. Native OTLP carries each selected source span with its attached events. Transport retries can duplicate delivery, so downstream consumers own logical interpretation and deduplication.

## Dataverse Exporter Contract

24. [PLANNED: OLS-4493] The product branch `traces/data_collection` exports only to the OLS `dataverse` exporter (module `dataverseexporter` in `lightspeed-otel-collector`, traces signal only). The exporter writes no files, and no component reads a file another component writes. FileExporter, the `data-collection` volume, the Agentic Dataverse exporter sidecar, its `otel` data mode, and its ledger are removed from the product path.
25. [PLANNED: OLS-4493] The product branch MUST NOT use a `batch` processor. The exporter batches with its own `exporterhelper` sending queue: in memory, `bytes` sizer, 32 MiB queue, one consumer, and a batch flush at 4 MiB or after 5 minutes. Every accepted trace is uploaded within the flush timeout plus upload time, at any volume. Low-volume data does not wait for file rotation. This does not remove producer SDK OTLP transport batching.
26. [PLANNED: OLS-4493] Payload: the exporter marshals each batch with `ptrace.JSONMarshaler` into one native OTLP **trace-batch object**, the same shape as a FileExporter JSONL line. The object preserves native identifiers, timestamps/status, resource/scope context, schema URLs, typed attributes, links, events, and dropped counts when present. It has no OLS-level `schema_version` field. The exporter wraps the object in a one-element JSON array and packages it as the single member of a gzip TAR named `<archive_path_prefix>traces-<UTC yyyy-mm-ddThh-mm-ss.mmm>-<8 hex>.json`. The operator sets `archive_path_prefix: agentic-v1/`. A TAR larger than 100 MiB is dropped as a permanent error.
27. [PLANNED: OLS-4493] Upload uses the existing ingress contract of the Python Dataverse exporter: `POST https://console.redhat.com/api/ingress/v1/upload`, multipart field `file`, filename `lightspeed-assistant.tgz`, part content type `application/vnd.redhat.<service_id>.periodic+tar`, `Authorization: Bearer <cloud.openshift.com auth>`, and `User-Agent: openshift-lightspeed-operator/user-data-collection cluster/<clusterID>`. The operator chooses `service_id` `ols` or `rhos-lightspeed` with its existing logic. Success is HTTP 202 with a JSON `request_id`.
28. [PLANNED: OLS-4493] Credentials: the exporter reads the pull-secret token and `ClusterVersion` `spec.clusterID` through the Kubernetes API, with the projected ServiceAccount token that the operator mounts into the Collector container only while the gate is on. The operator does not copy the token and does not widen who can read the pull secret. The exporter loads credentials on the first upload attempt, never at start, and a credential failure MUST NOT stop the Collector. It re-reads the token before every upload attempt and caches the cluster ID. The token is never logged. The API client trusts only the ServiceAccount CA and connects directly, without a proxy.
29. [PLANNED: OLS-4493] OpenShift TLS security profile: every TLS connection the exporter opens MUST use the minimum TLS version and cipher suites of the effective profile. The operator resolves it from `OLSConfig.spec.ols.tlsSecurityProfile`, then the cluster `APIServer` profile, then the Intermediate default, and writes `tls.min_version` and IANA `tls.cipher_suites` into the exporter configuration. Go does not allow TLS 1.3 cipher suites to be configured, so with a TLS 1.3 minimum only the version applies. A profile change rolls the Collector.
30. [PLANNED: OLS-4493] Cluster-wide proxy: uploads MUST use the cluster-wide proxy when one is set. The exporter follows the `https_proxy` and `no_proxy` variables that the operator already passes to the Collector container; the operator does not set `proxy_url`. `OLSConfig.spec.ols.proxyConfig` configures LLM provider traffic and does not apply to the exporter. The operator creates a ConfigMap labeled `config.openshift.io/inject-trusted-cabundle: "true"`, mounts it read-only in the Collector container, and points `tls.ca_file` at its `ca-bundle.crt`, so TLS-inspecting proxies work.
31. Native span relationships/timestamps and ordered message/event data, not batch, archive, or arrival order, support downstream reconstruction.

## Failure and Loss Semantics

32. [PLANNED: OLS-4493] Error classification:

| Condition | Result |
|---|---|
| Network error, timeout, HTTP 408, 429, 5xx, API server error while loading credentials | Retryable with backoff (30 s initial, 5 min maximum interval) for up to 1 hour |
| Missing `cloud.openshift.com` auth, malformed `.dockerconfigjson` | Permanent: the batch is dropped and logged |
| HTTP 401, 403, other 4xx (including 413) | Permanent: the batch is dropped and logged; the next batch re-reads the token |
| Packaged TAR larger than 100 MiB | Permanent: the batch is dropped and logged |

33. [PLANNED: OLS-4493] Fan-out isolation: when the exporter's queue is full, it counts and logs the dropped spans and returns success to the pipeline. Producers and other trace consumers (the configured trace backend or a customer-configured consumer) never see the exporter's queue or upload problems, and receive no duplicates because of them. A credential or ingress problem MUST NOT prevent the Collector from starting.
34. [PLANNED: OLS-4493] Accepted loss: data is lost when an outage outlasts the 1-hour retry window, when the 32 MiB queue is full, on permanent errors, and when the Collector process stops or the pod is replaced (except what drains within the termination grace period). The first rollout from the file-based release loses the old pod's unuploaded files once. The path adds no persistent storage, guaranteed delivery, or exactly-once promise. A lost 202 response causes a retry and a duplicate upload, and a customer consumer's full queue can make producers retry; downstream deduplication remains required.
35. [PLANNED: OLS-4493] Failures are silent to users: no producer error, no `OLSConfig` status condition, and no alert. `transcriptsDisabled: true` is the only user control. Logs and metrics serve Red Hat support through must-gather. Every successful upload logs one info-level line `Uploaded Agentic trace batch` with `request_id`, `archive_member`, `spans`, `payload_bytes`, and `duration`; the Collector's `otelcol.component.id` field identifies the exporter, so messages carry no component prefix. Each failed attempt logs the status or network error at warning level when retried and at error level when dropped; queue-full drops log at warning level, rate-limited.
36. [PLANNED: OLS-4493] The exporter reports the standard `exporterhelper` metrics and a dropped-span count by reason (`queue_full`, `permanent_error`) unless an existing `exporterhelper` metric reports the same count. The existing Collector `ServiceMonitor` scrapes them.
37. Collector image and generated configuration MUST be rolled out together: an image without the generated exporter component cannot run the generated configuration.

## Repository Ownership

| Repository | Responsibility |
|---|---|
| `lightspeed-operator` | Generate the transcript-and-credential-gated `dataverse` exporter configuration with the TLS profile, mount the projected ServiceAccount token and trusted CA bundle into the Collector container, and keep the credential RBAC. Preserve the Classic path and supported Agentic operand version boundary. |
| `lightspeed-agentic-operator` | Emit lifecycle, approval, Result CR, and terminal evidence; propagate existing endpoint and batch correlation without evaluating collection state. Producer coverage remains separate from export transport. |
| `lightspeed-agentic-sandbox` | Emit pinned GenAI agent/model/tool spans with ordered content and available literal correlation; retain successful raw native tool results regardless of later inspection; never write product files. |
| `lightspeed-otel-collector` | Route exact eligible service resources into an unbatched product branch; own the `dataverse` exporter's batching, packaging, upload, credentials, and failure isolation, not logical transforms. |
| `lightspeed-core/lightspeed-to-dataverse-exporter` | Keep the Classic `json` mode. [PLANNED: OLS-4493] Remove the `otel` mode and its ledger after the operator release that stops using it. |
| Dataverse data product | Own native OTLP extraction, version-aware SQL/dbt, deduplication, joins, ordered transcripts, run/phase reconstruction, outcome derivation, and analytics. |

## Relationship to Audit and Templog

38. Compliance controls govern compliance destinations/copies, not source product traces. Sandbox inspection guards the DeepAgents model boundary on every implemented route, including Vertex Gemini, native/custom OpenAI, and Azure, not trace retention. The sandbox-only Azure input-filter normalization in `tool-result-inspection.md` rule 44a produces a malicious/unknown outcome; existing inspection-span status and source-evidence policies still apply. Rejected native successful results remain untrusted forensic evidence; they MUST NOT reach a subsequent main-model request, normalized application result events, Result CRs, or termination messages. This collection contract does not establish additional subagent inspection coverage. The isolated classifier necessarily receives the inspected effective content, but its telemetry remains payload-free. Classic SSE/history/transcript restrictions remain unchanged.
38a. [PARTIALLY IMPLEMENTED: OLS-4434] Anthropic, Vertex/Google, native/custom OpenAI, and Azure API-key/Entra routes use shared DeepAgents inspection, tool-output boundaries, and generation capture. The legacy Gemini ADK and OpenAI Agents runtime adapters are removed; Vertex/OpenAI is unsupported and out of scope; its required sandbox/operator removal is defined in [Agentic runs](agentic-runs.md#vertexopenai-support-exclusion), not deferred implementation or a legacy fallback. Dependency cleanup and route-specific live acceptance remain separate. Source-evidence retention and compliance-copy policy remain unchanged. Replacing SDK hooks, native spans/events, tool names, or generation representation, including the change from Gemini ADK `generate_content` to shared `chat` capture, is subject to the mandatory compatibility review and version decision in rules 41–42; OLS-4434 grants no waiver and establishes no new schema/version discriminator. These producer descriptions do not assert downstream compatibility or live acceptance. The sandbox's local contract is `lightspeed-agentic-sandbox/.ai/spec/what/provider-contract.md` rules 50–67.
39. Templog remains the independent OTLP-log-to-PostgreSQL pipeline with run-scoped cleanup. Standalone OTLP log records do not enter product collection; events attached to matched trace spans remain native trace evidence. Disabling product collection does not disable compliance audit or configured backend tracing.

## Schema Versioning and Downstream Coordination

40. [PLANNED: OLS-4246] Sandbox instrumentation adopts GenAI message/span structures pinned to [core semantic conventions v1.41.0](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai), with instrumentation schema URL `https://opentelemetry.io/schemas/1.41.0`. Preserve that URL through collection/packaging. The [split GenAI conventions repository](https://github.com/open-telemetry/semantic-conventions-genai) is the evolving upstream reference, not an interchangeable version pin; changing to its development schema line requires an explicit versioned cutover.
41. Every change that can affect the structure or meaning of Agentic OTEL traces, spans, attached events, or embedded objects collected for Dataverse MUST receive compatibility review from the affected component owners and Dataverse extraction/transformation owners before merge. This applies across producers, Collector routing/processors/serialization, Dataverse export packaging, and operator configuration or dependency/image updates that can change emitted or collected data. Standards alignment is not permission for unreviewed OLS-specific changes.

    - The change MUST record the affected contract, backward-compatibility classification, schema/data-contract version decision, and supporting evidence. A decision not to bump the version MUST include a compatibility rationale approved by the Dataverse owners; additive optional fields are not automatically compatible.
    - Breaking changes include removed/renamed fields, spans, or events; changed types, nesting, encoding, units, or meaning; changed correlation/parent relationships, operation/message shapes, source-content policy, status/outcome semantics, or collection selection; and upstream SDK/semantic-convention changes with those effects.
    - A change classified as breaking MUST increment the Agentic Dataverse schema/data-contract version and update the corresponding Dataverse exporter configuration. Compatible downstream extraction/transformation changes MUST be ready before producer rollout. The review MUST establish how the consumer identifies the actual contract for supported producer versions and mixed-version deployments; a configuration-only bump does not change producer output.
    - Missing compatibility classification, version decision, or required owner approval blocks merge. Unavailable downstream evidence is an unresolved gate, not proof of compatibility. Compatibility review is required even when the author expects no breaking change.
42. The semantic-convention schema URL versions upstream conventions; the `archive_path_prefix` (for example, `v1/` or the operator-generated `agentic-v1/`) currently names archive organization. Neither alone establishes a complete OLS producer contract version. The current contract does not specify a complete product-contract discriminator/compatibility check; selecting and wiring that mechanism remains an explicit integration gap. An archive prefix MAY serve as the product-contract discriminator only after Dataverse owners explicitly adopt it and downstream routing/transformation enforces its meaning. Do not invent an implemented `schema_version` payload/configuration field or treat arbitrary JSON-object acceptance as semantic compatibility. A breaking rollout MUST NOT proceed while its consumer-visible discriminator is unresolved.

The adopted upstream content attributes are designated Opt-In, while this product plan deliberately specifies opt-out collection and source content whenever tracing records. Neither `transcriptsDisabled` nor `LIGHTSPEED_CAPTURE_CONTENT` configures producer-side source-content opt-in. That policy difference requires explicit governance resolution; structural alignment MUST NOT be described as full conformance to upstream content-consent guidance. This alignment does not introduce a new runtime gate.

## Implementation Status and Planned Changes

Status reviewed 2026-11-25. The file-based transport (FileExporter, `data-collection` volume, and Dataverse exporter sidecar in `otel` mode) shipped in a released bundle, and OLS-4491 verified the released Collector-to-Dataverse path. That transport left quiet active files unuploaded, deleted backups regardless of upload, and could reject shared OTLP requests. OLS-4493 replaces it.

| Stage | Scope / rollout boundary |
|---|---|
| Sandbox producer | Target scope is standard GenAI source spans and independent compliance projections; producer evidence does not establish export or upload. |
| Collector `dataverse` exporter [PLANNED: OLS-4493] | New component with batching, packaging, credentials, error classification, fan-out isolation, TLS profile, and proxy support; FileExporter removed from the image. |
| Operator wiring [PLANNED: OLS-4493] | Generate the exporter configuration, mount the token and trusted CA bundle into the Collector, and remove the sidecar, its ConfigMap, and both data volumes. Ships with the new Collector image (rule 37). |
| Dataverse compatibility [PLANNED: OLS-4493] | One trace-batch object per TAR member replaces one array of many objects per backup; rule 41 review with the Dataverse owners before the packaging change merges. |
| Dataverse exporter cleanup [PLANNED: OLS-4493] | Remove `otel` mode after the operator release that stops using it; released bundles pin their own image. |

Remaining checks: Dataverse parsing of the new packaging (OLS-4492), a low-volume upload within about 6 minutes on a cluster, a cluster-wide TLS-inspecting proxy with the Modern profile, Collector memory under representative load, producer coverage, and downstream SQL extraction.
