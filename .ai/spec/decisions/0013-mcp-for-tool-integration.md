# 0013: MCP for External Tool Integration

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator, lightspeed-agentic-sandbox

## Context

OLS needs extensible tool capabilities — cluster introspection, documentation search, custom admin tools — that must be independently deployable and upgradable without rebuilding the service. A standard protocol is needed so that the tool ecosystem can grow without tight coupling to the service's internals.

## Decision

Use Model Context Protocol (MCP) as the standard protocol for external tool integration. Tools are external processes with independent lifecycles, managed by the operator, communicating with the service over HTTP/SSE transport.

## Alternatives Considered

- **Native tool implementations compiled into the service** — rejected because it requires a service rebuild and redeployment for each new tool, tightly coupling tool development to the service release cycle.
- **OpenAI function calling with custom protocol** — rejected because it is non-standard with no ecosystem support, and would require building proprietary tooling for discovery, transport, and lifecycle management.
- **gRPC tool protocol** — rejected because MCP has broader ecosystem adoption and simpler HTTP/SSE transport that works through existing proxies and load balancers.

## Consequences

- Tools are external processes with independent lifecycles and deployment
- Operator manages MCP server deployments alongside the service
- Three MCP header resolution modes (kubernetes token, client-provided, file path) provide flexible auth for different deployment scenarios
- MCP Apps can bypass the LLM pipeline for direct tool invocation
