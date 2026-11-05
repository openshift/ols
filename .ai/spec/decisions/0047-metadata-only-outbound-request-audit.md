# 0047: Metadata-Only Python Outbound Request Audit

**Status:** Proposed — OLS-4192; specification only, pending implementation and review.
**Applies to:** lightspeed-service, lightspeed-agentic-sandbox

## Context

Operators need safe destination and outcome evidence for outbound requests without including prompts, bodies, credentials, or personal identities. Existing compliance spans intentionally retain content and, for Classic, user identity. Copying those spans into an outbound audit stream would violate its privacy boundary. Python request hooks cannot comprehensively observe skill subprocesses such as oc.

## Decision

Add an explicitly allowlisted, versioned JSON stdout record stream for Python application/SDK transport attempts, defined in [outbound-request-audit.md](../what/outbound-request-audit.md). Emit start and finish records correlated by attempt ID and valid OTel context, independently of trace sampling and endpoint availability while existing compliance audit is enabled. Capture SDK-specific transports/retries as well as shared HTTP clients. Never classify an observed transport failure as an egress-policy denial without such evidence; policy-denial detection is not required here.

This is a narrowly scoped exception to [ADR 0026](0026-audit-logging-design.md)'s span-only/custom-format prohibition, not a change to its content-bearing compliance evidence or exporters. New logs MUST NOT be derived by copying those evidence spans. Existing content policies, audit gates, product collection, Gateway audit, and operator APIs remain unchanged.

The stream covers application-level LLM, remote MCP, retrieval, and their SDK credential exchanges, not every request made by a Python library. Kubernetes API request auditing, including Classic authentication reviews and sandbox Result CR publication, is excluded as a separate infrastructure concern. Missing Kubernetes instrumentation is therefore not an implementation gap for OLS-4192.

Subprocess connections and network observers are explicitly excluded and tracked separately in OLS-4848. That follow-up may observe connections also used by Kubernetes Python clients, but does not promise equivalent API request-level auditing. Python instrumentation has no new deployment dependency and makes no comprehensive sandbox-network or five-second-searchability claim.

## Alternatives Considered

- **Reuse existing content-bearing compliance spans as records:** rejected because sensitive content and personal identities can enter the new stream; sampling and span-end timing also differ from attempt logging.
- **Instrument model/tool callbacks only:** rejected because callbacks do not identify transport requests, internal retries, credential traffic, or subprocess connections.
- **Require a network observer or audited proxy now:** deferred to OLS-4848 because it changes deployment requirements and cannot replace application request context.

## Consequences

- Operators can select metadata-only records independently of full-fidelity compliance evidence.
- A shared schema and per-repo coverage inventory must be maintained and tested.
- stdout contains an additional, distinguishable JSON record type; ingestion must select records by event/schema, not assume every JSON line is a compliance span.
- Source workload identity comes from logging enrichment. Run/request identity comes from validated non-personal correlation metadata.
- Unmatched start records can remain after abrupt process death; durable delivery and backend latency are not promised.
- Request metadata and network-level evidence may eventually overlap; they remain distinct sources, not interchangeable counts.
