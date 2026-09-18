# 0042 — Agentic Data Collection via OTLP Traces

## Status

Accepted for planned implementation under OLS-3569.

## Context

Agentic OLS needs product-analysis data for adoption, outcomes, model/tool behavior, and complete ordered transcripts. Agentic applications already produce correlated OTLP traces. Classic OLS has an existing, separate transcript-file exporter path.

The ownership boundary must avoid three failure modes:

1. application-owned product files would duplicate transport and filesystem behavior across Go and Python producers;
2. Collector-owned run reconstruction or logical models would add stateful joins and couple analytical schema changes to cluster releases; and
3. using OTLP logs would mix product collection with the templog/PostgreSQL contract.

## Decision

Agentic product collection reuses OTLP traces only. Producers emit complete provider-neutral, run-correlated trace atoms through the existing Collector endpoint. The Collector performs only mechanical eligibility, classification, raw projection, and ready-file staging. A separate Agentic instance of the existing Dataverse exporter uploads those ready files unchanged. Dataverse owns deduplication and all logical Actions and Transcripts transformations.

The existing transcript opt-out and telemetry credentials govern Agentic staging and upload without exposing collection state to Agentic producers. The Classic exporter path and all existing compliance, templog/PostgreSQL, and trace-backend paths remain unchanged.

The normative interface, enablement, loss semantics, and repository ownership are defined only in `../what/agentic-data-collection.md`.

## Consequences

- Agentic applications retain one telemetry transport and never write collection files.
- The Collector has no run reconstruction, action aggregation, Dataverse schema, SQL/dbt, or upload responsibility.
- Dataverse can revise logical joins and models without an OLS cluster release.
- Full-fidelity transcript content, reasoning, operational CR payloads, and secrets may be collected; opt-out and downstream governance are the policy controls.
- The dedicated `emptyDir` is retry buffering, not durable retention; pod replacement can lose unsent data, and ambiguous upload outcomes can cause downstream-deduplicated delivery.
- OTLP logs and PostgreSQL retain their templog ownership and lifecycle.
- The existing Classic app-server exporter remains a separate, unchanged instance.

## Rejected Alternatives

### Direct application filesystem writes

Rejected because it creates a second data path in each producer and spreads staging/upload concerns across components.

### Collector-built logical Actions and Transcripts

Rejected because run reconstruction, tool pairing, outcome derivation, deduplication, and aggregation belong in the Dataverse layer.

### Raw traces without a candidate interface

Rejected because the existing exporter needs an ingestible ready-file boundary. Mechanical atom classification and raw projection preserve the desired ownership split without logical modeling.

### OTLP logs as a product source

Rejected because logs are the templog transport and may contain bridged or duplicated application logging. Product collection is trace-only.
