# 0030: Observability Architecture

**Status:** Accepted
**Applies to:** lightspeed-otel-collector, lightspeed-agentic-operator, lightspeed-agentic-sandbox

## Context

No standard OTel exporter writes to PostgreSQL in the required per-run queryable format. A single trace spanning hours or days (waiting for human approval) is pathological for trace backends that expect traces in the seconds-to-minutes range. Per-phase traces have natural start/end times. The collector needs to support both OTLP export and temporary PostgreSQL storage.

## Decision

A custom OpenTelemetry Collector is built with OCB (OpenTelemetry Collector Builder) containing only needed components, including a custom `postgresexporter` for audit log storage and `postgresadmin` extension for HTTP-based log retrieval. Per-phase OTel traces (one trace per workflow phase, not one per lifecycle) are linked by `agentic_run.uid` span attribute and OTel Span Links. W3C `traceparent` header propagates traces between operator and sandbox.

## Alternatives Considered

- **Standard OTel collector with existing exporters** — rejected because no PostgreSQL exporter meets the per-run query requirement
- **Single lifecycle trace** — rejected because it is pathological for trace backends
- **Custom correlation outside OTel** — rejected because it reinvents trace correlation when OTel already supports Span Links
- **Sidecar log shipper** — rejected because it does not provide structured per-run query capability

## Consequences

- Custom collector is purpose-built and minimal
- File-backed sending queue survives pod restarts
- Hard dependency on PostgreSQL at startup (fail-fast, no accepting data that will fail on INSERT)
- Per-phase traces render well in trace UIs
- `agentic_run.uid` is the cross-trace correlation key
- All external channels use TLS
