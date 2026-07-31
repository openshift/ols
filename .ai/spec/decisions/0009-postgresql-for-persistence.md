# 0009: PostgreSQL as Single Persistence Backend

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator, lightspeed-otel-collector

## Context

Multiple persistence needs exist across the product: conversation history for multi-turn Q&A, per-user quota tracking for rate limiting, and temporary audit log storage for customers without external log aggregation. Running separate data stores for each concern would increase operational burden for cluster admins deploying OLS.

## Decision

PostgreSQL serves as the single persistence backend for conversation cache, quota state, and temporary audit log storage. The operator handles PostgreSQL deployment and TLS configuration. An in-memory cache option remains available for development and single-replica scenarios.

## Alternatives Considered

- **Redis for cache** — rejected because it adds another system to manage and lacks the SQL query capability needed for audit log queries.
- **Separate database per concern** — rejected due to operational overhead of deploying, monitoring, and backing up multiple database instances.
- **Embedded SQLite** — rejected because it doesn't support multi-replica access with proper locking, which is required for production Kubernetes deployments.

## Consequences

- Single database to deploy, manage, and monitor
- Operator handles PostgreSQL deployment and TLS (always service-CA with SSL mode `require`)
- Advisory locks provide safe concurrent access in multi-replica deployments
- Templog reuses the same PostgreSQL instance rather than introducing new infrastructure
