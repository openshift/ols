# 0001: LangChain as Unified LLM Interface Layer

**Status:** Accepted
**Applies to:** lightspeed-service

## Context

OLS supports multiple LLM backends (OpenAI, Azure OpenAI, WatsonX, RHEL AI/vLLM, Bedrock, Vertex AI, and others), each with different APIs, authentication mechanisms, and capabilities. Without a unified abstraction, the query pipeline would need per-provider code paths for streaming, tool calling, retry logic, and response parsing.

## Decision

Use LangChain as the unified LLM interface layer across all 8+ provider types. Provider-specific logic is isolated to thin adapter modules that register via decorator, while the core query pipeline operates against LangChain's standard interfaces.

## Alternatives Considered

- **Direct SDK integration per provider** — rejected because it would duplicate streaming, tool-calling, and retry logic for each provider, leading to inconsistent behavior and high maintenance cost.
- **OpenAI-compatible API only** — rejected because not all providers expose OpenAI-compatible endpoints, especially WatsonX and RHEL AI, which would be excluded.

## Consequences

- Provider-specific logic isolated to thin adapter modules
- New providers added via decorator registration without modifying the core pipeline
- Dependency on LangChain release cycle and API stability
- Occasional need for subclasses when LangChain doesn't support provider-specific features (e.g., vLLM reasoning token handling)
