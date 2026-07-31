# 0022: Sandbox Isolation

**Status:** Accepted
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-sandbox

## Context

Agent code (LLM interactions, tool execution, cluster commands) must be isolated from the operator for security. A shared ServiceAccount was found to cause cross-run permission leakage (confirmed vulnerability). Per-run SAs with per-run Roles ensure least-privilege isolation.

## Decision

Agent code runs in sandboxed ephemeral pods, not in the operator process. Each AgenticRun gets a dedicated ServiceAccount (`ls-exec-{namespace}-{run-name}`) for execution phases. Two sandbox modes are supported: `bare-pod` (default, no CRD dependencies) and `sandbox-claim` (uses Agent Sandbox API CRDs).

## Alternatives Considered

- **In-process agent execution** — rejected because there is no security isolation from the operator
- **Shared SA with per-run Roles** — rejected because of confirmed vulnerability with cross-run permission leakage
- **WebAssembly sandbox** — rejected because it needs full kubectl/oc tooling access
- **Namespace-per-run isolation** — rejected because namespace creation/deletion overhead is too high

## Consequences

- Each run gets isolated RBAC via dedicated ServiceAccount and Role
- Ephemeral pods are automatically cleaned up
- Per-run SA requires cross-namespace finalizer cleanup (Kubernetes owner refs do not work cross-namespace)
- Bare-pod mode works without Sandbox API CRDs
- Sandbox wraps multiple LLM SDKs behind a unified `/v1/agent/run` HTTP endpoint
- Generic env vars (`LIGHTSPEED_PROVIDER`, `LIGHTSPEED_MODEL`) are mapped to SDK-specific vars inside the sandbox
