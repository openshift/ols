# Compliance Audit Logging

Durable, reconstructable audit trail of AI actions across the OpenShift Lightspeed system. Required by EU AI Act and similar regulations. The agentic system (takes cluster actions) is highest priority; OLS (makes recommendations via troubleshoot mode) is also in scope.

Telemetry aligns with [OTel GenAI Semantic Conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/README.md) (v1.41) for spans, metrics, and structured logs. See the OTel GenAI Attribute Reference section for the full attribute catalog.

## Requirements & Principles

1. **Single-emission, dual-destination.** Each audit-significant datum is recorded exactly once as an OTel span or span event. Two exporters on the same TracerProvider produce two views: (a) OTLP exporter sends spans to a trace backend when an endpoint is configured; (b) stdout exporter serializes the same span data as OTLP JSON to stdout (always, when audit enabled). Application-level loggers (Go `logr`, Python `logging`) emit only developer-debugging messages and MUST NOT re-emit data that appears in spans or span events.

2. **Graceful degradation.** OTEL exporter endpoint is optional on both `OLSConfig` and `AgenticOLSConfig` CRs. When unconfigured, a no-op OTLP exporter is used. The stdout exporter always emits regardless — this is what any log aggregator (Loki, Splunk, Fluentd, etc.) reads from container logs.

3. **On/off, full fidelity.** Audit logging is enabled or disabled per CR (`OLSConfig`, `AgenticOLSConfig`). When enabled, everything emits at full fidelity — every LLM turn, every tool call input/output, every thinking block. No verbosity dial. This is an audit trail, not operational logging.

4. **No redaction of audit logs.** Redaction is an input-to-LLM concern, not a logging concern.

5. **CR serialization is the compliance record.** Ephemeral Kubernetes CRs are serialized into the span event stream at creation (immutable Result CRs) and at mutation (AgenticRunApproval on PATCH, AgenticRun status at phase transitions). Key fields from the CR are **span attributes** (queryable in trace backends); full CR serialization is a **span event attribute** (viewable at full fidelity). Serialization includes `.spec`, `.status` (for Result CRs), plus `metadata.name`, `metadata.namespace`, `metadata.creationTimestamp`, and `metadata.uid` — not the full Kubernetes metadata. The stdout exporter does NOT truncate — full fidelity is preserved. The OTLP exporter may truncate based on backend limits, but the stdout signal is the compliance record.

6. **Sandbox/service spans are the forensic record.** Real-time agent events capture the process (LLM text output, thinking, tool calls) as OTel span events attached to inference spans. CR serialization captures the decisions. Both are required; overlap is intentional; they serve different audiences.

7. **Human approval identity.** Mutating admission webhook on AgenticRunApproval PATCH injects authenticated user identity (`uid`, `username`) from the admission review. Authoritative for all paths (console, kubectl, API). Console populates approval decision fields; webhook adds/overwrites identity fields. See Mutating Admission Webhook section.

8. **No console-side audit events.** Both consoles are presentation layers. Every consequential action creates a CR or makes an API call captured by the receiving backend.

9. **Log size is the aggregator's problem.** Full CR content (`.spec` + `.status` + select metadata) is serialized without truncation in the stdout exporter.

## Correlation Model

### Agentic System — Per-Phase Traces

Each phase of an AgenticRun lifecycle gets its own trace. The AgenticRun UID links all phase traces as a correlation attribute.

- **`agentic_run.uid`** — the AgenticRun CR's `metadata.uid` with hyphens stripped to produce a 32-char hex string. Carried as a **span attribute** (not the trace ID) on every span in every phase trace. This is the cross-trace correlation key. Users query `agentic_run.uid = X` to see all phase traces for an AgenticRun.
- **`agentic_run.name`** and **`agentic_run.namespace`** — also carried as span attributes on every span for convenience.
- **Per-phase trace IDs** — each phase (analysis, execution, verification, escalation) gets a fresh, auto-generated OTEL trace ID. The operator creates the root span for each phase and propagates trace context to the sandbox via W3C `traceparent` header on `/v1/agent/run` calls.
- **Span Links** — each phase trace's root span includes an OTel Span Link back to the prior phase's root span, giving trace UIs a "click to see previous phase" affordance.
- **Human approval** — recorded as a standalone short-lived trace (just the approval event, not the wait time). Wait duration is derived from timestamps between the analysis-completed and approval-received traces.
- **On retry** (verification failure → re-execute) — new traces are created for the retry execution and verification phases. Retry index is a span attribute.

Note: agentic events do not carry a `user_id` — AgenticRuns are created by the alerts-adapter (a service account), not a human. The human identity enters the audit trail at approval time via the mutating webhook (`agentic_run.approval.completed` span event).

### OLS (lightspeed-service) — Per-Request Traces

Each HTTP request gets its own trace. The conversation ID links all request traces as a correlation attribute.

- **`gen_ai.conversation.id`** — the `conversation_id` UUID. Carried as a span attribute on every span. Users query `gen_ai.conversation.id = X` to see all requests in a conversation.
- **Per-request trace IDs** — each incoming request generates a fresh, auto-generated OTEL trace ID. Individual request traces are clean single-root trees.
- **`user_id`** — authenticated user identity from k8s token validation. Present as a span attribute on every span.

### CR Serialization Model

Operator CR payloads (AnalysisResult, ExecutionResult, etc.) use a split model:

- **Key fields → span attributes** (queryable in trace backends): `result.name`, `result.uid`, `options.count`, `phase`, `terminal.reason`.
- **Full CR serialization → span event attributes** (viewable, full fidelity): complete `.spec` + `.status` + select metadata as a single event attribute. Event names follow the audit event catalog (e.g., `agentic_run.analysis.completed`).

All serialized CRs include: `metadata.name`, `metadata.namespace`, `metadata.creationTimestamp`, `metadata.uid`, plus `.spec` and `.status` (for Result CRs).

## Agentic Audit Event Catalog

### Operator Events

Emitted as OTel span events attached to the operator's phase spans. Each carries `agentic_run.uid`, `agentic_run.name`, and `agentic_run.namespace` as span attributes on the parent span.

| Span Event | When | Attributes |
|---|---|---|
| `agentic_run.received` | New AgenticRun CR detected | Full AgenticRun CR serialization |
| `agentic_run.analysis.completed` | AnalysisResult CR created | `result.name`, `result.uid`, `options.count` + full AnalysisResult CR serialization |
| `agentic_run.approval.completed` | AgenticRunApproval PATCH observed | `approver.uid`, `approver.username`, selected option, full text of selected option |
| `agentic_run.execution.completed` | ExecutionResult CR created | `result.name`, `result.uid`, `actions_taken.count` + full ExecutionResult CR serialization |
| `agentic_run.verification.completed` | VerificationResult CR created, checks passed | `result.name`, `result.uid`, `checks.count` + full VerificationResult CR serialization |
| `agentic_run.verification.retry` | Verification failed, retrying | `result.name`, `retry_count`, `checks.count` + full VerificationResult CR serialization |
| `agentic_run.escalation.completed` | EscalationResult CR created | Full EscalationResult CR serialization |
| `agentic_run.terminal` | AgenticRun reaches terminal phase | `phase`, `reason` |

### Sandbox Events

Emitted as OTel spans and span events during agent execution. The sandbox receives trace context from the operator via `traceparent` header. The sandbox does not run its own agent loop — it consumes events from the provider SDK's internal agentic loop (Claude `query()`, OpenAI `Runner.run_streamed()`, Gemini `Runner.run_async()`).

**Spans** (with duration):

| Span Name | Kind | When | Key Attributes |
|---|---|---|---|
| `chat {gen_ai.request.model}` | `CLIENT` | Full SDK inference call | `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `agentic_run.uid` |
| `execute_tool {gen_ai.tool.name}` | `INTERNAL` | Each tool call/result pair | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.tool.type` |

**Span events** (point-in-time, attached to the inference span):

| Event Name | When | Attributes |
|---|---|---|
| `gen_ai.content.completion` | SDK yields complete text block | `gen_ai.completion` |
| `gen_ai.agent.thinking` | SDK yields thinking delta | `content` (Claude only) |

## OLS Audit Event Catalog

Every span carries `gen_ai.conversation.id` and `user_id` as span attributes.

**Spans** (with duration):

| Span Name | Kind | When | Key Attributes |
|---|---|---|---|
| `request.lifecycle` | `INTERNAL` | Full HTTP request lifecycle | `gen_ai.conversation.id`, `user_id` |
| `request.auth` | `INTERNAL` | User authentication | `user_id` |
| `request.rag` | `INTERNAL` | RAG chunk retrieval | Chunk count, source documents |
| `request.history` | `INTERNAL` | Conversation history load | Turn count, compressed (yes/no) |
| `chat {gen_ai.request.model}` | `CLIENT` | Each LLM turn | `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
| `execute_tool {gen_ai.tool.name}` | `INTERNAL` | Each tool call | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, MCP attributes when MCP-sourced |
| `request.store` | `INTERNAL` | Response storage | |

**Span events** (point-in-time, attached to the LLM turn span):

| Event Name | When | Attributes |
|---|---|---|
| `gen_ai.content.completion` | LLM emits text output | `gen_ai.completion` |
| `gen_ai.agent.thinking` | LLM emits reasoning/thinking | `content` |

Note: OLS runs its own tool-calling loop (not an SDK agentic loop), so per-turn token counts are available via `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens` on each `chat {model}` span.

## OTEL Span Hierarchy

### Agentic System — Per-Phase Traces

Each phase is its own trace. Traces are linked by `agentic_run.uid` span attribute and OTel Span Links.

**Analysis phase trace:**
```
agentic_run.analyze             [operator, root, INTERNAL, agentic_run.uid=<UID>]
└── chat claude-sonnet-4-...    [sandbox, CLIENT, via traceparent]
    ├── execute_tool Bash       [sandbox, INTERNAL]
    ├── execute_tool Bash       [sandbox, INTERNAL]
    └── (span events: gen_ai.content.completion, gen_ai.agent.thinking)
```

**Approval trace:**
```
agentic_run.human_approval      [operator, root, INTERNAL, agentic_run.uid=<UID>, linked→analysis trace]
└── (span event: agentic_run.approval.completed with approver identity)
```

**Execution phase trace:**
```
agentic_run.execute             [operator, root, INTERNAL, agentic_run.uid=<UID>, linked→approval trace]
└── chat claude-sonnet-4-...    [sandbox, CLIENT, via traceparent]
    ├── execute_tool Bash       [sandbox, INTERNAL]
    └── (span events: gen_ai.content.completion)
```

**Verification phase trace:**
```
agentic_run.verify              [operator, root, INTERNAL, agentic_run.uid=<UID>, linked→execution trace]
└── chat claude-sonnet-4-...    [sandbox, CLIENT, via traceparent]
    └── execute_tool Bash       [sandbox, INTERNAL]
```

**Terminal trace:**
```
agentic_run.terminal            [operator, root, INTERNAL, agentic_run.uid=<UID>, linked→verify trace]
└── (span event: agentic_run.terminal with phase and reason)
```

On retry (verification failure → re-execute), new execution and verification traces are created with `retry_index` as a span attribute.

### OLS (lightspeed-service) — Per-Request Traces

Each HTTP request is its own trace. Traces are linked by `gen_ai.conversation.id` span attribute.

```
request.lifecycle               [service, root, INTERNAL, gen_ai.conversation.id=<conv_id>]
├── request.auth                [service, INTERNAL]
├── request.rag                 [service, INTERNAL]
├── request.history             [service, INTERNAL]
├── chat gpt-4o                 [service, CLIENT, repeats per LLM turn]
│   ├── execute_tool search     [service, INTERNAL, repeats per tool call]
│   └── (span events: gen_ai.content.completion, gen_ai.agent.thinking)
└── request.store               [service, INTERNAL]
```

For multi-turn conversations, each request produces a separate trace. All traces for the same conversation share `gen_ai.conversation.id` as a span attribute. Query by `gen_ai.conversation.id` to see the full conversation.

## Mutating Admission Webhook

### Purpose

Inject authenticated user identity into AgenticRunApproval on PATCH. Serves two needs: audit logging (emit `agentic_run.approval.completed` span event with identity) and UI display (persist identity on the CR).

### Mechanics

- **Resource:** `agenticrunapprovals.agentic.openshift.io/v1alpha1`
- **Operation:** `PATCH`
- **Action:**
  1. Read `request.userInfo.username` and `request.userInfo.uid` from the AdmissionReview.
  2. Write `spec.approver.uid`, `spec.approver.username`, `spec.approver.timestamp` into the CR, overwriting any client-submitted values.
  3. Emit approval span event with user identity and `agentic_run.uid` (AgenticRun's `metadata.uid`, read from the CR's owner reference).
- **Hosted by:** The agentic-operator controller-manager (same process, same OTel tracer).
- **Failure mode:** Fail-closed — if the webhook is unavailable, the API server rejects the PATCH. Correct default for a compliance-critical path.
- **TLS:** Webhook certificate managed by the operator's existing cert infrastructure.

### CRD Change Required

Add `spec.approver` to AgenticRunApproval:

```yaml
spec:
  approver:
    uid: ""         # from userInfo.uid — webhook-authoritative
    username: ""    # from userInfo.username — webhook-authoritative
    timestamp: ""   # server-side time.Now() — webhook-authoritative
```

### Console Responsibility

The agentic console populates approval decision fields on the PATCH request (selected option, max retries, stage). It does not need to populate identity fields — the webhook handles that. If the console does populate them, the webhook overwrites them.

## Configuration Surface

### AgenticOLSConfig CR

```yaml
spec:
  audit:                                   # optional block; omitting = audit enabled, no OTEL export
    enabled: true                          # default: true (audit on even if spec.audit is absent)
    otel:
      endpoint: ""                         # optional OTLP endpoint; no-op exporter when empty/absent
```

### OLSConfig CR

```yaml
spec:
  audit:                                   # optional block; omitting = audit enabled, no OTEL export
    enabled: true                          # default: true (audit on even if spec.audit is absent)
    otel:
      endpoint: ""                         # optional OTLP endpoint; no-op exporter when empty/absent
```

### Defaults

If `spec.audit` is absent entirely, behavior is `enabled: true` with no-op OTLP exporter. The stdout exporter always emits OTLP JSON to stdout. The user must explicitly set `enabled: false` to disable.

### Propagation

- The lightspeed-operator reads `OLSConfig.spec.audit` and generates the corresponding config in `olsconfig.yaml` for lightspeed-service to consume.
- The agentic-operator reads `AgenticOLSConfig.spec.audit` directly and passes the OTEL endpoint to the sandbox (env var or config mount).
- The stdout exporter always emits when audit is enabled — this is what any log aggregator (Loki, Splunk, Fluentd, etc.) reads from container logs.
- The OTLP exporter is additive — gives distributed tracing visualization (Jaeger/Tempo) when an endpoint is configured.
- When `audit.otel.tls_mode` is `Secure`, the OTLP gRPC client MUST use the merged CA bundle from `certificate_directory` / `extra_ca` for TLS verification — the same trust store used for LLM provider and MCP connections.

### Auto-Detection

Auto-detection of OpenShift logging OTLP endpoints: [PLANNED].

## Structured Log Format — OTLP JSON

Audit events are emitted as OTel spans and span events. The stdout exporter serializes them as OTLP JSON — the same wire format used by the OTLP exporter. This means the stdout output IS valid OTLP that can be replayed into a trace backend if the OTLP exporter was offline.

### Single-Emission Rule

Each audit-significant datum is recorded exactly once, as an OTel span or span event. The stdout and OTLP exporters are two destinations for the same emission, not two separate emission paths. Application-level loggers (Go `logr`, Python `logging`) emit only developer-debugging messages and MUST NOT re-emit data that appears in spans or span events.

### Stdout Exporter Behavior

- The stdout exporter does NOT truncate span attributes or event attributes. Full fidelity is preserved.
- Each span is serialized as a single JSON line to stdout when the span ends.
- The OTLP exporter may truncate based on backend limits, but the stdout signal is the compliance record.
- Both Go and Python OTel SDKs ship stdout/console exporters natively: Go `go.opentelemetry.io/otel/exporters/stdout/stdouttrace`, Python `opentelemetry.sdk.trace.export.ConsoleSpanExporter`.

### Conventions

- Output format is OTLP JSON — the OTel standard wire format.
- `agentic_run.uid` (agentic) or `gen_ai.conversation.id` (OLS) on every span for cross-trace correlation.
- OLS spans additionally carry `user_id`.
- Span attributes use `gen_ai.*` naming per OTel GenAI semantic conventions.
- CR serialization payloads are span event attributes (not span attributes) to keep spans queryable while preserving full payloads.

## OTel GenAI Attribute Reference

Standard attributes adopted from OTel GenAI Semantic Conventions v1.41. All `gen_ai.*` attributes follow the semconv requirement levels.

### Inference Span Attributes (on `chat {model}` spans)

| Attribute | Requirement | Description |
|---|---|---|
| `gen_ai.operation.name` | Required | `"chat"` |
| `gen_ai.request.model` | Required | Model name requested (e.g., `claude-sonnet-4-20250514`) |
| `gen_ai.response.model` | Recommended | Actual model from provider response |
| `gen_ai.provider.name` | Required | Provider name (e.g., `anthropic`, `openai`, `google`) |
| `gen_ai.usage.input_tokens` | Recommended | Input token count for this operation |
| `gen_ai.usage.output_tokens` | Recommended | Output token count for this operation |
| `gen_ai.response.finish_reasons` | Recommended | Reasons the model stopped generating |
| `gen_ai.conversation.id` | Conditionally Required | Conversation identifier (OLS only) |
| `server.address` | Recommended | LLM API endpoint hostname |
| `server.port` | Recommended | LLM API endpoint port |
| `error.type` | Conditionally Required | Error type when the operation fails |

### Tool Execution Span Attributes (on `execute_tool {name}` spans)

| Attribute | Requirement | Description |
|---|---|---|
| `gen_ai.operation.name` | Required | `"execute_tool"` |
| `gen_ai.tool.name` | Required | Tool name |
| `gen_ai.tool.call.id` | Recommended | Tool call ID from SDK/provider |
| `gen_ai.tool.type` | Recommended | `"function"` |

### MCP Attributes (on tool spans when tool is MCP-sourced, OLS only; sandbox [PLANNED])

| Attribute | Requirement | Description |
|---|---|---|
| `mcp.method.name` | Recommended | MCP method invoked (e.g., `tools/call`) |
| `mcp.session.id` | Recommended | MCP session identifier |
| `mcp.protocol.version` | Recommended | MCP protocol version |
| `network.transport` | Recommended | `stdio` or `sse` |

### Operator Phase Span Attributes (on `agentic_run.*` spans)

Operator spans are Kubernetes workflow orchestration, not GenAI inference. They use custom `agentic_run.*` attributes.

| Attribute | Description |
|---|---|
| `agentic_run.uid` | AgenticRun CR `metadata.uid` (hyphens stripped) — cross-trace correlation key |
| `agentic_run.name` | AgenticRun CR name |
| `agentic_run.namespace` | AgenticRun CR namespace |
| `gen_ai.request.model` | Model being sent to sandbox (where known) |
| `gen_ai.provider.name` | Provider being sent to sandbox (where known) |
| `retry_index` | Retry count (on execution/verification retries) |
| `phase` | Terminal phase (on terminal span) |
| `reason` | Terminal reason (on terminal span) |
| `approver.uid` | Approver identity (on approval span) |
| `approver.username` | Approver username (on approval span) |

### Metrics

| Metric | Type | Unit | Labels | Component |
|---|---|---|---|---|
| `gen_ai.client.token.usage` | Histogram | `{token}` | `gen_ai.token.type` (input/output), `gen_ai.request.model`, `gen_ai.provider.name` | Sandbox, OLS |
| `gen_ai.client.operation.duration` | Histogram | `s` | `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.operation.name` | Sandbox, OLS |
| `gen_ai.execute_tool.duration` | Histogram | `s` | `gen_ai.tool.name` | Sandbox, OLS |

Token usage histogram bucket boundaries: `[1, 4, 16, 64, 256, 1024, 4096, 16384, 65536]`.

OLS additionally keeps its existing `ols_*` Prometheus metrics for backward compatibility. The `gen_ai.*` histograms supersede `ols_llm_token_sent_total`/`ols_llm_token_received_total` for distribution analysis.

[PLANNED] Streaming metrics (`gen_ai.client.operation.time_to_first_chunk`, `gen_ai.client.operation.time_per_output_chunk`) for OLS when streaming is the default path.

[PLANNED] MCP metrics (`mcp.client.operation.duration`, `mcp.client.session.duration`) pending sufficient usage data.

## Repo Ownership

| Repo | Audit Responsibilities |
|---|---|
| **lightspeed-agentic-operator** | Create per-phase root spans (`agentic_run.analyze`, `agentic_run.execute`, etc.) with `agentic_run.uid` as span attribute and Span Links to prior phases. Emit CR serialization as span events. Host mutating admission webhook for AgenticRunApproval PATCH (inject identity). Propagate trace context to sandbox via `traceparent` header. Configure stdout and OTLP exporters from `AgenticOLSConfig` CR. CRD change: add `spec.approver` to AgenticRunApproval. |
| **lightspeed-agentic-sandbox** | Create `chat {model}` inference spans and `execute_tool {name}` tool spans with `gen_ai.*` attributes. Emit text/thinking as span events on the inference span. Receive trace context from operator via `traceparent` header. Configure stdout and OTLP exporters. Expose `gen_ai.*` Prometheus metrics via `/metrics` endpoint. |
| **lightspeed-service** | Create per-request traces with `request.lifecycle` root span. Create `chat {model}` spans for LLM turns and `execute_tool {name}` spans for tools (with MCP attributes when MCP-sourced). Carry `gen_ai.conversation.id` and `user_id` on all spans. Configure stdout and OTLP exporters from `olsconfig.yaml`. Expose `gen_ai.*` Prometheus metrics alongside existing `ols_*` metrics. |
| **lightspeed-operator** | CRD change: add `spec.audit` to `OLSConfig`. Propagate audit config to `olsconfig.yaml` for lightspeed-service. |
| **lightspeed-agentic-console** | Populate approval decision fields on AgenticRunApproval PATCH (selected option, max retries, stage). Display `spec.approver` fields in UI. No audit emission responsibility. |
| **lightspeed-console** | No changes. No audit emission responsibility. |

## Child Spec Updates Required

Each child repo needs an audit logging spec with implementation details. The parent spec (this file) is authoritative for the "what" (requirements, event semantics, correlation contract, OTel GenAI attribute reference). Child specs are authoritative for the "how" (implementation within that repo).

| Repo | Child Spec File | Content |
|---|---|---|
| lightspeed-agentic-operator | `what/audit-logging.md` | Per-phase trace creation, span links, CR serialization as span events, webhook implementation, CRD changes |
| lightspeed-agentic-sandbox | `what/audit-logging.md` | GenAI span creation per provider (Claude, OpenAI, Gemini), trace context reception, single-emission rule, `gen_ai.*` metrics |
| lightspeed-service | `what/audit-logging.md` | Per-request trace creation, `gen_ai.conversation.id` propagation, MCP attributes on tool spans, single-emission rule, `gen_ai.*` metrics |
| lightspeed-operator | `what/audit-logging.md` | OLSConfig CRD audit fields, olsconfig.yaml generation for audit config |

## Cross-References

- `agentic-runs.md` — AgenticRun lifecycle, CRD definitions, phase transitions
- `agentic-security.md` — Approval authorization (cluster-admin gate), per-run SA isolation
- `query-pipeline.md` — OLS request processing stages, streaming events
- [OTel GenAI Semantic Conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/README.md)
- [OTel MCP Semantic Conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md)

## Planned Changes

| Ticket | Summary |
|---|---|
| [PLANNED] | Auto-detection of OpenShift logging OTLP endpoint |
| [DONE: OLS-3295] | Rename `Proposal` → `AgenticRun`, `ProposalApproval` → `AgenticRunApproval` across audit events and OTEL spans |
| OLS-3328 | Temporary audit log storage in PostgreSQL via custom OTel Collector (see `templog.md`) |
| OLS-3493 | OTel GenAI semantic conventions alignment (this spec update) |
| OLS-3696 | Templog phase storage — OTLP log records must carry `agenticrun.phase` attribute. Collector maps it to `phase` column. `trace_id` column renamed to `agentic_run_id`. See design spec `docs/superpowers/specs/2026-07-22-templog-phase-storage.md`. |
| [PLANNED] | Content capture controls — three-mode opt-in per OTel GenAI semconv |
| [PLANNED] | Evaluation events — `gen_ai.evaluation.result` for RAG relevance scoring |
| [PLANNED] | Cache token attributes — `gen_ai.usage.cache_read.input_tokens` for prompt caching |
