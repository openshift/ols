# Multicluster Operations

Cross-repo specification for fleet-scale agentic operations. A central hub cluster manages spoke clusters, routing alerts and agentic workflows across the fleet through a single control plane.

> **Testing:** how this feature is tested is specified separately in [multicluster-testing.md](multicluster-testing.md).

## Repos Involved

| Repo | Role |
|---|---|
| lightspeed-hub | Hub operator: SpokeCluster CRs, credential broker, adapter orchestrator, spoke watcher |
| lightspeed-hub-ui | Hub console: fleet dashboard, spoke management, approval UI |
| lightspeed-agentic-operator | AgenticRun reconciliation, `spec.targetCluster` support, ephemeral SA lifecycle on spoke |
| lightspeed-agentic-alerts-adapter | Standalone adapter: runs on hub, polls spoke AlertManagers |

## Architecture

### Hub-Managed Mode (MVP)

The hub is both control plane and compute plane. Sandboxes run on the hub, targeting spoke clusters via remote kube-api. Spoke footprint is minimal — ephemeral SA per run only. [PLANNED] AgenticRun CRD installed on spoke for embedded adapters.

### Spoke-Local Mode [PLANNED]

The hub is control plane only. Full agentic stack deployed to spoke. Sandboxes run locally on spoke. AgenticRun CRs live on the spoke, synced to hub via mirror CRs for fleet visibility. Approval routed from hub console back to spoke.

## Deployment Modes — Summary

| Concern | Hub-Managed (MVP) | Spoke-Local [PLANNED] |
|---|---|---|
| AgenticRun CRs live on | Hub (standalone adapters); [PLANNED] + spoke (embedded adapters) | Spoke |
| Who reconciles AgenticRuns | Hub's agentic-operator | Spoke's agentic-operator |
| Sandbox runs on | Hub | Spoke |
| Sandbox reaches spoke via | Remote kube-api (ephemeral SA token) | Local kube-api |
| Standalone adapters | Run on hub, poll spoke remotely | Run on spoke, watch locally |
| Embedded adapters | [PLANNED] Create AgenticRun locally on spoke; hub watches | Create AgenticRun locally on spoke |
| LLM credentials | Hub only | Distributed to spoke |
| Fleet visibility | Direct (hub CRs) + watched (spoke CRs) | Aggregated via mirror CRs |
| Approval | Hub UI → hub AgenticRun | Hub UI → mirror CR → hub operator writes to spoke |
| Hub compute scaling | Linear with spoke count | Constant |
| Best for | ROSA, managed services, edge | Self-managed, resource-rich |

## CRDs

### New CRDs (hub.openshift.io/v1alpha1)

1. **HubConfig** — cluster-scoped singleton. Fleet-level configuration: `spec.clusterRegistryMode` (`secret` or `mce`). In `secret` mode, admin creates SpokeCluster CRs manually. In `mce` mode, hub operator auto-discovers spokes from MCE `ManagedCluster` CRs matching an optional label selector (`spec.mce.selector.matchLabels`).
2. **SpokeCluster** — cluster-scoped, one per spoke. Manages spoke identity, credentials, connectivity, and status. See `lightspeed-hub/.ai/spec/what/spoke-lifecycle.md`.

### Modified CRDs (agentic.openshift.io/v1alpha1)

3. **AgenticRun** — new optional field `spec.targetCluster` referencing a SpokeCluster by name. When set, the agentic-operator creates an ephemeral SA on the spoke and mounts a spoke kubeconfig into the sandbox. When empty, behaves as today (local cluster).

### Planned CRDs [PLANNED]

4. **MirrorAgenticRun** (hub.openshift.io/v1alpha1) — spoke-local mode only. Lightweight copy of a spoke-side AgenticRun synced to hub for console access and approval routing.

## End-to-End Flow — Hub-Managed Mode

### Standalone Adapter Path (alerts-adapter)

1. Hub-side alerts-adapter polls spoke's AlertManager via remote kube-api using standing identity from SpokeCluster credentialSource.
2. Adapter creates AgenticRun CR on hub with `spec.targetCluster` set to the SpokeCluster name.
3. Hub's agentic-operator detects the new AgenticRun. Resolves the SpokeCluster CR and obtains spoke kubeconfig via the credential broker.
4. Agentic-operator creates an ephemeral ServiceAccount on the spoke, scoped to `spec.targetNamespaces`, via remote kube-api using the standing identity. Creates namespace-scoped Roles and RoleBindings. Calls the TokenRequest API to get a 24h bound token.
5. Agentic-operator creates a kubeconfig Secret on the hub containing the spoke API server URL and the ephemeral token.
6. Agentic-operator starts the sandbox pod on the hub with the spoke kubeconfig mounted. The sandbox's kubectl/oc/MCP tools target the spoke.
7. Standard agentic lifecycle: analysis → approval → execution → verification (see `agentic-runs.md`). All sandbox operations target the spoke via remote kube-api.
8. On terminal phase (completed, failed, escalated): agentic-operator deletes the ephemeral SA, Roles, and RoleBindings on the spoke. Deletes the kubeconfig Secret on the hub. Deletes the sandbox pod.
9. Token TTL (24h) is the safety net if cleanup fails.

### Embedded Adapter Path [PLANNED]

1. Hub operator installs AgenticRun CRD on spoke during registration.
2. Existing spoke-side operator (CVO, ACS, CMO) detects a domain-specific event.
3. Operator creates an AgenticRun CR locally on the spoke using standard Kubernetes API. No hub awareness needed — just import the CRD types and call `Create()`.
4. Hub's agentic-operator watches AgenticRun CRs on the spoke via a dedicated watcher (Kubernetes informer on the remote cluster). Detects the new CR.
5. From here, same as standalone path steps 3–9.

## Identity Model

### Standing Identity

From `SpokeCluster.spec.credentialSource`. Used exclusively by the hub operator and agentic-operator for spoke management operations.

| Source | Identity | MVP |
|---|---|---|
| `secret` | Stored kubeconfig in K8s Secret | Yes |
| `mce` | MCE cluster-proxy | Yes |
| `backplane` | Red Hat backplane API | [PLANNED] |

Permissions needed: create/delete ServiceAccounts, Roles, RoleBindings; TokenRequest API; read AlertManager, nodes, namespaces.

### Ephemeral SA (per-AgenticRun)

Created by the agentic-operator for each AgenticRun targeting a spoke. The sandbox's only identity on the spoke.

- Name: `ls-exec-{namespace}-{run-name}` (same convention as existing execution RBAC)
- Scope: namespace-scoped Roles in each `targetNamespace`
- Token: 24h TTL via TokenRequest API (bound token)
- Cleanup: labels + finalizer + token TTL safety net

### Cross-Cluster Cleanup

Owner references do not work across clusters. Cleanup is explicit:

1. **Labels**: All spoke-side resources labeled with `hub.openshift.io/spoke-cluster` and `hub.openshift.io/agentic-run`.
2. **Finalizer**: Finalizer on AgenticRun CR. Controller removes spoke-side resources before releasing the finalizer.
3. **Token TTL**: 24h token expiry as safety net. Periodic reconciliation sweeps stale SAs.

## Console Integration

The hub console is the single control plane for all modes. Console plugins can only read resources from the cluster they run on (the hub).

- **Hub-managed mode (MVP)**: AgenticRun CRs from standalone adapters live on the hub — console reads them directly. [PLANNED] AgenticRun CRs from embedded adapters live on the spoke — hub operator's spoke watcher caches status for the console.
- **Spoke-local mode [PLANNED]**: Console reads MirrorAgenticRun CRs on the hub. Approval actions on mirror CRs are propagated by the hub operator to the spoke.

## Connectivity

MVP uses direct kube-api connectivity. The admin ensures network path between hub and spoke (VPN, peering, same-VPC).

[PLANNED] Reverse tunnel via apiserver-network-proxy (ANP) for firewalled spokes. MCE cluster-proxy connectivity abstraction. Connection Factory pattern returning `rest.Config` with the right transport.

## Security Invariants

1. In hub-managed mode, LLM provider credentials never leave the hub.
2. Ephemeral SA tokens are scoped to `targetNamespaces` only — no cluster-wide write access on spoke.
3. Standing identity credentials (spoke kubeconfigs) are stored as K8s Secrets on the hub, encrypted at rest.
4. Hub namespace RBAC restricts which users/SAs can read spoke credential Secrets.
5. Credential Secrets are labeled for audit (`hub.openshift.io/credential-type: spoke-kubeconfig`).

## What Does NOT Change

- OLSConfig CR and LLM provider configuration
- MCP server definitions and tool filtering
- Sandbox runtime (lightspeed-agentic-sandbox)
- Agent and LLMProvider CRDs
- ApprovalPolicy enforcement
- Single-cluster deployment mode (continues to work with no hub)
