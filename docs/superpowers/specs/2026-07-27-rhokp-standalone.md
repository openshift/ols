# Deploy RHOKP as a Standalone HTTPS Cluster Service

**Feature Request:** [OLS-3697](https://redhat.atlassian.net/browse/OLS-3697)
**Date:** 2026-07-27
**Status:** Draft
**Related:** [OLS-3526](https://redhat.atlassian.net/browse/OLS-3526) (standalone HTTPS ocp-mcp pattern), [OLS-3572](https://redhat.atlassian.net/browse/OLS-3572) (inter-operator handoff), [OLS-1894](https://redhat.atlassian.net/browse/OLS-1894) (ROSA-aware OKP)

## Problem

RHOKP (Red Hat Offline Knowledge Portal) currently runs as a sidecar container in the app-server pod, serving Solr HTTP on a remapped port (9080) via localhost. This creates several limitations:

1. **No external consumers** — only the colocated app-server can reach the Solr endpoint. Agentic sandbox pods and other future consumers cannot query OKP documentation.
2. **Port remapping complexity** — the sidecar's stock ports (8080/8443) conflict with the MCP server and app-server HTTPS, requiring sed-patching of Apache config at startup.
3. **75 GiB ephemeral storage on the app-server pod** — bloats the app-server pod's resource footprint and node scheduling constraints.
4. **No TLS** — Solr queries travel over plain HTTP within the pod network. While safe in a shared-pod context, this prevents cluster-wide access.

## Approach: Standalone HTTPS Deployment (ocp-mcp Pattern)

RHOKP moves from an app-server sidecar to a standalone Deployment with its own Service, following the ocp-mcp standalone HTTPS pattern ([OLS-3526](https://redhat.atlassian.net/browse/OLS-3526)). The operator creates a dedicated `lightspeed-rhokp` operand with OpenShift service-ca TLS, NetworkPolicy, and CA trust wiring for both app-server and agentic sandbox.

### Architecture

```
lightspeed-service (app-server)
  └─ HTTPS Solr client
       url: https://lightspeed-rhokp.<ns>.svc:8443/solr/portal-rag/hybrid-search
       trust: /etc/certs/lightspeed-rhokp-ca/service-ca.crt  (extra_ca)
            │
            ▼
lightspeed-rhokp Deployment + ClusterIP Service (:8443)
  ├─ service-ca serving cert Secret   lightspeed-rhokp-tls
  ├─ CA ConfigMap (inject-cabundle)   lightspeed-rhokp-ca
  └─ NetworkPolicy                    lightspeed-rhokp
```

Agentic sandbox pods also connect via HTTPS, with the endpoint URL and CA cert provided through the inter-operator handoff ConfigMap.

### 1. CRD Change: `spec.ols.deployment.rhokp` Becomes `Config`

The existing `spec.ols.deployment.rhokp` field changes from `ContainerConfig` (resources only) to full `Config` (replicas, resources, tolerations, nodeSelector) — matching `spec.ols.deployment.mcpServer`:

```yaml
spec:
  ols:
    deployment:
      rhokp:
        replicas: 1        # new (default 1, operator forces 1)
        resources: { ... }  # existing, carries over
        tolerations: [...]  # new
        nodeSelector: {}    # new
```

Replicas are forced to 1 by the operator (same as console, database, otel-collector). The field type change is backward-compatible: existing CRs that only set `resources` continue to work.

### 2. Component Lifecycle (Mirrors ocp-mcp)

#### Phase 1 — Resources

| Resource | Name | Purpose |
|---|---|---|
| ConfigMap | `lightspeed-rhokp-ca` | Empty, annotated `inject-cabundle: "true"` — service-ca injects the signing CA |
| NetworkPolicy | `lightspeed-rhokp` | Ingress from any pod in operator namespace on TCP `:8443` |

#### Phase 2 — Deployment

| Resource | Name | Purpose |
|---|---|---|
| Service | `lightspeed-rhokp` | ClusterIP, port `https` `:8443`, `serving-cert-secret-name` annotation → Secret `lightspeed-rhokp-tls` |
| Deployment | `lightspeed-rhokp` | Single replica, RHOKP image with service-ca cert on Apache HTTPS port 8443 |

Phase 2 waits for `tls.crt` / `tls.key` in the serving cert Secret before creating/updating the Deployment (same pattern as ocp-mcp).

#### Reconciliation Order

RHOKP Phase 1+2 runs **before** the app-server, so the Service and CA ConfigMap exist when the app-server wires its Solr client.

### 3. Standalone Deployment Spec

| Aspect | Value |
|---|---|
| Name | `lightspeed-rhokp` |
| Image | Same `--rhokp-image` flag / `related_images.json` entry `rhokp` |
| Pull policy | `PullIfNotPresent` |
| Entrypoint | Stock image entrypoint — no port remapping needed in standalone mode |
| HTTPS port | **8443** (Apache native, service-ca cert via `--tls-cert`/`--tls-key` or Apache SSL config) |
| Env | Optional `ACCESS_KEY` from Secret `rhokp-access-key` |
| Storage | **EmptyDir with sizeLimit: 75Gi** — corpus baked into image, explicit quota |
| Resources | Defaults per OpenShift conventions (2 CPU, 2 GiB memory requests, no limits) |
| Override | `spec.ols.deployment.rhokp` (`Config`: replicas, resources, tolerations, nodeSelector) |
| Security | Restricted PSS except `readOnlyRootFilesystem: false` (Solr/httpd writes at startup) |
| Probes | HTTPS GET `/solr/portal-rag/admin/ping` on port 8443; startup probe tolerates ~6 min cold start |

No port remapping — in standalone mode there are no port conflicts. The stock Apache config uses 8443 for HTTPS natively.

### 4. App-Server Integration Changes

| Before (sidecar) | After (standalone) |
|---|---|
| `solr_hybrid.solr_http_base`: `http://localhost:9080` | `https://lightspeed-rhokp.<ns>.svc:8443` |
| RHOKP container in app-server pod spec | Removed |
| No CA trust needed (localhost HTTP) | CA volume mount from `lightspeed-rhokp-ca`, path added to `extra_ca` |
| No change detection for RHOKP | Deployment tracks `lightspeed-rhokp-ca` content hash annotation |
| 75 GiB ephemeral on app-server pod | App-server pod ephemeral storage no longer needed for OKP |

`OCP_CLUSTER_VERSION` and `OLS_ROSA_PRODUCT` env vars remain on the app-server (the service uses them for Solr `chunk_filter_query` construction, not the RHOKP container).

### 5. TLS

- **Serving cert:** OpenShift service-ca issues `lightspeed-rhokp-tls` (same mechanism as ocp-mcp).
- **Client trust:** App-server mounts `lightspeed-rhokp-ca` at `/etc/certs/lightspeed-rhokp-ca/` and adds `service-ca.crt` to `extra_ca`.
- **Cert rotation:** On `lightspeed-rhokp-tls` change, watcher restarts both RHOKP Deployment and app-server (`ACTIVE_BACKEND`).

### 6. Agentic Sandbox Access (Handoff ConfigMap Extension)

The inter-operator handoff ConfigMap (`lightspeed-sandbox-config`, per [OLS-3572](https://redhat.atlassian.net/browse/OLS-3572)) gains RHOKP-specific entries:

| Key | Type | Description |
|---|---|---|
| `rhokp-endpoint` | string | `https://lightspeed-rhokp.<ns>.svc:8443`. Present when OKP is enabled (not `byokRAGOnly`). |

The RHOKP CA cert volume and volume mount are included directly in the base `sandbox-pod-spec` PodSpec (same pattern as MCP CA — CA certs are mounted in the PodSpec, not passed as separate ConfigMap keys).

When `byokRAGOnly` is true, both `rhokp-endpoint` and the CA mount are absent from the ConfigMap / PodSpec.

### 7. Monitoring

The operator creates a ServiceMonitor `lightspeed-rhokp-monitor` to enable Prometheus scraping of RHOKP metrics:

| Aspect | Value |
|---|---|
| ServiceMonitor name | `lightspeed-rhokp-monitor` |
| Scrape endpoint | HTTPS `:8443`, path `/solr/admin/metrics` (Solr built-in Prometheus reporter) |
| TLS | `serverName: lightspeed-rhokp.<ns>.svc`, CA from service-ca |
| Interval | Default Prometheus scrape interval |

ServiceMonitor creation is skipped if Prometheus Operator CRDs are not installed (same guard as app-server and OTEL collector ServiceMonitors).

### 8. Gating

Same gate as today: `!spec.ols.byokRAGOnly`. When `byokRAGOnly` is true:
- RHOKP standalone Deployment, Service, NetworkPolicy, CA ConfigMap are not created (or removed if they exist)
- `solr_hybrid` config is omitted from `olsconfig.yaml`
- `OCP_CLUSTER_VERSION` / `OLS_ROSA_PRODUCT` env vars are not set
- Handoff ConfigMap omits `rhokp-endpoint` and RHOKP CA mount

No new CRD field for gating — clean replacement of sidecar in one release.

### 9. Sidecar Removal

- Remove RHOKP container from `appserver/deployment.go`
- Remove port remapping logic from `rhokp.go` (or repurpose for standalone)
- Remove 75 GiB ephemeral storage request from app-server pod
- Remove constraint 5 from app-server spec ("RHOKP sidecar requires approximately 75 GiB of ephemeral storage")

### 10. Teardown

`rhokp.Remove()` deletes Deployment, Service, NetworkPolicy, CA ConfigMap, TLS Secret (`lightspeed-rhokp-tls`), and ServiceMonitor (`lightspeed-rhokp-monitor`) — same pattern as `ocpmcp.Remove()`. Called when `byokRAGOnly` becomes true or on CR deletion (finalizer).

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ OLSConfig CR                                                 │
│  spec.ols.byokRAGOnly: false  (default → OKP enabled)       │
│  spec.ols.deployment.rhokp: { resources, tolerations, ... }  │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│ lightspeed-operator (reconcile)                              │
│                                                              │
│  Phase 1: CA ConfigMap (inject-cabundle), NetworkPolicy      │
│  Phase 2: Service (serving-cert), wait TLS, Deployment       │
│                                                              │
│  App-server wiring:                                          │
│    solr_hybrid.solr_http_base = https://lightspeed-rhokp.…  │
│    extra_ca += lightspeed-rhokp-ca/service-ca.crt            │
│    CA hash annotation for restart on rotation                │
│                                                              │
│  Handoff ConfigMap extension:                                │
│    rhokp-endpoint = https://lightspeed-rhokp.<ns>.svc:8443  │
│    base PodSpec += RHOKP CA volume + mount                   │
└─────────────────────────────────────────────────────────────┘
          │                            │
          ▼                            ▼ (handoff)
┌──────────────────────┐  ┌──────────────────────────────────┐
│ lightspeed-service    │  │ lightspeed-agentic-operator       │
│ (app-server)          │  │                                   │
│                       │  │  Sandbox pods query RHOKP via     │
│ Queries RHOKP via     │  │  https://lightspeed-rhokp.…:8443 │
│ https://lightspeed-…  │  │  CA from handoff ConfigMap        │
│ CA from extra_ca      │  │  PodSpec base volume mount        │
└──────────────────────┘  └──────────────────────────────────┘
```

## Acceptance Criteria

1. RHOKP runs as a standalone Deployment with ClusterIP Service on port 8443
2. Service-ca TLS cert issued and mounted for Apache HTTPS
3. App-server queries RHOKP via HTTPS cluster DNS (no localhost)
4. App-server trusts RHOKP CA via `extra_ca`
5. RHOKP sidecar removed from app-server pod spec
6. App-server pod no longer requires 75 GiB ephemeral storage
7. EmptyDir with sizeLimit used for RHOKP standalone pod storage
8. `spec.ols.deployment.rhokp` type changed from `ContainerConfig` to `Config`
9. NetworkPolicy restricts RHOKP ingress to operator namespace pods
10. Cert rotation triggers rolling restart of both RHOKP and app-server
11. `byokRAGOnly=true` prevents RHOKP standalone deployment (same gate as sidecar)
12. Handoff ConfigMap includes `rhokp-endpoint` and RHOKP CA in base PodSpec
13. Port remapping logic removed (no longer needed in standalone mode)
14. ServiceMonitor `lightspeed-rhokp-monitor` scrapes RHOKP metrics via HTTPS

## Testing Strategy

### lightspeed-operator
- **Unit:** `byokRAGOnly=false` → verify RHOKP Deployment, Service, CA ConfigMap, NetworkPolicy created
- **Unit:** `byokRAGOnly=true` → verify RHOKP resources not created / removed
- **Unit:** `spec.ols.deployment.rhokp` resources/tolerations/nodeSelector → verify applied to standalone Deployment
- **Unit:** Verify `solr_hybrid.solr_http_base` is HTTPS cluster DNS URL
- **Unit:** Verify app-server mounts RHOKP CA and adds to `extra_ca`
- **Unit:** Verify handoff ConfigMap includes `rhokp-endpoint` and CA volume in base PodSpec
- **Unit:** Cert rotation → verify both RHOKP and app-server restarted
- **Integration:** App-server can query RHOKP Solr via HTTPS

### lightspeed-service
- No code changes expected — `solr_http_base` is operator-configured, and HTTPS trust comes from `extra_ca` merge at startup.

### lightspeed-agentic-operator
- **Unit:** Handoff ConfigMap with `rhokp-endpoint` → verify sandbox PodSpec includes RHOKP CA mount
- **Integration:** Sandbox pod can query RHOKP Solr via HTTPS

## Changes by Repository

| Repo | Changes |
|---|---|
| **lightspeed-operator** | New `internal/controller/rhokp/` package (standalone lifecycle, TLS, NetworkPolicy). Remove RHOKP sidecar from `appserver/deployment.go`. Update `buildSolrHybridSettings()` to HTTPS cluster DNS. App-server CA mount + `extra_ca`. TLS watcher for `lightspeed-rhokp-tls`. Handoff ConfigMap extension (`rhokp-endpoint`, CA in base PodSpec). CRD: `spec.ols.deployment.rhokp` type change from `ContainerConfig` to `Config`. Phase 1/2 reconciliation additions. |
| **lightspeed-service** | No code changes. `solr_http_base` is operator-configured. HTTPS trust via `extra_ca` (already supported). |
| **lightspeed-agentic-operator** | Consume `rhokp-endpoint` + CA from handoff ConfigMap for sandbox PodSpec (lands with OLS-3572 handoff). |

## Risk Assessment

**Risk Level: 3 (High)**

Per risk-level-rubric decision tree:
1. Does the change touch an external contract? — Yes: `spec.ols.deployment.rhokp` type changes from `ContainerConfig` to `Config` (CRD spec field change → Risk 3).
2. Does the change affect user-visible behavior? — Yes: RHOKP moves from sidecar to standalone Deployment (operational topology change). App-server pod no longer needs 75 GiB ephemeral storage.
3. Does the change alter internal logic? — Yes: new operand package, sidecar removal, TLS wiring, handoff extension.

Mitigations:
- CRD type change is backward-compatible (existing `resources` field carries over, new fields are optional)
- Same `byokRAGOnly` gating — no new CRD field for activation
- Follows proven ocp-mcp standalone pattern
- Service requires no code changes — HTTPS trust is already supported via `extra_ca`
- 2+ human reviewers required per Risk 3 rubric
