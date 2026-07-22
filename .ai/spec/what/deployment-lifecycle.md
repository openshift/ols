# Deployment Lifecycle

The Kubernetes operator that deploys and manages all OpenShift Lightspeed components from a single `OLSConfig` custom resource.

## End-to-End Flow

### CR Creation

1. A cluster admin creates a cluster-scoped `OLSConfig` singleton named "cluster" with LLM providers, RAG indexes, MCP servers, and deployment configuration.

### Reconciliation

2. The operator adds a finalizer (`ols.openshift.io/finalizer`) on first reconcile and returns immediately.
3. On subsequent reconciles, the operator validates external references: LLM credential secrets, custom TLS secrets, proxy CA certificates.
4. The operator annotates user-provided external resources (secrets, configmaps) with `ols.openshift.io/watcher: cluster` to enable change watching.

### Phase 1 — Independent Resources (continue-on-error)

5. The operator generates ConfigMaps: `olsconfig` (from CR spec), system prompt override, MCP config, agentic console nginx config.
6. The operator creates or updates Secrets: LLM credentials (from provider `credentialsSecretRef`), custom TLS (from `tlsConfig.keyCertSecretRef`).
7. The operator creates ServiceAccounts, Roles, RoleBindings for console, PostgreSQL, app server, alerts adapter, and agentic console.
7a. For the alerts adapter: ServiceAccount, ClusterRole (`agentic.openshift.io/agenticruns`: create, list, get), ClusterRoleBinding, RoleBinding in `openshift-monitoring` (binds SA to `monitoring-alertmanager-view`).
7b. For the agentic console: ServiceAccount.
8. The operator creates NetworkPolicies for all components (including alerts adapter and agentic console).

### Phase 2 — Deployments (with health checks)

9. **Console UI**: Single-replica nginx deployment. PatternFly image version selected per OCP version. ConsolePlugin CR created and activated in the Console CR.
10. **PostgreSQL**: Single-replica database deployment. TLS certificates provisioned via the service-ca operator.
11. **App Server**: FastAPI application deployment with:
    - RHOKP sidecar (always deployed; serves OKP content via Solr HTTP on localhost:8080; requires ~75 GiB ephemeral storage). Not deployed when `byokRAGOnly` is true.
    - Data collector sidecar (if feedback/transcripts enabled and telemetry secret exists)
    - OpenShift MCP server sidecar (if introspection enabled)
    - BYOK RAG init containers (copy customer index content from OCI image to shared volume, when `spec.ols.rag` configured)
11a. **Alerts Adapter**: Single-replica Go deployment. Polls AlertManager for firing alerts and creates `AgenticRun` CRs. `ALERTMANAGER_URL` env hardcoded to `https://alertmanager-main.openshift-monitoring.svc:9094`. Status condition: `AlertsAdapterReady`.
11b. **Agentic Console**: Single-replica nginx deployment with TLS via service-ca cert. ConsolePlugin CR created and activated in the Console CR alongside the classic console plugin. Status condition: `AgenticConsolePluginReady`.

### Resource Conventions [OLS-3397]

11c. All operator-managed container defaults follow the [OpenShift resource conventions](https://github.com/openshift/enhancements/blob/master/CONVENTIONS.md#resources-and-limits): defaults declare CPU and memory requests only, and do not set resource limits. This applies to all containers across all deployments (Console UI, PostgreSQL, App Server and its sidecars). Users may override via the CRD to set limits if their environment requires it. The RHOKP sidecar's ~75 GiB ephemeral storage requirement is unaffected by this convention.

### External Resource Watching

12. The operator watches annotated external resources (secrets, configmaps) for data changes.
13. On change, the operator triggers a pod restart by updating the `ols.openshift.io/force-reload` annotation on the pod template with an RFC3339Nano timestamp.
14. System resources are always watched: pull secret (`openshift-config/pull-secret`), service-ca certs, kube-root-ca.

### Status Reporting

15. The operator reports `OverallStatus` (Ready/NotReady) and condition types: `ApiReady`, `CacheReady`, `ConsolePluginReady`, `AlertsAdapterReady` [PLANNED: OLS-3236], `AgenticConsolePluginReady` [PLANNED: OLS-3236], `ResourceReconciliation`.
16. On pod failures, the operator includes diagnostic info: container reason, message, exit code.

### Cleanup on Deletion

17. The operator removes the console plugin from the Console CR.
18. The operator deletes the ConsolePlugin CR.
18a. The operator removes the agentic console plugin from the Console CR.
18b. The operator deletes the agentic ConsolePlugin CR.
18c. The operator deletes the alerts-adapter RoleBinding in `openshift-monitoring`, ClusterRoleBinding, and ClusterRole.
19. The operator lists and deletes all owned resources (by OwnerReference).
20. The operator removes the finalizer, even if cleanup partially fails.

## Integration Contracts

### CRD — `ols.openshift.io/v1alpha1`

| CRD | Scope | Purpose |
|---|---|---|
| `OLSConfig` | Cluster (singleton "cluster") | Full deployment specification: LLM providers, RAG, MCP, tools, deployment config, status conditions |

### Generated ConfigMaps

| Name | Content | Consumed By |
|---|---|---|
| `olsconfig` | Generated `olsconfig.yaml` from CR spec | App server (mounted at `/etc/lightspeed/olsconfig.yaml`) |
| MCP config | MCP server list with URLs, timeouts, header sources | App server |
| Nginx config | Console plugin nginx configuration | Console deployment |

### Restart Trigger

When an external resource changes, the operator sets `ols.openshift.io/force-reload` on the pod template to an RFC3339Nano timestamp, causing a rolling update.

### Operator Image Flags

The operator accepts image overrides at startup: `--service-image`, `--console-image`, `--console-image-pf5`, `--console-image-4-19`, `--postgres-image`, `--openshift-mcp-server-image`, `--dataverse-exporter-image`, `--rhokp-image`, `--alerts-adapter-image` [PLANNED: OLS-3236], `--agentic-console-image` [PLANNED: OLS-3236].

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-operator** | OLSConfig CR reconciliation, resource generation (ConfigMaps, Secrets, RBAC, NetworkPolicies), deployment creation and health monitoring, external resource watching, restart triggers, status reporting, finalizer cleanup, console plugin activation, image version selection per OCP version. Also deploys agentic alerts adapter and agentic console plugin as reconciled operands. |
| **lightspeed-service** | Reads generated `olsconfig.yaml` at startup. Does not participate in deployment — is deployed by the operator. |
| **lightspeed-console** | Static files served by nginx. ConsolePlugin CR registered by the operator. Does not self-deploy. |
| **lightspeed-agentic-alerts-adapter** | Polls AlertManager, creates AgenticRun CRs. Deployed by the lightspeed-operator. Does not self-deploy. |
| **lightspeed-agentic-console** | Static files served by nginx. ConsolePlugin CR registered by the lightspeed-operator. Does not self-deploy. |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-3236 | Deploy agentic-alerts-adapter and agentic-console-plugin as reconciled operands of the lightspeed-operator. Migrate agentic-console deployment from agentic-operator. |
| OLS-3397 | Remove default resource limits from all operator-managed containers per OpenShift conventions. Keep requests only. CRD still accepts user-specified limits. |
