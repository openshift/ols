# Multicluster Agentic Lightspeed — Architecture Design

## Problem Statement

OpenShift Lightspeed (OLS) today operates as a single-cluster system. Every cluster that wants AI-assisted troubleshooting and remediation must have the full OLS stack installed locally. This creates adoption friction for fleet operators — Red Hat SREs managing ROSA/ARO/HCP, and customers managing their own multi-cluster environments — because the per-cluster setup cost exceeds the troubleshooting value at scale.

Additionally, a broken cluster has difficulty diagnosing itself. Centralized management from a healthy hub cluster provides a more reliable troubleshooting surface.

### Target Users

- **Red Hat SREs** managing managed OpenShift offerings (ROSA, ARO, HCP) via backplane
- **Customers** managing their own fleet of OpenShift or Kubernetes clusters

### Constraints

- ACM cannot be required (some customers won't use it)
- MCE is acceptable as a fallback but not required for the primary path
- Spoke clusters may be edge devices with limited resources
- Existing adapter teams embed adapter logic in their product operators (ACS, CVO, CMO, OSSM)
- Ease of setup is a first-class design goal

## Architecture Overview

The multicluster architecture introduces a thin **hub layer** in front of the existing agentic stack. The hub handles three concerns that don't exist today: cluster identity, credential resolution, and cross-cluster routing. Everything else — LLM integration, Proposal lifecycle, sandbox execution, adapter domain logic — stays in the existing components unchanged.

```
                                    ┌─────────────────────────────────────┐
                                    │           Hub Cluster               │
                                    │                                     │
  ┌─────────┐   ┌──────────┐       │  ┌──────────────────────────────┐   │
  │   CLI   │───│  Hub UI  │───────┼─▶│       lightspeed-hub         │   │
  └─────────┘   └──────────┘       │  │  ┌────────────────────────┐  │   │
                (optional)          │  │  │   Cluster Registry     │  │   │
                                    │  │  │   (backplane/MCE/      │  │   │
                                    │  │  │    manual secrets)     │  │   │
                                    │  │  ├────────────────────────┤  │   │
                                    │  │  │   Credential Broker    │  │   │
                                    │  │  ├────────────────────────┤  │   │
                                    │  │  │   MCP Router           │  │   │
                                    │  │  ├────────────────────────┤  │   │
                                    │  │  │   Adapter Orchestrator │  │   │
                                    │  │  └────────────────────────┘  │   │
                                    │  └──────────┬───────────────────┘   │
                                    │             │                       │
                                    │  ┌──────────▼───────────────────┐   │
                                    │  │  Existing Agentic Stack      │   │
                                    │  │  ┌─────────────────────────┐ │   │
                                    │  │  │ lightspeed-service      │ │   │
                                    │  │  │ (LLM, RAG, chat)        │ │   │
                                    │  │  ├─────────────────────────┤ │   │
                                    │  │  │ agentic-operator        │ │   │
                                    │  │  │ (Proposal lifecycle)    │ │   │
                                    │  │  ├─────────────────────────┤ │   │
                                    │  │  │ agentic-sandbox         │ │   │
                                    │  │  │ (agent runtime)         │ │   │
                                    │  │  └─────────────────────────┘ │   │
                                    │  └──────────────────────────────┘   │
                                    │             │                       │
                                    │  ┌──────────▼───────────────────┐   │
                                    │  │  Per-Spoke Adapter Pods      │   │
                                    │  │  (standalone adapters only)  │   │
                                    │  │  ┌────────┐ ┌────────┐      │   │
                                    │  │  │ spoke-1│ │ spoke-2│ ...  │   │
                                    │  │  │adapter │ │adapter │      │   │
                                    │  │  └────┬───┘ └────┬───┘      │   │
                                    │  └───────┼──────────┼───────────┘   │
                                    └──────────┼──────────┼───────────────┘
                                               │          │
                              ┌────────────────▼┐   ┌─────▼──────────────┐
                              │  Spoke Cluster 1 │   │  Spoke Cluster 2   │
                              │  (ROSA/ARO/HCP/  │   │  (OCP/EKS/edge)    │
                              │   OCP/EKS)       │   │                    │
                              │                  │   │                    │
                              │  No OLS workloads│   │  No OLS workloads  │
                              │  Just kube-api   │   │  Just kube-api     │
                              └──────────────────┘   └────────────────────┘
```

### Key Principles

- Hub is a **router and credential broker**, not a reimplementation of the engine
- Zero spoke footprint for the default path (hub reaches spokes via kube-api)
- Existing single-cluster OLS deployment continues to work unchanged
- Hub adds the "which cluster" dimension; existing engine handles "what to do"
- Ease of setup: install hub, register spokes, done

## Hub Cluster Deployment

The hub runs three layers, two of which already exist:

### Layer 1: Existing OLS Stack (unchanged)

Deployed by `lightspeed-operator` via `OLSConfig` CR. Handles:

- LLM provider configuration (API keys, models, provider types)
- RAG indexes
- MCP server configuration (including OCP MCP server sidecar)
- Conversation cache (PostgreSQL)
- Query processing, tool calling, streaming

No changes needed. LLM provider config lives here — the hub layer does not duplicate it.

### Layer 2: Existing Agentic Stack (minimal changes)

Deployed by `lightspeed-agentic-operator`. Handles:

- Proposal lifecycle (analysis → approval → execution → verification)
- Sandbox pod management
- Agent and LLMProvider CRs
- ApprovalPolicy enforcement

Changes needed:
- Accept `spec.targetCluster` on Proposals
- Mount spoke kubeconfig into sandbox when `targetCluster` is set
- Create per-proposal ServiceAccount and RBAC on the spoke (via remote kube-api)
- Clean up spoke-side resources on terminal phase

### Layer 3: New Hub Layer

New component: `lightspeed-hub` (deployed via Helm chart or operator).

Responsibilities:
- Cluster registry (SpokeCluster CRs)
- Credential broker (pluggable: backplane, MCE, K8s Secrets)
- Adapter orchestrator (manage per-spoke adapter pods for standalone adapters)
- MCP routing (pass cluster context to lightspeed-service)
- REST API surface (serves CLI and web UI)

## Spoke Cluster Deployment

### Default path: zero footprint

Nothing is installed on spokes. The hub reaches into spokes via their kube-api server using stored credentials (or backplane/MCE). All analysis, execution, and verification happens on the hub, with remote kube-api calls to the spoke.

### Fallback: lightweight adapter on spoke (Option 1)

When an adapter's event source is not accessible remotely (not exposed via kube-api proxy), a lightweight adapter pod runs on the spoke. It watches local event sources and creates Proposals on the hub via the remote Proposal client. This is the exception, not the norm.

### Spoke sandbox escalation

When remediation requires local execution (node debugging, filesystem access), the hub's agentic-operator creates a temporary sandbox pod on the spoke via remote kube-api call. The sandbox executes locally, then is deleted after the Proposal completes.

## CRD Design

### HubConfig (cluster-scoped singleton)

Hub-level settings.

```yaml
apiVersion: hub.openshift.io/v1alpha1
kind: HubConfig
metadata:
  name: cluster
spec:
  credentialBackend: secret          # default: secret | backplane | mce
  adapterImages:                     # maps adapter type → container image
    alerts: registry.redhat.io/openshift-lightspeed/alerts-adapter:latest
  defaultAdapters:                   # adapters enabled by default for new spokes
    - type: alerts
      enabled: true
```

### SpokeCluster (cluster-scoped, one per spoke)

Each registered spoke cluster is represented by its own CR. Standard Kubernetes pattern (like ACM's ManagedCluster, Cluster API's Cluster).

```yaml
apiVersion: hub.openshift.io/v1alpha1
kind: SpokeCluster
metadata:
  name: prod-rosa-east
  labels:
    environment: production
    cloud: aws
    offering: rosa
spec:
  apiServer: "https://api.prod-rosa-east.example.com:6443"
  credentialSource:
    secret:
      name: prod-rosa-east-credentials
      namespace: openshift-lightspeed
    # OR
    # backplane:
    #   clusterID: "abc-123-def"
    # OR
    # mce:
    #   managedClusterName: "prod-rosa-east"
  adapters:
    - type: alerts
      enabled: true
status:
  conditions:
    - type: Connected
      status: "True"
      lastTransitionTime: "2026-06-22T14:00:00Z"
    - type: AdaptersReady
      status: "True"
      lastTransitionTime: "2026-06-22T14:00:05Z"
  adapters:
    - type: alerts
      podName: adapter-alerts-prod-rosa-east-7f8d9
      status: Running
```

Benefits of per-spoke CRs:
- Independent reconciliation — one broken spoke doesn't affect others
- Per-spoke status and conditions
- Owner references — adapter pods, credential secrets owned by their SpokeCluster CR (auto-GC on deletion)
- Per-spoke RBAC — can restrict which users can see/manage which spokes
- Simple registration — `kubectl apply` a single CR

### Proposal CRD Extension

One new optional field: `spec.targetCluster`.

```yaml
apiVersion: agentic.openshift.io/v1alpha1
kind: Proposal
metadata:
  name: alert-etcdHighCommit-prod-rosa-east-a1b2c3d4
  namespace: openshift-lightspeed
  labels:
    agentic.openshift.io/source: alertmanager
    agentic.openshift.io/target-cluster: prod-rosa-east
spec:
  targetCluster: prod-rosa-east       # NEW: references SpokeCluster by name
                                       # Empty = local hub cluster
  request: |
    A Kubernetes alert is firing on cluster prod-rosa-east.
    ...
  targetNamespaces:
    - openshift-etcd
  analysis:
    agent: default
  execution:
    agent: default
  verification:
    agent: default
```

Behavior per phase when `targetCluster` is set:

| Phase | Behavior |
|---|---|
| Analysis | Sandbox gets spoke kubeconfig. MCP tools and kubectl target spoke API server. |
| Execution | Hub sandbox executes via remote kube-api (default). Temporary spoke sandbox for local-access operations (escalation). |
| Verification | Sandbox queries spoke remotely to confirm fix. |

Backward compatibility: `targetCluster` is optional. Omitting it preserves today's single-cluster behavior.

## Credential Management

### Credential Broker

Pluggable interface inside `lightspeed-hub`:

```
CredentialSource interface:
  GetKubeconfig(clusterName) → rest.Config

Implementations:
  SecretCredentialSource    → reads K8s Secret, returns kubeconfig/token
  BackplaneCredentialSource → calls backplane API, returns short-lived token
  MCECredentialSource       → uses MCE cluster-proxy, returns proxied config
```

### Credential Layering

| User population | Credential source | Notes |
|---|---|---|
| Red Hat SREs | Backplane | Already exists, no new credential storage |
| OpenShift customers with MCE | MCE cluster-proxy | Optional, no new credential storage |
| Everyone else | Stored K8s Secrets | Kubeconfigs stored on hub, encrypted at rest |

### Spoke Registration Flow (automated)

```
$ ols-hub register cluster \
    --name prod-rosa-east \
    --api-server https://api.prod-rosa-east.example.com:6443 \
    --kubeconfig ~/.kube/rosa-east.yaml \
    --adapters alerts

Hub does automatically:
  1. Create SpokeCluster CR on hub
  2. Store spoke kubeconfig as Secret on hub (owned by SpokeCluster)
  3. Create ServiceAccount on hub: spoke-proposal-writer-prod-rosa-east
     └── RoleBinding: can only create/list Proposals + read ProposalApprovals
  4. Generate long-lived token for that ServiceAccount
  5. Using the spoke kubeconfig, create on the SPOKE:
     └── Secret: lightspeed-hub-config (in a well-known namespace)
         ├── hub-api-server: <hub API server URL>
         ├── hub-token: <generated SA token>
         └── cluster-name: prod-rosa-east
  6. Validate connectivity both directions (hub→spoke, spoke→hub)
  7. Deploy standalone adapter pods on hub (for configured adapter types)
  8. Update SpokeCluster status: Connected=True, AdaptersReady=True
```

Deregistration reverses all steps. Owner references on hub-side resources enable cascade deletion via the SpokeCluster CR. Spoke-side resources (lightspeed-hub-config Secret) cleaned up via remote kube-api call.

Target UX: 3 steps from zero to multicluster:
1. Install the hub (Helm chart)
2. Configure LLM provider (OLSConfig — existing flow)
3. Register spoke clusters (one CLI command per spoke)

## Adapter Strategy

### Two adapter categories

**Standalone adapters** (e.g., alerts-adapter): Own container image, domain-focused. Run on the hub via the adapter orchestrator with remote transport. The adapter thinks it's watching a local event source — the orchestrator configures the environment to route to the spoke.

**Embedded adapters** (e.g., ACS, CVO, CMO, OSSM): Adapter logic is embedded in the product's own operator on the spoke. These teams use the **remote Proposal client library** to create Proposals on the hub instead of locally.

### Adapter Orchestrator (standalone adapters)

A controller inside `lightspeed-hub` that reconciles `SpokeCluster` CRs:

1. For each adapter entry in `spec.adapters` where `enabled: true`:
   - Resolve adapter container image from HubConfig
   - Create/update adapter Deployment on the hub
   - Configure environment: spoke kubeconfig, event source endpoints (via kube-api proxy), target cluster name
   - Owner reference to SpokeCluster CR (auto-GC on deletion)
2. Monitor adapter pod health, update SpokeCluster status
3. Remove adapter pods for disabled/removed entries

### Remote Proposal Client Library (embedded adapters)

A thin Go package that wraps the standard Kubernetes client to target the hub:

```go
import hubclient "github.com/openshift/lightspeed-agentic-operator/pkg/hubclient"

// Initialized once — reads from lightspeed-hub-config Secret on spoke
client := hubclient.New(hubclient.Config{
    HubAPIServer: os.Getenv("LIGHTSPEED_HUB_API_SERVER"),
    HubToken:     os.Getenv("LIGHTSPEED_HUB_TOKEN"),
    ClusterName:  os.Getenv("LIGHTSPEED_CLUSTER_NAME"),
})

// Same Create call — Proposal lands on hub with targetCluster auto-set
client.Create(ctx, proposal)
```

Product teams change ~5 lines in their adapter setup. Domain logic unchanged.

The `lightspeed-hub-config` Secret on the spoke (created during registration) provides the connection info. Product operators reference this Secret to configure the remote client.

Going forward, new adapter teams are encouraged to build standalone adapters for the simplest integration path.

## MCP Routing

MCP server configuration lives in `OLSConfig.spec.mcpServers` — no duplication in the hub layer. The hub adds a routing layer, not new MCP servers.

### Chat flow

```
CLI/UI → lightspeed-hub (REST API, adds cluster context header)
       → lightspeed-service (processes query, passes context to MCP)
       → OCP MCP server sidecar (uses spoke kubeconfig for kube-api calls)
       → Spoke cluster API server
```

The hub talks to lightspeed-service via its Kubernetes Service. Lightspeed-service talks to the MCP sidecar via localhost within the pod. The sidecar is never accessed from outside the pod.

### Sandbox flow (agentic Proposals)

When a sandbox runs for a Proposal with `targetCluster` set:
- Agentic-operator mounts the spoke's kubeconfig into the sandbox pod
- `kubectl`, `oc`, and bash commands inside the sandbox target the spoke
- MCP tools used by the agent inside the sandbox also target the spoke
- The sandbox operates as if it were local to the spoke

## CLI Design

The CLI (`ols-hub`) is the primary interface. It wraps the hub's REST API.

```
ols-hub
├── cluster
│   ├── register     Register a spoke cluster
│   ├── deregister   Remove a spoke cluster
│   ├── list         List registered spokes with status
│   └── status       Show detailed status for one spoke
│
├── chat             Interactive chat targeting a specific cluster
│   └── --cluster    Required: which spoke to query against
│
├── proposal
│   ├── list         List proposals (filterable by cluster, status)
│   ├── get          Show proposal details
│   ├── approve      Approve a proposal step
│   ├── deny         Deny a proposal
│   └── logs         Stream agent execution logs
│
├── mcp
│   └── serve        Run as MCP server for Claude Code / Codex integration
│
└── config
    ├── set          Configure hub settings
    └── show         Show current hub configuration
```

### External AI assistant integration

The CLI can serve as an MCP server, exposing hub capabilities (list clusters, chat, query cluster state, view proposals) as MCP tools that any AI assistant (Claude Code, Codex, etc.) can call:

```bash
ols-hub mcp serve
```

## Web UI

Optional, separately deployed. Lightweight SPA served by its own Deployment (`lightspeed-hub-ui`). Talks to the same REST API as the CLI.

### Pages

| Page | Purpose |
|---|---|
| Fleet Dashboard | Spoke status overview, active proposals, recent alerts |
| Cluster Detail | Single spoke: adapter status, proposals, health |
| Proposals List | Filterable table across fleet. Filter by cluster, phase, source |
| Proposal Detail | Full lifecycle view with approval actions |
| Chat | Cluster picker + chat interface with streamed responses |

The hub REST API is the single backend for both CLI and UI. If the UI deployment is not installed, everything works through the CLI.

## Security Model

### Credential storage

| Credential | Storage | Lifecycle |
|---|---|---|
| Spoke kubeconfigs (cluster-admin) | K8s Secrets on hub, owned by SpokeCluster CR | Created at registration, cascade-deleted on deregistration |
| Spoke proposal-writer SA tokens | K8s Secrets on hub, owned by SpokeCluster CR | Auto-generated at registration, pushed to spoke |
| LLM provider API keys | K8s Secrets, referenced by OLSConfig | Managed by cluster admin (existing flow) |
| Hub API tokens (CLI/UI users) | ServiceAccount tokens | Created per user or integration |

Hub stores cluster-admin credentials for all spokes. Compromise of the hub = compromise of all spokes. Mitigations:
- Secrets encrypted at rest (standard K8s etcd encryption)
- Hub namespace RBAC restricts who can read credential Secrets
- Credential Secrets labeled for audit (`hub.openshift.io/credential-type: spoke-kubeconfig`)
- Future: credential rotation policy, short-lived tokens via backplane/MCE

### Hub-spoke trust model

```
Hub → Spoke (outbound):
  Uses stored kubeconfig (cluster-admin level)
  For: adapter event polling, MCP tool calls, sandbox execution,
       RBAC creation, registration setup

Spoke → Hub (outbound, embedded adapters only):
  Uses auto-generated ServiceAccount token
  Scoped to: create/list Proposals, read ProposalApprovals
  Cannot: read Secrets, access other spokes, modify hub config
```

### RBAC on the hub

| Role | Can do | Use case |
|---|---|---|
| Hub admin | Register/deregister spokes, configure hub, access all spokes | Fleet operator, SRE lead |
| Spoke operator | View/approve/deny Proposals for assigned spokes only | SRE for specific clusters |
| Viewer | View cluster status and Proposals, no approval actions | Dashboard monitoring |

### Per-proposal ServiceAccount on spokes

When a Proposal executes against a spoke:
- Ephemeral SA created on the spoke: `ls-exec-{ns}-{name}`
- RBAC Roles/RoleBindings created on the spoke, scoped to `targetNamespaces`
- **SA created with short-lived token (24h expiry)** via Kubernetes bound token API
- Normal path: operator cleans up SA and RBAC when Proposal reaches terminal phase
- Crash/failure path: token expires after 24h, becoming useless. When hub recovers, normal reconciliation sweeps stale SAs.

No reconciliation loops or CronJobs needed — token expiry is the safety net.

### Spoke proposal-writer SA scoping

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spoke-proposal-writer-prod-rosa-east
  namespace: openshift-lightspeed
rules:
  - apiGroups: ["agentic.openshift.io"]
    resources: ["proposals"]
    verbs: ["create", "list", "watch"]
  - apiGroups: ["agentic.openshift.io"]
    resources: ["proposalapprovals"]
    verbs: ["get", "list", "watch"]
```

## Multi-Hub Topology

The architecture supports hub-to-hub watching naturally. A hub is a Kubernetes cluster — it can be registered as a `SpokeCluster` on a peer hub.

```
Hub-A (us-east)                    Hub-B (eu-west)
├── SpokeCluster: spoke-1          ├── SpokeCluster: spoke-4
├── SpokeCluster: spoke-2          ├── SpokeCluster: spoke-5
├── SpokeCluster: hub-b-eu-west    ├── SpokeCluster: hub-a-us-east
```

If Hub-A has problems, Hub-B detects them and can remediate remotely. Minimum 2 hubs for mutual watch, 3 for full resilience (any single hub failure covered).

No special CRD fields or configuration needed — the design is topology-agnostic.

## New Components Summary

| Component | Type | Purpose |
|---|---|---|
| `lightspeed-hub` | Deployment (Go or Python service) | Cluster registry, credential broker, adapter orchestrator, MCP routing, REST API |
| `lightspeed-hub-ui` | Deployment (static SPA + nginx) | Optional web dashboard |
| `ols-hub` | CLI binary | Primary user interface, wraps hub REST API |
| `hubclient` | Go library | Remote Proposal client for embedded adapters |

## Changes to Existing Components

| Component | Change |
|---|---|
| Proposal CRD | Add optional `spec.targetCluster` field |
| agentic-operator | Mount spoke kubeconfig when `targetCluster` set; create/cleanup per-proposal SA and RBAC on spoke via remote kube-api |
| lightspeed-service | Accept cluster context header on query endpoints; pass to MCP sidecar |
| OCP MCP server | Configure `cluster_provider_strategy` automatically based on registered spokes (existing capability, hub automates config) |

## What Does NOT Change

- OLSConfig CR and LLM provider configuration
- MCP server definitions and tool filtering
- Sandbox runtime (lightspeed-agentic-sandbox)
- Agent and LLMProvider CRDs
- ApprovalPolicy enforcement
- Adapter domain logic (what to watch, when to trigger)
- Single-cluster deployment mode (continues to work with no hub)
