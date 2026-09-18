# 0030: Observability Architecture

**Status:** Accepted
**Applies to:** lightspeed-otel-collector, lightspeed-agentic-operator, lightspeed-agentic-sandbox

## Context

No standard OTel exporter writes templog records to PostgreSQL in the required per-run queryable format. A single trace spanning hours or days (waiting for human approval) is pathological for trace backends that expect traces in the seconds-to-minutes range. Per-phase traces have natural start/end times. The Collector supports optional trace export and the independent templog/PostgreSQL pipeline; PostgreSQL is not part of Agentic product data collection.

## Decision

A custom OpenTelemetry Collector is built with OCB (OpenTelemetry Collector Builder) containing only needed components, including a custom `postgresexporter` for templog storage and `postgresadmin` extension for HTTP-based log retrieval. Agentic observability uses one trace per workflow phase rather than one lifecycle trace; literal span-attribute correlation and Span Links connect phases. Current batch propagation is defined by `../what/audit-logging.md` and `../what/agentic-data-collection.md`.

## Alternatives Considered

- **Standard OTel collector with existing exporters** — rejected because no PostgreSQL exporter meets the per-run query requirement
- **Single lifecycle trace** — rejected because it is pathological for trace backends
- **Custom correlation outside OTel** — rejected because it reinvents trace correlation when OTel already supports Span Links
- **Sidecar log shipper** — rejected because it does not provide structured per-run query capability

## Consequences

- Custom collector is purpose-built and minimal
- File-backed queues and files survive a Collector process restart only while their pod-local volume remains; they are not durable across pod replacement
- Templog has a PostgreSQL startup dependency; unrelated trace pipelines and Agentic product collection do not
- Per-phase traces render well in trace UIs
- `agenticrun.uid` is the cross-trace correlation key
- All external channels use TLS
