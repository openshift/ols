# 0026: Audit Logging Design

**Status:** Accepted (design complete; rollout incremental — OLS-3493, OLS-3696)
**Applies to:** lightspeed-service, lightspeed-agentic-sandbox, lightspeed-agentic-operator, lightspeed-otel-collector

## Context

Compliance regulations (EU AI Act) require complete audit trails of AI system behavior. Partial logging or configurable verbosity defeats the compliance purpose. Application loggers must not re-emit data that appears in spans (prevents double-counting and inconsistency). Console actions are captured at the API/CR layer, making console-side emission redundant.

## Decision

Audit logging uses OpenTelemetry aligned with GenAI Semantic Conventions v1.41, with single-emission dual-destination: each audit datum is recorded once as an OTel span/event, with two exporters (stdout OTLP JSON and OTLP to tracing backend) producing two views. Stdout is the compliance record with no truncation. Full fidelity is mandatory — every LLM turn, tool call, and thinking block is recorded. No audit redaction is performed (redaction is an input concern, not a logging concern). Console plugins do not emit audit events. The design targets EU AI Act compliance.

## Alternatives Considered

- **Custom logging format** — rejected because it is non-standard with no ecosystem tooling
- **Configurable verbosity levels** — rejected because it defeats the compliance purpose
- **Output redaction** — rejected because if PII reaches the LLM, it was already a failure at the input redaction layer; the audit record must be complete
- **Vendor-specific APM** — rejected because of lock-in and non-standard interfaces
- **Console-side event emission** — rejected because it creates dual-sourcing of audit data

## Consequences

- Clean cut on naming: all custom attribute names removed, only OTel GenAI standard names (exception: `ols_*` Prometheus metrics kept for backward compatibility)
- Full CR content is serialized as span events, not span attributes (which have size constraints)
- OTel tracing backend is optional but stdout is always on
- Application loggers only emit developer-debugging messages
