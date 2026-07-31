# 0023: Alerts Adapter Design

**Status:** Accepted
**Applies to:** lightspeed-agentic-alerts-adapter

## Context

The adapter bridges AlertManager firing alerts into the agentic system. Resilience requirements demand that when the adapter restarts, the next poll immediately sees all firing alerts (webhooks would miss events during downtime). Statefulness would require persistence infrastructure. Create-only simplifies the design — the agentic-operator owns the full lifecycle from creation.

## Decision

The alerts-adapter polls AlertManager's `GET /api/v2/alerts` endpoint (not webhooks), maintains no internal state (fresh diff between AlertManager and Kubernetes API each cycle), and only creates AgenticRun CRs (never modifies or deletes them). Deduplication uses deterministic naming from alert metadata (alertname + namespace + 8-char SHA-256 hash of startsAt). Each firing alert maps to exactly one AgenticRun (1:1 cardinality, no grouping).

## Alternatives Considered

- **Webhooks** — rejected because of missed events during adapter downtime and requirement for AlertManager configuration changes
- **Stateful adapter with database** — rejected because it adds operational complexity for state that can be reconstructed from AlertManager and Kubernetes APIs
- **Alert grouping** — rejected and deferred to future work based on real-world usage patterns
- **Adapter manages full lifecycle** — rejected because it violates separation of concerns and duplicates operator logic

## Consequences

- Restarts, upgrades, and pod rescheduling are inherently safe
- Concurrent replicas handle race conditions via 409 AlreadyExists (treated as success)
- FNV-64a fingerprint with configurable ignored labels enables stable deduplication
- Polling interval and cooldown windows are configurable
