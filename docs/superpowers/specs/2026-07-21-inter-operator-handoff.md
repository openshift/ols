# Inter-Operator Configuration Handoff

**Feature Request:** [OLS-3572](https://redhat.atlassian.net/browse/OLS-3572)
**Date:** 2026-07-21
**Status:** Draft
**Related:** [OLS-3526](https://redhat.atlassian.net/browse/OLS-3526) (standalone HTTPS ocp-mcp), [OLS-3594](https://redhat.atlassian.net/browse/OLS-3594) (ocp-mcp auto-injection), [OLS-3443](https://redhat.atlassian.net/browse/OLS-3443) (MCP server connectivity), [OLS-3697](https://redhat.atlassian.net/browse/OLS-3697) (standalone HTTPS RHOKP)

## Problem

The lightspeed-operator manages cluster infrastructure — container images, MCP server deployment, TLS certificates, OTEL collector — that agentic sandbox pods need to consume. The lightspeed-agentic-operator creates those sandbox pods but has no mechanism to learn about this managed infrastructure. The two operators share the same OLM bundle and namespace but have no runtime interaction (system-overview rule 5). They reconcile different API groups (`ols.openshift.io` vs `agentic.openshift.io`).

Additionally, the agentic operator currently has two separate code paths for pod spec construction: `PodSpecBuilder` (typed `corev1.PodSpec` for bare-pod mode) and `EnsureAgentTemplate` (unstructured map patches for sandbox-claim mode). Every new config injection must be implemented twice, making the handoff problem harder than it needs to be.

## Approach: ConfigMap-Based Handoff with Base PodSpec

The lightspeed-operator owns all infrastructure knowledge and builds a base `corev1.PodSpec` for sandbox pods. This PodSpec — along with metadata — is serialized into a well-known ConfigMap. The agentic operator reads the ConfigMap, overlays per-run specifics, and delivers the result as either a bare Pod or a SandboxTemplate.

### 1. OLSConfig CRD Extension

A new `spec.agenticOLS` section is added to the `OLSConfig` CRD, parallel to `spec.ols`:

```yaml
spec:
  ols:
    # existing classic OLS config...
  agenticOLS:
    sandboxMode: "bare-pod"   # "bare-pod" (default) or "sandbox-claim"
```

This section is the home for agentic-specific configuration that the classic operator needs to know about. `sandboxMode` replaces the agentic operator's `--sandbox-mode` startup flag — the mode is now controlled via CRD rather than process arguments.

### 2. ConfigMap Contract

The lightspeed-operator creates and maintains a ConfigMap during reconciliation:

**Name:** `lightspeed-sandbox-config`
**Namespace:** operator namespace (`openshift-lightspeed`)
**Owner:** lightspeed-operator (owner reference to OLSConfig CR)

| Key | Type | Description |
|---|---|---|
| `sandbox-pod-spec` | JSON | Serialized `corev1.PodSpec` — sandbox container image, infrastructure env vars (`OTEL_EXPORTER_OTLP_ENDPOINT`), CA cert volumes + volume mounts, resource defaults. Everything the sandbox pod needs from infrastructure is baked in. |
| `sandbox-mode` | string | `bare-pod` or `sandbox-claim` — from `OLSConfig.spec.agenticOLS.sandboxMode` |
| `mcp-endpoint` | string | MCP server endpoint URL. Present when ocp-mcp is deployed as a standalone HTTPS service. Used by the agentic operator to construct `LIGHTSPEED_MCP_SERVERS` entries when merging with per-run MCP servers. |
| `otel-endpoint` | string | OTEL collector gRPC endpoint. Informational (already set as env var in PodSpec). Present when templog collector is deployed. |
| `rhokp-endpoint` | string | [PLANNED: OLS-3697] RHOKP Solr HTTPS endpoint URL (`https://lightspeed-rhokp.<ns>.svc:8443`). Present when OKP is enabled (`!byokRAGOnly`). |

The ConfigMap is **always created** by the lightspeed-operator. Keys are absent when the corresponding feature is not enabled (e.g., `mcp-endpoint` absent when ocp-mcp is not deployed, `otel-endpoint` absent when templog is not deployed). The `sandbox-pod-spec` key is always present.

### 3. Base PodSpec Contents (Built by Classic Operator)

The lightspeed-operator builds the base `corev1.PodSpec` containing:

| Component | Source | In PodSpec as |
|---|---|---|
| Sandbox container image | `--agentic-sandbox-image` flag / related-images.json | Container image field |
| OTEL endpoint | Templog OTel collector service | `OTEL_EXPORTER_OTLP_ENDPOINT` env var |
| MCP CA certificate | Service-CA cert for ocp-mcp service | Volume + VolumeMount (CA bundle mounted directly) |
| RHOKP CA certificate | [PLANNED: OLS-3697] Service-CA cert for RHOKP service | Volume + VolumeMount (CA bundle mounted directly) |
| Resource defaults | Operator defaults (per OpenShift resource conventions) | Container resources |

The base PodSpec does NOT include per-run config — that is the agentic operator's responsibility.

### 4. Agentic Operator: Consumer

The agentic operator reads the ConfigMap and uses it as the foundation for all sandbox pod creation.

#### Reading the ConfigMap

1. On startup and on watch events, read `lightspeed-sandbox-config` ConfigMap.
2. Deserialize `sandbox-pod-spec` into typed `corev1.PodSpec`.
3. Read `sandbox-mode` to determine delivery mode.
4. Cache the base PodSpec and mode for use during run reconciliation.

#### Fail-Hard on Missing ConfigMap

If the ConfigMap is not found:
- Retry with backoff (bounded retries, e.g. 24 retries with 5s backoff — same pattern as Solr startup retries).
- If still not found after timeout, **fail the run** with a clear error: `"lightspeed-sandbox-config ConfigMap not found — lightspeed-operator must be installed and reconciled"`.
- **No fallback** to self-built pod specs. The classic operator is a hard prerequisite. No backward compatibility with the old self-contained pod spec building.

#### Per-Run Overlay

For each `AgenticRun`, the agentic operator overlays per-run config onto the base PodSpec:

| Config | Source | Applied as |
|---|---|---|
| LLM env vars | `Agent` + `LLMProvider` CRs | Env vars per sandbox-execution rule 16a |
| LLM credentials | `LLMProvider.spec.*.credentialsSecret` | `envFrom` + volume mount at `/var/run/secrets/llm-credentials/` |
| Per-run MCP servers | `ToolsSpec.mcpServers` | Merged into `LIGHTSPEED_MCP_SERVERS` env var (alongside any base MCP servers from ConfigMap) |
| Skills | `ToolsSpec.skills` | OCI image volumes |
| Required secrets | `ToolsSpec.requiredSecrets` | Env vars or file mounts per `SecretMountSpec` |
| Service account | Per-run SA (execution) or shared SA (analysis/verification) | PodSpec.serviceAccountName |
| Probes | Readiness + liveness | Container probes |
| Reasoning config | `Agent.spec.reasoningConfig` | `LIGHTSPEED_REASONING_CONFIG` env var |
| Audit config | `AgenticOLSConfig` | `LIGHTSPEED_AUDIT_ENABLED`, `LIGHTSPEED_CAPTURE_CONTENT` env vars |

#### Single Overlay Path, Mode-Specific Delivery

All per-run configuration (LLM env vars, credentials, MCP servers, skills, required secrets, service account, probes, reasoning config, audit env vars) is applied to the PodSpec through a **single code path**. There are not two parallel implementations — one overlay function produces the final PodSpec, and only then does the mode determine delivery:

- **Bare-pod mode** (`sandbox-mode: bare-pod`): Create a `Pod` directly from the completed PodSpec.
- **Sandbox-claim mode** (`sandbox-mode: sandbox-claim`): Convert the completed PodSpec into a `SandboxTemplate`.

The decision between bare-pod and sandbox-claim happens **after** the PodSpec is fully built — not before. This eliminates the current duplication where `PodSpecBuilder` and `EnsureAgentTemplate` each independently implement LLM env var injection, MCP wiring, skills mounting, audit env vars, probes, and security context.

### 5. OTEL Support for Agentic Sandbox

OTEL support is a natural consumer of the handoff:

1. **lightspeed-operator** deploys the OTel collector (templog, per `AgenticOLSConfig.spec.templog`) and includes `OTEL_EXPORTER_OTLP_ENDPOINT` as an env var in the base PodSpec.
2. **agentic operator** reads the base PodSpec — OTEL env var is already present. No agentic-operator-side OTEL logic needed.
3. **Sandbox pod** starts with `OTEL_EXPORTER_OTLP_ENDPOINT` set, tracing spans flow to the collector.

When OTEL is not configured (collector not deployed), the env var is absent from the base PodSpec and sandbox tracing is no-op.

### 6. Watch and Reconciliation

- The agentic operator adds a watch on the `lightspeed-sandbox-config` ConfigMap (same pattern as existing `ApprovalPolicy` and `AgenticOLSConfig` watches).
- When the ConfigMap changes (new image, cert rotation, OTEL endpoint change, sandbox mode change), the agentic operator invalidates its cached base PodSpec and re-reconciles. New pods/templates use the updated base. Existing pods are not affected (they retain their config until replaced).

### 7. Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ OLSConfig CR                                                 │
│                                                              │
│  spec:                                                       │
│    ols: { ... }             # classic OLS config             │
│    agenticOLS:                                               │
│      sandboxMode: bare-pod  # or sandbox-claim               │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│ lightspeed-operator (reconcile)                              │
│                                                              │
│  1. Build base PodSpec:                                      │
│     - sandbox image (from related-images / flag)             │
│     - OTEL_EXPORTER_OTLP_ENDPOINT (from templog collector)   │
│     - CA cert volume + mount (from service-CA)               │
│     - resource defaults                                      │
│                                                              │
│  2. Write ConfigMap "lightspeed-sandbox-config":              │
│     - sandbox-pod-spec: <serialized PodSpec>                 │
│     - sandbox-mode: bare-pod                                 │
│     - mcp-endpoint: <URL>  (when ocp-mcp deployed)           │
│     - otel-endpoint: <URL> (when templog deployed)           │
└─────────────────────────────────────────────────────────────┘
          │
          ▼ (watch)
┌─────────────────────────────────────────────────────────────┐
│ lightspeed-agentic-operator (reconcile AgenticRun)           │
│                                                              │
│  1. Read ConfigMap → deserialize base PodSpec + mode         │
│     (fail hard if missing after timeout)                     │
│                                                              │
│  2. Overlay per-run config:                                  │
│     - LLM creds, env vars, skills, per-run MCP, SA, probes  │
│                                                              │
│  3. Deliver based on sandbox-mode:                           │
│     - bare-pod → create Pod from PodSpec                     │
│     - sandbox-claim → build SandboxTemplate from PodSpec     │
└─────────────────────────────────────────────────────────────┘
```

## Acceptance Criteria

1. lightspeed-operator creates `lightspeed-sandbox-config` ConfigMap with base PodSpec during reconciliation
2. `OLSConfig` CRD gains `spec.agenticOLS.sandboxMode` field
3. Base PodSpec includes sandbox container image, OTEL env var, CA cert volumes/mounts
4. Agentic operator reads ConfigMap and uses base PodSpec for all sandbox pod creation
5. Agentic operator fails hard (after timeout) when ConfigMap is missing — no fallback
6. Both bare-pod and sandbox-claim modes derive from the same base PodSpec
7. SandboxTemplate is built by the agentic operator from the overlayed PodSpec
8. `--sandbox-mode` flag on agentic operator is deprecated in favor of ConfigMap-provided mode
9. OTEL endpoint flows from classic operator through ConfigMap to sandbox pods
10. ConfigMap changes trigger re-reconciliation in the agentic operator

## Testing Strategy

### lightspeed-operator
- **Unit:** OLSConfig with `spec.agenticOLS.sandboxMode` → verify ConfigMap created with correct `sandbox-mode` key
- **Unit:** OTEL collector deployed → verify `OTEL_EXPORTER_OTLP_ENDPOINT` present in base PodSpec
- **Unit:** ocp-mcp deployed → verify CA cert volume/mount in base PodSpec and `mcp-endpoint` key present
- **Unit:** Cert rotation → verify ConfigMap updated with new PodSpec

### lightspeed-agentic-operator
- **Unit:** ConfigMap present → verify base PodSpec deserialized and per-run overlay applied correctly
- **Unit:** ConfigMap missing → verify fail-hard after timeout with clear error
- **Unit:** Bare-pod mode → Pod created from overlayed PodSpec
- **Unit:** Sandbox-claim mode → SandboxTemplate built from overlayed PodSpec
- **Unit:** Per-run MCP servers merged with base MCP config
- **Integration:** Classic + agentic operators deployed → verify sandbox pods start with correct OTEL endpoint and CA certs

## Changes by Repository

| Repo | Changes |
|---|---|
| **lightspeed-operator** | Add `spec.agenticOLS` to OLSConfig CRD. New reconciler logic to build base PodSpec and maintain `lightspeed-sandbox-config` ConfigMap. |
| **lightspeed-agentic-operator** | Refactor `PodSpecBuilder` to read base from ConfigMap and overlay per-run config. Simplify `EnsureAgentTemplate` to build SandboxTemplate from PodSpec. Add ConfigMap watch. Deprecate `--sandbox-mode` flag. Fail-hard on missing ConfigMap. |
| **lightspeed-agentic-sandbox** | No changes — already consumes env vars and mounts. |

## Risk Assessment

**Risk Level: 3 (High)**

Per risk-level-rubric decision tree:
1. Does the change touch an external contract? — Yes: new `spec.agenticOLS` field on OLSConfig CRD (API contract change → Risk 3).
2. Does the change affect user-visible behavior? — Yes: sandbox mode moves from operator flag to CRD field (operational change). Fail-hard on missing ConfigMap changes failure behavior.
3. Does the change alter internal logic? — Yes: significant refactor of pod spec construction in agentic operator, new ConfigMap reconciliation in classic operator.

Mitigations:
- New CRD field is additive and optional with backward-compatible default (`bare-pod`)
- ConfigMap is operator-internal, not user-facing
- Agentic operator fail-hard ensures misconfigurations are caught early
- Both operators are in the same OLM bundle, so coordinated deployment is guaranteed
- 2+ human reviewers required per Risk 3 rubric
