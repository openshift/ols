# Compliance Audit Logging

Durable, reconstructable audit trail of AI actions across the OpenShift Lightspeed system. Required by EU AI Act and similar regulations. The agentic system (takes cluster actions) is highest priority; OLS (makes recommendations via troubleshoot mode) is also in scope.

Sandbox GenAI spans and metrics adopt the structures and selected conventions of [OTel GenAI Semantic Conventions v1.41](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai). This is not a claim of full upstream content-consent conformance: source content is recorded independently of compliance-copy capture, while upstream designates content attributes Opt-In. The policy difference is explicit in [Agentic data collection](agentic-data-collection.md#schema-versioning-and-downstream-coordination). Operator CR lifecycle events remain span events; see the OTel GenAI Attribute Reference below for the span attribute catalog.

The sandbox instrumentation schema URL is `https://opentelemetry.io/schemas/1.41.0`. It versions upstream conventions, not every OLS-specific trace field or semantic change. All changes to collected trace evidence, including content retention and status semantics, MUST be versioned and coordinated with Dataverse transformations under [Agentic data collection](agentic-data-collection.md#schema-versioning-and-downstream-coordination). Exported raw tool payloads remain untrusted evidence; inspection is not a trace-sanitization boundary.

## Requirements & Principles

1. **Single emission, multiple destinations.** Sandbox agent, inference, and tool content is recorded on standard GenAI span attributes, not additional GenAI span events. When compliance audit is enabled, stdout OTLP JSON and (when an OTLP endpoint exists) templog records are derived views of those completed source spans. A configured trace endpoint independently receives the unmodified source spans; application developer diagnostics do not create another product transcript. Agentic product collection may consume the same trace signal under the independent contract in `agentic-data-collection.md`.

2. **Graceful degradation.** An OTEL endpoint is optional; without it there is no OTLP trace or log export, while enabled sandbox compliance audit still emits OTLP JSON to stdout. Product traces are exported when an endpoint is configured, whether or not sandbox compliance audit is enabled.

3. **Independent content controls.** `LIGHTSPEED_AUDIT_ENABLED=true` enables sandbox compliance stdout and endpoint-backed derived templog; `LIGHTSPEED_CAPTURE_CONTENT` controls only the compliance copies, defaulting to the audit setting when unset. Captured source-span prompt, tool, output, and available reasoning content is not gated by this compliance flag when tracing is recording. Where emitted, content-enabled compliance copies may retain the complete recorded content, including a successful native tool result later rejected by sandbox inspection. Compliance views omit the six standard content attributes when explicitly opted out, without changing the source spans.

4. **No producer-side redaction of recorded sandbox traces.** Input-to-LLM redaction remains a separate concern. The optional sandbox compliance-copy content policy removes complete standard content attributes from stdout/templog views when disabled; it does not redact or mutate the original trace spans.

5. **CR serialization is the compliance record.** Ephemeral Kubernetes CRs are serialized into the span event stream at creation (immutable Result CRs) and at mutation (AgenticRunApproval on PATCH, AgenticRun status at phase transitions). Key fields from the CR are **span attributes** (queryable in trace backends); full CR serialization is a **span event attribute** (viewable at full fidelity). Serialization includes `.spec`, `.status` (for Result CRs), plus `metadata.name`, `metadata.namespace`, `metadata.creationTimestamp`, and `metadata.uid` — not the full Kubernetes metadata. The stdout exporter does NOT truncate — full fidelity is preserved. The OTLP exporter may truncate based on backend limits, but the stdout signal is the compliance record.

6. **Sandbox/service spans are the forensic record.** The sandbox records real model requests and actual native tool executions in GenAI span attributes: ordered messages include available LLM text and reasoning parts; tool attributes hold available arguments and the raw result of successful native execution, including when sandbox inspection later rejects that result. Only native execution failures omit `gen_ai.tool.call.result`. Operator CR serialization captures decisions as separate span events. The sandbox does not create `gen_ai.choice`, reasoning, or tool-content events.

7. **Human approval identity.** Mutating admission webhook on AgenticRunApproval PATCH injects authenticated user identity (`uid`, `username`) from the admission review. Authoritative for all paths (console, kubectl, API). Console populates approval decision fields; webhook adds/overwrites identity fields. See Mutating Admission Webhook section.

8. **No console-side audit events.** Both consoles are presentation layers. Every consequential action creates a CR or makes an API call captured by the receiving backend.

9. **Log size is the aggregator's problem.** Full CR content (`.spec` + `.status` + select metadata) is serialized without truncation in the stdout exporter.

## Correlation Model

### Agentic System — Per-Phase Traces

Each phase of an AgenticRun lifecycle gets its own trace. The AgenticRun UID links all phase traces as a correlation attribute.

- **`agenticrun.uid`** — the literal AgenticRun CR `metadata.uid`, including hyphens. Carried as a **span attribute** on operator phase spans and on sandbox agent/model/tool spans when supplied by batch correlation; never sourced from a resource attribute.
- **`agenticrun.phase`** — operator phase and supplied sandbox span attribute; one of `analysis`, `approval`, `execution`, `verification`, `escalation`, or `terminal`. **`agenticrun.name`** and **`agenticrun.namespace`** identify the operator run spans; the sandbox does not synthesize them.
- **Per-phase trace IDs** — each phase gets a fresh, auto-generated OTEL trace ID.
- **Batch sandbox propagation** — the operator carries the active phase context and correlation through the input ConfigMap and Pod environment (`TRACEPARENT`, `LIGHTSPEED_AGENTICRUN_UID`, `LIGHTSPEED_AGENTICRUN_STEP`); the sandbox returns a Result CR through the Kubernetes API. The current batch flow does not propagate this contract through `/v1/agent/run`.
- **Human approval** — recorded as a standalone short-lived trace (just the approval event, not the wait time). Wait duration is derived from timestamps between the analysis-completed and approval-received traces.
- **On verification failure** — the operator transitions to the escalation phase. A new escalation trace is created. There are no execution retries on verification failure.

Note: agentic events do not carry a `user_id` — AgenticRuns are created by the alerts-adapter (a service account), not a human. The human identity enters the audit trail at approval time via the mutating webhook (`agenticrun.approval.completed` span event).

### OLS (lightspeed-service) — Per-Request Traces

Each HTTP request gets its own trace. The conversation ID links all request traces as a correlation attribute.

- **`gen_ai.conversation.id`** — the `conversation_id` UUID. Carried as a span attribute on every span. Users query `gen_ai.conversation.id = X` to see all requests in a conversation.
- **Per-request trace IDs** — each incoming request generates a fresh, auto-generated OTEL trace ID. Individual request traces are clean single-root trees.
- **`user_id`** — authenticated user identity from k8s token validation. Present as a span attribute on every span.

### CR Serialization Model

Operator CR payloads (AnalysisResult, ExecutionResult, etc.) use a split model:

- **Key fields → span attributes** (queryable in trace backends): `result.name`, `result.uid`, `options.count`, `phase`, `terminal.reason`.
- **Full CR serialization → span event attributes** (viewable, full fidelity): complete `.spec` + `.status` + select metadata as a single event attribute. Event names follow the audit event catalog (e.g., `agenticrun.analysis.completed`).

All serialized CRs include: `metadata.name`, `metadata.namespace`, `metadata.creationTimestamp`, `metadata.uid`, plus `.spec` and `.status` (for Result CRs).

## Agentic Audit Event Catalog

### Operator Events

Emitted as OTel span events attached to the operator's phase spans. Each parent span carries `agenticrun.uid`, `agenticrun.name`, `agenticrun.namespace`, and `agenticrun.phase`.

| Span Event | When | Attributes |
|---|---|---|
| `agenticrun.received` | New AgenticRun CR detected | Full AgenticRun CR serialization |
| `agenticrun.analysis.completed` | AnalysisResult CR created | `result.name`, `result.uid`, `options.count` + full AnalysisResult CR serialization |
| `agenticrun.approval.completed` | AgenticRunApproval PATCH observed | `approver.uid`, `approver.username`, decision, selected option, full AgenticRunApproval CR serialization |
| `agenticrun.execution.completed` | ExecutionResult CR created | `result.name`, `result.uid`, `actions_taken.count` + full ExecutionResult CR serialization |
| `agenticrun.verification.completed` | VerificationResult CR created | `result.name`, `result.uid`, `checks.count` + full VerificationResult CR serialization |
| `agenticrun.escalation.completed` | EscalationResult CR created | Full EscalationResult CR serialization |
| `agenticrun.terminal` | AgenticRun reaches terminal phase | `phase`, `reason`, full terminal AgenticRun CR serialization |

### Sandbox Spans

The sandbox receives trace context and correlation through its Pod environment. `invoke_agent lightspeed` is an INTERNAL agent-invocation span beneath the operator phase span when `TRACEPARENT` is valid; without valid parent context it starts a new trace. Each actual inference or executed tool is a sibling child under that agent span. The agent, inference, and tool spans carry the literal run correlation supplied by the existing invocation configuration. Each `tool_result.inspection` span carries only the literal `agenticrun.uid` and `agenticrun.phase` values supplied in that configuration; missing values remain absent and are never inferred from a Resource, process environment, parent context, or another span.

| Span Name | Kind | When | Key Span Attributes |
|---|---|---|---|
| `invoke_agent lightspeed` | `INTERNAL` | One agent invocation | `gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name=lightspeed`, endpoint `gen_ai.provider.name`, requested model when known, `gen_ai.input.messages`, `gen_ai.system_instructions` when supplied, exact post-shaped `AgentResult.output` as `gen_ai.output.messages` when a terminal result is normally produced (including domain `success=false`), `agenticrun.uid`, `agenticrun.phase` when supplied |
| `{gen_ai.operation.name} {gen_ai.request.model}` | `CLIENT` | Each actual SDK model request | `gen_ai.operation.name=chat` for DeepAgents/OpenAI or `generate_content` for Gemini, requested and observed response model, provider, ordered `gen_ai.input.messages` / `gen_ai.output.messages`, `gen_ai.system_instructions`, `gen_ai.tool.definitions` when known, observed input/output and `gen_ai.usage.reasoning.output_tokens` counts |
| `execute_tool {gen_ai.tool.name}` | `INTERNAL` | Each actual tool execution, including registered skill loads | `gen_ai.operation.name=execute_tool`, `gen_ai.tool.name`, provider/SDK `gen_ai.tool.call.id` only when exposed, `gen_ai.tool.type`, `gen_ai.tool.call.arguments`, raw `gen_ai.tool.call.result` on successful native execution regardless of later inspection |

Content fields on source spans are populated when the span is recording, independently of compliance-copy capture. Message arrays are JSON-string standard v1.41 structures; supported assistant reasoning is a `reasoning` part, not `gen_ai.reasoning_content` or a separate event. A successful native tool span retains its raw callback result and remains `UNSET` even if inspection later rejects it or classification fails; only native tool failures omit the standard result and set `ERROR`, and interruption closes only still-open operations. Valid benign and malicious inspection outcomes leave `tool_result.inspection` spans `UNSET`; `classifier_error`, including cancellation, is `ERROR` with controlled metadata. A fail-closed abort leaves the enclosing agent span `ERROR` with no terminal output. A normally produced agent result, including domain `success=false`, is recorded exactly; actual pre-terminal failures have no terminal output. Provider/SDK call IDs connect model and tool records only when a common ID is actually exposed: Gemini observes finalized ADK Events for late SDK-assigned IDs on model output and actual tools; IDs ADK strips from later effective requests remain absent, and supplied provider IDs remain unchanged. SDK skill loads use the real tool name rather than a fabricated `load_skill` event; skill content is not emitted twice. Full prompt/tool/reasoning content depends on what the SDK exposes and whether tracing records the span; compliance copies omit content if configured, and no GenAI content span events are emitted.

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

OLS (lightspeed-service) content emission is a separate service-owned contract; the sandbox v1.41 span-attribute rules above do not prescribe OLS-specific LLM-turn content events.

Note: OLS runs its own tool-calling loop (not an SDK agentic loop), so per-turn token counts are available via `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens` on each `chat {model}` span.

## OTEL Span Hierarchy

### Agentic System — Per-Phase Traces

Each phase is its own trace. Traces are linked by `agenticrun.uid` span attribute and OTel Span Links.

**Analysis phase trace:**
```
agenticrun.analyze              [operator, root, INTERNAL, agenticrun.uid=<UID>]
└── invoke_agent lightspeed     [sandbox, INTERNAL, via traceparent]
    ├── chat claude-sonnet-4-... [sandbox, CLIENT, ordered message attributes]
    ├── execute_tool Bash        [sandbox, INTERNAL, call arguments/result attributes]
    ├── chat claude-sonnet-4-... [sandbox, CLIENT, ordered message attributes]
    └── execute_tool Bash        [sandbox, INTERNAL]
```

**Approval trace:**
```
agenticrun.human_approval       [operator, root, INTERNAL, agenticrun.uid=<UID>, linked→analysis trace]
└── (span event: agenticrun.approval.completed with approver identity)
```

**Execution phase trace:**
```
agenticrun.execute              [operator, root, INTERNAL, agenticrun.uid=<UID>, linked→approval trace]
└── invoke_agent lightspeed     [sandbox, INTERNAL, via traceparent]
    ├── chat claude-sonnet-4-... [sandbox, CLIENT, ordered message attributes]
    └── execute_tool Bash        [sandbox, INTERNAL]
```

**Verification phase trace:**
```
agenticrun.verify               [operator, root, INTERNAL, agenticrun.uid=<UID>, linked→execution trace]
└── invoke_agent lightspeed     [sandbox, INTERNAL, via traceparent]
    ├── chat claude-sonnet-4-... [sandbox, CLIENT]
    └── execute_tool Bash        [sandbox, INTERNAL]
```

**Terminal trace:**
```
agenticrun.terminal             [operator, root, INTERNAL, agenticrun.uid=<UID>, linked→verify trace]
└── (span event: agenticrun.terminal with phase and reason)
```

On verification failure, the operator transitions directly to the escalation phase — there are no execution retries.

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

Inject authenticated user identity into AgenticRunApproval on PATCH. Serves two needs: audit logging (emit `agenticrun.approval.completed` span event with identity) and UI display (persist identity on the CR).

### Mechanics

- **Resource:** `agenticrunapprovals.agentic.openshift.io/v1alpha1`
- **Operation:** `PATCH`
- **Action:**
  1. Read `request.userInfo.username` and `request.userInfo.uid` from the AdmissionReview.
  2. Write `spec.approver.uid`, `spec.approver.username`, `spec.approver.timestamp` into the CR, overwriting any client-submitted values.
  3. Emit approval span event with user identity and `agenticrun.uid` (AgenticRun's literal `metadata.uid`, read from the CR's owner reference).
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

If `spec.audit` is absent entirely, compliance-audit behavior is `enabled: true` with no-op configured audit OTLP exporter. The stdout exporter emits OTLP JSON while compliance audit is enabled. The user must explicitly set `enabled: false` to disable compliance audit.

[PLANNED: OLS-3569] Product trace transport, enablement, correlation, native-span export, and downstream interpretation are governed by `agentic-data-collection.md`. Compliance audit switches do not become product-collection switches.

### Propagation

- The agentic-operator reads `AgenticOLSConfig.spec.audit` for compliance audit. The independent shared Collector transport is defined in `agentic-data-collection.md`; this audit configuration does not introduce another product endpoint or collection-state key.
- The stdout exporter always emits when compliance audit is enabled — this is what any log aggregator (Loki, Splunk, Fluentd, etc.) reads from container logs.
- A configured compliance OTLP destination is additive. Whether the shared Collector stages and exports eligible native product spans is governed only by `agentic-data-collection.md`.
- When `audit.otel.tls_mode` is `Secure`, the OTLP gRPC client MUST use the merged CA bundle from `certificate_directory` / `extra_ca` for TLS verification — the same trust store used for LLM provider and MCP connections.

### Auto-Detection

Auto-detection of OpenShift logging OTLP endpoints: [PLANNED].

## Structured Log Format — OTLP JSON

Sandbox compliance spans are derived from recorded GenAI source spans and serialized as OTLP JSON on stdout when audit is enabled; operator CR lifecycle span events remain separate. This OTLP wire format can be replayed to a trace backend if the OTLP exporter was offline, subject to the sandbox compliance content policy.

### Single-Emission Rule

Each sandbox agent, inference, and tool datum is recorded on its source span once. Audit-gated stdout and templog are derived views; configured product OTLP trace export receives the original source span. Operator CR lifecycle data remain operator span events. A product consumer reuses the trace signal without causing another sandbox emission; developer logs MUST NOT create a duplicate product transcript.

### Stdout Exporter Behavior

- Sandbox stdout does not truncate the attributes it includes. When `LIGHTSPEED_CAPTURE_CONTENT=false`, the exporter removes standard content attributes from an encoded compliance projection without modifying source spans.
- Enabled audit stdout emits a complete OTLP JSON line when each sandbox span ends; with audit disabled there is no sandbox stdout compliance export.
- A configured OTLP trace exporter receives the unmodified source spans, subject to downstream/backend limits.
- The sandbox uses its `OTLPJsonStdoutExporter` for the OTLP JSON wire format; the SDK `ConsoleSpanExporter` is not the source of that format.

### Conventions

- Output format is OTLP JSON — the OTel standard wire format.
- `agenticrun.uid` (agentic) or `gen_ai.conversation.id` (OLS) on relevant spans for cross-trace correlation; sandbox UID/phase attributes are populated only when supplied.
- OLS spans additionally carry `user_id`.
- Span attributes use `gen_ai.*` naming per OTel GenAI semantic conventions.
- CR serialization payloads are span event attributes (not span attributes) to keep spans queryable while preserving full payloads.

## OTel GenAI Attribute Reference

Standard attributes adopted from OTel GenAI Semantic Conventions v1.41. On sandbox agent, model, and tool spans, content attributes are available when recording and actual SDK data exists; compliance copies may exclude content without changing the source span. The table describes the attributes applicable to the implementation, not a guarantee that every provider exposes optional fields.

### Inference Span Attributes (on model-operation spans)

| Attribute | Requirement | Description |
|---|---|---|
| `gen_ai.operation.name` | Required | `"chat"` for DeepAgents/OpenAI, `"generate_content"` for Gemini |
| `gen_ai.request.model` | Required | Model name requested (e.g., `claude-sonnet-4-20250514`) |
| `gen_ai.response.model` | Recommended | Actual model when exposed by the SDK; otherwise absent |
| `gen_ai.provider.name` | Required | Routed endpoint provider (e.g., `anthropic`, `gcp.vertex_ai`, `aws.bedrock`, `azure.ai.openai`) |
| `gen_ai.usage.input_tokens` | Recommended | Observed input token count for this request |
| `gen_ai.usage.output_tokens` | Recommended | Observed output token count for this request |
| `gen_ai.usage.reasoning.output_tokens` | Recommended | Observed reasoning-token subset of output tokens, when available |
| `gen_ai.conversation.id` | Conditionally Required | Conversation identifier (OLS only) |
| `error.type` | Conditionally Required | Error type when the operation fails |
| `gen_ai.input.messages`, `gen_ai.output.messages` | Opt-in | Ordered JSON-string v1.41 messages; reasoning uses a `reasoning` part, tool calls/responses use their standard parts |
| `gen_ai.system_instructions`, `gen_ai.tool.definitions` | Opt-in | Separate instructions and offered tools when known |
| `gen_ai.output.type` | Conditionally Required | `"json"` when a JSON output schema was requested |

### Tool Execution Span Attributes (on `execute_tool {name}` spans)

| Attribute | Requirement | Description |
|---|---|---|
| `gen_ai.operation.name` | Required | `"execute_tool"` |
| `gen_ai.tool.name` | Required | Tool name |
| `gen_ai.tool.call.id` | Recommended | Tool call ID from SDK/provider |
| `gen_ai.tool.type` | Recommended | `"function"` |
| `gen_ai.tool.call.arguments` | Opt-in | JSON arguments when recording actual tool execution |
| `gen_ai.tool.call.result` | Opt-in | JSON result on successful actual tool execution |

### MCP Attributes (on tool spans when tool is MCP-sourced, OLS only; sandbox [PLANNED])

| Attribute | Requirement | Description |
|---|---|---|
| `mcp.method.name` | Recommended | MCP method invoked (e.g., `tools/call`) |
| `mcp.session.id` | Recommended | MCP session identifier |
| `mcp.protocol.version` | Recommended | MCP protocol version |
| `network.transport` | Recommended | `stdio` or `sse` |

### Operator Phase Span Attributes (on `agenticrun.*` spans)

Operator spans are Kubernetes workflow orchestration, not GenAI inference. They use custom `agenticrun.*` attributes.

| Attribute | Description |
|---|---|
| `agenticrun.uid` | Literal AgenticRun CR `metadata.uid`, including hyphens — cross-trace correlation key |
| `agenticrun.name` | AgenticRun CR name |
| `agenticrun.namespace` | AgenticRun CR namespace |
| `gen_ai.request.model` | Model being sent to sandbox (where known) |
| `gen_ai.provider.name` | Provider being sent to sandbox (where known) |
| `agenticrun.phase` | Active phase on every operator phase span and propagated sandbox span |
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
| **lightspeed-agentic-operator** | Create per-phase root spans (`agenticrun.analyze`, `agenticrun.execute`, etc.) with audit correlation and Span Links. Emit CR serialization as span events. Host the AgenticRunApproval webhook. Propagate batch trace context and correlation. Configure compliance audit from `AgenticOLSConfig`; product responsibilities are referenced from `agentic-data-collection.md`. |
| **lightspeed-agentic-sandbox** | Create inference and tool spans with `gen_ai.*` attributes, receive batch correlation from the operator, and expose `gen_ai.*` metrics. Product Transcript responsibilities are referenced from `agentic-data-collection.md`. |
| **lightspeed-service** | Create per-request traces with `request.lifecycle` root span. Create `chat {model}` spans for LLM turns and `execute_tool {name}` spans for tools (with MCP attributes when MCP-sourced). Carry `gen_ai.conversation.id` and `user_id` on all spans. Configure stdout and OTLP exporters from `olsconfig.yaml`. Expose `gen_ai.*` Prometheus metrics alongside existing `ols_*` metrics. |
| **lightspeed-operator** | CRD change: add `spec.audit` to `OLSConfig`. Propagate audit config to `olsconfig.yaml` for lightspeed-service. |
| **lightspeed-agentic-console** | Populate approval decision fields on AgenticRunApproval PATCH (selected option, stage). Display `spec.approver` fields in UI. No audit emission responsibility. |
| **lightspeed-console** | No changes. No audit emission responsibility. |

## Child Spec Updates Required

Each child repo needs an audit logging spec with implementation details. This parent file is authoritative for compliance requirements, the audit event catalog, trace correlation, and the OTel GenAI reference; `agentic-data-collection.md` is authoritative for product-span eligibility, native OTLP export, and downstream interpretation. Child specs are authoritative only for implementation within that repo.

| Repo | Child Spec File | Content |
|---|---|---|
| lightspeed-agentic-operator | `what/audit-logging.md` | Per-phase trace creation, span links, CR serialization as span events, webhook implementation, CRD changes |
| lightspeed-agentic-sandbox | `what/audit-logging.md` | GenAI span creation per provider (Claude, OpenAI, Gemini), trace context reception, single-emission rule, `gen_ai.*` metrics |
| lightspeed-service | `what/audit-logging.md` | Per-request trace creation, `gen_ai.conversation.id` propagation, MCP attributes on tool spans, single-emission rule, `gen_ai.*` metrics |
| lightspeed-operator | `what/audit-logging.md` | OLSConfig CRD audit fields, olsconfig.yaml generation for audit config |

## Relationship to Agentic Product Data Collection

Agentic product collection may reuse the same OTLP trace signal without changing compliance destinations or creating duplicate application emissions. OTLP logs remain exclusive to log aggregation and templog. All product policy, native-span export interfaces, downstream interpretation, and ownership are defined in `agentic-data-collection.md`.

## Cross-References

- `agentic-runs.md` — AgenticRun lifecycle, CRD definitions, phase transitions
- `agentic-security.md` — Approval authorization (cluster-admin gate), per-run SA isolation
- `query-pipeline.md` — OLS request processing stages, streaming events
- [OTel GenAI Semantic Conventions v1.41](https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/docs/gen-ai)
- [OTel MCP Semantic Conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md)

## Planned Changes

| Ticket | Summary |
|---|---|
| [PLANNED] | Auto-detection of OpenShift logging OTLP endpoint |
| [DONE: OLS-3295] | Rename `Proposal` → `AgenticRun`, `ProposalApproval` → `AgenticRunApproval` across audit events and OTEL spans |
| OLS-3328 | Temporary audit log storage in PostgreSQL via custom OTel Collector (see `templog.md`) |
| OLS-3493 | OTel GenAI semantic conventions alignment (this spec update) |
| OLS-3696 | Templog phase storage — OTLP log records must carry `agenticrun.phase` attribute. Collector maps it to `phase` column. `trace_id` column renamed to `agentic_run_id`. See design spec `docs/superpowers/specs/2026-07-22-templog-phase-storage.md`. |
| OLS-3569 | Agentic product data collection reuses full-fidelity OTLP traces; logs remain templog-only. See `agentic-data-collection.md`. |
| [PLANNED] | Content capture controls — three-mode opt-in per OTel GenAI semconv |
| [PLANNED] | Evaluation events — `gen_ai.evaluation.result` for RAG relevance scoring |
| [PLANNED] | Cache token attributes — `gen_ai.usage.cache_read.input_tokens` for prompt caching |
