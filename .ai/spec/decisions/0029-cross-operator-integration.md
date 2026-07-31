# 0029: Cross-Operator Integration

**Status:** Accepted
**Applies to:** lightspeed-operator, lightspeed-agentic-operator

## Context

Two operators share the same namespace but reconcile different API groups. Agentic-operator had duplicated pod spec construction code (PodSpecBuilder and EnsureAgentTemplate each independently implementing LLM env var injection, MCP wiring, skills mounting, audit env vars, probes, and security context). Lightspeed-operator already has production-grade reconciliation, image management, status reporting, and disconnected support via related_images.json.

## Decision

Agentic operands (alerts-adapter, agentic-console-plugin) are deployed by lightspeed-operator, not agentic-operator. Inter-operator communication uses a ConfigMap-based handoff: lightspeed-operator builds a base PodSpec for sandbox pods and serializes it into `lightspeed-sandbox-config` ConfigMap; agentic-operator reads and overlays per-run specifics. If the ConfigMap is missing after bounded retries, agentic-operator fails hard with no fallback.

## Alternatives Considered

- **Agentic-operator deploys its own operands** — rejected because the fire-and-forget RunnableFunc pattern had no reconciliation loop, no related_images.json, no status reporting, no CRD deployment config, and no cleanup
- **Duplicate pod spec construction** — rejected because of maintenance burden and divergence risk between the two code paths

## Consequences

- Single overlay code path in agentic-operator
- Mode (bare-pod vs sandbox-claim) determines delivery only after PodSpec is fully built
- Lightspeed-operator owns all infrastructure knowledge
- Fail-hard ensures misconfigurations are caught early
- No backward compatibility with old self-contained pod spec building
- Both operators must be running for the system to function
