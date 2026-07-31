# 0012: Disconnected Operation

**Status:** Accepted
**Applies to:** all repos

## Context

Enterprise customers in regulated industries (government, financial, healthcare) operate air-gapped clusters with no internet access. The product must function in these environments.

## Decision

All OLS features must work without internet access, provided the LLM provider is reachable (which may be on-premise). Container images are available via disconnected registries. No external service dependencies at runtime.

## Alternatives Considered

- **Internet-required features with graceful degradation** — rejected because air-gapped customers would get a degraded product
- **Online-only deployment mode** — rejected because it excludes a significant customer segment

## Consequences

- RAG content and embedding models shipped in container images (not downloaded at runtime)
- Operator manages images via `related_images.json` for mirroring
- No telemetry phoning home
- LLM provider must be reachable but can be on-premise (RHEL AI/vLLM)
- All MCP tools must function without internet
- Affects every new feature — must always consider the disconnected case
