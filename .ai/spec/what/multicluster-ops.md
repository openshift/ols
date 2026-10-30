# Multicluster Operations

Cross-repo specification for fleet-scale agentic operations. A central hub cluster manages spoke clusters, routing alerts and agentic workflows across the fleet through a single control plane.

> **Testing:** how this feature is tested is specified separately in [multicluster-testing.md](multicluster-testing.md).
>
> **Baseline RBAC [PLANNED: OLS-4632]:** [multicluster-agent-rbac.md](multicluster-agent-rbac.md) defines fleet defaults, additive spoke reader roles, seed-SA discovery, validation, and dedicated per-step binding cleanup. It supersedes fixed-list reader selection for remote runs; approved execution RBAC is unchanged.

## On-Demand Activation and Shutdown [PLANNED: OLS-4665]

The [approved discussion design](../../../docs/superpowers/specs/2026-10-29-OLS-4665-on-demand-multicluster-design.md) and [ADR 0046](../decisions/0046-hubconfig-driven-multicluster-lifecycle.md) define the planned delivery/lifecycle contract:

- OLS v2 installs hub APIs and static ServiceAccount/RBAC but no hub Deployment. The OLS operator deploys and lifecycle-manages the hub when the singleton HubConfig is created; no OLSConfig activation property is used.
- HubConfig explicitly selects Secret registration or MCE discovery. MCE defaults to ongoing discovery of all managed clusters, optionally restricted by a selector. SpokeCluster resources may be staged before activation but remain inactive.
- HubConfig deletion stops new fleet work, drains existing workflows, decommissions registrations, deletes generated credentials, and removes hub runtime resources. Approval waits block drain until completed or explicitly cancelled. Individual spoke deletion also drains before credential cleanup.
- Unreachable-spoke decommissioning is best-effort only after draining, with cleanup warnings. Preserve administrator credential Secrets and install-time RBAC. Re-enable requires a new HubConfig; single-cluster work is unaffected.

This planned contract supersedes immediate unmanage/preserve-registration behavior on HubConfig deletion in the child hub spec. It also replaces OLS-4665's currently written OLSConfig activation requirement; ticket/team alignment and technical protocol validation remain follow-ups, not completed implementation.

## Repos Involved

| Repo | Role |
|---|---|
| lightspeed-operator | [PLANNED: OLS-4665] v2 hub assets/static RBAC; HubConfig-driven hub operand deployment and protected shutdown |
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

1. A single alerts-adapter instance on the hub watches `SpokeCluster` CRs and polls each spoke's AlertManager via a dedicated per-spoke kubeconfig Secret (`spoke-alert-kubeconfig-{spoke-name}`), separate from the standing kubeconfig. See [alerts-adapter-multicluster.md](alerts-adapter-multicluster.md) for details.
2. Adapter creates AgenticRun CR on hub with `spec.targetCluster` set to the SpokeCluster name.
3. Hub's agentic-operator detects the new AgenticRun. Reads the standing kubeconfig Secret by naming convention: `spoke-kubeconfig-{targetCluster}`. Builds a `rest.Config` from it (transparently routes through MCE proxy if `proxy-url` is present).
4. **Analysis phase**: Agentic-operator creates a per-step SA (`ls-anl-{run-UID}`) on the spoke via remote kube-api using the standing kubeconfig. Creates dedicated reader ClusterRoleBindings for the SA, copying RoleRefs from the spoke's baseline source bindings without modifying them. Currently the source list is hardcoded to two bindings; [PLANNED: OLS-4632] discover eligible bindings to the spoke seed SA as specified in `multicluster-agent-rbac.md`. Calls TokenRequest API on the spoke for a 24h token. Creates a sandbox kubeconfig Secret on the hub (`ls-sandbox-kubeconfig-{run-name}-analysis`) with spoke API server + ephemeral token + proxy-url (if present). Mounts into sandbox pod.
5. **Approval gate**: User approves in hub console.
6. **Execution phase**: Agentic-operator creates a per-step SA (`ls-exe-{run-UID}`) on the spoke. Adds reader access (same as analysis). Additionally creates namespace-scoped Roles + RoleBindings and, when requested, a run-specific ClusterRole + ClusterRoleBinding on the spoke based on the approved option's RBAC requirements. Gets 24h token. Creates execution sandbox kubeconfig Secret. Mounts into sandbox pod.
7. **Verification phase**: Creates per-step SA (`ls-ver-{run-UID}`) with reader access only (same as analysis). Gets token, creates kubeconfig, mounts into sandbox.
8. Standard agentic lifecycle for each phase (see `agentic-runs.md`). All sandbox operations target the spoke via remote kube-api through the mounted kubeconfig.
9. On terminal phase (completed, failed, escalated): agentic-operator deletes all per-step SAs and their RoleBindings on the spoke. Deletes dedicated per-step reader ClusterRoleBindings without modifying the baseline source bindings. Deletes sandbox kubeconfig Secrets on the hub (auto-GC via owner reference to AgenticRun). Deletes sandbox pods.
10. Token TTL (24h) is the safety net if cleanup fails.

### Embedded Adapter Path [PLANNED]

1. Hub operator installs AgenticRun CRD on spoke during registration.
2. Existing spoke-side operator (CVO, ACS, CMO) detects a domain-specific event.
3. Operator creates an AgenticRun CR locally on the spoke using standard Kubernetes API. No hub awareness needed — just import the CRD types and call `Create()`.
4. Hub's agentic-operator watches AgenticRun CRs on the spoke via a dedicated watcher (Kubernetes informer on the remote cluster). Detects the new CR.
5. From here, same as standalone path steps 3–9.

## Identity Model

### Standing Kubeconfig

The hub operator creates a normalized kubeconfig Secret per spoke during registration: `spoke-kubeconfig-{spoke-name}`. This is the integration contract between the hub operator and the agentic-operator. Standalone adapters (e.g., alerts-adapter) use their own per-spoke credential Secrets — see [alerts-adapter-multicluster.md](alerts-adapter-multicluster.md).

| Credential source | What the standing kubeconfig contains | MVP |
|---|---|---|
| `secret` | Spoke API server URL + admin-provided kubeconfig credentials | Yes |
| `mce` | Spoke API server URL + MCE proxy-url + hub SA token authorized for MCE cluster-proxy | Yes |
| `backplane` | Spoke API server URL + backplane-issued token | [PLANNED] |

The `proxy-url` field in the kubeconfig is handled transparently by Go's HTTP transport. Consumers call `clientcmd.RESTConfigFromKubeConfig()` and get a `rest.Config` that routes through the MCE proxy automatically — no MCE-specific code in the agentic-operator or adapters.

The standing identity is separate from the baseline seed SA. In secret mode it retains the administrator-supplied kubeconfig identity and its permissions; provisioning does not automatically substitute a restricted controller SA. It needs authority to provision and clean up spoke resources, request SA tokens, and materialize approved execution Roles/RoleBindings and ClusterRoles/ClusterRoleBindings. [PLANNED: OLS-4632] It also needs to list/get source ClusterRoleBindings and read referenced ClusterRoles, with sufficient grant authority under Kubernetes bind/escalation prevention. This feature does not automatically widen that identity.

### Spoke-Side Reader RBAC (provisioned at registration)

During spoke registration, the hub operator creates:
- `openshift-lightspeed-managed` namespace on the spoke (separate from `openshift-lightspeed` to avoid collisions with a spoke-local OLS installation)
- `lightspeed-agent` SA in `openshift-lightspeed-managed` on the spoke
- `cluster-reader` and `cluster-monitoring-view` ClusterRoleBindings referencing `openshift-lightspeed-managed/lightspeed-agent`

These source bindings establish the reader baseline; no sandbox runs as the seed SA. The current remote path reads a hardcoded list of source bindings and creates dedicated per-step bindings copying their RoleRefs, without modifying sources. [PLANNED: OLS-4632] The hub instead reconciles bindings for the configured effective roles, and the agentic-operator discovers eligible source bindings through the exact spoke seed SA. See [the baseline RBAC contract](multicluster-agent-rbac.md). The separate namespace avoids collisions with a standalone spoke installation.

### Per-Step SAs (per-AgenticRun)

Created by the agentic-operator for each step of an AgenticRun targeting a spoke. Same naming convention and RBAC pattern as single-cluster mode, but SAs are created on the spoke via remote kube-api using the standing kubeconfig.

| Step | SA name | Access |
|---|---|---|
| Analysis | `ls-anl-{run-UID}` | Cluster-wide read (via reader ClusterRoleBindings) |
| Execution | `ls-exe-{run-UID}` | Cluster-wide read + namespace-scoped write (from approved option RBAC) |
| Verification | `ls-ver-{run-UID}` | Cluster-wide read (via reader ClusterRoleBindings) |
| Escalation | `ls-esc-{run-UID}` | Cluster-wide read (via reader ClusterRoleBindings) |

For each step, the agentic-operator:
1. Creates the per-step SA on the spoke (via standing kubeconfig)
2. Creates dedicated per-step reader ClusterRoleBindings copying the baseline source RoleRefs; [PLANNED: OLS-4632] sources are discovered and validated per spoke, not selected from the hardcoded list
3. For execution only: materializes the approved option's namespace-scoped Roles + RoleBindings and any requested cluster-scoped ClusterRole + ClusterRoleBinding
4. Calls TokenRequest API on the spoke → 24h bound token
5. Creates a sandbox kubeconfig Secret on the hub with spoke API server + proxy-url (if present) + ephemeral token
6. Mounts the sandbox kubeconfig into the sandbox pod as `KUBECONFIG`

### Sandbox Kubeconfig Secret

Per-step kubeconfig Secret created on the hub for mounting into sandbox pods:
- Name: `ls-sandbox-kubeconfig-{run-name}-{step}`
- Contains: spoke API server URL + proxy-url (copied from standing kubeconfig if present) + per-step SA token
- Owner reference to AgenticRun CR (auto-GC)
- The sandbox uses the mounted `KUBECONFIG` for spoke access. The current remote path separately uses the hub pod's ServiceAccount token for hub-side Result CR access; the spoke and hub identities are distinct

The proxy-url copy is mechanical — no conditional logic:
```go
sandboxCluster.ProxyURL = standingCluster.ProxyURL  // empty string if not MCE
```

### Cross-Cluster Cleanup

Owner references do not work across clusters. Cleanup is explicit:

1. **Labels**: All spoke-side resources labeled with `hub.openshift.io/spoke-cluster` and `hub.openshift.io/agentic-run`.
2. **Finalizer**: Finalizer on AgenticRun CR. Controller removes spoke-side resources (per-step SAs, Roles, RoleBindings) and deletes dedicated per-step reader ClusterRoleBindings before releasing the finalizer. [PLANNED: OLS-4632] Reader binding cleanup uses actual run/step ownership rather than the current source list.
3. **Token TTL**: 24h token expiry as safety net. Periodic reconciliation sweeps stale SAs.
4. **Hub-side cleanup**: Sandbox kubeconfig Secrets are auto-GC'd via owner reference to AgenticRun.

## Console Integration

The hub console is the single control plane for all modes. Console plugins can only read resources from the cluster they run on (the hub).

- **Hub-managed mode (MVP)**: AgenticRun CRs from standalone adapters live on the hub — console reads them directly. [PLANNED] AgenticRun CRs from embedded adapters live on the spoke — hub operator's spoke watcher caches status for the console.
- **Spoke-local mode [PLANNED]**: Console reads MirrorAgenticRun CRs on the hub. Approval actions on mirror CRs are propagated by the hub operator to the spoke.

## Connectivity

MVP uses direct kube-api connectivity. The admin ensures network path between hub and spoke (VPN, peering, same-VPC).

[PLANNED] Reverse tunnel via apiserver-network-proxy (ANP) for firewalled spokes. MCE cluster-proxy connectivity abstraction. Connection Factory pattern returning `rest.Config` with the right transport.

## Security Invariants

1. In hub-managed mode, LLM provider credentials never leave the hub.
2. Baseline access is read-only. Additional execution permissions come from the approved option's RBAC: namespace-scoped grants apply only in the declared namespaces, while explicitly approved cluster-scoped rules can grant cluster-wide access. [PLANNED: OLS-4632] Configured baseline roles and discovered source roles follow the reader restrictions in [multicluster-agent-rbac.md](multicluster-agent-rbac.md); they cannot supply execution-only writes.
3. Standing identity credentials (spoke kubeconfigs) are stored as K8s Secrets on the hub, encrypted at rest.
4. Hub namespace RBAC restricts which users/SAs can read spoke credential Secrets.
5. Credential Secrets are labeled for audit (`hub.openshift.io/credential-type: spoke-kubeconfig`).

## What Does NOT Change

- OLSConfig activation API and LLM provider configuration (planned multicluster activation uses HubConfig, not a new OLSConfig property)
- MCP server definitions and tool filtering
- Sandbox runtime (lightspeed-agentic-sandbox)
- Agent and LLMProvider CRDs
- ApprovalPolicy enforcement
- Single-cluster deployment mode (continues to work with no hub)
