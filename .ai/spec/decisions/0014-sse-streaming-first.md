# 0014: SSE Streaming as Primary Query API

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-console

## Context

LLM responses are latency-sensitive — users expect progressive rendering as tokens are generated. Streaming also enables the tool approval workflow where the service pauses mid-stream to request user confirmation before executing agentic actions. A non-streaming endpoint exists but is being deprecated (OLS-2682).

## Decision

Server-Sent Events (SSE) streaming is the primary query API. The non-streaming endpoint is deprecated and planned for removal. All new features (tool approval, progressive rendering, status events) are built on the streaming path only.

## Alternatives Considered

- **WebSocket** — rejected because the communication pattern is unidirectional (server-to-client token stream) and WebSocket's bidirectional complexity is unnecessary; connection management is also more complex.
- **gRPC streaming** — rejected because browser clients cannot use gRPC natively, and the console plugin needs direct access.
- **Polling** — rejected because it introduces unacceptable latency for token-by-token display and wastes resources on repeated requests.

## Consequences

- Console processes SSE events in real-time for progressive token rendering
- Tool approval workflow only works with the streaming endpoint
- Non-streaming endpoint planned for removal to reduce API surface
- SSE is HTTP/1.1-compatible and works through the console plugin proxy without special configuration
