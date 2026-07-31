# 0002: FastAPI with Single Uvicorn Worker

**Status:** Accepted
**Applies to:** lightspeed-service

## Context

The core backend manages a process-global singleton config (AppConfig) with lazy-initialized subsystems including cache, RAG index, quota tracking, and tool registry. Multi-worker deployment would require shared-state coordination across processes for these singletons. The service needs to handle concurrent requests efficiently while keeping the deployment model simple.

## Decision

The lightspeed-service uses Python/FastAPI with a single Uvicorn worker process. Concurrency is handled via async within the single process, and horizontal scaling is achieved through multiple Kubernetes pod replicas rather than multiple workers per pod.

## Alternatives Considered

- **Multi-worker Uvicorn** — rejected because the singleton AppConfig pattern is process-local; introducing shared state across workers adds complexity without benefit since async already handles concurrent I/O.
- **Go service** — rejected because the Python ecosystem is required for LangChain, ML models, and embedding libraries that form the core of the LLM integration pipeline.

## Consequences

- Async I/O handles concurrent requests within a single process
- Horizontal scaling via Kubernetes replicas rather than multiple workers
- Simpler deployment model with no inter-worker coordination
- AppConfig is always consistent within a process — no shared-state bugs
