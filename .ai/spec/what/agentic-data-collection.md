# Agentic Data Collection

Canonical cross-repository contract for Agentic OLS product-analysis collection. Agentic producers emit full-fidelity correlated OTLP traces; the Collector mechanically separates raw trace atoms into Actions and Transcript candidates; a dedicated exporter uploads ready files; Dataverse owns all logical models and transformations. [PLANNED: OLS-3569]

Visual companion: [Agentic data collection map](agentic-data-collection-map.svg).

## Principles

1. [PLANNED: OLS-3569] Agentic product data MUST use the existing OTLP **trace** path. Agentic applications MUST NOT write product-data files.
2. [PLANNED: OLS-3569] OTLP logs remain exclusively on the templog/PostgreSQL path. No log, including a log bridged from a span event, may be staged or uploaded by `lightspeed-to-dataverse-exporter`. The product pipeline consumes no metrics.
3. [PLANNED: OLS-3569] Collection is opt-out and full fidelity. It performs no PII, secret, CR-field, prompt, context, tool-payload, skill-content, output, or reasoning redaction or truncation. Reasoning events are included.
4. [PLANNED: OLS-3569] The Collector MAY filter, classify, project, and stage individual trace atoms. It MUST NOT join spans, pair tool calls with results, reconstruct runs or phases, assemble transcripts, deduplicate logical events, calculate counts, derive outcomes, or define Dataverse tables.
5. [PLANNED: OLS-3569] Dataverse owns flattening, deduplication, joins, ordered transcript assembly, run/phase reconstruction, outcome derivation, aggregation, logical SQL/dbt, and final model names.
6. [PLANNED: OLS-3569] Product collection MUST NOT change or suppress existing compliance audit, templog/PostgreSQL, configured trace-backend, or Classic product-collection behavior.

## End-to-End Flow

```text
agentic-operator + batch sandbox
              |
              | existing OTLP traces
              v
      lightspeed-otel-collector
              |
              | eligible raw atoms; mechanical classification
              +-----------------------+
              |                       |
              v                       v
        Actions candidates      Transcript candidates
              |                       |
              +-----------+-----------+
                          | dedicated pod-local emptyDir
                          v
             lightspeed-to-dataverse-exporter
                          |
                          v
                      Dataverse
                          |
                 logical SQL/dbt models
```

## Enablement and Topology

7. [PLANNED: OLS-3569] Agentic collection is enabled only on the OCP ≥ 5.0 v2 bundle and only when both of these conditions hold:
   - `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` is false or absent; and
   - usable existing `cloud.openshift.com` telemetry credentials are available.
   OCP 4.x remains Classic-only under decision 0037 and MUST NOT deploy an Agentic collection branch or Agentic exporter instance.
8. [PLANNED: OLS-3569] `transcriptsDisabled` is the sole product collection control for both Classic transcripts and Agentic Actions/Transcripts. `feedbackDisabled` continues to control only Classic feedback. `AgenticOLSConfig.spec.audit.enabled` controls compliance audit only. No new product-collection CR field is introduced.
9. [PLANNED: OLS-3569] Existing Classic behavior is unchanged: its feedback-or-transcripts gate, app-server transcript production, app-server `lightspeed-to-dataverse-exporter` sidecar, storage, service identity, and upload behavior remain as they are. The Agentic exporter is a separate instance in the Collector pod with a separate `emptyDir`.
10. [PLANNED: OLS-3569] The classic operator owns evaluation of the opt-out and credential gates. A failed gate omits only the Agentic trace-to-candidate branch, its volume, and its exporter; it MUST NOT remove or disrupt the Collector's existing receivers, templog/PostgreSQL, admin, metrics, or configured trace-forwarding pipelines.
11. [PLANNED: OLS-3569] Agentic producers neither receive nor evaluate collection state. The existing `lightspeed-agentic-configuration` ConfigMap key `otel-collector-endpoint` remains the Collector handoff; the agentic operator consumes it and uses the existing `OTEL_EXPORTER_OTLP_ENDPOINT` for itself and batch sandbox pods. OLS-3569 adds no endpoint environment variable and no handoff ConfigMap key.

## Input Contract

12. [PLANNED: OLS-3569] Eligible product input is limited to OTLP traces whose resource `service.name` is exactly `lightspeed-agentic-operator` or `lightspeed-agentic-sandbox`.
13. [PLANNED: OLS-3569] Every eligible span MUST carry non-empty literal `agenticrun.uid` and valid `agenticrun.phase` as **span attributes**. There is no resource-attribute fallback, and the Collector MUST NOT infer either value from another span, trace/span IDs, names, payloads, or topology.
14. [PLANNED: OLS-3569] `agenticrun.uid` is the hyphenated `AgenticRun.metadata.uid` and is the stable cross-phase key. `agenticrun.phase` is one of `analysis`, `approval`, `execution`, `verification`, `escalation`, or `terminal`. Each phase may use a separate standard OTEL trace ID.
15. [PLANNED: OLS-3569] For batch sandboxes, the operator propagates active trace context and correlation through the Kubernetes input ConfigMap and Pod environment (`TRACEPARENT`, `LIGHTSPEED_AGENTICRUN_UID`, and `LIGHTSPEED_AGENTICRUN_STEP`); the sandbox publishes its Result CR through the Kubernetes API. This collection contract does not use `/v1/agent/run`.
16. [PLANNED: OLS-3569] The sandbox MUST translate the propagated run UID and step into `agenticrun.uid` and `agenticrun.phase` span attributes on every product span. A span event inherits eligibility from its containing span; event attributes need not duplicate those two values.

## Candidate Streams

### Transcript Candidates

17. [PLANNED: OLS-3569] The following provider-neutral sandbox span events are the complete Transcript candidate interface. Required values are literal and unredacted.

| Trace event | Required attributes | Meaning |
|---|---|---|
| `gen_ai.input` | `gen_ai.input.system_prompt`, `gen_ai.input.prompt`, `gen_ai.input.context`, `gen_ai.input.output_schema` | Exact effective system prompt, provider prompt, canonical context, and canonical output schema; absent optional inputs use an empty string |
| `gen_ai.choice` | At least one of `gen_ai.completion`, `gen_ai.reasoning_content` | Exact assistant completion and/or reasoning in provider observation order |
| `gen_ai.tool.call` | `gen_ai.tool.name`, `gen_ai.tool.call.id`, `tool.input` | Tool identity, stable call ID, and complete input |
| `gen_ai.tool.result` | `gen_ai.tool.name`, `gen_ai.tool.call.id`, `tool.status`, `tool.output` | Matching call ID, normalized `ok`/`error` status, and complete output |
| `gen_ai.skill.loaded` | `gen_ai.skill.name`; optional `gen_ai.skill.content`, `gen_ai.skill.metadata` | Explicit skill load signal |
| `gen_ai.skill.used` | `gen_ai.skill.name`; optional `gen_ai.skill.content`, `gen_ai.skill.metadata` | Explicit skill-use signal; never inferred from text |
| `gen_ai.output` | `gen_ai.output.value`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.reasoning_tokens` | Exact terminal value after provider post-processing and complete invocation usage |

18. [PLANNED: OLS-3569] `gen_ai.input` occurs once per sandbox invocation. `gen_ai.output` occurs once per successfully completed sandbox inference; an invocation that fails before producing a terminal value emits no output event and retains the failure on its operational span and Actions evidence. Choices, reasoning, tool, and skill events retain normalized provider observation order. All supported providers MUST expose the same interface.
19. [PLANNED: OLS-3569] Tool content events supplement the operational `execute_tool {name}` span and use the same tool name and stable call ID. The Collector MUST NOT pair them. `gen_ai.output` supplements rather than replaces preceding `gen_ai.choice` events.

### Actions Candidates

20. [PLANNED: OLS-3569] Actions candidates are every remaining eligible span or span event. Literal CR payloads remain raw operational facts even when they contain text; the Collector does not inspect payload content to reclassify them.
21. [PLANNED: OLS-3569] Dataverse derives the following expected logical Actions from these exact raw datapoints; the rows below are not Collector output records.

| Logical Action | Required raw evidence and datapoints |
|---|---|
| Run created | `agenticrun.received` timestamp and literal AgenticRun CR: UID, name, namespace, creation timestamp, spec, and initial status |
| Phase completed | Phase span start/end/native status, corresponding `agenticrun.<phase>.completed` event, literal Result CR, conditions/failures, and source timestamps; attempts remain separate atoms |
| Approval decision | `agenticrun.approval.completed` timestamp, authenticated approver UID/username, decision, selected option index/title, and literal AgenticRunApproval CR |
| Analysis result | `agenticrun.analysis.completed`: Result UID/name, option count, full AnalysisResult spec/status, options, conditions, failures, and source timestamps |
| Execution result | `agenticrun.execution.completed`: Result UID/name, actions-taken count, full ExecutionResult spec/status, action statuses, conditions, and failures |
| Verification result | `agenticrun.verification.completed`: Result UID/name, check count, full VerificationResult spec/status, check statuses, summary, conditions, and failures |
| Escalation result | `agenticrun.escalation.completed`: Result UID/name, full EscalationResult spec/status, summary, conditions, and failures |
| Terminal outcome | `agenticrun.terminal` timestamp, final phase, condition reason, and literal terminal AgenticRun spec/status; cancellation remains `Failed` with reason `CancelledByUser`, while analytics MAY derive a downstream cancellation label |
| LLM operation | `chat {model}` start/end/native status, provider, requested/response model, input/output/reasoning token counts, error attributes, run UID, and phase |
| Tool operation | `execute_tool {name}` start/end/native status, tool name/type, call ID, error attributes, run UID, and phase |

22. [PLANNED: OLS-3569] Expected terminal evidence also covers `Completed / NoActionRequired`, ordinary failure, denial, escalation, and `EmergencyStopped`. Product analytics MUST NOT invent a `Cancelled` product phase or rewrite `Failed / CancelledByUser`.
23. [PLANNED: OLS-3569] Shared correlation metadata MAY occur in both streams. A Transcript event itself MUST occur only in Transcripts and MUST NOT also be emitted as an Actions candidate.

## Candidate Record Envelope

24. [PLANNED: OLS-3569] Each candidate is one versioned, raw JSON object. Its stable envelope contains:

| Field group | Contract |
|---|---|
| Type | `schema_version` is literal `"1.0"`; `candidate_type` is disjoint `"action"` or `"transcript"`; `record_kind` is `"span"` or `"span_event"` |
| Source identity | `service_name`, original span/event `name`, `trace_id`, containing `span_id`, nullable `parent_span_id`, and zero-based original `event_index` for events |
| Correlation | literal `agenticrun_uid` and valid `phase` copied from the required span attributes |
| Time | source `timestamp`: native span start for a span, native event timestamp for an event |
| Raw OTEL | `otel` preserves native timing, kind, status, trace state/flags, links, schema metadata, and dropped counts; `attributes` preserves namespaced original resource, scope, span, and event attributes |

25. [PLANNED: OLS-3569] OTEL identifiers and values use standard OTLP JSON representation. Original attribute keys, types, and values remain namespaced and unchanged; same-named attributes from different OTEL levels MUST NOT collide.
26. [PLANNED: OLS-3569] Candidate identity for deduplication is `(service_name, trace_id, span_id, record_kind, event_index)`, with `event_index` null for a span. Retries or an ambiguous upload result MAY deliver a candidate more than once; Dataverse MUST deduplicate by this identity before logical transformations.
27. [PLANNED: OLS-3569] Transcript ordering uses source timestamp; within one containing span, the original zero-based `event_index` is authoritative for equal timestamps. Stable trace ID, span ID, and event index break remaining ties without implying Collector-side assembly. The Collector MUST NOT renumber events after filtering.
28. [PLANNED: OLS-3569] An atom that cannot produce a valid envelope MUST NOT enter a ready file. Rejection reporting MUST be bounded and content-free.

## Shared Volume and File Protocol

29. [PLANNED: OLS-3569] The Collector pod has one dedicated pod-local `emptyDir` shared only by the Collector container and its separate Agentic `lightspeed-to-dataverse-exporter` sidecar. It exposes two logical roots, Actions and Transcripts; physical mounts and staging mechanics belong to the operator and Collector child specs.
30. [PLANNED: OLS-3569] The Collector is the sole writer. Its external file contract ends when it atomically publishes a complete, immutable JSONL ready file to exactly one candidate root. Each line is one complete candidate; a file MAY contain multiple runs.
31. [PLANNED: OLS-3569] The Agentic exporter reads only ready files, uploads their records without transformation, and deletes a file only after confirmed whole-file success. Failed or unconfirmed uploads leave the file unchanged for retry.
32. [PLANNED: OLS-3569] The product path has no PostgreSQL input, output, schema, or durability dependency. PostgreSQL remains owned by templog and other existing product services, not Agentic Dataverse collection.

## Failure and Loss Semantics

33. [PLANNED: OLS-3569] Envelope rejection, queue exhaustion, spool-full, or file-operation failure drops or rejects only affected product candidates and records bounded content-free loss telemetry. It MUST NOT back-pressure or fail compliance, templog/PostgreSQL, or configured trace-backend pipelines.
34. [PLANNED: OLS-3569] Spool pressure MUST NOT evict or overwrite immutable ready files. Recovery may resume staging when capacity returns; candidates rejected before a ready file exists are lost.
35. [PLANNED: OLS-3569] Ready files are retry buffers, not durable storage. Collector process restart may preserve them while the pod volume remains; Collector pod replacement, collection disablement, or volume removal loses all unsent ready and in-progress data.
36. [PLANNED: OLS-3569] Confirmed successful upload permits deletion. An upload whose success cannot be confirmed retains the file and may cause duplicate delivery on retry; rule 26 makes that safe downstream.
37. [PLANNED: OLS-3569] Missing upload credentials is a normal disabled state: no Agentic branch, volume, or Agentic exporter is deployed. Credential absence MUST NOT break existing Collector pipelines.

## Repository Ownership

| Repository | Responsibility |
|---|---|
| `lightspeed-operator` | Own the OCP eligibility, existing opt-out and credential gates, unchanged handoff endpoint, Collector configuration, separate Agentic exporter instance, and dedicated `emptyDir`; preserve the Classic exporter path |
| `lightspeed-agentic-operator` | Emit lifecycle, approval, Result CR, and terminal trace atoms; carry literal correlation on every product span; propagate the existing endpoint and batch correlation without evaluating collection state |
| `lightspeed-agentic-sandbox` | Emit provider-neutral ordered Transcript events and operational chat/tool spans with required span correlation; never write product files |
| `lightspeed-otel-collector` | Implement service/attribute filtering, disjoint atom classification, raw-envelope projection, bounded loss telemetry, and atomic ready-file production; never implement logical Dataverse transformations |
| Agentic `lightspeed-to-dataverse-exporter` instance | Upload immutable ready files unchanged, retry failures, and delete only confirmed successes |
| Dataverse data product | Govern candidate ingestion and dedupe; own all logical Actions and Transcripts SQL/dbt, joins, ordering, reconstruction, aggregations, and derived analytics |

## Relationship to Audit and Templog

38. [PLANNED: OLS-3569] Compliance audit retains its existing destinations, enablement, and full-fidelity single-emission behavior. Product classification does not alter traces delivered to a configured audit/trace backend.
39. [PLANNED: OLS-3569] Templog remains an independent OTLP-log-to-PostgreSQL pipeline with run-scoped cleanup. Its logs are valid OTLP but never enter the Agentic ready-file/export path.

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-3569 | Trace-only Agentic product collection through raw Actions and Transcript candidate streams and the existing Dataverse exporter |
