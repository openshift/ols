# Agentic Data Collection

Canonical cross-repository contract for Agentic product-analysis data. The target design routes Agentic product traces through the existing OpenTelemetry Collector FileExporter, which writes native OTLP trace-batch JSONL on a bounded pod-local volume. The first planned operator rollout is local-file-only; later operator wiring is planned to add a Dataverse exporter sidecar in `otel` mode for rotated backups. The implementation-status section records staged rollout limits and remaining integration work.

[Agentic data collection map](agentic-data-collection-map.svg) shows the first local-file rollout and later Dataverse consumer path.

## Principles

1. [PLANNED: OLS-4246] Agentic product data MUST use the existing OTLP **trace** path. Agentic applications MUST NOT write product-data files.
2. [PLANNED: OLS-4246] OTLP log records remain exclusively on the templog/PostgreSQL path. The Agentic exporter consumes traces only, not separate log or metric signals. Any event attached to an eligible trace span remains native trace evidence and MUST NOT be stripped or classified as a separate log by the Collector.
3. [PLANNED: OLS-4246] Collection is opt-out. Native product traces are retained without product-path PII, secret, CR-field, prompt, context, tool-payload, skill-content, output, or reasoning redaction. On a recording sandbox source span, available raw callback output from successful native tool execution is retained independently of inspection, including a result rejected later. “Complete” means data exposed by the SDK callback after existing upstream limits, not unlimited process output. `LIGHTSPEED_CAPTURE_CONTENT` filters compliance copies only, not source or product traces. Reasoning is represented as ordered message parts, not separate reasoning events.
4. [PLANNED: OLS-4246] The Collector routes eligible resources and writes native OTLP trace batches; it performs no product-semantic transformations.
5. [PLANNED: OLS-4246] Downstream consumers own flattening, deduplication, joins, ordered transcript assembly, run/phase reconstruction, outcome derivation, aggregation, logical SQL/dbt, and final model names.
6. [PLANNED: OLS-4246] Preserve existing compliance audit, templog/PostgreSQL, configured trace-backend, and Classic product-collection behavior. The shared transcript opt-out still disables Classic transcripts; it MUST NOT disable independent compliance, templog, backend tracing, or Classic feedback under its existing control. This is not a promise of runtime failure isolation; native FileExporter failure semantics are defined below.

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
              | sidecar: rotated backups (OLS-4370)
              | [PLANNED: OLS-4493] + active records before rotation
              v
      JSON array in gzip TAR -> upload
              |
              v
      Dataverse: logical Actions, transcripts, and analytics
```

## Enablement and Topology

7. [PLANNED: OLS-4246] The initial local-file branch is enabled when `OLSConfig.spec.ols.userDataCollection.transcriptsDisabled` is false or absent. It requires neither `cloud.openshift.com` credentials nor a configured trace backend. The local-file branch has no separate OCP-version/bundle gate. This does not expand Agentic product support: Agentic operands and their handoff require the runtime OCP ≥ 5.0 gate under decision 0042; OCP 4.x runs Classic workloads only even though Agentic APIs and controller infrastructure are installed.
8. [PLANNED: OLS-4246] `transcriptsDisabled` is the sole product collection control for both Classic transcripts and the Agentic local-file branch. `feedbackDisabled` continues to control only Classic feedback. `AgenticOLSConfig.spec.audit.enabled` controls compliance audit only. No new product-collection CR field is introduced.
9. [PLANNED: OLS-4246] Existing Classic behavior is unchanged: its feedback-or-transcripts and telemetry-credential gates, app-server transcript production, app-server Dataverse exporter sidecar, storage, service identity, and upload behavior remain as they are. That sidecar does not consume Collector files.
10. [PLANNED: OLS-4246] The classic operator owns the local-file opt-out gate. Opt-out omits the product route, FileExporter pipeline, collection volume, and mount while preserving existing Collector consumers. The first rollout MUST NOT deploy an Agentic Dataverse sidecar. A later operator rollout adds that sidecar with its upload credentials and configuration; no upload-authentication gate is needed for local file creation.
11. [PLANNED: OLS-4246] Agentic producers neither receive nor evaluate collection state. The existing `lightspeed-agentic-configuration` ConfigMap key `otel-collector-endpoint` remains the Collector handoff; the agentic operator consumes it and uses the existing `OTEL_EXPORTER_OTLP_ENDPOINT` for itself and batch sandbox pods. OLS-4246 adds no endpoint environment variable or handoff ConfigMap key. Disabling templog does not disable product traces.

## Input Contract

12. [PLANNED: OLS-4246] Eligible product input is limited to OTLP trace resources whose `service.name` is exactly `lightspeed-agentic-operator` or `lightspeed-agentic-sandbox`. All their spans and attached events are routed, regardless of operation name, GenAI content, inspection outcome, or run-correlation attributes. Unmatched resources are not written to the product file branch; backend forwarding remains independent.
13. [PLANNED: OLS-4246] Run correlation is producer evidence, not a Collector eligibility predicate. Producers MUST stamp available literal `agenticrun.uid` and `agenticrun.phase` as span attributes; missing correlation does not cause FileExporter exclusion. The Collector MUST NOT infer missing correlation from resources, other spans, trace/span IDs, names, payloads, or topology.
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
| Terminal outcome | `agenticrun.terminal` timestamp, final phase, condition reason, and literal terminal AgenticRun spec/status; cancellation remains `Failed` with reason `CancelledByUser`, while analytics MAY derive a downstream cancellation label |
| LLM operation | `chat {model}` source span start/end/native status for current DeepAgents routes, provider, observed requested/response model and input/output/reasoning token counts when available, error attributes, run UID, and phase; historical evidence retains its producer's emitted operation, with compatibility governed by rules 41–42 |
| Tool operation | `execute_tool {name}` source span start/end/native status, tool name/type, call ID, error attributes, run UID, and phase |

22. [PLANNED: OLS-4246] Expected terminal evidence also covers `Completed / NoActionRequired`, ordinary failure, denial, escalation, and `EmergencyStopped`. Product analytics MUST NOT invent a `Cancelled` product phase or rewrite `Failed / CancelledByUser`.
23. Native OTLP carries each selected source span with its attached events. Transport retries can duplicate delivery, so downstream consumers own logical interpretation and deduplication.

## Native OTLP File Contract

24. [PLANNED: OLS-4246] Use contrib `fileexporter` v0.159.0 with JSON format and no compression. Each JSONL line is one complete native OTLP **trace-batch object**, potentially containing multiple `resourceSpans`, scopes, spans, and attached events. Preserve native identifiers, timestamps/status, resource/scope context, schema URLs, typed attributes, links, events, and dropped counts when present. The payload has no OLS-level `schema_version` field.
25. [PLANNED: OLS-4246] The Collector product branch MUST NOT use a batch processor. Collector batching belongs only on the independently configured trace-backend branch; otherwise count batching can combine acceptable inputs into a FileExporter write above its size limit. This does not remove producer SDK OTLP transport batching.
26. [PLANNED: OLS-4246] The operator supplies active path `/var/lib/lightspeed-data/otel/traces.jsonl`, `create_directory: true`, and rotation settings `max_megabytes: 1`, `max_backups: 400`, `max_days: 1`. The pinned rotator interprets the size as 1MiB. Collector reference configurations may use different trial settings; they are not the operator contract. Operator values verified 2026-11-03; the operator contract is recorded in `lightspeed-operator/.ai/spec/what/data-collection.md`.
27. [PLANNED: OLS-4246] Active-file rotation is size-triggered in the pinned implementation. The rotator checks `size + writeLen > max` before writing: it normally rotates before the next record's JSON, and it rotates before the LF write when a record exactly fills the file. A backup then ends with a complete JSON object without LF, and the new active file begins with a lone LF. It renames the active file to a timestamped backup (normally `traces-<timestamp>-size.jsonl`) and recreates the active name. A restart reopens and appends to the retained active file; a crash between the JSON and LF writes can leave a complete object without LF and concatenate the next object after it. `max_days` removes aged **backups**; it does not periodically seal an active file. Shutdown closes but does not force rotation. Rotation mode ignores `flush_interval`. Low-volume data may remain active indefinitely.
28. Native span relationships/timestamps and ordered message/event data, not file, line, or arrival order, support downstream reconstruction.

## Shared Volume, Retention, and Consumer Protocol

29. [PLANNED: OLS-4246] The operator mounts a `data-collection` pod-local `emptyDir` with `sizeLimit: 500Mi` read-write at `/var/lib/lightspeed-data/otel` in the Collector container and read-only at `/input` in the Dataverse sidecar.
30. [PLANNED: OLS-4246] FileExporter owns active files, size rotation, and backup deletion. One active file plus 400 backups at 1MiB is approximately 401MiB of normal retained data, below the 500Mi volume ceiling. Cleanup is asynchronous; this is bounded normal retention, not a hard instantaneous disk quota or a guarantee against node pressure, permissions, I/O errors, or other volume users. With no consumer, rotation evicts old data rather than accumulating files indefinitely.
31. [PLANNED: OLS-4246] The operator adds a separate Dataverse exporter sidecar with `data_mode: otel` (distinct from its authentication `mode`). Its source mount MUST be read-only and `data_dir` MUST address the directory containing `traces.jsonl` and its direct-child backups: mount the volume's `otel` subdirectory at the pickup root, or point to that subdirectory beneath a root mount. A separate writable `ledger_file` MUST be outside the source tree. The released-bundle path was verified under OLS-4491. The sidecar wiring is unchanged by Phase 2.1; only its consumption protocol changes.
32. [PLANNED: OLS-4246] The current `otel` consumer (Phase 1) discovers matching rotated backups only, without recursion, and excludes the active filename. For each backup it skips blank lines, accepts a complete final JSON object without LF, and packages the batch objects into one top-level JSON array inside one gzip TAR member. It preserves record JSON apart from surrounding whitespace and array punctuation; it does not flatten OTLP, validate GenAI semantics, or filter correlation/content. Each backup is uploaded separately; successful acknowledgment records filename/request ID in the ledger. The consumer never deletes or modifies source files. FileExporter retention is independent of upload acknowledgment.

    [PLANNED: OLS-4493] Phase 2.1 additionally consumes complete records from the active file under the same read-only mount, using a source-identity plus acknowledged-byte-offset ledger. It holds a partial trailing record, accepts a no-LF final object, separates concatenated objects, and never modifies the active file. A source may produce several upload members over its life; a complete backup read from offset 0 to EOF in one chunk keeps its existing member name. Duplicate delivery remains possible; downstream deduplication remains required. Design and decision: [`docs/superpowers/specs/2026-11-03-OLS-4493-active-spool-export-design.md`](../../../docs/superpowers/specs/2026-11-03-OLS-4493-active-spool-export-design.md), [ADR 0047](../decisions/0047-active-spool-tailing-for-dataverse-export.md).

## Failure and Loss Semantics

33. [PLANNED: OLS-4246] Accept native FileExporter failure semantics: invalid configuration or an unwritable path can fail Collector startup, and write failures can reject a shared OTLP trace request even if a backend branch already accepted it. Separate pipelines do not provide unconditional failure isolation. No product-specific Collector queue, retry wrapper, or filesystem recovery layer is introduced.
34. [PLANNED: OLS-4246] A serialized JSON write larger than 1MiB is rejected rather than split. The operator's 20MiB OTLP receiver limit does not guarantee a batch fits after JSON encoding. JSON bytes and LF are separate writes; a boundary rotation can leave a complete final record without LF, which the consumer accepts.
35. [PLANNED: OLS-4246] Same-pod Collector restart may append to the retained active file; it does not replay uploaded data. Unconsumed backups may be deleted by count/age retention. The consumer's polling interval must account for backup turnover; there is no acknowledgment channel that postpones Collector cleanup. [PLANNED: OLS-4493] Phase 2.1 resumes the active file by source identity and acknowledged byte offset, so a restart neither resets a consumed prefix nor forces the active file to rotate first.
36. This path adds no fsync, persistent-volume requirement, exactly-once promise, or guaranteed delivery. Pod replacement/volume removal loses local files. Upload success followed by failed ledger persistence can cause duplicate delivery; downstream deduplication remains required. [PLANNED: OLS-4493] A small active file is delivered at the next consumer poll without waiting for rotation; a partial trailing record is held until it is complete.
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
42. The semantic-convention schema URL versions upstream conventions; the consumer's `archive_path_prefix` (for example, `v1/` or the operator-generated `agentic-v1/`) currently names archive organization, and ledger `version: 1` versions internal checkpoint state. None alone establishes a complete OLS producer contract version. The current contract does not specify a complete product-contract discriminator/compatibility check; selecting and wiring that mechanism remains an explicit integration gap. An archive prefix MAY serve as the product-contract discriminator only after Dataverse owners explicitly adopt it and downstream routing/transformation enforces its meaning. Do not invent an implemented `schema_version` payload/configuration field or treat arbitrary JSON-object acceptance as semantic compatibility. A breaking rollout MUST NOT proceed while its consumer-visible discriminator is unresolved.

The adopted upstream content attributes are designated Opt-In, while this product plan deliberately specifies opt-out collection and source content whenever tracing records. Neither `transcriptsDisabled` nor `LIGHTSPEED_CAPTURE_CONTENT` configures producer-side source-content opt-in. That policy difference requires explicit governance resolution; structural alignment MUST NOT be described as full conformance to upstream content-consent guidance. This alignment does not introduce a new runtime gate.

## Implementation Status and Planned Changes

Status reviewed 2026-11-03: the operator Collector configuration, the read-only Dataverse sidecar, and the rotated-backup `otel` consumer are merged; OLS-4491 is closed with the released Collector-to-Dataverse verification. OLS-4492 payload verification and Phase 2.1 remain separate. The 2026-10-03 review below is retained as the earlier staged view; operator values were corrected to 1MiB, 400 backups, and 1 day in rules 26, 30, and 34.

| Stage | Scope / rollout boundary |
|---|---|
| Collector local-file branch | Target scope is a native FileExporter component and unbatched file branch; this scope alone does not establish operator deployment or Dataverse upload. |
| Sandbox producer | Target scope is standard GenAI source spans and independent compliance projections; producer evidence does not establish file or sidecar deployment. |
| First operator rollout | Implemented (OLS-4370): local collection/configuration and bounded volume; the first stage did not include the Dataverse consumer. |
| Dataverse consumer | Implemented for rotated files (OLS-4370); it does not deploy the Collector sidecar or establish downstream SQL compatibility. |
| Operator sidecar | Implemented (OLS-4370, OLS-4491): image, read-only source, writable ledger, upload identity/configuration, and released-path verification. |
| Phase 2.1 active-spool export [PLANNED: OLS-4493] | Consumer reads complete records from the active file by source identity and acknowledged byte offset; see the linked design and ADR 0047. No Collector or CRD change. |

The 2026-10-03 status review recorded an isolated OpenShift smoke using generated resources, including Collector file writes under an assigned UID and the opt-out variant; that smoke does not establish a full operator/OLSConfig rollout. Remaining integration checks are versioning of all collected-contract changes; low-volume active-file delivery under size-only rotation (Phase 2.1, OLS-4493); consumption before retention eviction; full operator rollout; producer coverage; and downstream SQL extraction. The sidecar's read-only source mount and writable ledger are implemented and verified under OLS-4491. This spec alignment does not itself verify cluster, sidecar, external Dataverse, or Snowflake runtime behavior.
