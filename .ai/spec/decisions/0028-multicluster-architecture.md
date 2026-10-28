# 0028: Multicluster Architecture

**Status:** Accepted (revised 2026-08-20)
**Applies to:** lightspeed-hub, lightspeed-hub-ui, lightspeed-agentic-operator

**Amendment [PLANNED: OLS-4632]:** [ADR 0045](0045-multicluster-agent-baseline-rbac.md) refines baseline reader provisioning and remote selection. The agentic operator creates dedicated per-step bindings rather than adding subjects to shared source bindings. Its planned source discovery uses the spoke seed SA with configurable fleet defaults and spoke additions. The namespace-only constraint below does not describe all current permissions: baseline reads can be cluster-wide and approved execution can include cluster-scoped RBAC; see [multicluster operations](../what/multicluster-ops.md#security-invariants).

## Context

Multicluster operations need a central control plane for fleet-wide agentic operations. Spoke clusters may be managed services (ROSA, ARO, HCP) where sensitive credentials must not reside, or edge devices with limited resources. Different user populations need different credential sources. The architecture must support both zero/minimal spoke footprint (hub-managed) and full spoke autonomy (spoke-local) as a future option.

Key constraints from team review (2026-06-30):
- LLM credentials and sensitive information must never reside on spoke clusters in hub-managed mode (hard security boundary for ROSA/managed-service use cases).
- Operations must be namespace-scoped (`targetNamespaces`) — tools must not access user workloads.
- The design must be co-engineered with existing operator teams (CVO, ACS, CMO) who will embed adapter logic.
- ACM cannot be required. MCE is acceptable as an optional credential source.

## Decision

### Hub-Managed Mode (MVP)

The hub is both control plane and compute plane. A thin hub operator layer manages spoke registration, credential brokering, and adapter orchestration in front of the existing agentic stack. The agentic-operator on the hub reconciles AgenticRuns with a new `spec.targetCluster` field, creating ephemeral SAs on spoke clusters and mounting spoke kubeconfigs into sandbox pods.

- **HubConfig CR** (`hub.openshift.io/v1alpha1`): cluster-scoped singleton. `spec.clusterRegistryMode` selects fleet-wide credential management strategy (`secret` or `mce`). Single source of truth — a validating webhook ensures all SpokeCluster CRs match.
- **SpokeCluster CR** (`hub.openshift.io/v1alpha1`): cluster-scoped, one per spoke. Contains `apiServer` and `credentialSource` matching the HubConfig mode.
- **Standing kubeconfig Secret**: per-spoke normalized kubeconfig created by hub operator during registration (`spoke-kubeconfig-{name}`). For secret mode, contains direct credentials. For MCE mode, includes `proxy-url` for transparent MCE cluster-proxy routing. This is the single integration contract — the agentic-operator and adapters read this Secret without knowing the credential source.
- **Spoke-side reader RBAC**: hub operator creates `lightspeed-agent` SA and reader ClusterRoleBindings on spoke during registration, matching the single-cluster RBAC pattern.
- **Per-step SAs**: agentic-operator creates per-step SAs on the spoke (same `ls-{step}-{UID}` naming as single-cluster), adds them to reader ClusterRoleBindings via `addReaderSubject`, and creates sandbox kubeconfig Secrets with 24h ephemeral tokens.
- **Standalone adapters**: run on hub as pods, poll spoke event sources via standing kubeconfig.
- **Sandboxes**: run on hub, target spoke via per-step sandbox kubeconfig (proxy-url copied from standing kubeconfig if MCE).
- **Direct kube-api connectivity**: admin ensures network path between hub and spoke.

### Spoke-Local Mode (PLANNED)

Hub is control plane only. Full agentic stack deployed to spoke. AgenticRun CRs live on spoke, synced to hub via MirrorAgenticRun CRs. Approval routed from hub console back to spoke via remote kube-api.

### Embedded Adapters (PLANNED)

Hub installs AgenticRun CRD on spoke during registration. Existing spoke-side operators (CVO, ACS, CMO) create AgenticRun CRs locally using standard Kubernetes API — no hub awareness needed. Hub's agentic-operator watches spoke for new AgenticRun CRs via dedicated watcher.

## Alternatives Considered

- **Spoke-primary only (EJ's review)** — rejected for MVP because ROSA/managed-service spokes cannot run workloads or hold LLM credentials. Kept as spoke-local mode for future.
- **Spoke agents only (no controller on spoke)** — hub creates sandbox pods on spoke remotely without a local controller. Rejected because it combines the complexity of both modes without the benefits of either.
- **No HubConfig CRD** — initially rejected because all settings were per-spoke. Reinstated when `clusterRegistryMode` emerged as a genuinely fleet-wide decision needing a single source of truth.
- **Push model for embedded adapters (hubclient library)** — rejected in favor of hub watching spoke CRs. The watch model is simpler for product teams (just create a CR locally, no hub awareness) and eliminates the need for hub connectivity Secrets on spoke.
- **Pub/sub broker between hub and spoke** — rejected because it adds operational complexity (another dependency to deploy and manage) that contradicts the ease-of-setup design goal.
- **Per-spoke deployment mode** — rejected for MVP. Fleet-wide mode simplifies controller logic. Per-spoke override planned for future.
- **`spec.connectivity` field for tunneling** — rejected for MVP. Direct kube-api only. Connection Factory pattern with ANP tunnel support planned for future.

## Consequences

- Hub adds the "which cluster" dimension; existing agentic engine handles "what to do"
- Per-spoke CRs enable independent reconciliation, per-spoke status, and per-spoke RBAC
- Minimal spoke footprint in hub-managed mode (ephemeral SA per run only; AgenticRun CRD for embedded adapters in future)
- Pluggable credentials accommodate all user segments (secret, MCE, backplane in future)
- Hub console is the single control plane — spokes do not need their own UI
- Hub compute scales linearly with spoke count (sandboxes on hub); spoke-local mode addresses this in future
- Cross-cluster owner references do not work — cleanup is explicit (labels + finalizers + token TTL)
