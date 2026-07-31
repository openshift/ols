# 0004: Operator Deployment Model

**Status:** Accepted
**Applies to:** lightspeed-operator

## Context

A single management plane for the entire deployment ensures consistent lifecycle management (upgrades, restarts, health monitoring). The OLSConfig CR is the single source of truth. Singleton CRs prevent conflicting configurations. Two-phase reconciliation allows independent resources to partially succeed while ensuring deployment status reflects the real state.

## Decision

The lightspeed-operator deploys and manages ALL components: service, console plugin, PostgreSQL, alerts adapter, agentic console plugin, OTel collector, MCP server, and RHOKP. No component self-deploys. Both `OLSConfig` and `ApprovalPolicy` are cluster-scoped singleton CRs named "cluster". Reconciliation follows a two-phase pattern: Phase 1 creates independent resources (continue-on-error), Phase 2 creates deployments and updates status conditions (fail-fast on pod failures).

## Alternatives Considered

- **Separate operator per component** — rejected because of operational overhead and no unified lifecycle
- **Helm charts** — rejected because of no reconciliation loop and no self-healing
- **Manual deployment** — rejected because it is error-prone with no lifecycle management
- **Multiple CR instances with merge semantics** — rejected because of conflict resolution complexity

## Consequences

- Single OLSConfig CR drives entire deployment
- Component-based modular architecture within the operator (each component has its own reconciliation package)
- Finalizer ensures cleanup of cluster-scoped resources (ConsolePlugin CRs, cross-namespace RoleBindings, PVCs)
- All container images managed via related_images.json for disconnected support
