# Deployment Lifecycle

The Kubernetes operator deploys and manages the core OpenShift Lightspeed components from a single `OLSConfig` custom resource.

**On-demand multicluster [PLANNED: OLS-4665]:** the v2 bundle also installs hub APIs and static ServiceAccount/RBAC, but no hub Deployment. Creating the singleton HubConfig activates an OLS-operator-managed hub operand; no OLSConfig activation property is introduced. Deleting HubConfig drains workflows and decommissions the fleet before runtime removal. This is a separate protected lifecycle, not the immediate best-effort OLSConfig cleanup below. See [multicluster operations](multicluster-ops.md#on-demand-activation-and-shutdown-planned-ols-4665), [ADR 0046](../decisions/0046-hubconfig-driven-multicluster-lifecycle.md), and the [design spec](../../../docs/superpowers/specs/2026-10-29-OLS-4665-on-demand-multicluster-design.md).

**Unified bundle and runtime gating (target after catalog cutover):** one OLM bundle installs both controllers and the complete CRD/RBAC set on supported OCP 4.x and 5.x clusters; older catalog history may still contain Classic-only bundles. The operator reads the `Version`/`ClusterVersion` resource and derives three states: **Enabled** for a matching completed OCP 5.0+ version, **Disabled** for a matching completed version earlier than 5.0, and **Unknown** when the resource is unreadable or does not establish a matching completed version. Enabled permits configured Classic-side Agentic console/adapter operands and handoff; these do not check for `AgenticOLSConfig`. AgenticRun workflow execution separately requires explicit creation of an unsuspended `AgenticOLSConfig` and a validated agentic-controller gate. Disabled prevents new Agentic operands and leaves any existing Agentic operands and Agentic CA Secrets untouched. Under Unknown, the operator also performs no Agentic operand/CA-secret mutations, preserves Agentic status, and requeues without claiming `UnsupportedOCPVersion`. Only an Enabled gate may run version-dependent Agentic reconciliation or explicit-disable cleanup; explicit OLSConfig deletion has separate finalizer cleanup. See decision `decisions/0042-unified-olm-bundle-runtime-gating.md`.

## End-to-End Flow

### CR Creation

1. A cluster admin creates a cluster-scoped `OLSConfig` singleton named "cluster" with LLM providers, RAG indexes, MCP servers, and deployment configuration.

### Reconciliation

2. The operator handles the OLSConfig finalizer first, independently of ClusterVersion, so explicit deletion cleanup is not blocked by an unreadable Version CR. For normal reconciliation, it then reads the Version CR once and uses that snapshot throughout. Disabled does not introduce Agentic operands and leaves existing Agentic resources and CA Secrets untouched. In Unknown, it likewise preserves Agentic resources/status and requeues. Classic reconciliation may continue while the gate is Unknown. On first reconcile, it adds the finalizer (`ols.openshift.io/finalizer`) and returns immediately.
3. On subsequent reconciles, the operator validates external references: LLM credential secrets, custom TLS secrets, proxy CA certificates.
4. The operator annotates user-provided external resources (secrets, configmaps) with `ols.openshift.io/watcher: cluster` to enable change watching.

### Phase 1 — Independent Resources (continue-on-error)

5. The operator generates ConfigMaps: `olsconfig` (from CR spec), system prompt override, MCP config, agentic console nginx config. Agentic-specific resources are reconciled only when the Version gate is Enabled; Disabled and Unknown skip their create/update/cleanup paths.
6. The operator creates or updates Secrets: LLM credentials (from provider `credentialsSecretRef`), custom TLS (from `tlsConfig.keyCertSecretRef`). Agentic CA Secrets are created/updated/deleted only when Enabled (including explicit component opt-out cleanup), and are left untouched in Disabled and Unknown.
7. The operator creates ServiceAccounts, Roles, RoleBindings for console, PostgreSQL, app server, alerts adapter, and agentic console, subject to the same Agentic gate.
7a. For the alerts adapter: ServiceAccount, ClusterRole (`agentic.openshift.io/agenticruns`: create, list, get), ClusterRoleBinding, RoleBinding in `openshift-monitoring` (binds SA to `monitoring-alertmanager-view`).
7b. For the agentic console: ServiceAccount.
8. The operator creates NetworkPolicies for all reconciled components; Agentic NetworkPolicies are created only when the Version gate is Enabled.

### Phase 2 — Deployments (with health checks)

9. **Console UI**: Single-replica nginx deployment. The operator uses a single console image regardless of OCP minor version. ConsolePlugin CR created and activated in the Console CR.
10. **PostgreSQL**: Single-replica database deployment. TLS certificates provisioned via the service-ca operator.
11. **App Server**: FastAPI application deployment with:
    - [PLANNED: OLS-3697] RHOKP standalone Deployment/Service (`lightspeed-rhokp`) — serves OKP content via Solr HTTPS on port 8443; requires ~75 GiB EmptyDir. Reconciled before app-server. Not deployed when `byokRAGOnly` is true.
    - Classic data collector sidecar (if feedback/transcripts enabled and telemetry secret exists)
    - OpenShift MCP server sidecar (if introspection enabled)
    - RHOKP wait init container (when `!byokRAGOnly`): polls RHOKP Solr ping endpoint until it responds (~360s timeout), ensuring the app-server does not start until RHOKP is reachable. Follows the same pattern as the PostgreSQL wait init container.
    - OpenShift MCP server standalone Deployment/Service (if introspection enabled)
    - BYOK RAG init containers (copy customer index content from OCI image to shared volume, when `spec.ols.rag` configured)
11a. **Alerts Adapter** (when the Version gate is Enabled and configured): Single-replica Go deployment. Polls AlertManager for firing alerts and creates `AgenticRun` CRs. `ALERTMANAGER_URL` env hardcoded to `https://alertmanager-main.openshift-monitoring.svc:9094`. Status condition: `AlertsAdapterReady`.
11b. **Agentic Console** (when the Version gate is Enabled and an image is configured): Single-replica nginx deployment with TLS via service-ca cert. ConsolePlugin CR created and activated in the Console CR alongside the classic console plugin. Status condition: `AgenticConsolePluginReady`.

### Resource Conventions [OLS-3397]

11c. All operator-managed container defaults follow the [OpenShift resource conventions](https://github.com/openshift/enhancements/blob/master/CONVENTIONS.md#resources-and-limits): defaults declare CPU and memory requests only, and do not set resource limits. This applies to all containers across all deployments (Console UI, PostgreSQL, App Server and its sidecars, standalone RHOKP, standalone MCP). Users may override via the CRD to set limits if their environment requires it. [PLANNED: OLS-3697] The RHOKP standalone Deployment's ~75 GiB EmptyDir sizeLimit is unaffected by this convention.

11d. [PLANNED: OLS-4246] **Agentic data collection:** The planned first stage writes native OTLP trace-batch JSONL to `/var/lib/lightspeed-data/otel/traces.jsonl` via FileExporter and a 500Mi pod-local `emptyDir` mounted read-write only in Collector. The sole collection gate is `transcriptsDisabled`: false or unset enables the local branch; true disables it. No telemetry credentials or additional OCP-version gate apply to local files. This does not expand the OCP ≥ 5.0 Agentic runtime support boundary defined by ADR 0042; Agentic APIs and controller infrastructure may be installed on OCP 4.x but Agentic work remains inactive. The first stage adds no Agentic Dataverse sidecar; the Classic app-server sidecar remains unchanged. Later operator wiring is planned to run the existing exporter in `data_mode: otel` against rotated direct-child backups, with read-only input and a writable ledger outside it. Producer requirements remain in [the canonical collection contract](agentic-data-collection.md). The FileExporter-capable Collector image and compatible operator configuration must ship together.

### External Resource Watching

12. The operator watches annotated external resources (secrets, configmaps) for data changes.
13. On change, the operator triggers a pod restart by updating the `ols.openshift.io/force-reload` annotation on the pod template with an RFC3339Nano timestamp.
13a. **Credential hot-reload exception (OLS-3450):** When `spec.ols.credentialHotReload` is `true`, LLM credential secrets are **not annotated** with `ols.openshift.io/watcher: cluster` (and existing annotations are removed). The watcher never fires for these secrets, so no pod restart occurs on credential rotation. The service re-reads credentials from disk on each request instead. Non-LLM secrets (TLS, MCP headers, system) are always annotated and always restart. Changing `credentialsSecretRef.name` in the CR still triggers a restart (volume mount change).
14. System resources are always watched: pull secret (`openshift-config/pull-secret`), service-ca certs, kube-root-ca.

### Status Reporting

15. The operator reports `OverallStatus` (Ready/NotReady) and condition types: `ApiReady`, `CacheReady`, `ConsolePluginReady`, `AlertsAdapterReady` [PLANNED: OLS-3236], `AgenticConsolePluginReady` [PLANNED: OLS-3236], `OtelCollectorReady`, `MCPServerReady`, `ResourceReconciliation`. In Unknown, it preserves existing Agentic conditions and does not emit `UnsupportedOCPVersion` solely because the Version CR could not establish a completed release.
16. On pod failures, the operator includes diagnostic info: container reason, message, exit code.

### Cleanup on Deletion

17. The operator removes the console plugin from the Console CR.
18. The operator deletes the ConsolePlugin CR.
18a. The operator removes the agentic console plugin from the Console CR.
18b. The operator deletes the agentic ConsolePlugin CR.
18c. The operator deletes the alerts-adapter RoleBinding in `openshift-monitoring`, ClusterRoleBinding, and ClusterRole.
19. The operator lists and deletes all owned resources (by OwnerReference).
20. The operator removes the finalizer, even if cleanup partially fails. This explicit OLSConfig deletion cleanup runs before version gating and proceeds even when the Version CR is unreadable.

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

### TLS Certificate Verification

The service verifies TLS certificates for all outbound LLM provider connections. Two paths exist:

1. **No TLS security profile configured** — the service uses Python's `ssl.create_default_context()`, which enables both certificate chain and hostname verification by default. When a custom certificate store is configured (`certificates_store`), the CA bundle is loaded into the context without disabling hostname checks.
2. **TLS security profile configured** — the operator propagates the profile (ciphers, minimum TLS version) from the `OLSConfig` CR into `olsconfig.yaml`. The service constructs an `ssl.SSLContext` with the specified constraints and hostname verification enabled.

Both paths enforce hostname verification. Disabling `check_hostname` is not permitted — connections to LLM providers must validate that the server certificate matches the requested host.

### Restart Trigger

When an external resource changes, the operator sets `ols.openshift.io/force-reload` on the pod template to an RFC3339Nano timestamp, causing a rolling update. When `spec.ols.credentialHotReload` is enabled, LLM credential secrets are excluded from this mechanism — the service handles credential freshness via per-request file re-reads (OLS-3450).

### Operator Image Flags

The operator accepts image overrides at startup: `--service-image`, `--console-image`, `--postgres-image`, `--openshift-mcp-server-image`, `--dataverse-exporter-image`, `--rhokp-image` [used for standalone RHOKP Deployment, OLS-3697], `--alerts-adapter-image` [PLANNED: OLS-3236], `--agentic-console-image` [PLANNED: OLS-3236].

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-operator** | OLSConfig CR reconciliation, resource generation (ConfigMaps, Secrets, RBAC, NetworkPolicies), deployment creation and health monitoring, external resource watching, restart triggers, status reporting, finalizer cleanup, console plugin activation, and image version selection per OCP version. Also deploys agentic alerts adapter and agentic console plugin as reconciled operands; the OLS-4246 first-stage Collector file branch is proposed, with Dataverse OTel consumer mount/sidecar wiring planned under `agentic-data-collection.md`. |
| **lightspeed-service** | Reads generated `olsconfig.yaml` at startup. Does not participate in deployment — is deployed by the operator. |
| **lightspeed-console** | Static files served by nginx. ConsolePlugin CR registered by the operator. Does not self-deploy. |
| **lightspeed-agentic-alerts-adapter** | Polls AlertManager, creates AgenticRun CRs. Deployed by the lightspeed-operator. Does not self-deploy. |
| **lightspeed-agentic-console** | Static files served by nginx. ConsolePlugin CR registered by the lightspeed-operator. Does not self-deploy. |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-3236 | Deploy agentic-alerts-adapter and agentic-console-plugin as reconciled operands of the lightspeed-operator. Migrate agentic-console deployment from agentic-operator. |
| OLS-3397 | Remove default resource limits from all operator-managed containers per OpenShift conventions. Keep requests only. CRD still accepts user-specified limits. |
| OLS-3799 | Add wait-for-rhokp init container to app-server deployment (when `!byokRAGOnly`) to block startup until RHOKP Solr is reachable. Service-side: replace `@cached_property` with lazy init + unlimited retry for `SolrHybridSearch` client. |
| OLS-3697 | RHOKP standalone HTTPS cutover — sidecar replaced by `lightspeed-rhokp` Deployment/Service. ServiceMonitors added for RHOKP and MCP. |
| OLS-4007 | Consolidate Classic and Agentic into one OLM bundle. AgenticRun execution requires explicit creation of an unsuspended `AgenticOLSConfig` and a completed supported OCP version; Classic-side configured operands use the version gate but not the AgenticOLSConfig. See decision 0042. |
| OLS-4348 | Define product strategy, validation gates, and approval criteria for retiring the Classic-only v1 bundle. |
| OLS-4349 | Build one unified Classic + Agentic bundle and gate agentic runtime behavior safely. |
| OLS-4350 | Clean up AgenticRun workloads, finalizers, and handoff state idempotently on explicit Agentic disable; version-gate Disabled/Unknown states preserve existing resources. |
| OLS-4351 | Validate fresh installs and supported v1/unified migrations across OCP 4.x and 5.0, including upgrade and downgrade paths. |
| OLS-4352 | Migrate FBC/Konflux release paths to the unified bundle, verify identical bundle digests across supported catalogs, and retire Classic v1 after the validation gates pass. |
| OLS-3450 | Credential hot-reload: opt-in `spec.ols.credentialHotReload` flag skips LLM secret watching/restart; service re-reads credentials per request. See design spec `docs/superpowers/specs/2026-09-01-credential-hot-reload-design.md`. |
| OLS-4246 | Staged Agentic trace-only collection: first a transcript-opt-out-gated local FileExporter trace-batch JSONL path with no uploader; later a Dataverse `data_mode: otel` rotated-file consumer and operator source/ledger wiring, with final wiring planned. Producer requirements are in [the canonical collection contract](agentic-data-collection.md). |
| OLS-2991 | OCP 4.23 release artifacts — add the per-version FBC catalog and staging/prod ReleasePlans, consuming the unified bundle digest (OLS-4352). |
| OLS-2992 | OCP 5.0 release artifacts — add the per-version FBC catalog and staging/prod ReleasePlans using the same unified bundle digest, subject to the OLS-4351/OLS-4352 migration gates. |
