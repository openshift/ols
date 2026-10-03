# Agentic Data Collection

Canonical cross-repository contract for Agentic product-analysis data. Agentic product traces use the existing OpenTelemetry Collector FileExporter, which writes native OTLP trace-batch JSONL on a bounded pod-local volume. The first operator rollout is local-file-only; later operator wiring adds a Dataverse exporter sidecar in `otel` mode for rotated backups. PRs #105, #229, #2088, and #147 remain open proposals; see Implementation Status.

[Agentic data collection map](agentic-data-collection-map.svg) shows the first local-file rollout and later Dataverse consumer path.

## Principles

1. [PLANNED: OLS-3569] Agentic product data MUST use the existing OTLP **trace** path. Agentic applications MUST NOT write product-data files.
2. [PLANNED: OLS-3569] OTLP log records remain exclusively on the templog/PostgreSQL path. The Agentic exporter consumes traces only, not separate log or metric signals. Any event attached to an eligible trace span remains native trace evidence and MUST NOT be stripped or classified as a separate log by the Collector.
3. [PLANNED: OLS-3569] Collection is opt-out. Native product traces are retained without product-path PII, secret, CR-field, prompt, context, tool-payload, skill-content, output, or reasoning redaction. On a recording sandbox source span, available raw callback output from successful native tool execution is retained independently of inspection, including a result rejected later. “Complete” means data exposed by the SDK callback after existing upstream limits, not unlimited process output. `LIGHTSPEED_CAPTURE_CONTENT` filters compliance copies only, not source or product traces. Reasoning is represented as ordered message parts, not separate reasoning events.
4. [PLANNED: OLS-3569] The Collector routes eligible resources and writes native OTLP trace batches; it performs no product-semantic transformations.
5. [PLANNED: OLS-3569] Downstream consumers own flattening, deduplication, joins, ordered transcript assembly, run/phase reconstruction, outcome derivation, aggregation, logical SQL/dbt, and final model names.
6. [PLANNED: OLS-3569] Preserve existing compliance audit, templog/PostgreSQL, configured trace-backend, and Classic product-collection behavior. The shared transcript opt-out still disables Classic transcripts; it MUST NOT disable independent compliance, templog, backend tracing, or Classic feedback under its existing control. This is not a promise of runtime failure isolation; native FileExporter failure semantics are defined below.

## End-to-End Flow

```text
agentic-operator + batch sandbox
              |
              | existing OTLP traces
              v
      lightspeed-otel-collector
              |                         |
              | service-name route      | independent backend route
              | no batch processor      | batch processor
              v                         v
      native FileExporter          configured trace backend
              |
              | native OTLP trace-batch JSONL
              v
      otel/traces.jsonl + size-rotated backups
              |
              | first rollout ends here; FileExporter manages retention
              |
              | [PLANNED: later operator sidecar, data_mode: otel]
              v
      rotated backups only -> JSON array in gzip TAR -> upload
              |
              v
      Dataverse: logical Actions, transcripts, and analytics
```

## Enablement and Topology

7. [PLANNED: OLS-3569] The initial local-file branch is enabled when `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` is false or absent. It requires neither `cloud.openshift.com` credentials nor a configured trace backend. Operator PR #2088 adds no separate OCP-version/bundle gate to this Collector branch. This does not expand Agentic product support: Agentic operands and their handoff remain OCP ≥ 5.0/v2-only under decision 0037; OCP 4.x remains Classic-only.
8. [PLANNED: OLS-3569] `transcriptsDisabled` is the sole product collection control for both Classic transcripts and the Agentic local-file branch. `feedbackDisabled` continues to control only Classic feedback. `AgenticOLSConfig.spec.audit.enabled` controls compliance audit only. No new product-collection CR field is introduced.
9. [PLANNED: OLS-3569] Existing Classic behavior is unchanged: its feedback-or-transcripts and telemetry-credential gates, app-server transcript production, app-server Dataverse exporter sidecar, storage, service identity, and upload behavior remain as they are. That sidecar does not consume Collector files.
10. [PLANNED: OLS-3569] The classic operator owns the local-file opt-out gate. Opt-out omits the product route, FileExporter pipeline, collection volume, and mount while preserving existing Collector consumers. The first rollout MUST NOT deploy an Agentic Dataverse sidecar. A later operator PR adds that sidecar with its upload credentials and configuration; no upload-authentication gate is needed for local file creation.
11. [PLANNED: OLS-3569] Agentic producers neither receive nor evaluate collection state. The existing `lightspeed-agentic-configuration` ConfigMap key `otel-collector-endpoint` remains the Collector handoff; the agentic operator consumes it and uses the existing `OTEL_EXPORTER_OTLP_ENDPOINT` for itself and batch sandbox pods. OLS-3569 adds no endpoint environment variable or handoff ConfigMap key. Disabling templog does not disable product traces.

## Input Contract

12. [PLANNED: OLS-3569] Eligible product input is limited to OTLP trace resources whose `service.name` is exactly `lightspeed-agentic-operator` or `lightspeed-agentic-sandbox`. All their spans and attached events are routed, regardless of operation name, GenAI content, inspection outcome, or run-correlation attributes. Unmatched resources are not written to the product file branch; backend forwarding remains independent.
13. [PLANNED: OLS-3569] Run correlation is producer evidence, not a Collector eligibility predicate. Producers MUST stamp available literal `agenticrun.uid` and `agenticrun.phase` as span attributes; missing correlation does not cause FileExporter exclusion. The Collector MUST NOT infer missing correlation from resources, other spans, trace/span IDs, names, payloads, or topology.
14. [PLANNED: OLS-3569] `agenticrun.uid` is the hyphenated `AgenticRun.metadata.uid` and is the stable cross-phase key. `agenticrun.phase` is one of `analysis`, `approval`, `execution`, `verification`, `escalation`, or `terminal`. Each phase may use a separate standard OTEL trace ID.
15. [PLANNED: OLS-3569] For batch sandboxes, the operator propagates active trace context and correlation through the Kubernetes input ConfigMap and Pod environment (`TRACEPARENT`, `LIGHTSPEED_AGENTICRUN_UID`, and `LIGHTSPEED_AGENTICRUN_STEP`); the sandbox publishes its Result CR through the Kubernetes API. This collection contract does not use `/v1/agent/run`.
16. [PLANNED: OLS-3569] The sandbox MUST translate the run UID and step supplied through its existing invocation configuration into literal span attributes on agent/model/tool and `tool_result.inspection` spans when supplied. Missing inspection correlation remains absent; no Resource, re-read process environment, parent-context, or other-span fallback is introduced. Attached events retain their native attributes without duplicating correlation solely for collection.

## Producer Evidence and Downstream Interpretation

The producer facts and analytical goals below do not define Collector record classes or filters beyond exact resource service names. Native OTLP nesting, spans, and attached events remain evidence for downstream interpretation.

### GenAI Producer Evidence

17. [PLANNED: OLS-3569] Eligible `lightspeed-agentic-sandbox` spans may carry the standard [OpenTelemetry GenAI Semantic Conventions v1.41](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai). The operation names and attributes below are producer evidence and possible downstream meaning; Collector routing depends only on the exact `service.name` values in rule 12.

| Span operation | Producer evidence / downstream meaning |
|---|---|
| `invoke_agent` | Agent-level effective user prompt (including formatted context), separate `gen_ai.system_instructions` when supplied, and the exact post-shaped `AgentResult.output` as an assistant output message whenever a terminal result is normally produced, including domain `success=false`; pre-terminal failures have no fabricated output; `gen_ai.agent.name=lightspeed` |
| `chat` or `generate_content` | Each actual model request and response as JSON-string arrays of v1.41 messages, with separate `gen_ai.system_instructions` and `gen_ai.tool.definitions` when known; `chat` for DeepAgents/OpenAI, `generate_content` for Gemini |
| `execute_tool` | Actual tool execution with `gen_ai.tool.name`, a provider/SDK call ID only when exposed, JSON arguments and the complete raw callback result for successful native execution even if later rejected by inspection; native failures retain the error type and `ERROR` span status, without a success result |

18. [PLANNED: OLS-3569] `invoke_agent lightspeed` is the INTERNAL parent of sibling `{gen_ai.operation.name} {model}` CLIENT inference and `execute_tool {name}` INTERNAL spans. Each actual model request receives its own model span (`chat` for DeepAgents/OpenAI, `generate_content` for Gemini); timestamps and ordered message arrays preserve flow order. Text, available reasoning, tool-call, and tool-response parts use the pinned standard message representation. Provider-supplied finish reasons are retained when available; `unknown` is a sandbox-defined fallback accepted by the message schema, not an OTel-standardized finish reason. Observed models and token counts are recorded when available.

19. [PLANNED: OLS-3569] A common provider/SDK-assigned call ID connects a model tool-call part, actual tool span, and later model tool-response part only when that ID is exposed at the relevant boundaries; the Collector MUST NOT synthesize missing IDs or pair by tool name, content, or arrival order. Gemini's finalized ADK Event supplies late SDK-assigned IDs for model output and actual tool spans; IDs that ADK strips from the subsequent effective request remain absent, and supplied provider IDs remain unchanged. A registered skill instruction load is recorded only when it actually executes as an ordinary provider tool (`load_skill` only when that is its real SDK tool name), with its actual arguments and raw successful result on the tool span and any SDK-trimmed model-visible result in the next request. No synthetic skill-load span or `gen_ai.skill.used` event is added; an arbitrary `SKILL.md` read does not establish a skill load. Producers do not synthesize GenAI choice, tool-content, reasoning, input, output, or error span events.

### Logical Action and Transcript Goals

20. [PLANNED: OLS-3569] Agentic operator and sandbox producers record lifecycle, approval, Result CR, and terminal evidence as native trace spans/events. Literal CR payloads, including text-bearing fields, remain raw operational evidence.
21. [PLANNED: OLS-3569] Downstream data products may derive the following logical Actions and ordered transcript analytics from raw native OTLP evidence:

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
| LLM operation | `chat {model}` or `generate_content {model}` source span start/end/native status, provider, observed requested/response model and input/output/reasoning token counts when available, error attributes, run UID, and phase |
| Tool operation | `execute_tool {name}` source span start/end/native status, tool name/type, call ID, error attributes, run UID, and phase |

22. [PLANNED: OLS-3569] Expected terminal evidence also covers `Completed / NoActionRequired`, ordinary failure, denial, escalation, and `EmergencyStopped`. Product analytics MUST NOT invent a `Cancelled` product phase or rewrite `Failed / CancelledByUser`.
23. Native OTLP carries each selected source span with its attached events. Transport retries can duplicate delivery, so downstream consumers own logical interpretation and deduplication.

## Native OTLP File Contract

24. [PLANNED: OLS-3569] Use contrib `fileexporter` v0.159.0 with JSON format and no compression. Each JSONL line is one complete native OTLP **trace-batch object**, potentially containing multiple `resourceSpans`, scopes, spans, and attached events. Preserve native identifiers, timestamps/status, resource/scope context, schema URLs, typed attributes, links, events, and dropped counts when present. The payload has no OLS-level `schema_version` field.
25. [PLANNED: OLS-3569] The Collector product branch MUST NOT use a batch processor. Collector batching belongs only on the independently configured trace-backend branch; otherwise count batching can combine acceptable inputs into a FileExporter write above its size limit. This does not remove producer SDK OTLP transport batching.
26. [PLANNED: OLS-3569] The operator supplies active path `/var/lib/lightspeed-data/otel/traces.jsonl`, `create_directory: true`, and rotation settings `max_megabytes: 16`, `max_backups: 16`, `max_days: 1`. The pinned rotator interprets the size as 16MiB. Collector reference configurations may use smaller trial settings; they are not the operator contract.
27. [PLANNED: OLS-3569] Active-file rotation is size-triggered in the pinned implementation. It renames the active file to a timestamped backup (normally `traces-<timestamp>-size.jsonl`) and recreates the active name. `max_days` removes aged **backups**; it does not periodically seal an active file. Shutdown closes but does not force rotation. Rotation mode ignores `flush_interval`. Low-volume data may remain active indefinitely.
28. Native span relationships/timestamps and ordered message/event data, not file, line, or arrival order, support downstream reconstruction.

## Shared Volume, Retention, and Consumer Protocol

29. [PLANNED: OLS-3569] The first operator rollout mounts a `data-collection` pod-local `emptyDir` with `sizeLimit: 500Mi` read-write at `/var/lib/lightspeed-data` in the Collector container only.
30. [PLANNED: OLS-3569] FileExporter owns active files, size rotation, and backup deletion. One active file plus 16 backups at 16MiB is approximately 272MiB of normal retained data, below the 500Mi volume ceiling. Cleanup is asynchronous; this is bounded normal retention, not a hard instantaneous disk quota or a guarantee against node pressure, permissions, I/O errors, or other volume users. With no consumer, rotation evicts old data rather than accumulating files indefinitely.
31. [PLANNED: OLS-3569] The final operator PR adds a separate Dataverse exporter sidecar with `data_mode: otel` (distinct from its authentication `mode`). Its source mount MUST be read-only and `data_dir` MUST address the directory containing `traces.jsonl` and its direct-child backups: mount the volume's `otel` subdirectory at the pickup root, or point to that subdirectory beneath a root mount. A separate writable `ledger_file` MUST be outside the source tree. Source mount/authentication/ledger wiring is not supplied by PR #2088.
32. [PLANNED: OLS-3569] The `otel` consumer excludes the active filename and discovers matching rotated backups only, without recursion. For each backup it skips blank lines, accepts a complete final JSON object without LF, and packages the batch objects into one top-level JSON array inside one gzip TAR member. It preserves record JSON apart from surrounding whitespace and array punctuation; it does not flatten OTLP, validate GenAI semantics, or filter correlation/content. Each backup is uploaded separately; successful acknowledgment records filename/request ID in the ledger. The consumer never deletes or modifies source files. FileExporter retention is independent of upload acknowledgment.

## Failure and Loss Semantics

33. [PLANNED: OLS-3569] Accept native FileExporter failure semantics: invalid configuration or an unwritable path can fail Collector startup, and write failures can reject a shared OTLP trace request even if a backend branch already accepted it. Separate pipelines do not provide unconditional failure isolation. No product-specific Collector queue, retry wrapper, or filesystem recovery layer is introduced.
34. [PLANNED: OLS-3569] A serialized JSON write larger than 16MiB is rejected rather than split. The operator's 20MiB OTLP receiver limit does not guarantee a batch fits after JSON encoding. JSON bytes and LF are separate writes; a boundary rotation can leave a complete final record without LF, which the consumer accepts.
35. [PLANNED: OLS-3569] Same-pod Collector restart may append to the retained active file; it does not replay uploaded data or force active-file pickup. Unconsumed backups may be deleted by count/age retention. The future consumer's polling interval must account for backup turnover; there is no acknowledgment channel that postpones Collector cleanup.
36. This path adds no fsync, persistent-volume requirement, exactly-once promise, or guaranteed delivery. Pod replacement/volume removal loses local files. Upload success followed by failed ledger persistence can cause duplicate delivery; downstream deduplication remains required. A small active file is not uploadable merely because the sidecar exists.
37. Collector image and generated configuration MUST be rolled out together: an image without `fileexporter` cannot run the generated configuration.

## Repository Ownership

| Repository | Responsibility |
|---|---|
| `lightspeed-operator` | Generate opt-out-gated native FileExporter configuration and Collector-only local volume in the first rollout; later deploy/configure the Agentic Dataverse sidecar. Preserve the Classic path and supported Agentic operand version boundary. |
| `lightspeed-agentic-operator` | Emit lifecycle, approval, Result CR, and terminal evidence; propagate existing endpoint and batch correlation without evaluating collection state. Producer coverage remains separate from file transport. |
| `lightspeed-agentic-sandbox` | Emit pinned GenAI agent/model/tool spans with ordered content and available literal correlation; retain successful raw native tool results regardless of later inspection; never write product files. |
| `lightspeed-otel-collector` | Route exact eligible service resources into an unbatched native FileExporter branch; own local rotation and retention, not logical transforms or uploads. |
| `lightspeed-core/lightspeed-to-dataverse-exporter` | Add `otel` mode for rotated JSONL discovery, array/TAR packaging, upload, and acknowledgment ledger; do not own source retention or semantic reconstruction. |
| Dataverse data product | Own native OTLP extraction, version-aware SQL/dbt, deduplication, joins, ordered transcripts, run/phase reconstruction, outcome derivation, and analytics. |

## Relationship to Audit and Templog

38. Compliance controls govern compliance destinations/copies, not source product traces. Sandbox inspection guards the DeepAgents main-model boundary, not trace retention; Gemini and OpenAI inspection remain out of scope. Rejected native successful results remain untrusted forensic evidence; they MUST NOT reach a subsequent main-model request, normalized application result events, Result CRs, or termination messages. This collection contract does not establish additional subagent inspection coverage. The isolated classifier necessarily receives the inspected effective content, but its telemetry remains payload-free. Classic SSE/history/transcript restrictions remain unchanged.
39. Templog remains the independent OTLP-log-to-PostgreSQL pipeline with run-scoped cleanup. Standalone OTLP log records do not enter product collection; events attached to matched trace spans remain native trace evidence. Disabling product collection does not disable compliance audit or configured backend tracing.

## Schema Versioning and Downstream Coordination

40. [PLANNED: OLS-3569] Sandbox instrumentation adopts GenAI message/span structures pinned to [core semantic conventions v1.41.0](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai), with instrumentation schema URL `https://opentelemetry.io/schemas/1.41.0`. Preserve that URL through collection/packaging. The [split GenAI conventions repository](https://github.com/open-telemetry/semantic-conventions-genai) is the evolving upstream reference, not an interchangeable version pin; changing to its development schema line requires an explicit versioned cutover.
41. Every change to collected trace structure or meaning MUST be versioned and coordinated with Dataverse extraction/transformation owners before rollout, including custom Agentic fields, operation/message shapes, source-content policy, correlation, and status semantics. Standards alignment is the baseline, not permission for unversioned OLS-specific changes.
42. The semantic-convention schema URL versions upstream conventions; the consumer's `archive_path_prefix: v1/` versions archive organization, and ledger `version: 1` versions internal checkpoint state. None alone versions every OLS producer contract change. The reviewed PRs supply no complete product-contract discriminator/compatibility check; selecting and wiring that mechanism remains an explicit integration gap. Do not invent an implemented payload field or treat arbitrary JSON-object acceptance as semantic compatibility.

The adopted upstream content attributes are designated Opt-In, while this product plan deliberately specifies opt-out collection and source content whenever tracing records. Neither `transcriptsDisabled` nor `LIGHTSPEED_CAPTURE_CONTENT` configures producer-side source-content opt-in. That policy difference requires explicit governance resolution; structural alignment MUST NOT be described as full conformance to upstream content-consent guidance. This alignment does not introduce a new runtime gate.

## Implementation Status and Planned Changes

Status observed 2026-10-03: the following PRs are open. Their source establishes the proposed contracts, not merged or production end-to-end delivery. Existing local sandbox evidence changes are preserved; they may be ahead of the published PR head.

| Change | Scope / rollout boundary |
|---|---|
| [Collector #105](https://github.com/openshift/lightspeed-otel-collector/pull/105) | Native FileExporter component and unbatched file branch; no operator deployment or Dataverse upload. |
| [Sandbox #229](https://github.com/openshift/lightspeed-agentic-sandbox/pull/229) | Standard GenAI source spans and independent compliance projections; producer evidence, not file/sidecar deployment. |
| [Operator #2088](https://github.com/openshift/lightspeed-operator/pull/2088) | Local collection/configuration and bounded volume only; [latest author comment](https://github.com/openshift/lightspeed-operator/pull/2088#issuecomment-5969588237) identifies the dependency on #105. No Dataverse consumer in this rollout. |
| [Dataverse exporter #147](https://github.com/lightspeed-core/lightspeed-to-dataverse-exporter/pull/147) | Adds `otel` consumer mode; does not deploy the Collector sidecar or establish downstream SQL compatibility. |
| Final operator sidecar PR [PLANNED: OLS-3569] | After the prerequisite PRs merge, wire compatible images, read-only source path, writable ledger, upload identity/credentials/configuration, and verify actual collection-to-upload delivery. |

Operator #2088 reports an isolated OpenShift smoke using generated resources, including Collector file writes under an assigned UID and the opt-out variant; it does not claim a full operator/OLSConfig rollout. Remaining integration checks: versioning of all collected-contract changes; low-volume active-file delivery under size-only rotation; consumption before retention eviction; the future sidecar's Kubernetes read-only source mount and writable ledger; full operator rollout; producer coverage and downstream SQL extraction. This spec alignment does not itself verify cluster, sidecar, external Dataverse, or Snowflake runtime behavior.
