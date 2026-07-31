# 0036: RHOKP Standalone Deployment

**Status:** Accepted
**Applies to:** lightspeed-operator, lightspeed-service

## Context

The sidecar pattern has multiple limitations: ~75 GiB ephemeral storage bloats the app-server pod; sidecar's stock ports conflict with MCP server and app-server HTTPS requiring port remapping; no TLS (plain HTTP within pod); no external consumers can reach it (only the colocated app-server); agentic sandbox pods cannot access OKP content.

## Decision

RHOKP (Red Hat OpenShift Knowledge Proxy) moves from an app-server sidecar to a standalone Deployment with its own Service, following the ocp-mcp standalone HTTPS pattern. The sidecar is removed.

## Alternatives Considered

- **Keep sidecar** — rejected because of storage bloat, port conflicts, no TLS, and no external access
- **Shared PVC** — rejected because RHOKP needs an HTTP API, not just file access
- **DaemonSet** — rejected because of unnecessary resource consumption on every node

## Consequences

- RHOKP gets its own Service with TLS
- Other pods (including agentic sandbox) can access OKP content
- CRD field changes from `ContainerConfig` (resources only) to `Config` (replicas, resources, tolerations, nodeSelector)
- Backward-compatible — existing CRs with only `resources` still work
- Eliminates 75 GiB ephemeral storage from app-server pod
