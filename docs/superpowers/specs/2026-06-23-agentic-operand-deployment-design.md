# Agentic Operand Deployment via lightspeed-operator

Jira: [OLS-3236](https://redhat.atlassian.net/browse/OLS-3236)
Parent: [OCPSTRAT-3095](https://redhat.atlassian.net/browse/OCPSTRAT-3095) — Agentic Lightspeed for OpenShift (TP in OCP 5.0)

## Goal

Deploy the agentic-alerts-adapter and agentic-console-plugin as operator-managed pods in the `openshift-lightspeed` namespace, with full reconciliation lifecycle, health monitoring, and status reporting.

## Architecture Decision: Why lightspeed-operator

### Context

The agentic-alerts-adapter has no operator deployment today — only static manifests in its own repo. The agentic-console-plugin is deployed by the agentic-operator via a one-shot `RunnableFunc` at startup: `CreateOrUpdate` once, no reconciliation loop, no status conditions, no cleanup on deletion.

Two candidates exist for managing these deployments:

1. **lightspeed-operator** — mature deployment infrastructure with two-phase reconciliation, `related_images.json` for disconnected environments, per-component status conditions and pod diagnostics, OLSConfig CRD with deployment configuration (resources, tolerations, nodeSelector, affinity), finalizer-based cleanup, and external resource watching.
2. **lightspeed-agentic-operator** — fire-and-forget `RunnableFunc` pattern with no reconciliation loop, no `related_images.json`, no status reporting, no CRD deployment config, no cleanup.

### Decision

Use the **lightspeed-operator** to deploy both components.

### Rationale

- **No infrastructure duplication**: building reconciliation, image management, status reporting, and lifecycle management in the agentic-operator would replicate everything the lightspeed-operator already has.
- **Consistent operand management**: all operand deployments (app-server, classic console, PostgreSQL, and now alerts-adapter and agentic-console) follow the same reconciliation pattern, status conditions, and CRD configuration surface.
- **Disconnected support**: `related_images.json` and OLM `relatedImages` in the CSV provide air-gapped image resolution. The agentic-operator has no equivalent.
- **Production-grade lifecycle**: health checks, pod diagnostics, restart triggers, and finalizer cleanup come for free by plugging into the existing two-phase reconciliation.
- **Bundle coherence**: the lightspeed-operator OLM bundle already contains both controllers (lightspeed-operator and agentic-operator). Having the lightspeed-operator manage all operand deployments centralizes the deployment surface in one controller.

### Consequences

- The agentic-operator no longer deploys any operands directly. Its `controller/console/` package and `--agentic-console-image` flag are removed. It focuses solely on reconciling `Proposal` CRs, managing the `AgenticOLSConfig` kill switch, and bootstrapping sandbox resources.
- The lightspeed-operator gains two new component packages and two new status conditions, increasing its reconciliation scope.
- The lightspeed-operator's RBAC expands to include permissions for creating alerts-adapter resources (ClusterRole, ClusterRoleBinding for `agentic.openshift.io/proposals`).

## Components and Resources

Everything deploys in `openshift-lightspeed` (the operator's namespace). Both components follow the existing pattern: Phase 1 (RBAC, NetworkPolicy — continue-on-error) → Phase 2 (Deployment + health check — fail-fast).

### Alerts Adapter

New `internal/controller/alertsadapter/` package.

| Resource | Name | Scope | Notes |
|---|---|---|---|
| Deployment | `lightspeed-agentic-alerts-adapter` | Namespace | 1 replica, `ALERTMANAGER_URL` env hardcoded to `https://alertmanager-main.openshift-monitoring.svc:9094` |
| ServiceAccount | `lightspeed-agentic-alerts-adapter` | Namespace | |
| ClusterRole | `lightspeed-agentic-alerts-adapter` | Cluster | `agentic.openshift.io/proposals`: create, list, get |
| ClusterRoleBinding | `lightspeed-agentic-alerts-adapter` | Cluster | Binds SA → ClusterRole |
| RoleBinding | `lightspeed-agentic-alerts-adapter-alertmanager` | `openshift-monitoring` | Binds SA to `monitoring-alertmanager-view` Role. Cross-namespace — `CreateOrUpdate` + explicit finalizer cleanup |
| NetworkPolicy | `lightspeed-agentic-alerts-adapter` | Namespace | |
| Status condition | `AlertsAdapterReady` | — | Deployment health check |

### Agentic Console

New `internal/controller/agenticconsole/` package.

| Resource | Name | Scope | Notes |
|---|---|---|---|
| Deployment | `lightspeed-agentic-console-plugin` | Namespace | 1 replica, nginx with TLS via service-ca cert |
| ServiceAccount | `lightspeed-agentic-console-plugin` | Namespace | |
| Service | `lightspeed-agentic-console-plugin` | Namespace | Port 9443, `service.beta.openshift.io/serving-cert-secret-name` annotation |
| ConfigMap | `lightspeed-agentic-console-plugin` | Namespace | nginx.conf |
| ConsolePlugin | `lightspeed-agentic-console-plugin` | Cluster | Registers plugin with OpenShift Console CR |
| NetworkPolicy | `lightspeed-agentic-console-plugin` | Namespace | |
| Status condition | `AgenticConsolePluginReady` | — | Deployment health check |

### Cross-Namespace Resources

Two resources live outside `openshift-lightspeed`:

1. **RoleBinding in `openshift-monitoring`** — alerts-adapter SA → `monitoring-alertmanager-view` Role for AlertManager access.
2. **ConsolePlugin CR** (cluster-scoped) — registers agentic-console with the OpenShift Console CR.

Both use `CreateOrUpdate` and explicit cleanup in the finalizer path, following the same pattern the existing classic console plugin uses for Console CR activation.

## Reconciliation Integration

Both components slot into the existing two-phase reconciliation in `olsconfig_controller.go`.

### Phase 1 — Independent Resources

Added to `reconcileIndependentResources`:

```
existing:
  - console UI resources
  - postgres resources
  - application server resources
added:
  - alerts adapter resources  (SA, ClusterRole, ClusterRoleBinding, RoleBinding, NetworkPolicy)
  - agentic console resources (SA, ConfigMap, NetworkPolicy)
```

### Phase 2 — Deployments and Status

Added to `reconcileDeploymentsAndStatus`:

```
existing:
  - console UI deployment       → ConsolePluginReady
  - postgres deployment         → CacheReady
  - application server deploy   → ApiReady
added:
  - alerts adapter deployment   → AlertsAdapterReady
  - agentic console deployment  → AgenticConsolePluginReady
    (also: Service, ConsolePlugin CR, Console CR activation)
```

### Status Conditions

`OverallStatus` becomes `Ready` only when all five conditions are `True`.

New condition types in `utils/types.go`:

```go
TypeAlertsAdapterReady        = "AlertsAdapterReady"
TypeAgenticConsolePluginReady = "AgenticConsolePluginReady"
```

### Deployment Constants

New constants in `utils/constants.go`:

```go
AlertsAdapterDeploymentName  = "lightspeed-agentic-alerts-adapter"
AgenticConsoleDeploymentName = "lightspeed-agentic-console-plugin"
```

### Finalizer Cleanup

Added to the existing finalizer sequence:

1. Remove agentic console plugin from Console CR (same pattern as classic console)
2. Delete agentic ConsolePlugin CR
3. Delete alerts-adapter RoleBinding in `openshift-monitoring`
4. Remaining owned resources cleaned up via OwnerReference listing (existing logic)

### Watches

No new watches needed. Both Deployments are owned resources — `Owns(&appsv1.Deployment{})` is already registered, so changes trigger reconciliation automatically.

## Image Management

### Defaults

All agentic images use `:main` tags as defaults until Konflux onboarding is complete and productized images with SHA digests are available.

Constants in `utils/constants.go`:

```go
AlertsAdapterImageDefault  = "quay.io/openshift-lightspeed/lightspeed-agentic-alerts-adapter:main"
AgenticConsoleImageDefault = "quay.io/openshift-lightspeed/lightspeed-agentic-console-plugin:main"
AgenticSandboxImageDefault = "quay.io/openshift-lightspeed/lightspeed-agentic-sandbox:main"
```

After Konflux onboarding, these move to `related_images.json` with SHA digests and the constants switch to `relatedimages.GetDefaultImage()`.

### CLI Flags

lightspeed-operator deployment:

```
--alerts-adapter-image    (default: AlertsAdapterImageDefault)
--agentic-console-image   (default: AgenticConsoleImageDefault)
```

agentic-operator deployment (unchanged, but default now comes from lightspeed-operator constants):

```
--agentic-sandbox-image   (default: AgenticSandboxImageDefault)
```

The sandbox image is not deployed by the lightspeed-operator. The default is defined in lightspeed-operator constants and passed to the agentic-operator's deployment args in the CSV. The agentic-operator uses it for sandbox pod provisioning.

### CSV Changes

In `bundle/manifests/lightspeed-operator.clusterserviceversion.yaml`:

- Add `--alerts-adapter-image` and `--agentic-console-image` to lightspeed-operator deployment args
- Add both images to CSV `relatedImages` section (for disconnected/air-gapped)
- Remove `--agentic-console-image` from agentic-operator deployment args

### Konflux Onboarding

- Onboard `lightspeed-agentic-alerts-adapter` repo to Konflux (tracked by OBSINTA-1365)
- Once productized images exist, update `related_images.json` and switch constants to `relatedimages.GetDefaultImage()`

## CRD Changes

### OLSConfig Deployment Config

`spec.ols.deployment` gains two new fields:

| Field | JSON key | Go type | Notes |
|---|---|---|---|
| `spec.ols.deployment.alertsAdapter` | `alertsAdapter` | `Config` | resources, tolerations, nodeSelector, affinity, topologySpreadConstraints. Replicas forced to 1 |
| `spec.ols.deployment.agenticConsole` | `agenticConsole` | `Config` | Same shape. Replicas forced to 1 |

Both use the existing `Config` struct — no new types needed.

### RBAC

The lightspeed-operator's CSV `clusterPermissions` needs:

- ClusterRole/ClusterRoleBinding CRUD for the alerts-adapter's `agentic.openshift.io/proposals` access
- RoleBinding CRUD in `openshift-monitoring` for AlertManager access
- ConsolePlugin CRUD already exists (reused from classic console)

## Migration from Agentic-Operator

### Removed from agentic-operator

1. `controller/console/` package (reconciler.go, reconciler_test.go)
2. `EnsureAgenticConsole` RunnableFunc registration in `controller/setup.go`
3. `AgenticConsoleImage` from `controller.Options` struct
4. `--agentic-console-image` flag from `cmd/main.go`
5. Agentic-console image from agentic-operator deployment args in CSV

### Unchanged in agentic-operator

- Proposal controller — reconciles `Proposal` CRs
- `AgenticOLSConfig` controller — kill switch / suspension
- Sandbox bootstrap RunnableFunc — ensures `SandboxTemplate` resources
- CLI (`oc-agentic`)
- API types (`api/v1alpha1/`) — still consumed by alerts-adapter and lightspeed-operator
- `--agentic-sandbox-image` flag — stays, overrides the default

### Upgrade Path

On operator upgrade, the lightspeed-operator calls `CreateOrUpdate` on the agentic console resources that previously existed (created by the old agentic-operator). Since both use the same resource names (`lightspeed-agentic-console-plugin`), the lightspeed-operator adopts them in place. No deletion/recreation needed.

The alerts-adapter is net-new — no migration concern.

Both controllers are upgraded atomically in a single CSV update, so there is no window where both the old agentic-operator and the new lightspeed-operator try to manage the same resources.

## Affected Repositories

| Repo | Changes |
|---|---|
| **lightspeed-operator** | New `alertsadapter/` and `agenticconsole/` controller packages, CRD deployment config fields, image constants, CLI flags, CSV changes, finalizer additions, status conditions |
| **lightspeed-agentic-operator** | Remove `controller/console/` package, remove `--agentic-console-image` flag, remove console RunnableFunc |
| **lightspeed-agentic-alerts-adapter** | Konflux onboarding (OBSINTA-1365). No code changes — the operator deploys the existing container image |

## Spec Updates Required

After implementation, update these spec files:

| File | Update |
|---|---|
| Parent `what/deployment-lifecycle.md` | Add alerts-adapter and agentic-console to the deployment flow, Phase 1/2 steps, status conditions, finalizer cleanup |
| Parent `how/repo-map.md` | Add alerts-adapter deployment and agentic-console deployment rows under Classic OLS — Operator |
| Operator `what/reconciliation.md` | Add new Phase 1 and Phase 2 steps |
| Operator `what/crd-api.md` | Add `spec.ols.deployment.alertsAdapter` and `spec.ols.deployment.agenticConsole` fields |
| Operator `what/bundle-composition.md` | Update CSV changes, image references, and flag ownership |
| Agentic-operator `what/system-overview.md` | Remove console plugin from component inventory |
