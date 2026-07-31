# 0016: MCP App Iframe Sandboxing

**Status:** Accepted
**Applies to:** lightspeed-console, lightspeed-service

## Context

MCP Apps can return interactive HTML UIs rendered alongside chat responses. This HTML comes from external MCP servers and cannot be trusted. Loading untrusted HTML directly into the console plugin's DOM would create XSS and data exfiltration risks.

## Decision

MCP App interactive UIs are loaded into sandboxed iframes (`allow-scripts` only) with bidirectional JSON-RPC 2.0 communication over `postMessage`. The sandbox restriction prevents the iframe from accessing the parent console's DOM, cookies, or APIs.

## Alternatives Considered

- **Render HTML directly in DOM** — rejected because of XSS risk from untrusted MCP server content
- **Server-side rendering with sanitization** — rejected because it breaks interactive features that require JavaScript
- **No interactive UI** — rejected because it limits MCP App capabilities; some tools need rich visualization

## Consequences

- Security isolation for third-party HTML content
- Iframe can run JavaScript but cannot access parent context
- JSON-RPC 2.0 provides structured bidirectional communication
- MCP Apps can implement rich visualizations within sandbox constraints
- Some browser APIs unavailable in sandboxed iframes
