# 0005: Plugin Proxy API Calls

**Status:** Accepted
**Applies to:** lightspeed-console, lightspeed-agentic-console

## Context

OpenShift console plugins run in the browser but need to reach backend services. Direct browser-to-service connections face CORS restrictions, require separate TLS certificate handling, and bypass the console's authentication flow.

## Decision

All OLS API calls from the console plugins go through the OpenShift console's built-in plugin proxy (`/api/proxy/plugin/lightspeed-console-plugin/ols/`). No direct connections from browser to OLS service.

## Alternatives Considered

- **Direct API access with CORS headers** — rejected because it requires CORS configuration, bypasses console auth, and adds TLS complexity
- **Ingress Route** — rejected because it exposes OLS service directly and requires additional RBAC/auth
- **Service mesh sidecar** — rejected because it is heavyweight for a simple proxy need

## Consequences

- Console proxy handles authentication (passes user token), TLS termination, and routing
- No CORS issues; plugins are truly browser-only (no direct backend access)
- All API calls inherit console session authentication
- CLI (oc-ols) cannot use this path (requires admin-created Route + user-configured endpoint)
