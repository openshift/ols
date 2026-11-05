# Outbound Request Audit

[PLANNED: OLS-4192] Metadata-only auditing of application-level outbound requests initiated through Python application and SDK clients in Classic OLS and the agentic sandbox. Application traffic includes LLM, remote MCP, retrieval, and their SDK credential exchanges. Kubernetes API request auditing is excluded: infrastructure traffic, including sandbox Result CR publication, is a separate concern. This is a request-observation contract, not network-policy enforcement or comprehensive network observation.

## Intent and Scope

1. Operators MUST be able to correlate an application-initiated outbound request with its destination and observed outcome without collecting prompts, credentials, request/response content, or personal user identifiers in the new records.
2. Classic OLS and the sandbox MUST cover their production application-level Python request paths: LLM inference (including shaping, inspection, and auxiliary calls), remote MCP operations, retrieval, and SDK credential/token acquisition for those clients. The child specifications define the coverage inventory. HTTP, SDK-specific transports, and synchronous as well as asynchronous clients are in scope; instrumenting only httpx is insufficient. Python client usage alone does not make infrastructure traffic part of this audit stream.
3. A request means a client transport request, not a TCP connection, model turn, tool execution, or shell command. Connection reuse and HTTP multiplexing do not reduce the number of request records. Locally rejected input that never reaches a request boundary does not constitute a network attempt.
4. Subprocess-originated connections, including oc, curl, and Python scripts launched through skills, are excluded from this implementation. Their existing tool-execution evidence remains unchanged. Network-level coverage is a complementary follow-up under OLS-4848 and MUST NOT block this Python-only change.
5. Kubernetes API requests are excluded, including Classic TokenReview/SubjectAccessReview, sandbox Result CR create/read/status-update requests, and cluster API requests during readiness or other lifecycle stages. Their infrastructure auditing is a separate concern, regardless of whether they use Python clients. Database-wire protocols, DNS as a separate operation, inbound requests, other pods, external MCP servers' own downstream traffic, developer/test utilities, and the audit/telemetry exporter's own traffic are also excluded. Export exclusion prevents recursive auditing. A service's call to MCP remains in scope even when the remote tool accesses Kubernetes; neither that tool's downstream API request nor its result content is part of this request audit. OLS-4848 may later provide overlapping network-level evidence, but does not promise equivalent Kubernetes request-level auditing.
6. No proxy, sidecar, network observer, privileged workload, CRD field, or additional deployment component is introduced. No network-policy-denial classification or five-second searchability guarantee is required.

## Emission and Lifecycle

7. When the component's existing compliance-audit enablement is active, each in-scope transport attempt MUST produce `outbound.request.started` before invoking transport and `outbound.request.finished` when its response is consumed/closed or the attempt fails. An abrupt process termination can leave an unmatched start; durable completion after process death is not promised. Audit-disabled behavior remains component-specific under existing configuration.
8. Both records MUST use the same freshly generated `attempt_id`. Redirect hops and client/SDK retries MUST have separate attempt IDs when they issue separate transport requests, including internal SDK requests. Nested instrumentation MUST NOT emit a second pair for the same attempt. TCP reconnects internal to one transport request are not separately counted.
9. Completion outcomes are `success`, `http_error`, `transport_error`, or `cancelled`. HTTP status >=400 is `http_error`; other completed HTTP responses are `success` at this layer, not proof of model/tool business success. Non-HTTP SDK transports use their actual protocol completion and a controlled error category. Protocol errors MUST NOT be translated to HTTP status values.
10. Allowed error categories are `dns_error`, `connect_error`, `tls_error`, `timeout`, `protocol_error`, `http_error`, `cancelled`, and `unknown_error`. Use a specific category only when the client exposes enough evidence; connection failures MUST NOT be labeled policy denials. HTTP 401/403 are observed HTTP errors, not evidence of an egress denial. No raw exception message, traceback, or response-body-derived reason is emitted in these records.
11. Streaming requests MUST retain their start context until stream close, EOF, failure, or cancellation. Header receipt alone MUST NOT cause successful completion. Audit hooks MUST NOT buffer, consume early, replay, or drain streams, or change cancellation, retries, TLS, authentication, timeouts, proxying, or application results.
12. Logging failures MUST NOT replace application exceptions or block outbound requests indefinitely. Use the existing logging runtime and bounded shutdown behavior; no new durable spool or delivery guarantee is introduced. A safe, rate-limited diagnostic may report audit-emission failure without serializing the failed record or the application exception.

## Shared JSON Record Contract — Version 1

13. Producers MUST emit one structured JSON object per line to stdout through a dedicated audit path. Existing approved OTLP log forwarding may additionally carry the same safe record, but no new Collector pipeline or export dependency is required. Plaintext developer prefixes MUST NOT wrap these JSON lines. Network/request hooks MUST NOT duplicate the pair through logger propagation or overlapping adapters.
14. Records MUST be constructed from the following field allowlist, not by copying a span, SDK object, Resource, exception, or request/response dictionary. Optional unavailable fields MUST be omitted, never fabricated or replaced with zero.

| Field | Requirement | Meaning |
| --- | --- | --- |
| `schema_version` | Required | Integer `1`; versions this custom log contract, not OTel GenAI schemas |
| `event` | Required | `outbound.request.started` or `outbound.request.finished` |
| `timestamp` | Required | UTC RFC3339 event time |
| `service.name` | Required | `lightspeed-service` or `lightspeed-agentic-sandbox` |
| `attempt_id` | Required | Producer-generated random UUID for one transport attempt |
| `request.kind` | Required | `llm`, `mcp`, `retrieval`, `credential`, or `other`; `other` MUST NOT be used to include excluded infrastructure requests |
| `server.address` | When known | Normalized destination hostname, or literal IP if configured as the authority |
| `server.port` | When known | Destination port, including protocol default when unambiguous |
| `network.peer.address` | When observed | Actual connected peer IP; may identify a proxy, not the ultimate server |
| `network.transport` | Required | `tcp`, `udp`, or `other`, from the actual client protocol |
| `http.request.method` | HTTP only | Validated method token; never a URL or request target |
| `trace_id`, `span_id` | Required | Valid OTel context active for the attempt; same values on its start and finish |
| `gen_ai.conversation.id` | Classic, when available | Existing server-validated conversation UUID; not personal user identity |
| `agenticrun.uid`, `agenticrun.phase` | Sandbox, when supplied | Existing validated run UID and controlled phase |
| `gen_ai.tool.name` | Specific MCP tool call only | Known registered MCP tool name, never a local shell command or arbitrary label |
| `outcome` | Finish only, required | Completion outcome defined in rule 9 |
| `error.type` | Failed/cancelled finish | Controlled category defined in rule 10 |
| `http.response.status_code` | Finish, when received | Observed numeric HTTP status |
| `duration_ms` | Finish, required | Nonnegative elapsed time measured with a monotonic clock |
| `request.body.size` | Finish, when measurable | Complete encoded request-body bytes sent through the instrumented boundary |

15. `request.body.size` excludes headers, TLS framing, compression/protocol overhead outside that boundary, and response bytes. It is not token usage or an inferred model-payload size. Use an already available trustworthy length or count bytes naturally consumed by transport. Emit only a known complete size; failed/partial/unknown streaming bodies omit it. Never serialize a prompt just to compute size.
16. Destination authorities MUST be parsed without logging the original URL. Never include userinfo, URL path, query, fragment, headers, cookies, proxy credentials, resource names, manifests, command text, or SDK argument dictionaries. Malformed destinations MUST omit unsafe fields and still permit a safe attempt record. Peer IP MUST come from transport evidence, not an extra DNS lookup performed for audit.
17. Only bounded, validated infrastructure/correlation metadata may populate the fields. Destination hostnames MUST be valid normalized DNS names of at most 253 characters, or valid canonical IP literals; ports MUST be integers from 1 through 65535. MCP tool names MUST come from the registered tool and be at most 256 printable characters with no control characters. Conversation/run/attempt identifiers MUST be validated UUIDs; trace/span IDs MUST be valid nonzero OTel identifiers. Invalid optional values are omitted rather than echoed in diagnostics. Do not forward arbitrary trace baggage, personal identities, client request labels, or caller-supplied free text. Kubernetes logging enrichment supplies source pod/namespace/container identity; no personal user ID or application-level pod lookup is needed. Infrastructure destinations and correlation IDs still require normal access controls and retention policy.

## Correlation, Controls, and Compatibility

18. Capture context at attempt start and reuse it at finish, including across callbacks, threads, concurrent tools, and stream iteration. If no valid context exists, establish a local OTel context for the attempt; do not accept arbitrary IDs from request payloads. Log emission MUST NOT depend on trace sampling or on an OTLP endpoint. A valid context does not imply an exported trace exists.
19. Existing audit enablement controls these records. Content-capture settings MUST NEVER enable content in the outbound records. No new enablement flag or operator configuration handoff is added. Audit-disabled mode does not disable independent tracing or product collection.
20. This dedicated metadata-only log is an explicit, narrowly scoped exception to the existing compliance specifications' span-only/single-emission wording. It records transport attempts, not a duplicate LLM/tool transcript. Full-fidelity compliance spans, their identities/content policies, tool-result inspection, templog, and product collection remain unchanged. A log collector MUST be able to select `event=outbound.request.*` without selecting content-bearing compliance records.
21. Gateway audit remains active when present. These producers MUST NOT claim Gateway coverage, modify Gateway settings, or create a dependency on Gateway availability. A Python MCP request and Gateway tool-call audit are distinct evidence sources.
22. Structured stdout MUST remain consumable by OpenShift cluster logging and SIEM forwarding without a new ingestion service. Retention, backend delivery, and search latency belong to deployment logging facilities; this work provides no new persistence or latency SLA. Support follows the product's applicable OCP 4.x TP and 5.0 GA deployments, including restricted environments with no external logging backend. This does not change component/version availability or enable the agentic product on an otherwise unsupported OCP release.

## Coverage and Acceptance

23. Each child implementation MUST maintain a client/transport inventory with tests demonstrating that every in-scope application route is covered. Generic HTTP hooks alone are not proof of SDK retry, gRPC, or cloud credential coverage. Missing in-scope route coverage is an implementation gap; missing Kubernetes API instrumentation is not, because that traffic is explicitly excluded.
24. Required verification includes: synchronous/asynchronous success; HTTP errors; DNS/connect/TLS/timeout failures; redirects and retries; overlapping hooks; concurrent context isolation; streaming EOF/early close/error/cancellation; startup requests without conversation/run metadata; audit on/off; trace sampling and endpoint independence; and audit-logger failure isolation.
25. Leakage tests MUST plant distinct sentinel secrets in prompts, URL userinfo/path/query/fragment, headers, request/response bodies, MCP arguments/results, raw errors, and personal identities. Parse the new outbound records and assert none occurs anywhere in the serialized record. Existing content-bearing compliance streams are tested separately and MUST NOT be globally disabled or redacted to make this check pass.
26. Negative tests MUST show that shell/oc execution is not represented as a Python-observed outbound request and that excluded Kubernetes API calls do not enter the application audit stream, even when they share transport libraries with instrumented clients. Deployment checks MUST validate JSON parsing and source-pod enrichment through the supported cluster logging path; absence of comprehensive network visibility must be documented.

## Ownership and Child Specifications

| Repo | Responsibility | Specification |
| --- | --- | --- |
| lightspeed-service | Classic application request hooks, safe log emission, context isolation, provider/MCP/retrieval and SDK credential coverage | Child `.ai/spec/what/outbound-request-audit.md` |
| lightspeed-agentic-sandbox | Application Python/SDK request hooks, batch/run correlation, credential/MCP/provider coverage; Kubernetes Result publication excluded | Child `.ai/spec/what/outbound-request-audit.md` |
| lightspeed-operator / lightspeed-agentic-operator | Existing audit configuration and run-correlation handoff remain unchanged | Existing deployment/audit contracts; no new API or component |
| Cluster logging administrators | Source workload enrichment, collection, retention, SIEM forwarding | Existing platform facilities; no new SLA |

## References

- [Compliance audit logging](audit-logging.md) — separate content-bearing compliance records.
- [Agentic product data collection](agentic-data-collection.md) — independent trace export/content contracts.
- [Operand network policies](operand-network-policies.md) — policy ownership is not an observed request outcome.
- [OLS-4192](https://redhat.atlassian.net/browse/OLS-4192) — Python instrumentation.
- [OLS-4848](https://redhat.atlassian.net/browse/OLS-4848) — potential complementary sandbox subprocess network observation.
